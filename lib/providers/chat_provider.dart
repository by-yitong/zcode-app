import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/app_logger.dart';
import '../core/notifications/notification_service.dart';
import '../core/services/device_info_service.dart';
import '../core/relay/relay_client.dart';
import '../core/relay/relay_events.dart';
import '../core/relay/relay_protocol.dart';
import '../core/relay/rpc_codec.dart';
import '../data/models/workspace.dart';
import 'app_providers.dart';

// ── 进程内消息缓存 ──
// 会话 notifier 是 autoDispose: 列表↔聊天页往返即销毁重建 + 重新订阅拉取。
// 内存缓存让往返秒开; 不落盘 — 无 jsonEncode/旧格式兼容/Hive 依赖, 进程
// 重启自然清空 (代价: 冷启动首屏多等一拍网络, 可接受)。LRU 上限防内存膨胀。
const int _kMemCacheMaxTasks = 12;
final LinkedHashMap<String, List<DisplayMessage>> _memMsgCache =
    LinkedHashMap();

/// 只缓存稳定 (非流式) 消息: 流式消息每帧在变, 存了立刻过期。
/// DisplayMessage 不可变, 直接持 List 引用即快照, 零拷贝零序列化。
void _memCacheSave(String taskId, List<DisplayMessage> messages) {
  final stable = messages.where((m) => !m.isStreaming).toList(growable: false);
  if (stable.isEmpty) return;
  _memMsgCache.remove(taskId);
  _memMsgCache[taskId] = stable;
  while (_memMsgCache.length > _kMemCacheMaxTasks) {
    _memMsgCache.remove(_memMsgCache.keys.first);
  }
}

List<DisplayMessage> _memCacheLoad(String taskId) {
  final m = _memMsgCache.remove(taskId);
  if (m == null) return const [];
  _memMsgCache[taskId] = m; // touch (LRU)
  return m;
}

// ================================================================
// 对话状态管理 (实测 2026-06-15)
//
// 流程:
// 1. init: 加载历史 (getTaskSnapshot) + 订阅 session 事件
// 2. sendMessage: 入队 (enqueueTaskCommand), 等流式回复
// 3. session.event: tool.updated = AI 正在工作; 文本流 = 追加到 AI 消息
// ================================================================

/// 对话引用 (taskId 可空 = 新会话, workspacePath 必填)
class ChatRef {
  /// 任务 ID。null 表示新会话 (首发消息时调 createSession 创建)。
  final String? taskId;
  final String workspacePath;

  /// 工作区标识 (远程工作区形如 remote:ssh:host:22:user:path, 3.7.7 实测
  /// createSession/subscribe 均需携带)。null 时服务端按 path 解析。
  final String? workspaceIdentity;

  const ChatRef({
    this.taskId,
    required this.workspacePath,
    this.workspaceIdentity,
  });

  @override
  bool operator ==(Object other) =>
      other is ChatRef &&
      other.taskId == taskId &&
      other.workspacePath == workspacePath &&
      other.workspaceIdentity == workspaceIdentity;

  @override
  int get hashCode => Object.hash(taskId, workspacePath, workspaceIdentity);
}

/// AI 工具调用活动 (来自 tool.updated 事件)
class ToolActivity {
  final String toolCallId;
  final String toolName;
  final String status; // 'progress' | 'done' | 'error' | ... (payload.kind)
  final int? elapsedMs;
  /// 工具输入参数 (来自 payload.input, 可能含 command/path/query 等)
  final Map<String, dynamic>? input;
  /// 工具执行结果文本 (来自 payload.result 或 payload.output)
  final String? result;

  const ToolActivity({
    required this.toolCallId,
    required this.toolName,
    required this.status,
    this.elapsedMs,
    this.input,
    this.result,
  });

  /// 进行中判定 (含 V4 状态): inputStreaming=工具参数流式写入中,
  /// pendingApproval=等待用户批准 — 两者期间过程都不应收起。
  bool get isRunning =>
      status == 'scheduled' ||
      status == 'started' ||
      status == 'progress' ||
      status == 'running' ||
      status == 'inputStreaming' ||
      status == 'pendingApproval';
}

/// 计划项状态 (host bundle 实测 2026-06-19, todo.status 值)
enum TodoStatus { pending, inProgress, completed }

/// 计划项优先级 (host bundle 实测)
enum TodoPriority { high, medium, low }

/// 计划项 — AI 用 TodoWrite 工具产出的任务清单条目
///
/// wire 字段 (host bundle Zod schema, 规格 §11.3):
///   {content: string, status: "pending"|"in_progress"|"completed", priority: "high"|"medium"|"low"}
/// ⚠️ 字段名是 content 不是 title! 无 id 字段! 有 priority!
/// (之前代码用 title/id 是错的, 已订正)
class PlanItem {
  final String content;
  final TodoStatus status;
  final TodoPriority priority;

  const PlanItem({
    required this.content,
    this.status = TodoStatus.pending,
    this.priority = TodoPriority.medium,
  });

  /// 从单个 todo JSON 解析 (wire 字段名: content/status/priority)
  factory PlanItem.fromJson(Map<String, dynamic> json) {
    final s = json['status'] as String? ?? 'pending';
    // 兼容旧 title 字段 (历史快照可能有)
    final text = json['content'] as String? ?? json['title'] as String? ?? '';
    return PlanItem(
      content: text,
      status: switch (s) {
        'completed' => TodoStatus.completed,
        'in_progress' || 'inProgress' => TodoStatus.inProgress,
        _ => TodoStatus.pending,
      },
      priority: switch (json['priority'] as String?) {
        'high' => TodoPriority.high,
        'low' => TodoPriority.low,
        _ => TodoPriority.medium,
      },
    );
  }

  /// 兼容旧代码的 title getter
  String get title => content;
}

/// 权限选项 (host bundle 实测 2026-06-19, 规格 §11.2.3)
///
/// wire: {optionId, kind, name, description?, response:{decision, reason?}}
class PermissionOption {
  final String optionId;
  final String kind;
  final String name;
  final String? description;
  final String decision; // "allow" | "deny" | "escalate" | "modify"
  final Map<String, dynamic> fullResponse; // 完整 response (含 reason, permissionUpdates)

  const PermissionOption({
    required this.optionId,
    required this.kind,
    required this.name,
    this.description,
    this.decision = 'allow',
    this.fullResponse = const {},
  });

  /// 规范化 kind — wire 上存在驼峰 (allowOnce) 与下划线 (allow_once) 两种拼写,
  /// 统一成小写无下划线 (allowonce) 供 UI 映射中文标签
  String get normKind => kind.replaceAll('_', '').toLowerCase();

  factory PermissionOption.fromJson(Map<String, dynamic> json) {
    final response = json['response'] as Map<String, dynamic>?;
    return PermissionOption(
      optionId: json['optionId'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      name: json['name'] as String? ?? json['kind'] as String? ?? '',
      description: json['description'] as String?,
      decision: response?['decision'] as String? ?? 'allow',
      // ★ 网页端发完整 response (含 reason, permissionUpdates), 不能只发 decision!
      fullResponse: response ?? {},
    );
  }
}

/// 待确认的工具调用权限 (build/plan 模式下, AI 改文件/跑命令前请求批准)
///
/// wire 实测自 host bundle Zod schema (规格 §11.2.6):
///   {requestId, toolCallId, toolName, reason, riskLevel, input?, options[], requestedAt}
/// ★ options 是结构化的 PermissionOption[], 每个 option 自带 decision!
/// ★ 权限响应用 enqueueTaskCommand(type: respond_permission) + optionId, 不是文本回灌!
class PendingPermission {
  final String id; // = requestId (permissionRequestId)
  final String toolCallId;
  final String toolName;
  final String reason;
  final String riskLevel; // "low" | "medium" | "high" | "critical"
  final String traceId; // ★ permission 自己的 traceId (网页端用它做 runId 发 respond_permission)
  final Map<String, dynamic> input;
  final List<PermissionOption> options;

  const PendingPermission({
    required this.id,
    required this.toolCallId,
    required this.toolName,
    this.reason = '',
    this.riskLevel = 'medium',
    this.traceId = '',
    this.input = const {},
    this.options = const [],
  });

  factory PendingPermission.fromJson(Map<String, dynamic> json) {
    final optsRaw = json['options'] as List<dynamic>? ?? [];
    final requestId = json['requestId'] as String? ??
        json['permissionRequestId'] as String? ?? '';
    return PendingPermission(
      id: requestId,
      toolCallId: json['toolCallId'] as String? ??
          (json['raw'] is Map ? (json['raw'] as Map)['toolCallId'] as String? : null) ?? '',
      toolName: json['toolName'] as String? ??
          json['kind'] as String? ?? '',
      reason: json['reason'] as String? ??
          json['description'] as String? ?? '',
      riskLevel: json['riskLevel'] as String? ?? 'medium',
      // ★ traceId 在 runtime.pendingPermissions 顶层, projection 里没有 (用 toolCallId 兜底)
      traceId: json['traceId'] as String? ?? '',
      input: (json['input'] as Map<String, dynamic>?) ??
          (json['raw'] is Map ? (json['raw'] as Map)['input'] as Map<String, dynamic>? : null) ??
          const {},
      options: optsRaw
          .whereType<Map>()
          .map((e) => PermissionOption.fromJson(Map<String, dynamic>.from(e)))
          .where((o) => o.optionId.isNotEmpty)
          .toList(),
    );
  }
}

/// AskUserQuestion 工具的问题选项
class QuestionOption {
  final String label;
  final String description;

  const QuestionOption({required this.label, this.description = ''});
}

/// AskUserQuestion — AI 向用户提问的结构化数据
///
/// 捕获自真实 session 快照 (sample_init_events.json L3885):
/// tool: "AskUserQuestion", state.input.questions[] 每个:
/// {question, header, multiSelect, options[{label, description}]}
class AskUserQuestion {
  final String callId;
  final String question;
  final String header;
  final bool multiSelect;
  final List<QuestionOption> options;

  const AskUserQuestion({
    required this.callId,
    required this.question,
    this.header = '',
    this.multiSelect = false,
    this.options = const [],
  });

  /// 从 tool.updated 事件的 payload 解析
  factory AskUserQuestion.fromPayload(
      String callId, Map<String, dynamic> payload) {
    // payload 可能是 {input:{questions:[...]}} 或直接含 questions
    final input = payload['input'] as Map<String, dynamic>? ?? payload;
    final questions = input['questions'] as List<dynamic>? ?? [];
    if (questions.isEmpty) {
      return AskUserQuestion(callId: callId, question: '');
    }
    final q = questions.first as Map<String, dynamic>;
    final opts = (q['options'] as List<dynamic>? ?? [])
        .map((e) => QuestionOption(
              label: (e as Map<String, dynamic>)['label'] as String? ?? '',
              description:
                  (e)['description'] as String? ?? '',
            ))
        .where((o) => o.label.isNotEmpty)
        .toList();
    return AskUserQuestion(
      callId: callId,
      question: q['question'] as String? ?? '',
      header: q['header'] as String? ?? '',
      multiSelect: q['multiSelect'] as bool? ?? false,
      options: opts,
    );
  }
}

/// 消息内容的按序片段 — 匹配 web 客户端 parts[] 的逐项渲染。
///
/// 快照数据里 assistant 消息带 parts[] 数组, 每个元素按到达顺序描述一段
/// 内容 (正文 / 思考 / 工具调用)。旧代码把它们拍平到 content/thought/
/// activities 三个独立字段, 渲染时固定顺序 (思考→正文→工具卡)。
///
/// 为了和 web 客户端一致 (思考、正文、工具卡按真实发生顺序交错展示),
/// 这里把 parts[] 原样保留为 [MessagePart] 列表, UI 据此按序渲染。
sealed class MessagePart {
  const MessagePart();
}

/// 正文文本片段 (web part type: "text" / "content")
class TextPart extends MessagePart {
  final String text;
  const TextPart(this.text);
}

/// 思考过程片段 (web part type: "reasoning" / "thought")
class ThoughtPart extends MessagePart {
  final String text;
  /// 思考耗时 (wire: reasoning.durationMs), 完成后才有
  final int? durationMs;
  const ThoughtPart(this.text, {this.durationMs});
}

/// 工具调用片段 (web part type: "tool" / "tool-call")
class ToolPart extends MessagePart {
  final ToolActivity activity;
  const ToolPart(this.activity);
}

/// 步骤分隔片段 (web part type: "step-start" / "step-finish")
/// 多步骤回复的边界标记, UI 渲染为细分隔线
class StepPart extends MessagePart {
  final bool isStart; // true=step-start, false=step-finish
  const StepPart(this.isStart);
}

/// 子代理片段 (V4 `subagent` 行) — 独立的 AgentCard 渲染, 不混入工具合并卡。
///
/// wire 上子代理的内部活动在 [childSessionId] 指向的独立子会话里,
/// 主行流不包含 → [children] 懒加载 (展开时拉子会话行投影, 递归限深 3 层)。
class SubagentPart extends MessagePart {
  final String subagentType; // "Explore" / "Plan" / ...
  final String status; // running | success | failed | cancelled (wire 四态)
  final String summaryText; // 流式追加的摘要
  final String? childSessionId; // 嵌套内容的懒加载句柄
  final String? parentToolCallId; // 关联触发它的 Agent/Task 工具调用
  final String rowIdKey; // 去重/更新键 (subagent_<rowId>)
  final List<MessagePart> children; // 懒加载填充; 子会话内 subagent 行递归嵌套

  const SubagentPart({
    required this.subagentType,
    required this.status,
    required this.summaryText,
    required this.rowIdKey,
    this.childSessionId,
    this.parentToolCallId,
    this.children = const [],
  });

  bool get isRunning => status == 'running';

  SubagentPart copyWith({
    String? status,
    String? summaryText,
    String? childSessionId,
    List<MessagePart>? children,
  }) =>
      SubagentPart(
        subagentType: subagentType,
        status: status ?? this.status,
        summaryText: summaryText ?? this.summaryText,
        childSessionId: childSessionId ?? this.childSessionId,
        parentToolCallId: parentToolCallId,
        rowIdKey: rowIdKey,
        children: children ?? this.children,
      );
}

/// 显示用消息
/// 服务端排队中的消息 (任务运行中发送, state.queue.items)
class QueuedMessage {
  final String id; // queueItemId
  final String text;
  const QueuedMessage({required this.id, required this.text});
}

class DisplayMessage {
  final String id;
  final String role; // 'user' | 'assistant' | 'error' | 'marker'
  final String content;
  final String? thought;
  final String? model;
  final bool isStreaming;
  /// 轮次被打断 (turnHeader.state == completedInterrupted)。
  /// 对齐桌面端: 打断轮次无尾段正文 → 过程整轮展开不折叠。
  final bool interrupted;
  final DateTime createdAt;
  final List<ToolActivity> activities; // AI 调用的工具 (按到达顺序)
  /// 按序片段 (匹配 web 客户端 parts[])。非空时 UI 据此交错渲染,
  /// 否则回退到旧的 content/thought/activities 固定顺序渲染。
  final List<MessagePart> parts;

  // ── 轮次元数据 (turnHeader 行携带, 对齐 ZCode 客户端) ──
  /// 本轮工作时长 (activeMs > endedAt-startedAt)。运行中为 null,
  /// UI 用 [turnStartedAt] 实时跳动显示 "工作中 X"。
  final int? workedMs;
  /// 轮次开始时间 (wire: turnHeader.startedAt)
  final DateTime? turnStartedAt;
  /// 本轮文件变更统计 (wire: turnHeader.fileChanges, 权威来源)
  final V4TurnFileChanges? fileChanges;

  DisplayMessage({
    required this.id,
    required this.role,
    required this.content,
    this.thought,
    this.model,
    this.isStreaming = false,
    this.interrupted = false,
    this.activities = const [],
    this.parts = const [],
    this.workedMs,
    this.turnStartedAt,
    this.fileChanges,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  DisplayMessage copyWith({
    String? content,
    String? thought,
    String? model,
    bool? isStreaming,
    bool? interrupted,
    List<ToolActivity>? activities,
    List<MessagePart>? parts,
    int? workedMs,
    DateTime? turnStartedAt,
    V4TurnFileChanges? fileChanges,
  }) {
    return DisplayMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      thought: thought ?? this.thought,
      model: model ?? this.model,
      isStreaming: isStreaming ?? this.isStreaming,
      interrupted: interrupted ?? this.interrupted,
      activities: activities ?? this.activities,
      parts: parts ?? this.parts,
      workedMs: workedMs ?? this.workedMs,
      turnStartedAt: turnStartedAt ?? this.turnStartedAt,
      fileChanges: fileChanges ?? this.fileChanges,
      createdAt: createdAt,
    );
  }
}

/// 对话状态
class ChatState {
  final List<DisplayMessage> messages;
  final bool isLoadingHistory;
  final bool isResponding;
  final String? error;
  final String? activeTurnId; // 当前轮次 (同一次提问共享)
  // 代理模式: 'build'(确认) | 'yolo'(自动)。
  // 协议实测 (规格 §5.5): 只有这两种。新会话走 createSession.mode;
  // 已有会话可热切换 (zcode-session.setMode)。
  final String mode;
  /// 思考级别: 'max' | 'medium' | 'nothink'
  final String thoughtLevel;
  /// 当前会话的模型 ID (形如 providerId/slug), 来自 snapshot; null=未知。
  /// 供 UI 模型选择器显示真实模型名。
  final String? model;
  /// AI 向用户提问 (AskUserQuestion 工具), 需要用户选择后继续
  final AskUserQuestion? pendingQuestion;
  /// Token 用量 (累计 input/output; AI 回复完成后刷新, 累积保留)
  final ({int input, int output, int max})? tokenUsage;
  /// 当前会话标题 (来自 snapshot.meta.title; 供 UI 顶栏/历史抽屉显示)。
  /// null = 新会话尚未加载历史, UI 可回退到 task.title。
  final String? sessionTitle;
  /// AI 计划清单 (来自 snapshot.runtime.plan[], TodoWrite 工具产出)。
  /// 空列表 = 无计划。随 session 事件实时更新 (pending→in_progress→completed)。
  final List<PlanItem> plan;
  /// 待确认的工具调用 (build 模式下, runtime.pendingPermissions[])。
  /// 非空时 UI 弹确认卡, 用户批准/拒绝后清空对应项。
  final List<PendingPermission> pendingPermissions;
  /// 客户端子态: "计划模式" UI 选项的本地标记。
  /// wire 上 mode 仍为 'build' (后端只认 build/yolo), 仅用于 UI 区分与提示。
  final bool isPlanMode;
  /// AI 提议的计划 (ExitPlanMode 工具触发), 非空时 UI 弹批准/拒绝卡。
  /// 内容用最近 assistant 消息文本兜底 (plan 原文 wire 上 inputOmitted)。
  final String? pendingPlan;
  /// 服务端排队中的消息 (任务运行中发送, state.queue.items)。
  /// 非空时输入框上方显示队列条 (立即/编辑/删除)。
  final List<QueuedMessage> queuedMessages;

  const ChatState({
    this.messages = const [],
    this.isLoadingHistory = false,
    this.isResponding = false,
    this.error,
    this.activeTurnId,
    this.mode = 'build',
    this.thoughtLevel = 'max',
    this.model,
    this.pendingQuestion,
    this.tokenUsage,
    this.sessionTitle,
    this.plan = const [],
    this.pendingPermissions = const [],
    this.isPlanMode = false,
    this.pendingPlan,
    this.queuedMessages = const [],
  });

  ChatState copyWith({
    List<DisplayMessage>? messages,
    bool? isLoadingHistory,
    bool? isResponding,
    String? error,
    String? activeTurnId,
    String? mode,
    String? thoughtLevel,
    String? model,
    AskUserQuestion? pendingQuestion,
    ({int input, int output, int max})? tokenUsage,
    String? sessionTitle,
    List<PlanItem>? plan,
    List<PendingPermission>? pendingPermissions,
    bool? isPlanMode,
    Object? pendingPlan,
    List<QueuedMessage>? queuedMessages,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      isResponding: isResponding ?? this.isResponding,
      error: error,
      activeTurnId: activeTurnId ?? this.activeTurnId,
      mode: mode ?? this.mode,
      thoughtLevel: thoughtLevel ?? this.thoughtLevel,
      model: model ?? this.model,
      pendingQuestion: pendingQuestion ?? this.pendingQuestion,
      tokenUsage: tokenUsage ?? this.tokenUsage,
      sessionTitle: sessionTitle ?? this.sessionTitle,
      // List 字段直接赋值 (允许传空列表清空, 不用 ?? 保留旧值)
      plan: plan ?? this.plan,
      pendingPermissions: pendingPermissions ?? this.pendingPermissions,
      isPlanMode: isPlanMode ?? this.isPlanMode,
      queuedMessages: queuedMessages ?? this.queuedMessages,
      // pendingPlan: sentinel 区分"不传"(保留旧值) 和"传null"(清空)
      pendingPlan: identical(pendingPlan, _clearPendingPlan)
          ? null
          : (pendingPlan is String
              ? pendingPlan
              : this.pendingPlan),
    );
  }
}

/// sentinel: copyWith 传此对象表示"清空 pendingPlan"
const _clearPendingPlan = Object();

/// 对话 Notifier
class ChatNotifier extends StateNotifier<ChatState> {
  final RelayClient _relay;
  final ChatRef _ref;
  final void Function(Task task)? _onSessionCreated;
  final void Function(String taskId, String newTitle)? _onTitleUpdated;
  final String? Function() _preferredModelReader;
  final void Function(String?) _preferredModelSetter;
  final void Function(Set<String>) _mergeDiscovered;
  StreamSubscription<V4Frame>? _frameSub;
  StreamSubscription<bool>? _rpcReadySub;
  int _msgCounter = 0;

  /// 当前 taskId (新会话时为 null, createSession 后赋值)
  String? _taskId;
  bool _creating = false;
  bool _initDone = false;
  bool _initRunning = false; // _init 进行中禁止 resubscribe (会取消 init 的帧监听)

  /// V4 状态: 本地缓存的 rows (按 rowId 索引)。
  /// SplayTreeMap: 按 rowId 升序迭代, 重建时免去每帧 O(n log n) 排序。
  final Map<int, V4Row> _rows = SplayTreeMap();
  String? _v4SubscriptionId;
  String? _v4LogEpoch;
  int _v4Seq = 0;
  int _v4Revision = 0;

  // ── 增量重建: 已完成轮次缓存 + 脏水位 ──
  // 旧轮次的 rows 不可变 (只会在尾部追加/就地更新), 全量重扫纯属浪费。
  /// 轮次缓存: 消息 id → (DisplayMessage, 轮次最大 rowId)。
  /// 只缓存完成态 (isStreaming=false) 的轮次。
  final Map<String, (DisplayMessage, int)> _stableTurns = {};
  /// 自上次重建以来被 delta 触达的最小 rowId (含其所属轮的轮首);
  /// i64 max = 全部干净。低于水位的完成轮直接复用缓存实例。
  int _dirtyFrom = 0x7FFFFFFFFFFFFFFF;
  /// turnId → turnHeader rowId (脏水位定位到轮首, 保证含脏行的轮次必重扫)
  final Map<String, int> _turnHeaderRowIds = {};

  // ── 行日志加载 (网页端模式: conversationRowsRangeV4) ──
  /// 流快照窗口的第一行 id (窗口之前还有更早历史)
  int? _rowsFirstRowId;
  /// 行日志总行数 (totalCount > 已有行数 = 有更早历史可翻)
  int _rowsTotalCount = 0;
  /// 完成时刻元数据补读的防抖 (一轮只补读一次)
  bool _metaRefreshQueued = false;
  /// notifier 是否已销毁
  bool _disposedNotifier = false;
  /// rowsRange 响应标记的 hasMore (更早方向)
  bool _hasMoreOlder = false;
  /// 翻页进行中标志
  bool _loadingOlder = false;
  /// 流首帧快照到达信号 (历史加载等它先渲染尾部窗口)
  Completer<void>? _streamSnapshotDone;

  // ── 流式重建节流 ──
  // delta 帧可高频到达 (文本流式追加), 每帧全量重建 rows→messages
  // 会造成明显卡顿: 这里合并到 ≤8次/秒; 快照/翻页路径仍即时重建。
  Timer? _rebuildDebounce;
  bool _rebuildPending = false;
  int _rebuildCoalesced = 0;
  /// 加载期间已有屏上内容时静默翻页 (见 _loadHistory 头注释)
  bool _silentPagination = false;
  /// isResponding 落 false 的延迟确认 (control patch 闪断防抖, 见 _applyStatePatch)
  Timer? _respondingFallTimer;
  /// 已发出但 row 尚未到达的乐观用户消息文本。
  /// _rebuildMessagesFromRows 从 rows 重建会丢掉乐观消息, 用它补回,
  /// 避免"发送后消息闪没"; 对应 row 到达时清除 (不再依赖 isResponding —
  /// 闪断会把乐观消息和"思考中"占位一起删掉, 列表高度骤变导致视口跳动)。
  String? _pendingUserText;
  /// _pendingUserText 的设置时间: 任务已确认结束但 row 始终未到 (协议异常) 的兜底清除
  DateTime? _pendingUserTextAt;

  // ── 后台通知去重 ──
  /// 已通知过的权限请求 id (permissionId 会在多次 state patch 中重复出现)
  final Set<String> _notifiedPermIds = {};

  /// V4 发送命令并更新 CAS revision
  Future<Map<String, dynamic>> _sendV4Command(
    String commandType, {
    Map<String, dynamic> payload = const {},
    String? sessionId,
  }) async {
    final resp = await _relay.sendConversationCommandV4(
      workspacePath: _ref.workspacePath,
      workspaceIdentity: _ref.workspaceIdentity,
      commandType: commandType,
      payload: payload,
      sessionId: sessionId ?? _taskId,
      baseRevision: _v4Revision > 0 ? _v4Revision : null,
      baseLogEpoch: _v4LogEpoch,
    );
    final rev = resp['revisionAtDecision'];
    if (rev is int && rev > 0) {
      _v4Revision = rev;
    }
    return resp;
  }



  ChatNotifier(
    this._relay,
    this._ref, {
    required String? Function() preferredModelReader,
    required void Function(String?) preferredModelSetter,
    required void Function(Set<String>) mergeDiscovered,
    this._onSessionCreated,
    this._onTitleUpdated,
  })  : _preferredModelReader = preferredModelReader,
        _preferredModelSetter = preferredModelSetter,
        _mergeDiscovered = mergeDiscovered,
        super(const ChatState()) {
    _taskId = _ref.taskId;
    // 已有 taskId: 立即加载历史+订阅; 新会话: 等首发消息
    if (_taskId != null) {
      _init();
    }
    // 监听 RPC ready 变化: bridge degraded → reopen 后重新订阅。
    // 加标志位避免初始化期间触发 (会死循环)。
    // ★ 不看 isResponding: 断连时 turn 进行中 → 重连后没有非 running 的
    //   control patch 到达 (它只在收到 patch 时清), isResponding 会卡在
    //   true → 曾经的 !isResponding 守卫导致重连后永远不再订阅,
    //   会话内容从此不刷新。
    _rpcReadySub = _relay.onRpcReadyChange.listen((ready) {
      if (ready && _taskId != null && _initDone && !_initRunning) {
        appLog.i('[Chat] RPC ready (重连后), 重新订阅 V4 事件流...');
        _frameSub?.cancel();
        _frameSub = null;
        _resubscribe();
      }
    });
  }

  String _newMsgId() => 'local_${DateTime.now().millisecondsSinceEpoch}_${_msgCounter++}';

  /// 是否是新会话 (还没创建)
  bool get isNewChat => _taskId == null;

  /// 切换代理模式
  /// - 新会话 (_taskId==null): 仅更新本地 state, 首发消息 createSession 时带上
  /// V4 切换代理模式 — sendConversationCommandV4(switchCollaborationMode)
  Future<void> setMode(String mode) async {
    const valid = {'build', 'edit', 'yolo', 'plan'};
    if (!valid.contains(mode)) return;
    if (mode == state.mode) return;
    state = state.copyWith(mode: mode);
    if (_taskId == null) return;
    try {
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'switchCollaborationMode',
              sessionId: _taskId,
              baseRevision: _v4Revision,
              baseLogEpoch: _v4LogEpoch,
        // wire zod: payload 平铺 {mode} — 外层再包命令名会报 proto.invalidPayload
        payload: {'mode': mode},
      );
    } catch (e) {
      appLog.w('[Chat] 模式切换失败 ($mode): $e');
      state = state.copyWith(error: '模式切换失败: $e');
    }
  }

  /// V4 切换思考级别 — 合入 switchModelConfig
  Future<void> setThoughtLevel(String level) async {
    if (level != 'max' && level != 'medium' && level != 'nothink') return;
    if (level == state.thoughtLevel) return;
    final prev = state.thoughtLevel;
    state = state.copyWith(thoughtLevel: level);
    if (_taskId == null) return;
    try {
      final modelId = state.model ?? '';
      final parts = modelId.split('/');
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'switchModelConfig',
              sessionId: _taskId,
              baseRevision: _v4Revision,
              baseLogEpoch: _v4LogEpoch,
        // wire zod: payload 平铺 (外层包命令名会被拒)
        payload: {
          'provider': parts.length > 1 ? parts[0] : '',
          'model': parts.length > 1 ? parts[1] : modelId,
          'thought': level,
        },
      );
    } catch (e) {
      appLog.w('[Chat] 思考级别切换失败 ($level): $e');
      state = state.copyWith(thoughtLevel: prev, error: '思考级别切换失败: $e');
    }
  }

  /// V4 压缩对话
  Future<void> compact() async {
    if (_taskId == null) {
      state = state.copyWith(error: '新会话无需压缩');
      return;
    }
    _respondingFallTimer?.cancel();
    _respondingFallTimer = null;
    state = state.copyWith(isResponding: true, error: null);
    try {
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'compact',
              sessionId: _taskId,
              baseRevision: _v4Revision,
              baseLogEpoch: _v4LogEpoch,
      );
    } catch (e) {
      appLog.w('[Chat] 压缩失败: $e');
      state = state.copyWith(isResponding: false, error: '压缩失败: $e');
    }
  }

  /// 立即发送排队项 (sendQueuedNow — 相当于引导, 立即打断注入)
  ///
  /// 注意不带 baseRevision/baseLogEpoch: 队列变化会推进服务端 revision,
  /// 本地值滞后时命令会被 proto.staleRevision 静默拒绝 (实测); 网页端
  /// 命令信封也不带这两个字段。
  Future<void> sendQueuedNow(String queueItemId) async {
    if (_taskId == null) return;
    try {
      final resp = await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'sendQueuedNow',
        sessionId: _taskId,
        payload: {'queueItemId': queueItemId},
        // CAS 命令必须带 (服务端校验: "CAS commands require baseRevision
        // and baseLogEpoch"); 本地 revision 由增量实时推进 (见 _trackRevision)
        baseRevision: _v4Revision,
        baseLogEpoch: _v4LogEpoch,
      );
      final rad = (resp['revisionAtDecision'] as num?)?.toInt();
      if (rad != null) _trackRevision(rad);
      final status = resp['status'];
      if (status != 'accepted') {
        appLog.w('[Chat] 立即发送被拒绝: status=$status '
            'reason=${resp['reasonCode']}');
        state = state.copyWith(error: '立即发送被拒绝 ($status)');
      }
    } catch (e) {
      appLog.w('[Chat] 立即发送排队项失败: $e');
      state = state.copyWith(error: '立即发送失败: $e');
    }
  }

  /// 删除排队项 (不带 baseRevision, 同上)
  Future<void> removeQueuedItem(String queueItemId) async {
    if (_taskId == null) return;
    try {
      final resp = await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'deleteQueueItem',
        sessionId: _taskId,
        payload: {'queueItemId': queueItemId},
        baseRevision: _v4Revision,
        baseLogEpoch: _v4LogEpoch,
      );
      final rad = (resp['revisionAtDecision'] as num?)?.toInt();
      if (rad != null) _trackRevision(rad);
      final status = resp['status'];
      if (status != 'accepted') {
        appLog.w('[Chat] 删除排队项被拒绝: status=$status '
            'reason=${resp['reasonCode']}');
        state = state.copyWith(error: '删除排队项被拒绝 ($status)');
      }
    } catch (e) {
      appLog.w('[Chat] 删除排队项失败: $e');
      state = state.copyWith(error: '删除排队项失败: $e');
    }
  }

  /// V4 切换模型
  Future<void> setModel(String modelId) async {
    final cur = _preferredModelReader();
    if (modelId == cur) return;
    _preferredModelSetter(modelId);
    if (_taskId == null) return;
    try {
      final parts = modelId.split('/');
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'switchModelConfig',
              sessionId: _taskId,
              baseRevision: _v4Revision,
              baseLogEpoch: _v4LogEpoch,
        // wire zod: payload 平铺 (外层包命令名会被拒)
        payload: {
          'provider': parts.length > 1 ? parts[0] : '',
          'model': parts.length > 1 ? parts[1] : modelId,
          'thought': state.thoughtLevel,
        },
      );
    } catch (e) {
      appLog.w('[Chat] 模型切换失败 ($modelId): $e');
      state = state.copyWith(error: '模型切换失败: $e');
    }
  }

  Future<void> _init() async {
    state = state.copyWith(isLoadingHistory: true);
    if (_taskId != null) {
      try {
        final cached = _memCacheLoad(_taskId!);
        if (cached.isNotEmpty && state.messages.isEmpty) {
          state = state.copyWith(messages: cached);
        }
      } catch (e) {
        appLog.w('[Chat] 缓存消息加载失败: $e');
      }
    }
    final sw = Stopwatch()..start();
    _initRunning = true;
    try {
      // bridge 复用 (网页端模式): 全局一个 bridge, 已开则零开销返回
      final bridgeKey = _ref.workspaceIdentity ?? _ref.workspacePath;
      try {
        await _relay.ensureBridgeOpen(bridgeKey, taskId: _taskId);
      } catch (e) {
        appLog.w('[Chat] _init: bridge open error: $e, trying waitRpcReady...');
        await _relay.waitRpcReady(const Duration(seconds: 10));
      }

      // V4 握手 (幂等, 同一 bridge 已握过则跳过)
      await _relay.v4Handshake();

      // 订阅 — 历史快照由订阅流直接推送 (网页端模式, 不再单独拉 snapshot)
      appLog.d('[Chat] _init: subscribing V4...');
      final stream = await _relay.subscribeConversationV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        sessionId: _taskId!,
      );
      _streamSnapshotDone = Completer<void>();
      _frameSub = stream.listen((f) {
        _onV4Frame(f);
        if (f.payload is V4SnapshotPayload) {
          final c = _streamSnapshotDone;
          if (c != null && !c.isCompleted) c.complete();
        }
      });

      // 双路竞速: 订阅流 snapshot / 行日志直读并行, 先到先渲染。
      // 流路不 await — 大会话的流快照可能迟到/缺席; _loadHistory 里
      // 会短暂等它, 然后用 conversationRowsRangeV4 补齐更早历史。
      unawaited(_streamSnapshotDone!.future.then((_) {
        appLog.d('[Chat] _init: 流 snapshot 到达');
      }).catchError((_) {}));

      // 上报当前查看的会话 (桌面端设备信号里显示"正在看的对话")
      unawaited(() async {
        try {
          _relay.sendMobileViewState(
            activeWorkspaceKey:
                _ref.workspaceIdentity ?? _ref.workspacePath,
            activeTaskId: _taskId,
            deviceInfo: await DeviceInfoService.build(),
          );
        } catch (_) {}
      }());

      final histSw = Stopwatch()..start();
      await _loadHistory();
      appLog.i('[Chat] _init: done (总 ${sw.elapsedMilliseconds}ms, 历史 ${histSw.elapsedMilliseconds}ms, messages: ${state.messages.length})');
      _initDone = true;
    } catch (e, st) {
      appLog.e('[Chat] _init: FAILED', e, st);
      state = state.copyWith(isLoadingHistory: false, error: '加载失败: $e');
      _initDone = true;
    } finally {
      _initRunning = false;
    }
  }

  Future<void> _loadHistory({bool forceReload = false}) async {
    // 屏上已有内容 (缓存全量 / 重连时的实时视图) → 加载期间保持静默:
    // 快照/逐页都只合并不重建, 全部拉完后一次对齐。
    // 否则快照会先把整屏缩成尾部窗口, 翻页再撑回来, 视图来回跳。
    if (forceReload) {
      // ★ 编辑/回退后的权威刷新: 行日志 append-only + rowsRange 只合并不
      //   删除, 本地旧行 (被 rewind 的轮次) 只能靠清空重建才会消失 —
      //   与重启 App 走流快照替换 (rows.clear) 的行为对齐。
      _rows.clear();
      _stableTurns.clear();
      _turnHeaderRowIds.clear();
      _rowsFirstRowId = null;
      _hasMoreOlder = true;
      _dirtyFrom = 0x7FFFFFFFFFFFFFFF;
      _streamSnapshotDone = null;
      _silentPagination = false; // 直接重建: 尾部窗口到达即旧轮消失
    } else {
      _silentPagination = state.messages.isNotEmpty;
    }
    try {
      // 断连恢复中 (后台切回): 先等 RPC ready, 期间 UI 顶部显示同步条,
      // 而不是立即失败/静默无反馈
      try {
        await _relay.waitRpcReady(const Duration(seconds: 12));
      } catch (_) {
        // 等待超时 → 走下方兜底路径的错误分支
      }

      // ── 行日志直读 (网页端模式) ★ ──
      // conversationRowsRangeV4 只读行日志, 不触发会话冷恢复,
      // 不依赖 provider registry — 避开「模型供应商未就绪」整类问题。
      // 先短暂等订阅流的首帧快照 (它自带尾部窗口), 再补读窗口之前的更早行。
      try {
        await _streamSnapshotDone?.future
            .timeout(const Duration(milliseconds: 1200));
      } catch (_) {}
      try {
        var rowsLoaded = false;
        if (_rows.isEmpty) {
          // 无流快照 (空闲会话常见): 直接读尾部。
          // 已有屏上内容时静默合并, 避免把全量视图缩成尾部窗口。
          rowsLoaded = await _fetchRowsRange(rebuild: !_silentPagination);
        } else {
          // 流快照已渲染尾部窗口
          rowsLoaded = true;
        }
        if (rowsLoaded) {
          // 翻页拉齐全部更早历史 (网页端同款: 打开即全量)。
          // 屏上无内容 → 逐页渐进渲染 (历史从顶部逐步长出);
          // 屏上已有内容 (缓存/重连) → 静默拉完一次对齐, 全程不跳。
          var pages = 0;
          while (_hasMoreOlder &&
              _rowsFirstRowId != null &&
              _rowsFirstRowId! > 1 &&
              pages < 200) {
            final ok = await _fetchRowsRange(
                beforeRowId: _rowsFirstRowId, rebuild: !_silentPagination);
            if (!ok) break;
            pages++;
          }
          _silentPagination = false;
          _rebuildMessagesFromRows();
          appLog.d('[Chat] 全量历史: ${_rows.length}/$_rowsTotalCount 行 '
              '($pages 页追加)');
          _cacheCurrentMessages();
          state = state.copyWith(isLoadingHistory: false);
          return;
        }
      } catch (e) {
        appLog.w('[Chat] 行日志加载失败, 降级快照兜底: $e');
        _silentPagination = false;
      }

      // ── 兜底: 任务门面快照 (legacy 会话无行日志 / 行日志为空) ──
      final resp = await _fetchSnapshotWithRetry();
      final snapshot = resp['snapshot'] as Map<String, dynamic>?;
      if (snapshot == null) {
        appLog.w('[Chat] _loadHistory: 响应无 snapshot, 保留现有内容 (keys=${resp.keys.toList()})');
        state = state.copyWith(isLoadingHistory: false);
        return;
      }
      // V4 snapshot 可能用 rows 或 messages (host 版本决定)
      final rowsObj = snapshot['rows'] as Map<String, dynamic>?;
      List<dynamic>? rowsList = rowsObj?['window'] as List<dynamic>?;
      // rows 也可能是直接数组 (host 版本差异)
      rowsList ??= snapshot['rows'] as List<dynamic>?;
      final messagesJson = snapshot['messages'] as List<dynamic>?;

      if (rowsList != null && rowsList.isNotEmpty) {
        // V4 rows 格式
        _rows.clear();
        _stableTurns.clear();
        _turnHeaderRowIds.clear();
        _dirtyFrom = 0;
        for (final r in rowsList.whereType<Map>()) {
          final row = V4Row.fromJson(Map<String, dynamic>.from(r));
          _rows[row.rowId] = row;
          _logMarkerRow(row, 'fallback');
          _logTurnHeaderRow(row, 'fallback');
        }
        // ★ 先应用快照状态 (control.phase → isResponding), 再重建消息:
        //   rebuild 依赖 isResponding 判定最后一轮是否仍在工作
        _applySnapshotState(V4ConversationSnapshot.fromJson(snapshot));
        _rebuildMessagesFromRows();
        appLog.d('[Chat] _loadHistory: ${_rows.length} rows loaded');
      } else if (messagesJson != null && messagesJson.isNotEmpty) {
        // V3 messages 格式 (host 兼容)
        final messages = messagesJson
            .whereType<Map>()
            .map((e) => _displayFromV3Message(Map<String, dynamic>.from(e)))
            .toList();
        // 诊断: 每条消息的结构与文本提取结果 (排查合并回合/字段变形)
        for (var i = 0; i < messagesJson.length && i < messages.length; i++) {
          final raw = messagesJson[i];
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw);
          final parts = (m['parts'] as List?) ?? [];
          final partTypes = parts
              .whereType<Map>()
              .map((p) =>
                  '${p['type'] ?? p['kind'] ?? '?'}(${(p['text'] ?? p['content'] ?? '').toString().length})')
              .join(',');
          appLog.d('[Chat] v3[$i]: role=${m['role']} '
              'parts=[$partTypes] tools=${(m['tools'] as List?)?.length ?? 0} '
              'textLen=${messages[i].content.length} keys=${m.keys.toList()}');
        }
        final meta = snapshot['meta'] as Map<String, dynamic>?;
        state = state.copyWith(
          messages: messages,
          isLoadingHistory: false,
          sessionTitle: meta?['title'] as String?,
          model: meta?['model'] as String?,
          mode: meta?['mode'] as String? ?? 'build',
          thoughtLevel: meta?['thoughtLevel'] as String? ?? 'max',
        );
        appLog.d('[Chat] _loadHistory: ${messages.length} messages (v3 format)');
        if (_taskId != null) _memCacheSave(_taskId!, messages);
      } else {
        // 不可解析的快照形状: 打日志定位, 不清空已有内容
        appLog.w(
            '[Chat] _loadHistory: 快照无 rows/messages (keys=${snapshot.keys.toList()})');
        state = state.copyWith(isLoadingHistory: false);
      }
    } catch (e) {
      appLog.e('[Chat] _loadHistory: FAILED: $e');
      // 已有内容 (缓存/流快照先渲染) 时不覆盖为全局错误
      if (state.messages.isEmpty) {
        state = state.copyWith(
          isLoadingHistory: false,
          error: _isProviderNotReady(e)
              ? '桌面端模型供应商未就绪（刚重启或会话空闲时可能出现）。已在后台重试仍未成功，'
                    '请点「重试」，或在电脑端打开该工作区后刷新'
              : '历史加载失败: $e',
        );
      } else {
        state = state.copyWith(isLoadingHistory: false);
      }
    }
  }

  /// 行日志按区间读取 (网页端模式核心)
  ///
  /// [beforeRowId] 为空 = 从尾部取; 否则取该 rowId 之前的更早行。
  /// 响应 {rows[], atSeq, atLogEpoch, hasMore} — atLogEpoch 与本地纪元
  /// 不一致时整批丢弃 (服务端 schema 注明的陈旧读防护)。
  Future<bool> _fetchRowsRange(
      {int? beforeRowId, int limit = 200, bool rebuild = true}) async {
    final resp = await _relay.conversationRowsRangeV4(
      workspacePath: _ref.workspacePath,
      workspaceIdentity: _ref.workspaceIdentity,
      sessionId: _taskId!,
      beforeRowId: beforeRowId,
      limit: limit,
    );
    final epoch = resp['atLogEpoch'] as String?;
    if (_v4LogEpoch != null &&
        _v4LogEpoch!.isNotEmpty &&
        epoch != null &&
        epoch != _v4LogEpoch) {
      appLog.w('[Chat] rowsRange 陈旧读丢弃 (epoch $epoch ≠ $_v4LogEpoch)');
      return false;
    }
    final rowsJson = (resp['rows'] as List?) ?? [];
    var merged = 0;
    for (final r in rowsJson.whereType<Map>()) {
      final row = V4Row.fromJson(Map<String, dynamic>.from(r));
      if (!_rows.containsKey(row.rowId)) merged++;
      _rows[row.rowId] = row;
      if (row is V4TurnHeaderRow) _turnHeaderRowIds[row.turnId] = row.rowId;
      _logMarkerRow(row, 'rowsRange');
      _logTurnHeaderRow(row, 'rowsRange');
    }
    // 翻页合并的是更早的行, 直接压满水位走一次全量重建 (翻页本来也全量重建)
    if (rowsJson.isNotEmpty) _dirtyFrom = 0;
    final first = rowsJson.whereType<Map>()
        .map((r) => (r['rowId'] as num?)?.toInt())
        .whereType<int>()
        .fold<int?>(null, (a, b) => a == null ? b : (a < b ? a : b));
    if (first != null && (_rowsFirstRowId == null || first < _rowsFirstRowId!)) {
      _rowsFirstRowId = first;
    }
    _hasMoreOlder = resp['hasMore'] == true;
    if (rebuild) _rebuildMessagesFromRows();
    appLog.d('[Chat] rowsRange: +$merged 行 (before=$beforeRowId '
        '共${_rows.length} hasMore=$_hasMoreOlder)');
    return rowsJson.isNotEmpty;
  }

  /// 往上翻页: 加载更早的历史行 (滚动到顶部附近触发)
  Future<void> loadOlder() async {
    if (_taskId == null || _loadingOlder || !_hasMoreOlder) return;
    final oldest = _rows.keys.reduce((a, b) => a < b ? a : b);
    if (oldest <= 1) {
      _hasMoreOlder = false;
      return;
    }
    _loadingOlder = true;
    state = state.copyWith(isLoadingHistory: true);
    try {
      final got = await _fetchRowsRange(beforeRowId: oldest, limit: 100);
      if (!got) _hasMoreOlder = false;
      _cacheCurrentMessages();
    } catch (e) {
      appLog.w('[Chat] loadOlder 失败: $e');
    } finally {
      _loadingOlder = false;
      state = state.copyWith(isLoadingHistory: false);
    }
  }

  void _cacheCurrentMessages() {
    if (_taskId == null) return;
    _memCacheSave(_taskId!, state.messages);
  }

  /// 拉取任务快照, 对「模型供应商未就绪」自动退避重试。
  ///
  /// 服务端 getTaskSnapshot 走 session 冷恢复, 需要工作区的 provider registry
  /// 就绪; 桌面端刚重启/registry 同步中会瞬时拒绝 (zcode-server 实测), 重试可恢复。
  Future<Map<String, dynamic>> _fetchSnapshotWithRetry() async {
    const attempts = 3;
    for (var i = 1;; i++) {
      try {
        return await _relay.getTaskSnapshot(
          taskId: _taskId!,
          workspacePath: _ref.workspacePath,
          workspaceIdentity: _ref.workspaceIdentity,
          messageLimit: 50,
        );
      } on Exception catch (e) {
        if (i >= attempts || !_isProviderNotReady(e)) rethrow;
        appLog.w('[Chat] _loadHistory: 模型供应商未就绪 (第$i次), 2.5s 后重试');
        await Future<void>.delayed(const Duration(milliseconds: 2500));
      }
    }
  }

  static bool _isProviderNotReady(Object e) {
    final s = e.toString();
    return s.contains('模型供应商') || s.contains('请先登录或配置');
  }

  /// 手动重试加载历史 (错误横幅「重试」按钮)
  Future<void> reloadHistory() async {
    if (_taskId == null) return;
    state = state.copyWith(isLoadingHistory: true, error: null);
    await _loadHistory();
  }

  /// 对比状态变化, 触发后台事件通知 (需要确认/需要回答)。
  /// 任务完成的通知由 WorkspaceListNotifier 挂全局 workspace-list-updated
  /// 推送处理 (本 notifier 是 autoDispose, 退出聊天页即销毁, 不可靠)。
  void _checkNotify(ChatState prev, ChatState next) {
    final taskId = _taskId;
    if (taskId == null) return;

    // 1. 新出现的权限确认请求 (按 id 去重)
    for (final p in next.pendingPermissions) {
      if (_notifiedPermIds.contains(p.id)) continue;
      _notifiedPermIds.add(p.id);
      appLog.i('[Chat] 权限请求到达: ${p.toolName} (${p.id})');
      NotificationService.notifyPermission(
        taskId: taskId,
        workspaceKey: _ref.workspacePath,
        permissionId: p.id,
        toolName: p.toolName,
        reason: p.reason,
      );
    }
    // 清理已解决的权限 id, 防止集合无限增长
    _notifiedPermIds.removeWhere(
        (id) => !next.pendingPermissions.any((p) => p.id == id));

    // 2. AI 提问 (pendingQuestion null→非空)
    if (prev.pendingQuestion == null && next.pendingQuestion != null) {
      appLog.i('[Chat] AI 提问到达');
      NotificationService.notifyQuestion(
        taskId: taskId,
        workspaceKey: _ref.workspacePath,
        question: next.pendingQuestion!.question,
      );
    }
  }

  /// 从 V4 snapshot 更新 state (config/control/usage/plan/interactions)
  void _applySnapshotState(V4ConversationSnapshot snap) {
    final prevState = state;
    _v4LogEpoch = snap.logEpoch;
    _v4Seq = snap.seq;
    _v4Revision = snap.revision;

    final config = snap.config;
    final control = snap.control;
    final usage = snap.usage?.contextWindow;

    // pendingInteractions → permissions + questions
    final perms = <PendingPermission>[];
    V4PendingInteraction? question;
    for (final pi in snap.pendingInteractions) {
      if (pi.kind == 'permission' && pi.permission != null) {
        final p = pi.permission!;
        perms.add(PendingPermission(
          id: pi.interactionId,
          toolCallId: p.toolCallId,
          toolName: p.toolName,
          reason: p.summary,
          input: p.detail,
          options: p.options.map((o) => PermissionOption(
            optionId: o.optionId,
            kind: o.kind,
            name: o.label,
            decision: o.response['decision'] as String? ?? 'allow',
            fullResponse: o.response,
          )).toList(),
        ));
      } else if (pi.kind == 'userInput' && pi.userInput != null) {
        final u = pi.userInput!;
        if (u.questions.isNotEmpty) {
          question = pi;
        }
      }
    }

    // plan
    final plan = snap.plan.map((p) => PlanItem(
      content: p.content,
      status: switch (p.status) {
        'completed' => TodoStatus.completed,
        'inProgress' || 'in_progress' => TodoStatus.inProgress,
        _ => TodoStatus.pending,
      },
    )).toList();

    // 快照是权威全量状态, 直接采用 (取消可能挂起的 control 闪断防抖确认)
    _respondingFallTimer?.cancel();
    _respondingFallTimer = null;
    state = state.copyWith(
      isLoadingHistory: false,
      mode: config.mode,
      thoughtLevel: config.thought,
      model: config.modelId.isNotEmpty ? config.modelId : null,
      sessionTitle: snap.meta.title.isNotEmpty ? snap.meta.title : null,
      isResponding: control.isRunning,
      plan: plan,
      pendingPermissions: perms,
      queuedMessages: snap.queue.items
          .map((e) => QueuedMessage(id: e.queueItemId, text: e.text))
          .toList(),
      tokenUsage: usage != null
          ? (input: usage.usedTokens, output: 0, max: usage.maxTokens)
          : state.tokenUsage,
    );

    // 处理 AskUserQuestion
    if (question != null && question.userInput != null) {
      final u = question.userInput!;
      if (u.questions.isNotEmpty) {
        final q = u.questions[u.currentQuestionIndex ?? 0];
        state = state.copyWith(
          pendingQuestion: AskUserQuestion(
            callId: question.interactionId,
            question: q.question,
            header: q.header,
            multiSelect: q.multiSelect,
            options: q.options.map((o) => QuestionOption(
              label: o.label, description: o.description ?? '',
            )).toList(),
          ),
          isResponding: false,
        );
      }
    }

    // 标题回调
    if (snap.meta.title.isNotEmpty && _taskId != null) {
      _onTitleUpdated?.call(_taskId!, snap.meta.title);
    }

    _checkNotify(prevState, state);
  }

  /// 从 V3 messages[] 格式的消息构造 DisplayMessage
  DisplayMessage _displayFromV3Message(Map<String, dynamic> json) {
    final parts = json['parts'] as List<dynamic>?;
    final tools = json['tools'] as List<dynamic>?;
    final role = json['role'] as String? ?? 'assistant';
    final model = json['model'] as String?;

    final textBuffer = StringBuffer();
    final activities = <ToolActivity>[];

    // 解析 tools[]
    if (tools != null) {
      for (final t in tools.whereType<Map>()) {
        final tm = Map<String, dynamic>.from(t);
        activities.add(ToolActivity(
          toolCallId: (tm['raw'] is Map ? (tm['raw'] as Map)['toolCallId'] : null)?.toString() ?? '',
          toolName: tm['toolName'] as String? ?? tm['kind'] as String? ?? '',
          status: tm['status'] as String? ?? '',
          input: tm['input'] is Map ? Map<String, dynamic>.from(tm['input'] as Map) : null,
          result: tm['output'] is String ? tm['output'] : null,
        ));
      }
    }

    // 解析 parts[]
    if (parts != null) {
      for (final part in parts.whereType<Map>()) {
        final pm = Map<String, dynamic>.from(part);
        final type = pm['type'] as String? ?? '';
        if (type == 'text' || type == 'content') {
          final t = (pm['text'] ?? pm['content']) as String? ?? '';
          if (t.isNotEmpty) {
            if (textBuffer.isNotEmpty) textBuffer.write('\n');
            textBuffer.write(t);
          }
        } else if (type == 'reasoning' || type == 'thought') {
          // thought 不单独处理, 存到 thought 字段
        }
      }
    }

    return DisplayMessage(
      id: json['id'] as String? ?? '',
      role: role,
      content: textBuffer.toString().isNotEmpty
          ? textBuffer.toString()
          : (json['content'] as String? ?? ''),
      thought: json['thought'] as String?,
      model: model,
      activities: activities,
    );
  }

  /// V4 Frame 处理 ★★★
  void _onV4Frame(V4Frame frame) {
    // topic = conversation/<sessionId>: 只处理本会话的帧,
    // 防止工作区级推送的其他会话快照/增量串台覆盖当前显示
    if (_taskId != null && frame.topic.isNotEmpty &&
        !frame.topic.endsWith('/$_taskId')) {
      appLog.w('[Chat] V4 帧串台忽略: topic=${frame.topic} (当前 $_taskId)');
      return;
    }

    if (frame.payload is V4SnapshotPayload) {
      final snap = (frame.payload as V4SnapshotPayload).snapshot;
      _v4SubscriptionId = frame.subscriptionId;
      _v4LogEpoch = snap.logEpoch;
      _v4Seq = snap.seq;
      _v4Revision = snap.revision;
      // 空 window 的快照 (会话未物化/订阅退化) 不清空已渲染内容,
      // 否则点击历史会话时会闪掉缓存变成"新会话"空屏
      if (snap.rows.window.isEmpty && _rows.isNotEmpty) {
        appLog.w('[Chat] V4 空快照到达, 忽略 (topic=${frame.topic} '
            'sub=${frame.subscriptionId} 现有 ${_rows.length} rows)');
        return;
      }
      // 清空并重建 rows
      _rows.clear();
      _stableTurns.clear();
      _turnHeaderRowIds.clear();
      _dirtyFrom = 0;
      for (final r in snap.rows.window) {
        _rows[r.rowId] = r;
        _logMarkerRow(r, 'snapshot');
        _logTurnHeaderRow(r, 'snapshot');
      }
      // 记录尾部窗口边界: 窗口之前可能还有更早历史 (rowsRange 翻页用)。
      // ⚠️ 不能用 snap.rows.firstRowId — 实测恒为 1 (整个日志的起始 id),
      // 不是窗口首行; 用它会让翻页条件 (firstRowId>1) 永假, 旧历史加载不出。
      // 窗口边界从实际行的最小 rowId 算。
      _rowsFirstRowId = _rows.values
          .map((r) => r.rowId)
          .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
      _rowsTotalCount = snap.rows.totalCount;
      // 窗口之前还有更早行 → 允许翻页 (全量加载循环的启动条件)
      _hasMoreOlder = (_rowsFirstRowId ?? 1) > 1;
      // ★ 先应用快照状态 (control.phase → isResponding), 再重建消息。
      // 加载期间屏上已有内容 (缓存全量/重连视图) → 跳过中间重建,
      // 否则这里会把整屏缩成尾部窗口, 随后翻页再撑回来, 视图来回跳。
      _applySnapshotState(snap);
      if (_silentPagination) {
        appLog.d('[Chat] V4 snapshot: ${_rows.length} rows (静默合并, '
            'first=${_rowsFirstRowId ?? '-'} total=${snap.rows.totalCount})');
      } else {
        _rebuildMessagesFromRows();
        appLog.d('[Chat] V4 snapshot: ${_rows.length} rows '
            '(first=${_rowsFirstRowId ?? '-'} total=${snap.rows.totalCount})');
      }
    } else if (frame.payload is V4DeltasPayload) {
      final deltas = (frame.payload as V4DeltasPayload).deltas;
      for (final d in deltas) {
        _applyDelta(d);
      }
      // 高频流式增量 → 合并重建 (见 _scheduleRebuild)
      _scheduleRebuild();
    }
  }

  /// 调试: 记录 marker/未知行的原始结构 (压缩提示开发期)
  void _logMarkerRow(V4Row row, String src) {
    if (row is V4TimelineMarkerRow) {
      appLog.d('[Chat] marker行($src): ${jsonEncode(row.raw)}');
    } else if (row is V4UnknownRow) {
      appLog.d('[Chat] 未知行($src): kind=${row.kind} ${jsonEncode(row.raw)}');
    }
  }

  /// 应用单个 delta 到 _rows / state
  void _applyDelta(V4Delta delta) {
    switch (delta) {
      case V4RowAppended(:final row):
        _rows[row.rowId] = row;
        _markDirtyRow(row);
        _trackRevision(row.revision);
        _logMarkerRow(row, 'delta');
        _logTurnHeaderRow(row, 'delta-append');
      case V4RowUpserted(:final row):
        _rows[row.rowId] = row;
        _markDirtyRow(row);
        _trackRevision(row.revision);
        _logMarkerRow(row, 'delta');
        _logTurnHeaderRow(row, 'delta-upsert');
      case V4RowRemoved(:final fromRowId):
        _rows.remove(fromRowId);
        // 删行影响该行起的整段 → 水位压到该行
        if (fromRowId < _dirtyFrom) _dirtyFrom = fromRowId;
      case V4RowDeltaOp(:final rowId, :final path, :final append):
        final row = _rows[rowId];
        if (row == null) return;
        final updated = _applyRowDelta(row, path, append);
        _rows[rowId] = updated;
        _markDirtyRow(updated);
      case V4StateUpdated(:final patch, :final revision):
        _applyStatePatch(patch);
        // state 变化 (队列增删等) 同样推进 revision
        if (revision > 0) _trackRevision(revision);
        final r = (patch['revision'] as num?)?.toInt();
        if (r != null) _trackRevision(r);
      case _:
        appLog.w('[Chat] V4 delta: unhandled ${delta.runtimeType}');
    }
  }

  /// delta 触达某行 → 脏水位降到该行所属轮次的轮首 (turnHeader rowId)。
  /// 低于水位的完成轮才会被复用, 因此含该行的轮次 (extent ≥ 轮首) 必被重扫。
  /// 轮首未知时用行自身 rowId 兜底 (新轮的首个 delta 通常就是 header 本身)。
  void _markDirtyRow(V4Row row) {
    var from = row.rowId;
    if (row is V4TurnHeaderRow) {
      _turnHeaderRowIds[row.turnId] = row.rowId;
    } else {
      final headerId = _turnHeaderRowIds[row.turnId];
      if (headerId != null && headerId < from) from = headerId;
    }
    if (from < _dirtyFrom) _dirtyFrom = from;
  }

  /// 本地 revision 只前进不后退 — CAS 命令 (队列管理等) 需要它保持最新,
  /// 否则服务端以 proto.staleRevision 拒绝。
  void _trackRevision(int revision) {
    if (revision > _v4Revision) _v4Revision = revision;
  }

  /// 调试: 记录 turnHeader 行的关键字段 (排查"已工作 X"时长缺失)。
  /// 若完成态的 endedAt/activeMs 为 '-', 说明 host 没下发 → 显示"已处理"的根因。
  void _logTurnHeaderRow(V4Row row, String src) {
    if (row is V4TurnHeaderRow) {
      appLog.d('[Chat] turnHeader($src): rowId=${row.rowId} '
          'turn=${row.turnId.isEmpty ? '-' : row.turnId} '
          'state=${row.state} '
          'startedAt=${row.startedAt ?? '-'} '
          'endedAt=${row.endedAt ?? '-'} '
          'activeMs=${row.activeMs ?? '-'} '
          'fileChanges=${row.fileChanges == null ? '-' : '${row.fileChanges!.files}f'}');
    }
  }

  /// 追加文本到 row 的指定 path
  V4Row _applyRowDelta(V4Row row, String path, String append) {
    switch (row) {
      case V4AssistantTextRow():
        if (path == 'text') return row.copyWith(text: row.text + append);
      case V4ReasoningRow():
        if (path == 'text') return row.copyWith(text: row.text + append);
      case V4ToolCallRow():
        if (path == 'inputText') return row.copyWith(inputText: row.inputText + append);
        if (path == 'output.text') {
          final out = row.output?.copyWith(text: row.output!.text + append) ??
              V4ToolOutput(text: append);
          return row.copyWith(output: out);
        }
      case V4SubagentRow():
        // wire: delta(path='summaryText', op=append) — 摘要流式追加
        if (path == 'summaryText') {
          return row.copyWith(summaryText: row.summaryText + append);
        }
      default:
        break;
    }
    return row;
  }

  /// state.updated patch: 更新 control/config/usage 等
  void _applyStatePatch(Map<String, dynamic> patch) {
    final prevState = state;
    if (patch.containsKey('control')) {
      final ctrl = V4Control.fromJson(patch['control'] as Map<String, dynamic>? ?? {});
      final wasResponding = state.isResponding;
      if (ctrl.isRunning) {
        // running 到达即生效; 取消可能挂起的"完成确认"
        _respondingFallTimer?.cancel();
        _respondingFallTimer = null;
        if (!wasResponding) state = state.copyWith(isResponding: true);
      } else if (wasResponding) {
        // ★ 闪断防抖: turn 间隙/权限等待/排队切换时, host 会短暂下发
        //   非 running 的 control patch。立即落 false 会把乐观用户消息和
        //   "思考中"占位删掉再建回 → 列表尾部高度骤变, 视口来回跳。
        //   延迟确认; 期间回到 running 则当无事发生。
        _respondingFallTimer?.cancel();
        _respondingFallTimer = Timer(const Duration(milliseconds: 500), () {
          _respondingFallTimer = null;
          if (!state.isResponding || _disposedNotifier) return;
          state = state.copyWith(isResponding: false);
          // ★ 运行 → 完成: 补读尾部行, 取回 turnHeader 的 endedAt/activeMs
          //   (否则完成轮次算不出 workedMs, 状态行只能显示"已处理")
          if (_taskId != null) unawaited(_refreshTurnMetadata());
        });
      }
    }
    if (patch.containsKey('config')) {
      final cfg = V4Config.fromJson(patch['config'] as Map<String, dynamic>? ?? {});
      state = state.copyWith(
        mode: cfg.mode,
        thoughtLevel: cfg.thought,
        model: cfg.modelId.isNotEmpty ? cfg.modelId : state.model,
      );
    }
    if (patch.containsKey('usage')) {
      final u = V4Usage.fromJson(patch['usage'] as Map<String, dynamic>? ?? {});
      if (u.contextWindow != null) {
        state = state.copyWith(
          tokenUsage: (
            input: u.contextWindow!.usedTokens,
            output: 0,
            max: u.contextWindow!.maxTokens,
          ),
        );
      }
    }
    if (patch.containsKey('meta')) {
      final meta = V4Meta.fromJson(patch['meta'] as Map<String, dynamic>? ?? {});
      if (meta.title.isNotEmpty) {
        state = state.copyWith(sessionTitle: meta.title);
        if (_taskId != null) _onTitleUpdated?.call(_taskId!, meta.title);
      }
    }
    if (patch.containsKey('queue')) {
      final q = V4Queue.fromJson(patch['queue'] as Map<String, dynamic>? ?? {});
      state = state.copyWith(
          queuedMessages:
              q.items.map((e) => QueuedMessage(id: e.queueItemId, text: e.text)).toList());
    }
    if (patch.containsKey('pendingInteractions')) {
      final raw = patch['pendingInteractions'] as List<dynamic>? ?? [];
      final interactions = raw.whereType<Map>()
          .map((e) => V4PendingInteraction.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final perms = <PendingPermission>[];
      for (final pi in interactions) {
        if (pi.kind == 'permission' && pi.permission != null) {
          final p = pi.permission!;
          perms.add(PendingPermission(
            id: pi.interactionId,
            toolCallId: p.toolCallId,
            toolName: p.toolName,
            reason: p.summary,
            input: p.detail,
            options: p.options.map((o) => PermissionOption(
              optionId: o.optionId, kind: o.kind, name: o.label,
              decision: o.response['decision'] as String? ?? 'allow',
              fullResponse: o.response,
            )).toList(),
          ));
        }
      }
      state = state.copyWith(pendingPermissions: perms);
    }
    if (patch.containsKey('plan')) {
      final planRaw = patch['plan'] as Map<String, dynamic>?;
      final items = planRaw?['items'] as List<dynamic>? ?? [];
      state = state.copyWith(
        plan: items.whereType<Map>().map((e) {
          final p = V4PlanItem.fromJson(Map<String, dynamic>.from(e));
          return PlanItem(content: p.content, status: switch (p.status) {
            'completed' => TodoStatus.completed,
            'inProgress' || 'in_progress' => TodoStatus.inProgress,
            _ => TodoStatus.pending,
          });
        }).toList(),
      );
    }

    _checkNotify(prevState, state);
  }

  /// 从 _rows 重建 DisplayMessage 列表 (适配 UI)
  /// 按 rowId 顺序把 V4 rows 重建成消息列表。
  ///
  /// 对齐 ZCode 客户端的分组方式: 一个 turn (turnHeader) = 一条 assistant
  /// 消息, 内部按真实发生顺序交错渲染 (思考 → 工具 → 正文 → 工具 → …),
  /// 轮次元数据 (workedMs/turnStartedAt/fileChanges) 附着在消息上。
  /// 流式增量合并重建: delta 帧高频到达时只排一个 120ms 的尾随重建,
  /// 把每帧一次的全量 rows→messages 重建 + UI 通知压到 ≤8次/秒。
  void _scheduleRebuild() {
    if (_rebuildPending) {
      _rebuildCoalesced++;
      return;
    }
    _rebuildPending = true;
    _rebuildDebounce = Timer(const Duration(milliseconds: 120), () {
      _rebuildPending = false;
      if (_rebuildCoalesced >= 8) {
        appLog.d('[Chat] 增量重建 (合并 $_rebuildCoalesced 帧)');
      }
      _rebuildCoalesced = 0;
      if (_disposedNotifier) return;
      _rebuildMessagesFromRows();
    });
  }

  void _rebuildMessagesFromRows() {
    final messages = <DisplayMessage>[];
    // SplayTreeMap 已按 rowId 升序, 免排序
    final sortedRows = _rows.values.toList();

    // ── 当前轮次累积器 ──
    var turnId = '';
    V4TurnHeaderRow? header;
    var parts = <MessagePart>[];
    var activities = <ToolActivity>[];
    var contentBuf = StringBuffer();
    var thoughtBuf = StringBuffer();
    var lastTextState = '';
    var anyToolRunning = false;
    // 本轮累积的最大 rowId (缓存条目的 extent, 复用判据)
    var turnMaxRowId = 0;
    // 正在跳过被复用的旧轮内容行 (遇边界行复位)
    var skipping = false;
    // 本次扫描存活/新写的轮次缓存 id (用于剔除 rewind 遗留死条目)
    final liveTurnIds = <String>{};

    /// [olderTurn] = 本轮后面还有更新的轮次 — 旧轮不可能仍在运行。
    /// host 完成时不通过 delta 推 turnHeader 状态更新 (抓包实测 0 upsert),
    /// 旧轮的 header 会永远停在 running; 若不压制, 上一轮会一直显示
    /// "工作中/思考中", 与新轮同时出现两个流式指示。
    void flushTurn({bool olderTurn = false}) {
      if (header == null && parts.isEmpty) return;
      // 中断完成态是权威信号: 打断时行状态可能永远停在 streaming
      // (服务端不下发终态), 不压制的话该轮永远显示"思考中"。
      final interruptedTurn = header?.isInterrupted ?? false;
      final isRunning = !olderTurn &&
          !interruptedTurn &&
          ((header?.isRunning ?? false) ||
              lastTextState == 'streaming' ||
              anyToolRunning);
      // 轮次无正文就不渲染 (ZCode 同样吞掉空轮次) — 运行中的空壳同样吞:
      // "仅 turnHeader" 的空壳消息是思考中错位的来源, 运行态指示
      // 统一由紧贴 user 的占位与真实内容轮承担。
      // (thought 非空的"思考中"轮不是空壳, 正常产出)
      final hasBody = parts.isNotEmpty ||
          thoughtBuf.isNotEmpty ||
          contentBuf.isNotEmpty;
      if (!hasBody) {
        header = null;
        return;
      }
      final id = 'turn_${turnId}_r${header?.rowId ?? 0}';
      // ★ 完成轮缓存复用: extent < 脏水位 = 该轮自上次缓存后未被任何
      //   delta 触达, 行内容与上次完全一致, 直接用上次的 DisplayMessage
      //   (实例稳定也让 UI 侧 widget 缓存签名全部命中)。
      //   只缓存完成态: running 轮每帧都在变, 且新轮到达时它的
      //   olderTurn 语义会翻转, 必须重扫。
      if (!isRunning) {
        final cached = _stableTurns[id];
        if (cached != null && cached.$2 < _dirtyFrom) {
          messages.add(cached.$1);
          liveTurnIds.add(id);
          header = null;
          parts = [];
          activities = [];
          contentBuf = StringBuffer();
          thoughtBuf = StringBuffer();
          lastTextState = '';
          anyToolRunning = false;
          turnMaxRowId = 0;
          return;
        }
      }
      // ★ workedMs 兜底: 完成轮的 endedAt/activeMs 只在行日志里 (host
      //   完成时不推 delta 更新), 补读失败/漏读的轮次会永远缺时长。
      //   用本轮思考+工具耗时之和估算 — 对齐服务端 activeMs 的"活跃
      //   时长"语义 (agent 轮必有工具/思考; 纯文本轮无信号保持原样)
      int? worked = header?.workedMs;
      if (worked == null && !isRunning) {
        var est = 0;
        for (final p in parts) {
          if (p is ThoughtPart) {
            est += p.durationMs ?? 0;
          } else if (p is ToolPart) {
            est += p.activity.elapsedMs ?? 0;
          }
        }
        if (est > 0) worked = est;
      }
      final m = DisplayMessage(
        id: id,
        role: 'assistant',
        content: contentBuf.toString(),
        thought: thoughtBuf.isEmpty ? null : thoughtBuf.toString(),
        model: null,
        isStreaming: isRunning,
        interrupted: header?.isInterrupted ?? false,
        activities: activities,
        parts: parts,
        workedMs: worked,
        turnStartedAt: header?.startedAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(header!.startedAt!),
        fileChanges: header?.fileChanges,
        createdAt: header?.startedAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(header!.startedAt!),
      );
      if (!isRunning) {
        _stableTurns[id] = (m, turnMaxRowId);
        liveTurnIds.add(id);
      }
      messages.add(m);
      header = null;
      parts = [];
      activities = [];
      contentBuf = StringBuffer();
      thoughtBuf = StringBuffer();
      lastTextState = '';
      anyToolRunning = false;
      turnMaxRowId = 0;
    }

    /// turnHeader 缺失时 (老数据/异常) 也能累积内容行;
    /// turnId 变化说明新轮次开始, 先冲刷上一轮 (旧轮强制完成态)
    void ensureTurn(String rowTurnId) {
      if (header == null && turnId != rowTurnId) {
        flushTurn(olderTurn: true);
        turnId = rowTurnId;
      }
    }

    for (final row in sortedRows) {
      switch (row) {
        case V4TurnHeaderRow():
          _turnHeaderRowIds[row.turnId] = row.rowId;
          // ★ 增量快路径 (入口): 该轮未被触达且已有完成态缓存 →
          //   直接复用实例, 本轮内容行全部跳过 (扫描的 O(n) 主项)。
          final cacheId = 'turn_${row.turnId}_r${row.rowId}';
          final cached = _stableTurns[cacheId];
          if (cached != null && cached.$2 < _dirtyFrom) {
            messages.add(cached.$1);
            liveTurnIds.add(cacheId);
            skipping = true;
            turnId = row.turnId;
            header = null;
            parts = [];
            activities = [];
            contentBuf = StringBuffer();
            thoughtBuf = StringBuffer();
            lastTextState = '';
            anyToolRunning = false;
            turnMaxRowId = 0;
          } else {
            // 新轮次开始 → 被冲刷的旧轮强制完成态 (见 flushTurn 注释)
            flushTurn(olderTurn: true);
            skipping = false;
            turnId = row.turnId;
            header = row;
            turnMaxRowId = row.rowId;
          }
        case V4UserInputRow():
          skipping = false;
          // ★ user 行属于当前累积轮 (turnHeader 先行到达) → 不打断轮:
          //   保留 header 与已累积内容, user 独立成消息先入列,
          //   该轮最终 flush 的完整消息自然位于 user 之后 (顺序正确),
          //   且保住真实 header (rowId/startedAt/workedMs)。
          if (row.turnId != turnId || header == null) flushTurn();
          messages.add(DisplayMessage(
            id: 'row_${row.rowId}',
            role: 'user',
            content: row.text,
          ));
        case V4AssistantTextRow():
          if (skipping) {
            // turnId 漂移 (无头行的异常路径) → 停止跳过, 恢复累积
            if (row.turnId == turnId) continue;
            skipping = false;
          }
          if (row.text.isEmpty && row.state != 'streaming') continue;
          ensureTurn(row.turnId);
          if (row.text.isNotEmpty) {
            parts.add(TextPart(row.text));
            if (contentBuf.isNotEmpty) contentBuf.write('\n');
            contentBuf.write(row.text);
          }
          lastTextState = row.state;
          turnMaxRowId = row.rowId;
        case V4ReasoningRow():
          if (skipping) {
            // turnId 漂移 (无头行的异常路径) → 停止跳过, 恢复累积
            if (row.turnId == turnId) continue;
            skipping = false;
          }
          if (row.text.isEmpty) continue;
          ensureTurn(row.turnId);
          parts.add(ThoughtPart(row.text, durationMs: row.durationMs));
          thoughtBuf.write(row.text);
          turnMaxRowId = row.rowId;
        case V4ToolCallRow():
          if (skipping) {
            // turnId 漂移 (无头行的异常路径) → 停止跳过, 恢复累积
            if (row.turnId == turnId) continue;
            skipping = false;
          }
          ensureTurn(row.turnId);
          final activity = ToolActivity(
            toolCallId: row.toolCallId,
            toolName: row.toolName,
            status: row.status,
            input: row.input ?? _tryParseInputText(row.inputText),
            result: row.output?.text,
          );
          parts.add(ToolPart(activity));
          activities.add(activity);
          if (row.isRunning) anyToolRunning = true;
          turnMaxRowId = row.rowId;
        case V4SubagentRow():
          if (skipping) {
            // turnId 漂移 (无头行的异常路径) → 停止跳过, 恢复累积
            if (row.turnId == turnId) continue;
            skipping = false;
          }
          ensureTurn(row.turnId);
          // 子代理 → SubagentPart (AgentCard 渲染, 保留 wire 四态/嵌套句柄)
          parts.add(SubagentPart(
            subagentType: row.subagentType,
            status: row.status,
            summaryText: row.summaryText,
            childSessionId: row.childSessionId,
            parentToolCallId: row.parentToolCallId,
            rowIdKey: 'subagent_${row.rowId}',
          ));
          // 无 parts 的回退路径 (v3 快照) 仍以合成 ToolActivity 兼容
          final activity = ToolActivity(
            toolCallId: 'subagent_${row.rowId}',
            toolName: 'subagent (${row.subagentType})',
            status: row.status == 'running' ? 'running' : 'done',
            result: row.summaryText.isNotEmpty ? row.summaryText : null,
          );
          activities.add(activity);
          if (row.status == 'running') anyToolRunning = true;
          turnMaxRowId = row.rowId;
        case V4TimelineMarkerRow():
          // 压缩标记: 渲染为时间线分割线 (running=压缩中, 其余=已完成)
          if (row.marker['type'] == 'compact') {
            skipping = false;
            flushTurn();
            final status = row.marker['status'] as String? ?? '';
            final before = (row.marker['tokensBefore'] as num?)?.toInt();
            final after = (row.marker['tokensAfter'] as num?)?.toInt();
            String fmtTok(int v) =>
                v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';
            var label = status == 'running' ? '正在压缩对话' : '已压缩对话';
            if (status != 'running') {
              if (before != null && after != null) {
                label += ' · ${fmtTok(before)} → ${fmtTok(after)} tokens';
              } else if (before != null) {
                label += ' · ${fmtTok(before)} tokens';
              }
            }
            final createdMs = (row.raw['createdAt'] as num?)?.toInt();
            messages.add(DisplayMessage(
              id: 'row_${row.rowId}',
              role: 'marker',
              content: label,
              isStreaming: status == 'running',
              createdAt: createdMs != null
                  ? DateTime.fromMillisecondsSinceEpoch(createdMs)
                  : null,
            ));
          }
        case V4UnknownRow():
          continue;
      }
    }
    flushTurn();

    // 乐观用户消息: sendText 已发出但 row 未到 — 重建时补回,
    // 否则乐观插入的用户消息会被 rows 重建覆盖掉 ("发送后闪没")。
    // 清除条件只认 "row 已到达"; isResponding 闪断不清 (见字段注释),
    // 仅在任务确认结束超过 10s 仍未落行 (协议异常) 时兜底清除。
    if (_pendingUserText != null) {
      final pending = _pendingUserText!;
      final arrived =
          messages.any((m) => m.role == 'user' && m.content == pending);
      final stale = !state.isResponding &&
          _pendingUserTextAt != null &&
          DateTime.now().difference(_pendingUserTextAt!) >
              const Duration(seconds: 10);
      if (arrived || stale) {
        _pendingUserText = null;
        _pendingUserTextAt = null;
      } else {
        messages.add(DisplayMessage(
          id: 'pending_user',
          role: 'user',
          content: pending,
        ));
      }
    }

    // ★ "工作中"状态的权威绑定 = turnHeader.state (running → isStreaming,
    //   见 flushTurn), 与轮次数据绑定而非列表位置。
    //   曾有的"messages.last 强制置 streaming"位置推断兜底已删除 — 它在
    //   乐观消息缺位的时序窗口 (user row 未到) 会把上一条已完成的 AI 回复
    //   错误置为"思考中"。步骤间隙的闪收由"未完成轮不进 stableTurn 缓存 +
    //   host 不推完成 upsert (最后轮 header 停留 running)"天然覆盖。

    // AI 正在回复但还没有新文本行 → 显示 "思考中" 占位。
    // ★ 位置约束: 仅当列表尾部是 user 消息 (新问题已显示、AI 轮未开) 时
    //   添加 — 占位必然出现在新问题之后。尾部是旧 assistant 的时序间隙
    //   (user row 未到) 不加: 避免错位到上一条已完成的回复底部;
    //   turnHeader(running) 到达后自然出现带 streaming 态的新轮消息。
    // ★ 检查"任意位置"是否有流式中的 assistant 消息 (而非仅最后一条):
    //   排队消息出队后列表末尾是 user 行, 但前一个轮次仍在流式 —
    //   若只看 last 会再叠一个占位, 出现两个"思考中"。
    // 压缩进行中除外 — 压缩标记药丸已在展示进度, 再叠"思考中"就重复了。
    if (state.isResponding && messages.isNotEmpty && messages.last.role == 'user') {
      final compactRunning =
          messages.any((m) => m.role == 'marker' && m.isStreaming);
      final anyStreamingAi =
          messages.any((m) => m.role == 'assistant' && m.isStreaming);
      if (!anyStreamingAi && !compactRunning) {
        messages.add(DisplayMessage(
          id: 'thinking_placeholder',
          role: 'assistant',
          content: '',
          isStreaming: true,
        ));
      }
    }

    // 剔除 rewind/删行遗留的死缓存条目 (正常路径条目数 == 轮次数, 不会触发)
    if (_stableTurns.length > liveTurnIds.length + 8) {
      _stableTurns.removeWhere((k, _) => !liveTurnIds.contains(k));
    }
    // 重建完成 → 水位复位 (此后新 delta 再降低它)
    _dirtyFrom = 0x7FFFFFFFFFFFFFFF;

    // ★ 诊断: 思考中错位排查 — 运行中打印尾部消息与 streaming 归属
    if (state.isResponding) {
      final tail = messages.length <= 3
          ? messages.map((m) => '${m.role}:${m.id}${m.isStreaming ? "*" : ""}')
          : messages
              .sublist(messages.length - 3)
              .map((m) => '${m.role}:${m.id}${m.isStreaming ? "*" : ""}');
      final streaming = messages
          .where((m) => m.isStreaming)
          .map((m) => m.id)
          .toList();
      appLog.d('[Chat] rebuild诊断: n=${messages.length} '
          'tail=[${tail.join(' | ')}] streaming=$streaming');
    }

    state = state.copyWith(messages: messages);
    // 内存缓存 O(1) 引用快照, 直接写 (无需防抖)
    if (_taskId != null && messages.isNotEmpty) {
      _memCacheSave(_taskId!, messages);
    }
  }

  /// inputText (流式 JSON 文本) → Map。input 字段缺失时兜底解析。
  static Map<String, dynamic>? _tryParseInputText(String text) {
    if (text.isEmpty) return null;
    try {
      final v = jsonDecode(text);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// 发送消息
  Future<void> sendMessage(String content) async {
    appLog.d('[Chat] sendMessage: "${content.length > 100 ? '${content.substring(0, 100)}…' : content}" taskId=$_taskId model=${_preferredModelReader()} mode=${state.mode}');
    if (content.trim().isEmpty || _creating) return;

    // 任务运行中发送 → 服务端排队 (followupMode=queue), 不本地拦截。
    // 此时消息进队列不进消息列表 (queue 状态到达后由队列条展示)。
    final queued = state.isResponding && _taskId != null;
    if (queued) {
      state = state.copyWith(error: null);
      try {
        await _relay.sendConversationCommandV4(
          workspacePath: _ref.workspacePath,
          workspaceIdentity: _ref.workspaceIdentity,
          commandType: 'sendText',
          sessionId: _taskId,
          payload: {'text': content},
        );
        appLog.d('[Chat] 已加入队列 (${content.length} 字)');
      } catch (e) {
        appLog.w('[Chat] 排队发送失败: $e');
        state = state.copyWith(error: '发送失败: $e');
      }
      return;
    }

    // 1. 立即显示用户消息 + "思考中"占位:
    // _rebuildMessagesFromRows 从 rows 重建会覆盖乐观插入的消息,
    // 因此用 _pendingUserText 让重建把未落行的用户消息补回来。
    _pendingUserText = content;
    _pendingUserTextAt = DateTime.now();
    _respondingFallTimer?.cancel();
    _respondingFallTimer = null;
    state = state.copyWith(isResponding: true, error: null);
    _rebuildMessagesFromRows();

    try {
      // 3. 新会话: 先 createSession 拿 taskId, 再订阅 + 发消息
      if (_taskId == null) {
        _creating = true;
        // bridge 复用 (打开工作区时已开) + 幂等握手
        await _relay.ensureBridgeOpen(
            _ref.workspaceIdentity ?? _ref.workspacePath);
        // V4 命令前必须先握手 (3.7.7 实测顺序: hello → initialize → createSession,
        // 否则服务端报 fault.connection.handshakeRequired)
        await _relay.v4Handshake();
        appLog.i('[Chat] V4 createSession: mode=${state.mode}');
        // 3.7.7 迁移: 网页端已改走 sendConversationCommandV4(type: createSession)
        _taskId = await _relay.createSessionV4(
          workspacePath: _ref.workspacePath,
          workspaceIdentity: _ref.workspaceIdentity,
          mode: state.mode,
        );
        appLog.i('[Chat] 会话已创建(V4): $_taskId');
        // 热切换模型
        final desiredModel = _preferredModelReader();
        if (desiredModel != null) {
          try {
            await _relay.setSessionModel(
              workspacePath: _ref.workspacePath,
              sessionId: _taskId!,
              model: desiredModel,
            );
          } catch (e) {
            appLog.w('[Chat] 新会话热切换模型失败 ($desiredModel): $e');
          }
        }
        _onSessionCreated?.call(Task(
          id: _taskId!,
          workspaceKey: _ref.workspacePath,
          title: content,
          status: TaskStatus.running,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));
        // 订阅新会话 (V4 握手已在 createSession 前完成)
        final stream = await _relay.subscribeConversationV4(
          workspacePath: _ref.workspacePath,
          workspaceIdentity: _ref.workspaceIdentity,
          sessionId: _taskId!,
        );
        _frameSub = stream.listen(_onV4Frame);
      }
      // 4. V4 发送命令
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'sendText',
              sessionId: _taskId,
        payload: {'text': content},
      );
    } catch (e) {
      appLog.e('[Chat] 发送失败: $e');
      _pendingUserText = null;
      _pendingUserTextAt = null;
      _respondingFallTimer?.cancel();
      _respondingFallTimer = null;
      state = state.copyWith(
        isResponding: false,
        error: '发送失败: $e',
      );
      _rebuildMessagesFromRows();
    } finally {
      _creating = false;
    }
  }

  /// 处理 session 事件 (保留兼容, V4 不走此路径)
  Future<void> _onSessionEvent(SessionEvent event) async {}

  /// 处理 AskUserQuestion 工具事件 (V4 由 _applySnapshotState 处理)
  void _handleAskUserQuestion(SessionEvent event) {}

  /// 用户回答 AskUserQuestion
  Future<void> answerQuestion(List<String> selectedLabels) async {
    final q = state.pendingQuestion;
    if (q == null || _taskId == null) return;
    final answer = selectedLabels.join(', ');
    _respondingFallTimer?.cancel();
    _respondingFallTimer = null;
    state = state.copyWith(pendingQuestion: null, isResponding: true);
    try {
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'sendText',
              sessionId: _taskId,
        payload: {'text': '${q.question}=$answer'},
      );
    } catch (e) {
      appLog.w('[Chat] 回答提交失败: $e');
      state = state.copyWith(isResponding: false, error: '回答提交失败: $e');
    }
  }


  /// 回答工具权限确认 — V4 通过 sendConversationCommandV4(resolveInteraction)
  Future<void> answerPermission(String permissionId, String optionId, String decision,
      {Map<String, dynamic>? permInput, List<PermissionOption>? permOptions, String? permTraceId}) async {
    if (_taskId == null) return;

    Map<String, dynamic> fullResponse = {'decision': decision};
    if (permOptions != null) {
      final opt = permOptions.where((o) => o.optionId == optionId).firstOrNull;
      if (opt != null && opt.fullResponse.isNotEmpty) {
        fullResponse = opt.fullResponse;
      }
    }

    _respondingFallTimer?.cancel();
    _respondingFallTimer = null;
    state = state.copyWith(
      pendingPermissions: state.pendingPermissions.where((x) => x.id != permissionId).toList(),
      isResponding: true,
    );

    try {
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'resolveInteraction',
              sessionId: _taskId,
              baseRevision: _v4Revision,
              baseLogEpoch: _v4LogEpoch,
        // wire zod: payload 平铺 {interactionId, answer} — 外层再包命令名
        // 会报 proto.invalidPayload (同 switchCollaborationMode 的坑)。
        // answer 合并 option 的完整 response (含 reason/permissionUpdates,
        // 网页端同款 — allowAlways 的会话级放行依赖 permissionUpdates)。
        payload: {
          'interactionId': permissionId,
          'answer': {
            'optionId': optionId,
            'action': decision == 'deny' ? 'decline' : 'accept',
            ...fullResponse,
          },
        },
      );
    } catch (e) {
      appLog.w('[Chat] 权限确认失败 (permission=$permissionId, option=$optionId): $e');
      state = state.copyWith(isResponding: false, error: '权限确认失败: $e');
    }
  }

  /// 回答 plan 提议 — V4 也走 resolveInteraction
  Future<void> answerPlan(bool approved) async {
    if (state.pendingPlan == null || _taskId == null) return;
    _respondingFallTimer?.cancel();
    _respondingFallTimer = null;
    state = state.copyWith(pendingPlan: _clearPendingPlan, isResponding: true);
    try {
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'sendText',
              sessionId: _taskId,
        payload: {'text': approved ? 'User approved the plan, proceed' : 'User rejected the plan'},
      );
    } catch (e) {
      appLog.w('[Chat] plan 回答失败 (approved=$approved): $e');
      state = state.copyWith(isResponding: false, error: 'plan 回答失败: $e');
    }
  }

  /// 手动结束当前 AI 回复
  Future<void> stopResponding() async {
    // 乐观更新
    state = state.copyWith(isResponding: false);
    if (_taskId != null) {
      try {
        await _relay.sendConversationCommandV4(
          workspacePath: _ref.workspacePath,
          workspaceIdentity: _ref.workspaceIdentity,
          commandType: 'stop',
                sessionId: _taskId,
        );
      } catch (e) {
        appLog.w('[Chat] stop 失败: $e');
      }
    }
  }

  /// 回退最后一轮对话 (成功返回 true)
  Future<bool> rewindLastTurn() async {
    if (_taskId == null) return false;
    _respondingFallTimer?.cancel();
    _respondingFallTimer = null;
    state = state.copyWith(isResponding: true, error: null);
    try {
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'applyFileRewind',
              sessionId: _taskId,
              baseRevision: _v4Revision,
              baseLogEpoch: _v4LogEpoch,
        payload: {'target': 'lastTurn'},
      );
      await _loadHistory(forceReload: true);
      return true;
    } catch (e) {
      appLog.w('[Chat] 回退失败: $e');
      state = state.copyWith(isResponding: false, error: '回退失败: $e');
      return false;
    }
  }

  /// 编辑最后一条用户消息 (对齐网页端行为):
  /// wire 专用命令 editUserQuery (target=lastTurn, newText) — 服务端
  /// 原地改写该轮用户消息行并重新执行, 旧消息直接变成新消息、AI 重新回复。
  /// (不用 applyFileRewind+sendText 组合 — 那是回退文件变更, 不删对话轮次)
  Future<void> editLastUserMessage(String text) async {
    if (_taskId == null || text.trim().isEmpty) return;
    _respondingFallTimer?.cancel();
    _respondingFallTimer = null;
    state = state.copyWith(isResponding: true, error: null);
    try {
      // ★ wire zod 逐字段指路: target = {entityId: string, rowId: number}。
      //   userInput 行的 entityId == 该轮 turnId (rowsRange 实测);
      //   SplayTreeMap 按 rowId 升序, 最后一条 userInput 即值序列末个
      final lastUserRow = _rows.values.whereType<V4UserInputRow>().lastOrNull;
      await _relay.sendConversationCommandV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        commandType: 'editUserQuery',
        sessionId: _taskId,
        baseRevision: _v4Revision,
        baseLogEpoch: _v4LogEpoch,
        payload: {
          'target': {
            'entityId': lastUserRow?.turnId ?? '',
            'rowId': lastUserRow?.rowId ?? 0,
          },
          'newText': text,
        },
      );
      // ★ 行日志是 append-only: rewind 后旧行仍在 (turnHeader 仅被标
      //   completedInterrupted), 订阅流只推 upsert 不推删除 — 本地
      //   _rows 会残留旧轮。网页端行为 = 编辑成功后重拉快照 (服务端
      //   已剔除旧轮的当前视图), 这里对齐: 清空重建 (forceReload)。
      await _loadHistory(forceReload: true);
    } catch (e) {
      appLog.w('[Chat] 编辑消息失败: $e');
      state = state.copyWith(isResponding: false, error: '编辑失败: $e');
    }
  }

  /// 获取 Token 用量
  Future<Map<String, int>?> getTokenUsage() async {
    // V4: token usage 在 snapshot.usage 中, 不需单独 RPC
    return null;
  }

  /// 重新加载历史
  Future<void> reload() async {
    await _loadHistory();
  }

  /// bridge 重连后重新订阅 V4 事件流
  Future<void> _resubscribe() async {
    if (_taskId == null) return;
    try {
      // V4 handshake + subscribe
      await _relay.v4Handshake();
      final stream = await _relay.subscribeConversationV4(
        workspacePath: _ref.workspacePath,
        workspaceIdentity: _ref.workspaceIdentity,
        sessionId: _taskId!,
      );
      // 与 _init 同款: 流快照 completer 重置 (新订阅可能推新快照)
      _streamSnapshotDone = Completer<void>();
      _frameSub = stream.listen((f) {
        _onV4Frame(f);
        if (f.payload is V4SnapshotPayload) {
          final c = _streamSnapshotDone;
          if (c != null && !c.isCompleted) c.complete();
        }
      });
      // ★ 补拉断连期间错过的行: 行日志 append-only, 尾部读按 rowId 幂等
      //   合并 (没错过就 merged=0); turn 若已服务端完成, 补回的行含
      //   非 running control → fall timer 自然清掉卡住的 isResponding
      await _fetchRowsRange();
      appLog.i('[Chat] V4 resubscribe ✓ (尾部补拉完成)');
    } catch (e) {
      appLog.e('[Chat] V4 resubscribe FAILED: $e');
    }
  }

  @override
  void dispose() {
    _disposedNotifier = true;
    // 挂起的合并重建取消 (内存缓存已在每次重建即时写入, 无需落盘兜底)
    _rebuildDebounce?.cancel();
    _respondingFallTimer?.cancel();
    _frameSub?.cancel();
    _rpcReadySub?.cancel();
    super.dispose();
  }

  /// 子会话行 → 子代理 children 投影 (AgentCard 嵌套数据源)。
  /// 内存缓存 (子会话不可变历史); 递归限深 3 层 (子会话内再有 subagent 行
  /// 只保留摘要卡, 不再下钻)。失败向上抛, 由 AgentCard 降级为仅摘要。
  static const int _subagentDepthMax = 3;
  final Map<String, List<MessagePart>> _subagentChildrenCache = {};

  Future<List<MessagePart>> loadSubagentChildren(
    String childSessionId, {
    int depth = 1,
  }) async {
    final cached = _subagentChildrenCache[childSessionId];
    if (cached != null) return cached;
    final resp = await _relay.conversationRowsRangeV4(
      workspacePath: _ref.workspacePath,
      workspaceIdentity: _ref.workspaceIdentity,
      sessionId: childSessionId,
      limit: 200,
    );
    final rowsJson = (resp['rows'] as List?) ?? [];
    final parts = <MessagePart>[];
    for (final r in rowsJson.whereType<Map>()) {
      final row = V4Row.fromJson(Map<String, dynamic>.from(r));
      switch (row) {
        case V4AssistantTextRow() when row.text.isNotEmpty:
          parts.add(TextPart(row.text));
        case V4ReasoningRow() when row.text.isNotEmpty:
          parts.add(ThoughtPart(row.text));
        case V4ToolCallRow():
          parts.add(ToolPart(ToolActivity(
            toolCallId: row.toolCallId,
            toolName: row.toolName,
            status: row.status,
            input: row.input ?? _tryParseInputText(row.inputText),
            result: row.output?.text,
          )));
        case V4SubagentRow():
          // 深度内保留嵌套句柄 (其 children 由嵌套 AgentCard 再懒加载)
          parts.add(SubagentPart(
            subagentType: row.subagentType,
            status: row.status,
            summaryText: row.summaryText,
            childSessionId: depth < _subagentDepthMax ? row.childSessionId : null,
            parentToolCallId: row.parentToolCallId,
            rowIdKey: 'subagent_${row.rowId}',
          ));
        default:
          break;
      }
    }
    _subagentChildrenCache[childSessionId] = parts;
    return parts;
  }

  /// ★ 轮次完成时刻的元数据补读 (网页端同款行为)。
  /// 抓包实测 (web_turnheader_probe): 完成轮次的 turnHeader 权威时长
  /// (endedAt/activeMs) 在行日志里, 订阅流的尾部快照只有运行中轮次的
  /// header (无 endedAt)。网页端在完成后会补调 conversationRowsRangeV4
  /// 取回 — app 不补读的话, 完成的轮次算不出 workedMs → 显示"已处理"。
  Future<void> _refreshTurnMetadata() async {
    if (_metaRefreshQueued || _disposedNotifier) return;
    _metaRefreshQueued = true;
    try {
      // 小延迟: 等 host 把完成时刻的行日志落盘
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (_disposedNotifier || _taskId == null) return;
      await _fetchRowsRange(limit: 60);
    } catch (e) {
      appLog.w('[Chat] 完成元数据补读失败: $e');
    } finally {
      _metaRefreshQueued = false;
    }
  }
}

/// 对话 Provider (按 taskId+workspacePath 区分)
final chatProvider = StateNotifierProvider.autoDispose
    .family<ChatNotifier, ChatState, ChatRef>((ref, chatRef) {
  final relay = ref.watch(relayClientProvider);
  if (relay == null) {
    // 无 relay client 时返回一个空 notifier (不应发生, UI 应保证已登录)
    throw StateError('RelayClient not available');
  }
  return ChatNotifier(
    relay,
    chatRef,
    preferredModelReader: () => ref.read(preferredModelProvider),
    preferredModelSetter: (m) =>
        ref.read(preferredModelProvider.notifier).state = m,
    mergeDiscovered: (ids) =>
        ref.read(modelListProvider.notifier).mergeDiscoveredIds(ids),
    onSessionCreated: (task) {
      // 新会话加到 allTasksProvider 头部, 历史抽屉即时显示
      appLog.i('[Chat] onSessionCreated: ${task.id} ("${task.title}") 加入任务列表');
      final tasks = List<Task>.from(ref.read(allTasksProvider));
      if (!tasks.any((t) => t.id == task.id)) {
        ref.read(allTasksProvider.notifier).state = [task, ...tasks];
      }
    },
    onTitleUpdated: (taskId, newTitle) {
      // 服务端标题更新 (snapshot.meta.title): 用 copyWith 刷新对应 task,
      // 历史抽屉 (_HistoryDrawer) 等所有订阅 allTasksProvider 的 UI 自动重绘。
      appLog.d('[Chat] onTitleUpdated: $taskId → "$newTitle"');
      final tasks = ref.read(allTasksProvider);
      final idx = tasks.indexWhere((t) => t.id == taskId);
      if (idx < 0) return;
      if (tasks[idx].title == newTitle) return; // 无变化, 跳过
      final updated = List<Task>.from(tasks);
      updated[idx] = updated[idx].copyWith(title: newTitle);
      ref.read(allTasksProvider.notifier).state = updated;
    },
  );
});
