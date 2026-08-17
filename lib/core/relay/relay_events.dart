import 'dart:async';

/// V4 Frame — 服务器推送的基本单位
///
/// 通过 onDynamicConversationFrame (zcode-agent channel, listen) 接收。
/// 每个 Frame 包含 payload: snapshot (完整快照) 或 deltas (增量数组)。
class V4Frame {
  final String topic;
  final String subscriptionId;
  final int fromSeq;
  final int toSeq;
  final DateTime sentAt;
  final V4FramePayload payload;

  V4Frame({
    required this.topic,
    required this.subscriptionId,
    required this.fromSeq,
    required this.toSeq,
    required this.sentAt,
    required this.payload,
  });

  factory V4Frame.fromJson(Map<String, dynamic> j) {
    // V4 事件帧结构: 外层有 frame 字段, 内层才是实际 frame
    final inner = j['frame'] as Map<String, dynamic>? ?? j;

    final payloadRaw = inner['payload'] as Map<String, dynamic>? ?? {};
    final kind = payloadRaw['kind'] as String? ?? '';
    final V4FramePayload payload;
    if (kind == 'snapshot') {
      payload = V4SnapshotPayload.fromJson(payloadRaw);
    } else if (kind == 'deltas') {
      payload = V4DeltasPayload.fromJson(payloadRaw);
    } else {
      payload = V4UnknownPayload(kind);
    }
    return V4Frame(
      topic: inner['topic'] as String? ?? j['topic'] as String? ?? '',
      subscriptionId: inner['subscriptionId'] as String? ?? j['subscriptionId'] as String? ?? '',
      fromSeq: (inner['fromSeq'] as num?)?.toInt() ?? 0,
      toSeq: (inner['toSeq'] as num?)?.toInt() ?? 0,
      sentAt: inner['sentAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(inner['sentAt'] as int)
          : DateTime.now(),
      payload: payload,
    );
  }
}

sealed class V4FramePayload {}

class V4SnapshotPayload extends V4FramePayload {
  final V4ConversationSnapshot snapshot;
  V4SnapshotPayload(this.snapshot);

  factory V4SnapshotPayload.fromJson(Map<String, dynamic> j) {
    return V4SnapshotPayload(
      V4ConversationSnapshot.fromJson(j['snapshot'] as Map<String, dynamic>? ?? {}),
    );
  }
}

class V4DeltasPayload extends V4FramePayload {
  final List<V4Delta> deltas;
  V4DeltasPayload(this.deltas);

  factory V4DeltasPayload.fromJson(Map<String, dynamic> j) {
    final raw = j['deltas'] as List<dynamic>? ?? [];
    return V4DeltasPayload(
      raw.whereType<Map>().map((e) => V4Delta.fromJson(Map<String, dynamic>.from(e))).toList(),
    );
  }
}

class V4UnknownPayload extends V4FramePayload {
  final String kind;
  V4UnknownPayload(this.kind);
}

// ================================================================
// Delta 操作
// ================================================================

sealed class V4Delta {
  const V4Delta();

  factory V4Delta.fromJson(Map<String, dynamic> j) {
    final op = j['op'] as String? ?? '';
    return switch (op) {
      'row.appended' => V4RowAppended.fromJson(j),
      'row.upserted' => V4RowUpserted.fromJson(j),
      'row.removed' => V4RowRemoved.fromJson(j),
      'row.delta' => V4RowDeltaOp.fromJson(j),
      'state.updated' => V4StateUpdated.fromJson(j),
      'session.upserted' => V4SessionUpserted.fromJson(j),
      'session.removed' => V4SessionRemoved.fromJson(j),
      'config.updated' => V4ConfigUpdated.fromJson(j),
      _ => V4UnknownDelta(op, j),
    };
  }
}

class V4RowAppended extends V4Delta {
  final V4Row row;
  const V4RowAppended(this.row);
  factory V4RowAppended.fromJson(Map<String, dynamic> j) =>
      V4RowAppended(V4Row.fromJson(j['row'] as Map<String, dynamic>? ?? {}));
}

class V4RowUpserted extends V4Delta {
  final V4Row row;
  const V4RowUpserted(this.row);
  factory V4RowUpserted.fromJson(Map<String, dynamic> j) =>
      V4RowUpserted(V4Row.fromJson(j['row'] as Map<String, dynamic>? ?? {}));
}

class V4RowRemoved extends V4Delta {
  final int fromRowId;
  const V4RowRemoved(this.fromRowId);
  factory V4RowRemoved.fromJson(Map<String, dynamic> j) =>
      V4RowRemoved((j['fromRowId'] as num?)?.toInt() ?? 0);
}

/// 流式追加文本到指定 row 的 path 字段
class V4RowDeltaOp extends V4Delta {
  final int rowId;
  final String path; // "text" | "inputText" | "output.text" | "summaryText"
  final String append;
  const V4RowDeltaOp(this.rowId, this.path, this.append);
  factory V4RowDeltaOp.fromJson(Map<String, dynamic> j) => V4RowDeltaOp(
        (j['rowId'] as num?)?.toInt() ?? 0,
        j['path'] as String? ?? '',
        j['append'] as String? ?? '',
      );
}

/// 状态 patch — 更新 snapshot 的部分字段
class V4StateUpdated extends V4Delta {
  final Map<String, dynamic> patch;
  /// delta 级 revision (状态变化推进会话 revision, CAS 命令追踪用)
  final int revision;
  const V4StateUpdated(this.patch, {this.revision = 0});
  factory V4StateUpdated.fromJson(Map<String, dynamic> j) =>
      V4StateUpdated(j['patch'] as Map<String, dynamic>? ?? {},
          revision: (j['revision'] as num?)?.toInt() ?? 0);
}

class V4SessionUpserted extends V4Delta {
  final Map<String, dynamic> session;
  const V4SessionUpserted(this.session);
  factory V4SessionUpserted.fromJson(Map<String, dynamic> j) =>
      V4SessionUpserted(j['session'] as Map<String, dynamic>? ?? {});
}

class V4SessionRemoved extends V4Delta {
  final String sessionId;
  const V4SessionRemoved(this.sessionId);
  factory V4SessionRemoved.fromJson(Map<String, dynamic> j) =>
      V4SessionRemoved(j['sessionId'] as String? ?? '');
}

class V4ConfigUpdated extends V4Delta {
  final Map<String, dynamic> config;
  const V4ConfigUpdated(this.config);
  factory V4ConfigUpdated.fromJson(Map<String, dynamic> j) =>
      V4ConfigUpdated(j['config'] as Map<String, dynamic>? ?? {});
}

class V4UnknownDelta extends V4Delta {
  final String op;
  final Map<String, dynamic> raw;
  const V4UnknownDelta(this.op, this.raw);
}

// ================================================================
// V4 Conversation Snapshot
// ================================================================

class V4ConversationSnapshot {
  final int protocolVersion;
  final String sessionId;
  final String logEpoch;
  final int seq;
  final int revision;
  final V4Control control;
  final V4Config config;
  final V4Meta meta;
  final V4Usage? usage;
  final V4Goal? goal;
  final List<V4PlanItem> plan;
  final V4Rows rows;
  final List<V4PendingInteraction> pendingInteractions;
  final List<V4BackgroundWork> backgroundWorks;
  final V4Subagents? subagents;
  final V4Queue queue;
  final Map<String, dynamic> raw;

  V4ConversationSnapshot({
    this.protocolVersion = 1,
    required this.sessionId,
    this.logEpoch = '',
    this.seq = 0,
    this.revision = 0,
    required this.control,
    required this.config,
    required this.meta,
    this.usage,
    this.goal,
    this.plan = const [],
    required this.rows,
    this.pendingInteractions = const [],
    this.backgroundWorks = const [],
    this.subagents,
    this.queue = const V4Queue(),
    this.raw = const {},
  });

  factory V4ConversationSnapshot.fromJson(Map<String, dynamic> j) {
    return V4ConversationSnapshot(
      protocolVersion: j['protocolVersion'] as int? ?? 1,
      sessionId: j['sessionId'] as String? ?? '',
      logEpoch: j['logEpoch'] as String? ?? '',
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      revision: (j['revision'] as num?)?.toInt() ?? 0,
      control: V4Control.fromJson(j['control'] as Map<String, dynamic>? ?? {}),
      config: V4Config.fromJson(j['config'] as Map<String, dynamic>? ?? {}),
      meta: V4Meta.fromJson(j['meta'] as Map<String, dynamic>? ?? {}),
      usage: j['usage'] is Map
          ? V4Usage.fromJson(j['usage'] as Map<String, dynamic>)
          : null,
      goal: j['goal'] is Map
          ? V4Goal.fromJson(j['goal'] as Map<String, dynamic>)
          : null,
      plan: (j['plan'] as Map<String, dynamic>?)?['items'] is List
          ? ((j['plan'] as Map<String, dynamic>)['items'] as List)
              .whereType<Map>()
              .map((e) => V4PlanItem.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : [],
      rows: V4Rows.fromJson(j['rows'] as Map<String, dynamic>? ?? {}),
      queue: V4Queue.fromJson(j['queue'] as Map<String, dynamic>? ?? {}),
      pendingInteractions: (j['pendingInteractions'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((e) => V4PendingInteraction.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      backgroundWorks: (j['backgroundWorks'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((e) => V4BackgroundWork.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      subagents: j['subagents'] is Map
          ? V4Subagents.fromJson(j['subagents'] as Map<String, dynamic>)
          : null,
      raw: j,
    );
  }
}

/// 队列项 (state.queue.items[] — 任务运行中发送、被服务端排队的消息)
class V4QueueItem {
  final String queueItemId;
  final String kind; // sendText | sendGoalCommand
  final String text;

  const V4QueueItem({
    required this.queueItemId,
    this.kind = '',
    this.text = '',
  });

  factory V4QueueItem.fromJson(Map<String, dynamic> j) {
    final payload = j['payload'];
    return V4QueueItem(
      queueItemId: j['queueItemId'] as String? ??
          j['sourceCommandId'] as String? ??
          '',
      kind: j['kind'] as String? ?? '',
      text: (j['text'] as String?) ??
          (payload is Map ? payload['text'] as String? : null) ??
          '',
    );
  }
}

/// 队列状态 (state.queue)
class V4Queue {
  final List<V4QueueItem> items;
  final bool autoDrain;

  const V4Queue({this.items = const [], this.autoDrain = true});

  factory V4Queue.fromJson(Map<String, dynamic> j) => V4Queue(
        items: (j['items'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => V4QueueItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        autoDrain: j['autoDrain'] as bool? ?? true,
      );
}

class V4Control {
  final String phase; // running|completedSuccess|completedInterrupted|error|draft|prewarming
  final bool sessionEnded;
  final bool canStop;
  final String stopState; // idle|stoppable|stopping
  final Map<String, dynamic> lastError;
  final Map<String, dynamic> raw;

  V4Control({
    this.phase = 'draft',
    this.sessionEnded = false,
    this.canStop = false,
    this.stopState = 'idle',
    this.lastError = const {},
    this.raw = const {},
  });

  factory V4Control.fromJson(Map<String, dynamic> j) => V4Control(
        phase: j['phase'] as String? ?? 'draft',
        sessionEnded: j['sessionEnded'] as bool? ?? false,
        canStop: j['canStop'] as bool? ?? false,
        stopState: j['stopState'] as String? ?? 'idle',
        lastError: j['lastError'] as Map<String, dynamic>? ?? {},
        raw: j,
      );

  bool get isRunning => phase == 'running';
  bool get isComplete =>
      phase == 'completedSuccess' || phase == 'completedInterrupted';
}

class V4Config {
  final String provider;
  final String model;
  final String thought;
  final List<String> thoughtLevels;
  final String followupMode;
  final String mode;

  V4Config({
    this.provider = '',
    this.model = '',
    this.thought = 'max',
    this.thoughtLevels = const ['max', 'medium', 'nothink'],
    this.followupMode = 'queue',
    this.mode = 'build',
  });

  factory V4Config.fromJson(Map<String, dynamic> j) => V4Config(
        provider: j['provider'] as String? ?? '',
        model: j['model'] as String? ?? '',
        thought: j['thought'] as String? ?? 'max',
        thoughtLevels: (j['thoughtLevels'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        followupMode: j['followupMode'] as String? ?? 'queue',
        mode: j['mode'] as String? ?? 'build',
      );

  /// 完整模型 ID: "provider/model"
  String get modelId => provider.isNotEmpty && model.isNotEmpty
      ? '$provider/$model'
      : model;
}

class V4Meta {
  final String title;
  final String titleSource;

  V4Meta({this.title = '', this.titleSource = 'default'});

  factory V4Meta.fromJson(Map<String, dynamic> j) => V4Meta(
        title: j['title'] as String? ?? '',
        titleSource: j['titleSource'] as String? ?? 'default',
      );
}

class V4Usage {
  final V4ContextWindow? contextWindow;

  V4Usage({this.contextWindow});

  factory V4Usage.fromJson(Map<String, dynamic> j) => V4Usage(
        contextWindow: j['contextWindow'] is Map
            ? V4ContextWindow.fromJson(j['contextWindow'] as Map<String, dynamic>)
            : null,
      );
}

class V4ContextWindow {
  final int usedTokens;
  final int maxTokens;
  final int? autoCompactThresholdTokens;

  V4ContextWindow({
    this.usedTokens = 0,
    this.maxTokens = 0,
    this.autoCompactThresholdTokens,
  });

  factory V4ContextWindow.fromJson(Map<String, dynamic> j) => V4ContextWindow(
        usedTokens: (j['usedTokens'] as num?)?.toInt() ?? 0,
        maxTokens: (j['maxTokens'] as num?)?.toInt() ?? 0,
        autoCompactThresholdTokens:
            (j['autoCompactThresholdTokens'] as num?)?.toInt(),
      );
}

class V4Goal {
  final String objective;
  final String status;

  V4Goal({this.objective = '', this.status = 'active'});

  factory V4Goal.fromJson(Map<String, dynamic> j) => V4Goal(
        objective: j['objective'] as String? ?? '',
        status: j['status'] as String? ?? 'active',
      );
}

class V4PlanItem {
  final String id;
  final String content;
  final String status; // pending|inProgress|completed

  V4PlanItem({required this.id, required this.content, this.status = 'pending'});

  factory V4PlanItem.fromJson(Map<String, dynamic> j) => V4PlanItem(
        id: j['id'] as String? ?? '',
        content: j['content'] as String? ?? '',
        status: j['status'] as String? ?? 'pending',
      );
}

class V4Rows {
  final List<V4Row> window;
  final int totalCount;
  final int? firstRowId;

  V4Rows({this.window = const [], this.totalCount = 0, this.firstRowId});

  factory V4Rows.fromJson(Map<String, dynamic> j) => V4Rows(
        window: (j['window'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => V4Row.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        totalCount: (j['totalCount'] as num?)?.toInt() ?? 0,
        firstRowId: (j['firstRowId'] as num?)?.toInt(),
      );
}

// ================================================================
// V4 Row — 消息行 (替代 v3 的 messages[])
// ================================================================

sealed class V4Row {
  final int rowId;
  final String turnId;
  final int revision;

  const V4Row({required this.rowId, this.turnId = '', this.revision = 0});

  factory V4Row.fromJson(Map<String, dynamic> j) {
    final kind = j['kind'] as String? ?? '';
    return switch (kind) {
      'turnHeader' => V4TurnHeaderRow.fromJson(j),
      'userInput' => V4UserInputRow.fromJson(j),
      'assistantText' => V4AssistantTextRow.fromJson(j),
      'reasoning' => V4ReasoningRow.fromJson(j),
      'toolCall' => V4ToolCallRow.fromJson(j),
      'subagent' => V4SubagentRow.fromJson(j),
      'timelineMarker' => V4TimelineMarkerRow.fromJson(j),
      _ => V4UnknownRow.fromJson(j),
    };
  }

  Map<String, dynamic> toJson();
}

/// turnHeader 的文件变更统计 (host Zod schema 实测 3.7.7):
///   {additions, deletions, files, state?: "active"|"reverted"}
/// 这是 "N 个文件已更改 +N −M" 的权威数据源。
class V4TurnFileChanges {
  final int additions;
  final int deletions;
  final int files;

  V4TurnFileChanges({
    this.additions = 0,
    this.deletions = 0,
    this.files = 0,
  });

  factory V4TurnFileChanges.fromJson(Map<String, dynamic> j) =>
      V4TurnFileChanges(
        additions: (j['additions'] as num?)?.toInt() ?? 0,
        deletions: (j['deletions'] as num?)?.toInt() ?? 0,
        files: (j['files'] as num?)?.toInt() ?? 0,
      );
}

/// 轮次头 — 每个对话轮一条, 携带本轮的工作时长与文件变更。
///
/// 工作时长 (桌面端 asar 逆向, hyt/byt 函数):
///   优先 activeMs (服务器算好的活跃时长, 排除等待);
///   否则 endedAt - startedAt (已完成);
///   运行中用 now - startedAt 实时跳动。
///   state: running | completedSuccess | completedInterrupted | failed
class V4TurnHeaderRow extends V4Row {
  final String origin;
  final String executionKind;
  final String state;
  /// 轮次开始时间 (ms epoch, 必有)
  final int? startedAt;
  /// 轮次结束时间 (ms epoch, 完成后才有)
  final int? endedAt;
  /// 服务器计算的活跃时长 (优先于 endedAt-startedAt)
  final int? activeMs;
  /// 本轮文件变更统计 (权威来源)
  final V4TurnFileChanges? fileChanges;

  V4TurnHeaderRow({
    required super.rowId,
    super.turnId,
    super.revision,
    this.origin = 'userInput',
    this.executionKind = 'agent',
    this.state = 'running',
    this.startedAt,
    this.endedAt,
    this.activeMs,
    this.fileChanges,
  });

  factory V4TurnHeaderRow.fromJson(Map<String, dynamic> j) => V4TurnHeaderRow(
        rowId: (j['rowId'] as num?)?.toInt() ?? 0,
        turnId: j['turnId'] as String? ?? '',
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        origin: j['origin'] as String? ?? 'userInput',
        executionKind: j['executionKind'] as String? ?? 'agent',
        state: j['state'] as String? ?? 'running',
        startedAt: (j['startedAt'] as num?)?.toInt(),
        endedAt: (j['endedAt'] as num?)?.toInt(),
        activeMs: (j['activeMs'] as num?)?.toInt(),
        fileChanges: j['fileChanges'] is Map
            ? V4TurnFileChanges.fromJson(
                Map<String, dynamic>.from(j['fileChanges'] as Map))
            : null,
      );

  /// 轮次是否仍在运行
  bool get isRunning => state == 'running';

  /// 轮次是否被打断 (用户停止/中断后落定的完成态)。
  /// 桌面端 (AssistantMessage interrupted prop) 对应场景:
  /// 打断的轮次无"尾段正文" → 整轮展开, 不折叠过程。
  bool get isInterrupted => state == 'completedInterrupted';

  /// 计算工作时长 (对齐桌面端 hyt: activeMs > endedAt-startedAt)。
  /// 运行中返回 null, 由 UI 用 startedAt 实时跳动。
  int? get workedMs {
    if (isRunning) return null;
    if (activeMs != null) return activeMs;
    final s = startedAt, e = endedAt;
    if (s != null && e != null) return (e - s).clamp(0, 1 << 40);
    return null;
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'turnHeader', 'rowId': rowId, 'origin': origin,
        'executionKind': executionKind, 'state': state,
      };
}

class V4UserInputRow extends V4Row {
  final String text;
  /// ★ 引导输入: AI 工作中途的插话 (inputRouting.mode=guide)。
  /// 不开新轮次, 而是把当前轮次切成多个工作段 (workSegments)。
  final bool guided;
  /// 行实体 ID (用于匹配 workSegments[].triggerEntityId)
  final String? entityId;

  V4UserInputRow({
    required super.rowId,
    super.turnId,
    super.revision,
    this.text = '',
    this.guided = false,
    this.entityId,
  });

  factory V4UserInputRow.fromJson(Map<String, dynamic> j) => V4UserInputRow(
        rowId: (j['rowId'] as num?)?.toInt() ?? 0,
        turnId: j['turnId'] as String? ?? '',
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        text: j['text'] as String? ?? '',
        guided: j['guided'] as bool? ?? false,
        entityId: j['entityId'] as String?,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'userInput', 'rowId': rowId, 'text': text};
}

class V4AssistantTextRow extends V4Row {
  final String text;
  final String state; // streaming|complete|interrupted|failed
  final String? model;
  final String? feedback; // like|dislike|null

  V4AssistantTextRow({
    required super.rowId,
    super.turnId,
    super.revision,
    this.text = '',
    this.state = 'streaming',
    this.model,
    this.feedback,
  });

  factory V4AssistantTextRow.fromJson(Map<String, dynamic> j) =>
      V4AssistantTextRow(
        rowId: (j['rowId'] as num?)?.toInt() ?? 0,
        turnId: j['turnId'] as String? ?? '',
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        text: j['text'] as String? ?? '',
        state: j['state'] as String? ?? 'streaming',
        model: j['model'] as String?,
        feedback: j['feedback'] as String?,
      );

  V4AssistantTextRow copyWith({
    String? text,
    String? state,
    String? model,
    String? feedback,
  }) =>
      V4AssistantTextRow(
        rowId: rowId, turnId: turnId, revision: revision,
        text: text ?? this.text,
        state: state ?? this.state,
        model: model ?? this.model,
        feedback: feedback ?? this.feedback,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'assistantText', 'rowId': rowId, 'text': text, 'state': state};
}

class V4ReasoningRow extends V4Row {
  final String text;
  final String state; // streaming|complete|interrupted
  final int? durationMs;

  V4ReasoningRow({
    required super.rowId,
    super.turnId,
    super.revision,
    this.text = '',
    this.state = 'streaming',
    this.durationMs,
  });

  factory V4ReasoningRow.fromJson(Map<String, dynamic> j) => V4ReasoningRow(
        rowId: (j['rowId'] as num?)?.toInt() ?? 0,
        turnId: j['turnId'] as String? ?? '',
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        text: j['text'] as String? ?? '',
        state: j['state'] as String? ?? 'streaming',
        durationMs: (j['durationMs'] as num?)?.toInt(),
      );

  V4ReasoningRow copyWith({String? text, String? state, int? durationMs}) =>
      V4ReasoningRow(
        rowId: rowId, turnId: turnId, revision: revision,
        text: text ?? this.text,
        state: state ?? this.state,
        durationMs: durationMs ?? this.durationMs,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'reasoning', 'rowId': rowId, 'text': text, 'state': state};
}

class V4ToolCallRow extends V4Row {
  final String toolCallId;
  final String toolName;
  final String status; // inputStreaming|pendingApproval|running|success|error|cancelled
  final String inputText;
  final Map<String, dynamic>? input;
  final V4ToolOutput? output;
  final Map<String, dynamic>? error;

  V4ToolCallRow({
    required super.rowId,
    super.turnId,
    super.revision,
    required this.toolCallId,
    required this.toolName,
    this.status = 'running',
    this.inputText = '',
    this.input,
    this.output,
    this.error,
  });

  factory V4ToolCallRow.fromJson(Map<String, dynamic> j) => V4ToolCallRow(
        rowId: (j['rowId'] as num?)?.toInt() ?? 0,
        turnId: j['turnId'] as String? ?? '',
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        toolCallId: j['toolCallId'] as String? ?? '',
        toolName: j['toolName'] as String? ?? '',
        status: j['status'] as String? ?? 'running',
        inputText: j['inputText'] as String? ?? '',
        input: j['input'] as Map<String, dynamic>?,
        output: j['output'] is Map
            ? V4ToolOutput.fromJson(j['output'] as Map<String, dynamic>)
            : null,
        error: j['error'] as Map<String, dynamic>?,
      );

  V4ToolCallRow copyWith({
    String? status,
    String? inputText,
    Map<String, dynamic>? input,
    V4ToolOutput? output,
    Map<String, dynamic>? error,
  }) =>
      V4ToolCallRow(
        rowId: rowId, turnId: turnId, revision: revision,
        toolCallId: toolCallId, toolName: toolName,
        status: status ?? this.status,
        inputText: inputText ?? this.inputText,
        input: input ?? this.input,
        output: output ?? this.output,
        error: error ?? this.error,
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'toolCall', 'rowId': rowId,
        'toolCallId': toolCallId, 'toolName': toolName, 'status': status,
      };

  bool get isPendingApproval => status == 'pendingApproval';
  /// 等待批准也算"未完成" — 轮次保持工作中态, 过程不收起
  bool get isRunning =>
      status == 'running' ||
      status == 'inputStreaming' ||
      status == 'pendingApproval';
  bool get isDone =>
      status == 'success' || status == 'error' || status == 'cancelled';
}

class V4ToolOutput {
  final String text;

  V4ToolOutput({this.text = ''});

  factory V4ToolOutput.fromJson(Map<String, dynamic> j) => V4ToolOutput(
        text: j['text'] as String? ?? '',
      );

  V4ToolOutput copyWith({String? text}) =>
      V4ToolOutput(text: text ?? this.text);
}

class V4SubagentRow extends V4Row {
  final String subagentType;
  final String status;
  final String summaryText;
  final String? childSessionId;

  V4SubagentRow({
    required super.rowId,
    super.turnId,
    super.revision,
    this.subagentType = '',
    this.status = 'running',
    this.summaryText = '',
    this.childSessionId,
  });

  factory V4SubagentRow.fromJson(Map<String, dynamic> j) => V4SubagentRow(
        rowId: (j['rowId'] as num?)?.toInt() ?? 0,
        turnId: j['turnId'] as String? ?? '',
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        subagentType: j['subagentType'] as String? ?? '',
        status: j['status'] as String? ?? 'running',
        summaryText: j['summaryText'] as String? ?? '',
        childSessionId: j['childSessionId'] as String?,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'subagent', 'rowId': rowId, 'subagentType': subagentType};
}

class V4TimelineMarkerRow extends V4Row {
  final String sourceCommandId;
  final String lane;
  final Map<String, dynamic> marker; // 原始 marker (compact 统计等)
  final Map<String, dynamic> raw;

  V4TimelineMarkerRow({
    required super.rowId,
    super.turnId,
    super.revision,
    this.sourceCommandId = '',
    this.lane = '',
    this.marker = const {},
    this.raw = const {},
  });

  factory V4TimelineMarkerRow.fromJson(Map<String, dynamic> j) =>
      V4TimelineMarkerRow(
        rowId: (j['rowId'] as num?)?.toInt() ?? 0,
        turnId: j['turnId'] as String? ?? '',
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        sourceCommandId: j['sourceCommandId'] as String? ?? '',
        lane: j['lane'] as String? ?? '',
        marker: j['marker'] is Map
            ? Map<String, dynamic>.from(j['marker'] as Map)
            : const {},
        raw: Map<String, dynamic>.from(j),
      );

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'timelineMarker', 'rowId': rowId, 'lane': lane};
}

class V4UnknownRow extends V4Row {
  final String kind;
  final Map<String, dynamic> raw;

  V4UnknownRow({
    required super.rowId,
    super.turnId,
    super.revision,
    this.kind = 'unknown',
    this.raw = const {},
  });

  factory V4UnknownRow.fromJson(Map<String, dynamic> j) => V4UnknownRow(
        rowId: (j['rowId'] as num?)?.toInt() ?? 0,
        turnId: j['turnId'] as String? ?? '',
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        kind: j['kind'] as String? ?? 'unknown',
        raw: j,
      );

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'rowId': rowId, ...raw};
}

// ================================================================
// Pending Interaction (权限/用户输入请求)
// ================================================================

class V4PendingInteraction {
  final String interactionId;
  final String kind; // permission|userInput
  final int? anchorRowId;
  final DateTime createdAt;
  final V4PermissionPayload? permission;
  final V4UserInputPayload? userInput;

  V4PendingInteraction({
    required this.interactionId,
    required this.kind,
    this.anchorRowId,
    required this.createdAt,
    this.permission,
    this.userInput,
  });

  factory V4PendingInteraction.fromJson(Map<String, dynamic> j) {
    final kind = j['kind'] as String? ?? 'permission';
    final payload = j['payload'] as Map<String, dynamic>?;
    return V4PendingInteraction(
      interactionId: j['interactionId'] as String? ?? '',
      kind: kind,
      anchorRowId: (j['anchorRowId'] as num?)?.toInt(),
      createdAt: j['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int)
          : DateTime.now(),
      permission: kind == 'permission' && payload != null
          ? V4PermissionPayload.fromJson(payload)
          : null,
      userInput: kind == 'userInput' && payload != null
          ? V4UserInputPayload.fromJson(payload)
          : null,
    );
  }
}

class V4PermissionPayload {
  final String toolCallId;
  final String toolName;
  final String summary;
  final Map<String, dynamic> detail;
  final List<V4PermissionOption> options;

  V4PermissionPayload({
    this.toolCallId = '',
    this.toolName = '',
    this.summary = '',
    this.detail = const {},
    this.options = const [],
  });

  factory V4PermissionPayload.fromJson(Map<String, dynamic> j) =>
      V4PermissionPayload(
        toolCallId: j['toolCallId'] as String? ?? '',
        toolName: j['toolName'] as String? ?? '',
        summary: j['summary'] as String? ?? '',
        detail: j['detail'] as Map<String, dynamic>? ?? {},
        options: (j['options'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) =>
                V4PermissionOption.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class V4PermissionOption {
  final String optionId;
  final String label;
  final String kind; // allowOnce|allowAlways|deny|custom
  final Map<String, dynamic> response;

  V4PermissionOption({
    required this.optionId,
    required this.label,
    this.kind = 'allowOnce',
    this.response = const {},
  });

  factory V4PermissionOption.fromJson(Map<String, dynamic> j) =>
      V4PermissionOption(
        optionId: j['optionId'] as String? ?? '',
        label: j['label'] as String? ?? '',
        kind: j['kind'] as String? ?? 'allowOnce',
        response: j['response'] as Map<String, dynamic>? ?? {},
      );
}

class V4UserInputPayload {
  final String prompt;
  final bool freeText;
  final List<V4UserInputOption> options;
  final bool sensitive;
  final String? toolName;
  final List<V4Question> questions;
  final int? currentQuestionIndex;

  V4UserInputPayload({
    this.prompt = '',
    this.freeText = false,
    this.options = const [],
    this.sensitive = false,
    this.toolName,
    this.questions = const [],
    this.currentQuestionIndex,
  });

  factory V4UserInputPayload.fromJson(Map<String, dynamic> j) =>
      V4UserInputPayload(
        prompt: j['prompt'] as String? ?? '',
        freeText: j['freeText'] as bool? ?? false,
        options: (j['options'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) =>
                V4UserInputOption.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        sensitive: j['sensitive'] as bool? ?? false,
        toolName: j['toolName'] as String?,
        questions: (j['questions'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => V4Question.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        currentQuestionIndex: (j['currentQuestionIndex'] as num?)?.toInt(),
      );
}

class V4UserInputOption {
  final String optionId;
  final String label;

  V4UserInputOption({required this.optionId, required this.label});

  factory V4UserInputOption.fromJson(Map<String, dynamic> j) =>
      V4UserInputOption(
        optionId: j['optionId'] as String? ?? '',
        label: j['label'] as String? ?? '',
      );
}

class V4Question {
  final String question;
  final String header;
  final bool multiSelect;
  final List<V4QuestionOption> options;

  V4Question({
    this.question = '',
    this.header = '',
    this.multiSelect = false,
    this.options = const [],
  });

  factory V4Question.fromJson(Map<String, dynamic> j) => V4Question(
        question: j['question'] as String? ?? '',
        header: j['header'] as String? ?? '',
        multiSelect: j['multiSelect'] as bool? ?? false,
        options: (j['options'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => V4QuestionOption.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class V4QuestionOption {
  final String value;
  final String label;
  final String? description;

  V4QuestionOption({required this.value, required this.label, this.description});

  factory V4QuestionOption.fromJson(Map<String, dynamic> j) =>
      V4QuestionOption(
        value: j['value'] as String? ?? '',
        label: j['label'] as String? ?? '',
        description: j['description'] as String?,
      );
}

// ================================================================
// V3 兼容层 (relay_client.dart 仍引用, 逐步清理)
// ================================================================

/// V3 SessionEvent — 兼容壳 (V4 不使用)
class SessionEvent {
  final String kind;
  final String type;
  final String sessionId;
  final int seq;
  final Map<String, dynamic> payload;
  final String? toolCallId;
  final String? toolName;
  final String? delta;
  final String? turnId;
  final bool isDone;

  SessionEvent({
    this.kind = '',
    this.type = '',
    this.sessionId = '',
    this.seq = 0,
    this.payload = const {},
    this.toolCallId,
    this.toolName,
    this.delta,
    this.turnId,
    this.isDone = false,
  });

  factory SessionEvent.fromBody(dynamic body) {
    if (body is! Map) return SessionEvent();
    final j = Map<String, dynamic>.from(body);
    return SessionEvent(
      kind: j['kind'] as String? ?? '',
      type: j['type'] as String? ?? '',
      sessionId: j['sessionId'] as String? ?? '',
      payload: j,
      toolCallId: j['toolCallId'] as String?,
      toolName: j['toolName'] as String?,
    );
  }

  bool get isTextDelta => false;
  bool get isReasoningDelta => false;
  bool get isTurnCompleted => false;
  bool get isTurnStarted => false;
  bool get isToolEvent => false;
  bool get isTaskComplete => false;
  bool get isTaskError => false;
}

// AgentEvent 兼容壳
sealed class AgentEvent {}
class AgentMessageChunk extends AgentEvent {}

class V4BackgroundWork {
  final String workId;
  final String kind; // bash|subagent
  final String title;
  final String status; // running|resultPending|failed|cancelled
  final DateTime startedAt;

  V4BackgroundWork({
    required this.workId,
    this.kind = 'bash',
    this.title = '',
    this.status = 'running',
    required this.startedAt,
  });

  factory V4BackgroundWork.fromJson(Map<String, dynamic> j) =>
      V4BackgroundWork(
        workId: j['workId'] as String? ?? '',
        kind: j['kind'] as String? ?? 'bash',
        title: j['title'] as String? ?? '',
        status: j['status'] as String? ?? 'running',
        startedAt: j['startedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(j['startedAt'] as int)
            : DateTime.now(),
      );
}

class V4Subagents {
  final int revision;
  final List<String> childSessionIds;
  final int endedTotal;

  V4Subagents({
    this.revision = 0,
    this.childSessionIds = const [],
    this.endedTotal = 0,
  });

  factory V4Subagents.fromJson(Map<String, dynamic> j) => V4Subagents(
        revision: (j['revision'] as num?)?.toInt() ?? 0,
        childSessionIds: (j['childSessionIds'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        endedTotal: (j['endedTotal'] as num?)?.toInt() ?? 0,
      );
}
