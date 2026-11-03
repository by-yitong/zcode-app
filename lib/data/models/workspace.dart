/// 工作区类型
enum WorkspaceKind {
  local('local'),
  remote('remote');

  final String value;
  const WorkspaceKind(this.value);

  static WorkspaceKind fromString(String? value) {
    if (value == 'remote') return WorkspaceKind.remote;
    return WorkspaceKind.local;
  }
}

/// 工作区/项目
class Workspace {
  final String workspaceKey;
  final String workspaceIdentity;
  final String workspacePath;
  final String name;
  final WorkspaceKind kind;

  /// 3.16+ 工作区用途: 'project' (真实项目) | 'conversation' (草稿对话工作区,
  /// 路径形如 ~/.zcode/workspace/draft-xxx)。网页端把 conversation 分区
  /// (「对话」) 不与项目混排; null 为旧版协议 (全部按项目)。
  final String? purpose;
  final bool canBridge;
  final String? branch;
  final String? preferredTaskId;

  /// 网页端项目列表排序键 (readProjects / readTree 自带, -5..10)。
  /// null = Host 未给, 排序时排最后。
  final double? position;

  /// readTree 项目库中的项目 ID + 所属 host (本地为 'local')。
  /// bridge-open 带 project:{projectId, hostId} 时桌面端会为该项目
  /// 自动开工作区标签 (prepareProjectWorkspace) — 跨工作区打开项目的关键。
  final String? projectId;
  final String? hostId;

  Workspace({
    required this.workspaceKey,
    required this.workspaceIdentity,
    required this.workspacePath,
    required this.name,
    this.kind = WorkspaceKind.local,
    this.purpose,
    this.canBridge = true,
    this.branch,
    this.preferredTaskId,
    this.projectId,
    this.hostId,
    this.position,
  });

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final path =
        json['workspacePath'] as String? ?? json['path'] as String? ?? '';
    return Workspace(
      workspaceKey: path, // workspaceKey = workspacePath (实测)
      workspaceIdentity: json['workspaceIdentity'] as String? ?? path,
      workspacePath: path,
      name:
          json['label'] as String? ??
          json['name'] as String? ??
          path.split('/').where((s) => s.isNotEmpty).lastOrNull ??
          'Unknown',
      kind: WorkspaceKind.fromString(json['kind'] as String?),
      purpose: _parsePurpose(json['workspacePurpose'] ?? json['purpose']),
      canBridge: json['canBridge'] as bool? ?? true,
      branch: json['branch'] as String?,
      preferredTaskId:
          json['preferredTaskId'] as String? ?? json['taskId'] as String?,
      projectId: json['projectId'] as String?,
      hostId: json['hostId'] as String?,
      position: (json['position'] as num?)?.toDouble(),
    );
  }

  /// 保留其余字段, 仅更新 readTree 项目信息
  Workspace copyWithProject({
    String? projectId,
    String? hostId,
    double? position,
  }) {
    return Workspace(
      workspaceKey: workspaceKey,
      workspaceIdentity: workspaceIdentity,
      workspacePath: workspacePath,
      name: name,
      kind: kind,
      purpose: purpose,
      canBridge: canBridge,
      branch: branch,
      preferredTaskId: preferredTaskId,
      projectId: projectId ?? this.projectId,
      hostId: hostId ?? this.hostId,
      position: position ?? this.position,
    );
  }

  /// 路径归一化: 去尾斜杠 (Host 会把同一工作区存成带/不带斜杠两条,
  /// 如 zocde-app 与 zocde-app/, 精确字符串比较永远合并不上)。
  static String normalizePath(String path) =>
      path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// 两条路径是否同一工作区 (归一化后比较)
  static bool samePath(String a, String b) =>
      normalizePath(a) == normalizePath(b);

  static String? _parsePurpose(dynamic v) =>
      v == 'project' || v == 'conversation' ? v as String : null;

  /// 是否 conversation 工作区 (purpose=='conversation', 不进项目列表;
  /// 注意: 网页侧栏没有对话分区, 排除仅因它不是项目)
  bool get isConversation => purpose == 'conversation';

  /// 从 bootstrap 响应解析工作区列表 (项目区: 过滤 conversation 工作区)
  static List<Workspace> parseList(Map<String, dynamic> bootstrapResponse) {
    final result = bootstrapResponse['result'] as Map<String, dynamic>?;
    final workspacesJson = result?['workspaces'] as List<dynamic>? ?? [];
    final all = workspacesJson
        .map((e) => Workspace.fromJson(e as Map<String, dynamic>))
        .where((w) => w.workspaceKey.isNotEmpty)
        .toList();
    // 3.17.2 实测: bootstrap 可能只返回当前会话工作区 (如默认会话工作区
    // purpose=conversation); 沿用旧过滤会把列表滤空, 启动卡在"暂无可用工作区"。
    // 过滤后为空时保留原列表兜底 (进默认工作区后 readTree 合并会补齐项目)。
    final filtered = all.where((w) => !w.isConversation).toList();
    return filtered.isNotEmpty ? filtered : all;
  }

  /// 解析 readTree 的 projects → 项目列表 (网页侧栏同源, 含历史项目)
  ///
  /// project 形态 (asar 实测): {id, name?, roots:[{rootPath}], pinned?, deleted?}
  /// workspacePath = roots[0].rootPath; 过滤 deleted 与无 roots 项。
  /// [activeFallback] 为 bootstrap 的活跃工作区 — readTree 未含的按路径追加
  /// (活跃但未入库项目的工作区仍可连接), purpose 等 bootstrap 独有信息保留。
  static List<Workspace> parseTreeProjects(
    Map<String, dynamic> treeResp,
    List<Workspace> activeFallback,
  ) {
    dynamic projectsJson = treeResp['projects'];
    projectsJson ??= (treeResp['tree'] as Map<String, dynamic>?)?['projects'];
    if (projectsJson is! List) return activeFallback;
    final result = <Workspace>[];
    final seen = <String>{};
    for (final e in projectsJson) {
      if (e is! Map) continue;
      final p = Map<String, dynamic>.from(e);
      if (p['deleted'] == true) continue;
      final roots = p['roots'];
      final path =
          roots is List && roots.isNotEmpty && roots.first is Map
          ? (roots.first as Map)['rootPath'] as String? ?? ''
          : '';
      if (path.isEmpty) continue;
      // 归一化后去重: Host 会把同一工作区存成带/不带斜杠两条
      final normPath = Workspace.normalizePath(path);
      if (!seen.add(normPath)) continue;
      final treeProjectId = p['id'] as String?;
      final treeHostId = p['hostId'] as String? ?? 'local';
      final treePosition = (p['position'] as num?)?.toDouble();
      // bootstrap 同路径工作区优先 (带 purpose/kind 等完整信息),
      // 并补上 readTree 的项目导航信息 (projectId/hostId/position);
      // 匹配用归一化路径, 否则斜杠变体永远合并不上
      // (如项目需求投票系统: tree 是 draft-…/ 带斜杠, bootstrap 是不带斜杠
      // 且 purpose 缺失, 匹配不上就丢 purpose, 后续被误杀)。
      final active = activeFallback
          .where((w) => Workspace.samePath(w.workspacePath, path))
          .firstOrNull;
      result.add(
        active?.copyWithProject(
          projectId: treeProjectId,
          hostId: treeHostId,
          position: treePosition,
        ) ??
            Workspace.fromJson({
              'workspacePath': path,
              'label': p['name'],
              'projectId': treeProjectId,
              'hostId': treeHostId,
              'position': treePosition,
            }),
      );
    }
    // bootstrap 活跃但 readTree 没有的追加 (归一化去重, 避免斜杠双变体两行)
    for (final w in activeFallback) {
      if (seen.add(Workspace.normalizePath(w.workspacePath))) result.add(w);
    }
    return result;
  }

  /// 从 bootstrap 响应解析任务列表
  ///
  /// bootstrap 的 result.tasks 含所有工作区的任务。
  static List<Task> parseTasks(Map<String, dynamic> bootstrapResponse) {
    final result = bootstrapResponse['result'] as Map<String, dynamic>?;
    final tasksJson = result?['tasks'] as List<dynamic>? ?? [];
    return tasksJson
        .map((e) => Task.fromJson(e as Map<String, dynamic>))
        .where((t) => t.id.isNotEmpty)
        .toList();
  }
}

/// 任务/对话
class Task {
  final String id;
  final String workspaceKey;
  final String title;
  final TaskStatus status;
  final bool archived;

  /// 置顶 (window-project.readTree 全局任务库; 旧链路恒 false)
  final bool pinned;

  /// 所属项目 ID (readTree 全局任务库)。
  /// null = 无项目归属 (默认工作区/移动盘/未注册目录等任务都会是 null,
  /// 不等于草稿对话——草稿对话只是其中一小部分, 不能拿它当过滤条件)。
  final String? projectId;

  /// 任务所属 host (readTree 行自带; 本地任务为 'local', 远程为 host id)。
  /// bridge-open 带 taskId+hostId 时桌面端会自动切窗到该任务的工作区。
  final String? hostId;
  final DateTime? updatedAt;
  final DateTime? createdAt;

  Task({
    required this.id,
    required this.workspaceKey,
    required this.title,
    this.status = TaskStatus.idle,
    this.archived = false,
    this.pinned = false,
    this.projectId,
    this.hostId,
    this.updatedAt,
    this.createdAt,
  });

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id'] as String? ?? json['taskId'] as String? ?? '',
      workspaceKey:
          json['workspaceKey'] as String? ??
          json['workspacePath'] as String? ??
          json['workspace_key'] as String? ??
          '',
      title: json['title'] as String? ?? 'Untitled',
      // bootstrap 用 displayStatus, snapshot 用 status
      status: TaskStatus.fromString(
        json['displayStatus'] as String? ?? json['status'] as String?,
      ),
      archived: json['archived'] as bool? ?? false,
      pinned: json['pinned'] as bool? ?? false,
      projectId: json['projectId'] as String?,
      hostId: json['hostId'] as String?,
      // 时间戳: 实测为 int 毫秒, 兼容 ISO 字符串
      updatedAt: _parseTime(json['updatedAt']),
      createdAt: _parseTime(json['createdAt']),
    );
  }

  /// 解析 window-project.readTree 响应 (3.16 全局任务库, 网页侧栏同源)
  ///
  /// 形态: {projects:[...], tasks:[{taskId,workspacePath,...,pinned,archived}]}
  /// tasks 可能在顶层或 tree 嵌套; 解析失败返回空列表 (调用方降级)。
  static List<Task> parseTreeTasks(Map<String, dynamic> treeResp) {
    dynamic tasksJson = treeResp['tasks'];
    tasksJson ??= (treeResp['tree'] as Map<String, dynamic>?)?['tasks'];
    if (tasksJson is! List) return const [];
    return tasksJson
        .map((e) => Task.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((t) => t.id.isNotEmpty && t.workspaceKey.isNotEmpty)
        .toList();
  }

  static DateTime? _parseTime(dynamic v) {
    if (v == null) return null;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  Task copyWith({
    String? title,
    TaskStatus? status,
    bool? archived,
    bool? pinned,
    String? hostId,
    String? projectId,
    DateTime? updatedAt,
  }) {
    return Task(
      id: id,
      workspaceKey: workspaceKey,
      title: title ?? this.title,
      status: status ?? this.status,
      archived: archived ?? this.archived,
      pinned: pinned ?? this.pinned,
      hostId: hostId ?? this.hostId,
      projectId: projectId ?? this.projectId,
      updatedAt: updatedAt ?? this.updatedAt,
      createdAt: createdAt,
    );
  }
}

/// 任务状态
enum TaskStatus {
  idle('idle'),
  running('running'),
  complete('complete'),
  error('error');

  final String value;
  const TaskStatus(this.value);

  static TaskStatus fromString(String? value) {
    if (value == null) return TaskStatus.idle;
    // 3.7.7 推送用 "completed" (过去式), 旧接口用 "complete"
    if (value == 'completed') return TaskStatus.complete;
    for (final s in TaskStatus.values) {
      if (s.value == value) return s;
    }
    return TaskStatus.idle;
  }
}

/// 聊天消息
class ChatMessage {
  final String id;
  final String role; // 'user' | 'assistant'
  final String content;
  final String? model;
  final List<CodeBlock> codeBlocks;
  final List<DiffSummary> diffs;
  final bool isStreaming;
  final int? inputTokens;
  final int? outputTokens;
  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.model,
    this.codeBlocks = const [],
    this.diffs = const [],
    this.isStreaming = false,
    this.inputTokens,
    this.outputTokens,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  ChatMessage copyWith({
    String? content,
    String? model,
    List<CodeBlock>? codeBlocks,
    List<DiffSummary>? diffs,
    bool? isStreaming,
    int? inputTokens,
    int? outputTokens,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      model: model ?? this.model,
      codeBlocks: codeBlocks ?? this.codeBlocks,
      diffs: diffs ?? this.diffs,
      isStreaming: isStreaming ?? this.isStreaming,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      createdAt: createdAt,
    );
  }
}

/// 代码块
class CodeBlock {
  final String language;
  final String code;

  CodeBlock({required this.language, required this.code});
}

/// 代码差异摘要
class DiffSummary {
  final String filePath;
  final int added;
  final int removed;

  DiffSummary({required this.filePath, this.added = 0, this.removed = 0});
}

/// Agent 编辑模式
enum AgentMode {
  confirm('confirm', '变更前确认', '编辑前先问我'),
  autoEdit('auto-edit', '自动编辑', '自动编辑文件'),
  plan('plan', '计划模式', '编辑前先出计划'),
  fullAccess('full-access', '完全访问', '减少确认次数');

  final String value;
  final String displayName;
  final String description;
  const AgentMode(this.value, this.displayName, this.description);
}
