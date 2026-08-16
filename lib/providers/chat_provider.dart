import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/app_logger.dart';
import '../core/notifications/notification_service.dart';
import '../core/services/device_info_service.dart';
import '../core/relay/relay_client.dart';
import '../core/relay/relay_events.dart';
import '../core/relay/relay_protocol.dart';
import '../core/relay/rpc_codec.dart';
import '../core/storage/message_cache.dart';
import '../data/models/workspace.dart';
import 'app_providers.dart';

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

  /// V4 状态: 本地缓存的 rows (按 rowId 索引)
  final Map<int, V4Row> _rows = {};
  String? _v4SubscriptionId;
  String? _v4LogEpoch;
  int _v4Seq = 0;
  int _v4Revision = 0;

  // ── 行日志加载 (网页端模式: conversationRowsRangeV4) ──
  /// 流快照窗口的第一行 id (窗口之前还有更早历史)
  int? _rowsFirstRowId;
  /// 行日志总行数 (totalCount > 已有行数 = 有更早历史可翻)
  int _rowsTotalCount = 0;
  /// rowsRange 响应标记的 hasMore (更早方向)
  bool _hasMoreOlder = false;
  /// 翻页进行中标志
  bool _loadingOlder = false;
  /// 流首帧快照到达信号 (历史加载等它先渲染尾部窗口)
  Completer<void>? _streamSnapshotDone;

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
    _rpcReadySub = _relay.onRpcReadyChange.listen((ready) {
      if (ready && _taskId != null && !state.isResponding && _initDone && !_initRunning) {
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
        payload: {
          'switchCollaborationMode': {'mode': mode},
        },
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
        payload: {
          'switchModelConfig': {
            'provider': parts.length > 1 ? parts[0] : '',
            'model': parts.length > 1 ? parts[1] : modelId,
            'thought': level,
          },
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
        payload: {
          'switchModelConfig': {
            'provider': parts.length > 1 ? parts[0] : '',
            'model': parts.length > 1 ? parts[1] : modelId,
            'thought': state.thoughtLevel,
          },
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
        final cached = MessageCache.loadMessages(_taskId!);
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

  Future<void> _loadHistory() async {
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
          // 无流快照 (空闲会话常见): 直接读尾部
          rowsLoaded = await _fetchRowsRange();
        } else if (_rowsFirstRowId != null && _rowsFirstRowId! > 1) {
          // 流快照是尾部窗口: 补读窗口之前的全部更早行 (一次拉满)
          await _fetchRowsRange(beforeRowId: _rowsFirstRowId);
          rowsLoaded = _rows.isNotEmpty;
        } else if (_rows.isNotEmpty) {
          // 流快照已含全部行
          rowsLoaded = true;
        }
        if (rowsLoaded) {
          _cacheCurrentMessages();
          state = state.copyWith(isLoadingHistory: false);
          return;
        }
      } catch (e) {
        appLog.w('[Chat] 行日志加载失败, 降级快照兜底: $e');
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
        try { MessageCache.saveMessages(_taskId!, messages); } catch (_) {}
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
  Future<bool> _fetchRowsRange({int? beforeRowId, int limit = 200}) async {
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
      _logMarkerRow(row, 'rowsRange');
      _logTurnHeaderRow(row, 'rowsRange');
    }
    final first = rowsJson.whereType<Map>()
        .map((r) => (r['rowId'] as num?)?.toInt())
        .whereType<int>()
        .fold<int?>(null, (a, b) => a == null ? b : (a < b ? a : b));
    if (first != null && (_rowsFirstRowId == null || first < _rowsFirstRowId!)) {
      _rowsFirstRowId = first;
    }
    _hasMoreOlder = resp['hasMore'] == true;
    _rebuildMessagesFromRows();
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
    try {
      MessageCache.saveMessages(_taskId!, state.messages);
    } catch (_) {}
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
    appLog.d('[Chat] V4 frame: topic=${frame.topic} fromSeq=${frame.fromSeq} toSeq=${frame.toSeq}');

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
      for (final r in snap.rows.window) {
        _rows[r.rowId] = r;
        _logMarkerRow(r, 'snapshot');
        _logTurnHeaderRow(r, 'snapshot');
      }
      // 记录尾部窗口边界: 窗口之前可能还有更早历史 (rowsRange 翻页用)
      _rowsFirstRowId = snap.rows.firstRowId;
      _rowsTotalCount = snap.rows.totalCount;
      // ★ 先应用快照状态 (control.phase → isResponding), 再重建消息
      _applySnapshotState(snap);
      _rebuildMessagesFromRows();
      appLog.d('[Chat] V4 snapshot: ${_rows.length} rows '
          '(first=${snap.rows.firstRowId ?? '-'} total=${snap.rows.totalCount})');
    } else if (frame.payload is V4DeltasPayload) {
      final deltas = (frame.payload as V4DeltasPayload).deltas;
      appLog.d('[Chat] V4 deltas: ${deltas.length} ops');
      for (final d in deltas) {
        _applyDelta(d);
      }
      _rebuildMessagesFromRows();
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
        _trackRevision(row.revision);
        _logMarkerRow(row, 'delta');
        _logTurnHeaderRow(row, 'delta-append');
      case V4RowUpserted(:final row):
        _rows[row.rowId] = row;
        _trackRevision(row.revision);
        _logMarkerRow(row, 'delta');
        _logTurnHeaderRow(row, 'delta-upsert');
      case V4RowRemoved(:final fromRowId):
        _rows.remove(fromRowId);
      case V4RowDeltaOp(:final rowId, :final path, :final append):
        final row = _rows[rowId];
        if (row == null) return;
        _rows[rowId] = _applyRowDelta(row, path, append);
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
        // summaryText path
        break;
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
      state = state.copyWith(isResponding: ctrl.isRunning);
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
  void _rebuildMessagesFromRows() {
    final messages = <DisplayMessage>[];
    final sortedRows = _rows.values.toList()
      ..sort((a, b) => a.rowId.compareTo(b.rowId));

    // ── 当前轮次累积器 ──
    var turnId = '';
    V4TurnHeaderRow? header;
    var parts = <MessagePart>[];
    var activities = <ToolActivity>[];
    var contentBuf = StringBuffer();
    var thoughtBuf = StringBuffer();
    var lastTextState = '';
    var anyToolRunning = false;

    void flushTurn() {
      if (header == null && parts.isEmpty) return;
      final isRunning = (header?.isRunning ?? false) ||
          lastTextState == 'streaming' ||
          anyToolRunning;
      // 轮次为空且非运行中就不渲染 (ZCode 同样吞掉空轮次)
      if (parts.isEmpty && !isRunning) {
        header = null;
        return;
      }
      messages.add(DisplayMessage(
        id: 'turn_${turnId}_r${header?.rowId ?? 0}',
        role: 'assistant',
        content: contentBuf.toString(),
        thought: thoughtBuf.isEmpty ? null : thoughtBuf.toString(),
        model: null,
        isStreaming: isRunning,
        activities: activities,
        parts: parts,
        workedMs: header?.workedMs,
        turnStartedAt: header?.startedAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(header!.startedAt!),
        fileChanges: header?.fileChanges,
        createdAt: header?.startedAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(header!.startedAt!),
      ));
      header = null;
      parts = [];
      activities = [];
      contentBuf = StringBuffer();
      thoughtBuf = StringBuffer();
      lastTextState = '';
      anyToolRunning = false;
    }

    /// turnHeader 缺失时 (老数据/异常) 也能累积内容行;
    /// turnId 变化说明新轮次开始, 先冲刷上一轮
    void ensureTurn(String rowTurnId) {
      if (header == null && turnId != rowTurnId) {
        flushTurn();
        turnId = rowTurnId;
      }
    }

    for (final row in sortedRows) {
      switch (row) {
        case V4TurnHeaderRow():
          flushTurn();
          turnId = row.turnId;
          header = row;
        case V4UserInputRow():
          flushTurn();
          messages.add(DisplayMessage(
            id: 'row_${row.rowId}',
            role: 'user',
            content: row.text,
          ));
        case V4AssistantTextRow():
          if (row.text.isEmpty && row.state != 'streaming') continue;
          ensureTurn(row.turnId);
          if (row.text.isNotEmpty) {
            parts.add(TextPart(row.text));
            if (contentBuf.isNotEmpty) contentBuf.write('\n');
            contentBuf.write(row.text);
          }
          lastTextState = row.state;
        case V4ReasoningRow():
          if (row.text.isEmpty) continue;
          ensureTurn(row.turnId);
          parts.add(ThoughtPart(row.text, durationMs: row.durationMs));
          thoughtBuf.write(row.text);
        case V4ToolCallRow():
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
        case V4SubagentRow():
          ensureTurn(row.turnId);
          final activity = ToolActivity(
            toolCallId: 'subagent_${row.rowId}',
            toolName: 'subagent (${row.subagentType})',
            status: row.status == 'running' ? 'running' : 'done',
            result: row.summaryText.isNotEmpty ? row.summaryText : null,
          );
          parts.add(ToolPart(activity));
          activities.add(activity);
          if (row.status == 'running') anyToolRunning = true;
        case V4TimelineMarkerRow():
          // 压缩标记: 渲染为时间线分割线 (running=压缩中, 其余=已完成)
          if (row.marker['type'] == 'compact') {
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

    // ★ control.phase=running (isResponding) 是"任务仍在执行"的权威信号。
    //   步骤间隙 (上一个工具已完成、下一个行还没到达 / 权限等待 /
    //   turnHeader 缺失) 时, rows 里可能暂时没有任何 running 状态的行,
    //   会被误判为"已完成"而把过程收起 — 这里兜底: 会话运行中, 最后一轮
    //   (尚无权威完成时长 workedMs) 保持"工作中"态。
    //   已带 workedMs 的完成轮次不受影响 (排队间隙不会误开)。
    if (state.isResponding && messages.isNotEmpty) {
      final last = messages.last;
      if (last.role == 'assistant' &&
          !last.isStreaming &&
          last.workedMs == null) {
        messages[messages.length - 1] = last.copyWith(isStreaming: true);
      }
    }

    // AI 正在回复但还没有新文本行 → 显示 "思考中" 占位。
    // 压缩进行中除外 — 压缩标记药丸已在展示进度, 再叠"思考中"就重复了。
    if (state.isResponding) {
      final compactRunning =
          messages.any((m) => m.role == 'marker' && m.isStreaming);
      final lastIsStreamingAi = messages.isNotEmpty &&
          messages.last.role == 'assistant' &&
          messages.last.isStreaming;
      if (!lastIsStreamingAi && !compactRunning) {
        messages.add(DisplayMessage(
          id: 'thinking_placeholder',
          role: 'assistant',
          content: '',
          isStreaming: true,
        ));
      }
    }

    state = state.copyWith(messages: messages);
    // 缓存
    if (_taskId != null && messages.isNotEmpty) {
      try { MessageCache.saveMessages(_taskId!, messages); } catch (_) {}
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

    // 1. 立即显示用户消息
    final userMsg = DisplayMessage(
      id: _newMsgId(),
      role: 'user',
      content: content,
    );
    // 发送消息时乐观加了占位 AI 气泡, 但 _rebuildMessagesFromRows 会覆盖。
    // 改为: 不加乐观气泡, 只加用户消息 + isResponding
    state = state.copyWith(
      messages: [...state.messages, userMsg],
      isResponding: true,
      error: null,
    );
    // 立刻重建以显示 "思考中" 占位气泡
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
      state = state.copyWith(
        messages: state.messages.where((m) => m.id != userMsg.id).toList(),
        isResponding: false,
        error: '发送失败: $e',
      );
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
        payload: {
          'resolveInteraction': {
            'interactionId': permissionId,
            'answer': {
              'optionId': optionId,
              'action': decision == 'allow' ? 'accept' : (decision == 'deny' ? 'decline' : 'accept'),
            },
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

  /// 回退最后一轮对话
  Future<void> rewindLastTurn() async {
    if (_taskId == null) return;
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
      await _loadHistory();
    } catch (e) {
      appLog.w('[Chat] 回退失败: $e');
      state = state.copyWith(isResponding: false, error: '回退失败: $e');
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
      _frameSub = stream.listen(_onV4Frame);
      appLog.i('[Chat] V4 resubscribe ✓');
    } catch (e) {
      appLog.e('[Chat] V4 resubscribe FAILED: $e');
    }
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _rpcReadySub?.cancel();
    super.dispose();
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
