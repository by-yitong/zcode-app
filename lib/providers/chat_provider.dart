import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/app_logger.dart';
import '../core/notifications/notification_service.dart';
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

  bool get isRunning =>
      status == 'scheduled' ||
      status == 'started' ||
      status == 'progress' ||
      status == 'running';
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
  const ThoughtPart(this.text);
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
class DisplayMessage {
  final String id;
  final String role; // 'user' | 'assistant' | 'error'
  final String content;
  final String? thought;
  final String? model;
  final bool isStreaming;
  final DateTime createdAt;
  final List<ToolActivity> activities; // AI 调用的工具 (按到达顺序)
  /// 按序片段 (匹配 web 客户端 parts[])。非空时 UI 据此交错渲染,
  /// 否则回退到旧的 content/thought/activities 固定顺序渲染。
  final List<MessagePart> parts;

  DisplayMessage({
    required this.id,
    required this.role,
    required this.content,
    this.thought,
    this.model,
    this.isStreaming = false,
    this.activities = const [],
    this.parts = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  DisplayMessage copyWith({
    String? content,
    String? thought,
    String? model,
    bool? isStreaming,
    List<ToolActivity>? activities,
    List<MessagePart>? parts,
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
      final snapshotDone = Completer<void>();
      var gotSnapshot = false;
      _frameSub = stream.listen((f) {
        _onV4Frame(f);
        if (!gotSnapshot && f.payload is V4SnapshotPayload) {
          gotSnapshot = true;
          if (!snapshotDone.isCompleted) snapshotDone.complete();
        }
      });

      // 双路竞速: 订阅流 snapshot / getTaskSnapshot 并行, 先到先渲染
      // (state 更新幂等)。流路不 await — 大会话的流快照可能迟到/缺席,
      // 到达时 _onV4Frame 会自动刷新; RPC 路必达, 以它为准结束 init。
      unawaited(snapshotDone.future.then((_) {
        appLog.d('[Chat] _init: 流 snapshot 到达');
      }).catchError((_) {}));
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
      final resp = await _relay.getTaskSnapshot(
        taskId: _taskId!,
        workspacePath: _ref.workspacePath,
        messageLimit: 50,
      );
      final snapshot = resp['snapshot'] as Map<String, dynamic>?;
      if (snapshot == null) {
        state = state.copyWith(isLoadingHistory: false);
        return;
      }
      // V4 snapshot 可能用 rows 或 messages (host 版本决定)
      final rowsObj = snapshot['rows'] as Map<String, dynamic>?;
      final rowsList = rowsObj?['window'] as List<dynamic>?;
      final messagesJson = snapshot['messages'] as List<dynamic>?;
      
      if (rowsList != null && rowsList.isNotEmpty) {
        // V4 rows 格式
        _rows.clear();
        for (final r in rowsList.whereType<Map>()) {
          final row = V4Row.fromJson(Map<String, dynamic>.from(r));
          _rows[row.rowId] = row;
        }
        _rebuildMessagesFromRows();
        _applySnapshotState(V4ConversationSnapshot.fromJson(snapshot));
        appLog.d('[Chat] _loadHistory: ${_rows.length} rows loaded');
      } else if (messagesJson != null && messagesJson.isNotEmpty) {
        // V3 messages 格式 (host 兼容)
        final messages = messagesJson
            .whereType<Map>()
            .map((e) => _displayFromV3Message(Map<String, dynamic>.from(e)))
            .toList();
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
        state = state.copyWith(isLoadingHistory: false);
      }
    } catch (e) {
      appLog.e('[Chat] _loadHistory: FAILED: $e');
      // 已有内容 (缓存/流快照先渲染) 时不覆盖为全局错误
      if (state.messages.isEmpty) {
        state = state.copyWith(isLoadingHistory: false, error: '历史加载失败: $e');
      } else {
        state = state.copyWith(isLoadingHistory: false);
      }
    }
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

    if (frame.payload is V4SnapshotPayload) {
      final snap = (frame.payload as V4SnapshotPayload).snapshot;
      _v4SubscriptionId = frame.subscriptionId;
      _v4LogEpoch = snap.logEpoch;
      _v4Seq = snap.seq;
      _v4Revision = snap.revision;
      // 清空并重建 rows
      _rows.clear();
      for (final r in snap.rows.window) {
        _rows[r.rowId] = r;
      }
      _rebuildMessagesFromRows();
      _applySnapshotState(snap);
      appLog.d('[Chat] V4 snapshot: ${_rows.length} rows');
    } else if (frame.payload is V4DeltasPayload) {
      final deltas = (frame.payload as V4DeltasPayload).deltas;
      appLog.d('[Chat] V4 deltas: ${deltas.length} ops');
      for (final d in deltas) {
        _applyDelta(d);
      }
      _rebuildMessagesFromRows();
    }
  }

  /// 应用单个 delta 到 _rows / state
  void _applyDelta(V4Delta delta) {
    switch (delta) {
      case V4RowAppended(:final row):
        _rows[row.rowId] = row;
      case V4RowUpserted(:final row):
        _rows[row.rowId] = row;
      case V4RowRemoved(:final fromRowId):
        _rows.remove(fromRowId);
      case V4RowDeltaOp(:final rowId, :final path, :final append):
        final row = _rows[rowId];
        if (row == null) return;
        _rows[rowId] = _applyRowDelta(row, path, append);
      case V4StateUpdated(:final patch):
        _applyStatePatch(patch);
      case _:
        appLog.w('[Chat] V4 delta: unhandled ${delta.runtimeType}');
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
  void _rebuildMessagesFromRows() {
    final messages = <DisplayMessage>[];
    final sortedRows = _rows.values.toList()..sort((a, b) => a.rowId.compareTo(b.rowId));

    for (final row in sortedRows) {
      switch (row) {
        case V4TurnHeaderRow():
          // 轮次标题: 不渲染为消息, 但可标记 turn 边界
          continue;
        case V4UserInputRow():
          messages.add(DisplayMessage(
            id: 'row_${row.rowId}',
            role: 'user',
            content: row.text,
          ));
        case V4AssistantTextRow():
          if (row.text.isNotEmpty || row.state == 'streaming') {
            messages.add(DisplayMessage(
              id: 'row_${row.rowId}',
              role: 'assistant',
              content: row.text,
              model: row.model,
              isStreaming: row.state == 'streaming',
            ));
          }
        case V4ReasoningRow():
          // 思考行: 作为独立消息或附加到前一条 assistant 消息的 thought
          // 简化: 如果前一条是 assistant, 附加 thought; 否则单独显示
          if (row.text.isNotEmpty) {
            if (messages.isNotEmpty && messages.last.role == 'assistant') {
              final last = messages.last;
              messages[messages.length - 1] = last.copyWith(
                thought: (last.thought ?? '') + row.text,
              );
            } else {
              messages.add(DisplayMessage(
                id: 'row_${row.rowId}',
                role: 'assistant',
                content: '',
                thought: row.text,
                isStreaming: row.state == 'streaming',
              ));
            }
          }
        case V4ToolCallRow():
          // 工具调用: 附加到前一条 assistant 消息的 activities
          final activity = ToolActivity(
            toolCallId: row.toolCallId,
            toolName: row.toolName,
            status: row.status,
            input: row.input,
            result: row.output?.text,
          );
          if (messages.isNotEmpty && messages.last.role == 'assistant') {
            final last = messages.last;
            final activities = [...last.activities, activity];
            messages[messages.length - 1] = last.copyWith(activities: activities);
          } else {
            messages.add(DisplayMessage(
              id: 'row_${row.rowId}',
              role: 'assistant',
              content: '',
              activities: [activity],
              isStreaming: row.isRunning,
            ));
          }
        case V4SubagentRow():
          // 子代理: 作为工具活动显示
          final activity = ToolActivity(
            toolCallId: 'subagent_${row.rowId}',
            toolName: 'subagent (${row.subagentType})',
            status: row.status == 'running' ? 'running' : 'done',
            result: row.summaryText.isNotEmpty ? row.summaryText : null,
          );
          if (messages.isNotEmpty && messages.last.role == 'assistant') {
            final last = messages.last;
            messages[messages.length - 1] = last.copyWith(
              activities: [...last.activities, activity],
            );
          }
        case V4TimelineMarkerRow():
          continue;
        case V4UnknownRow():
          continue;
      }
    }

    // AI 正在回复但还没有新文本行 → 显示 "思考中" 占位
    if (state.isResponding) {
      final lastIsStreamingAi = messages.isNotEmpty &&
          messages.last.role == 'assistant' &&
          messages.last.isStreaming;
      if (!lastIsStreamingAi) {
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

  /// 发送消息
  Future<void> sendMessage(String content) async {
    appLog.d('[Chat] sendMessage: "${content.length > 100 ? '${content.substring(0, 100)}…' : content}" taskId=$_taskId model=${_preferredModelReader()} mode=${state.mode}');
    if (content.trim().isEmpty || state.isResponding || _creating) return;

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
