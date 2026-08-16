/// Agent 能力域数据模型 (技能/子智能体/命令/钩子/MCP/外部导入)
///
/// 字段来源: docs/v4-API协议规格.md (3.7.7 桌面端 asar 实测确认)。
/// 所有解析均防御式 — 服务端字段可能缺失或为 null。
library;

// ================================================================
// 技能
// ================================================================

class SkillEntry {
  final String id;
  final String name;
  final String description;
  final String body; // SKILL.md 正文
  final String? path;
  final String? sourcePath;
  final String scope; // user | workspace | plugin
  final bool enabled;
  final String? pluginName;

  const SkillEntry({
    required this.id,
    required this.name,
    required this.description,
    this.body = '',
    this.path,
    this.sourcePath,
    this.scope = 'user',
    this.enabled = false,
    this.pluginName,
  });

  static SkillEntry fromJson(Map<String, dynamic> j) => SkillEntry(
        id: (j['id'] ?? j['name'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        description: (j['description'] ?? j['desc'] ?? '').toString(),
        body: (j['body'] ?? '').toString(),
        path: j['path']?.toString(),
        sourcePath: j['sourcePath']?.toString(),
        scope: (j['scope'] ?? j['source'] ?? 'user').toString(),
        enabled: j['enabled'] is bool ? j['enabled'] as bool : false,
        pluginName: j['pluginName']?.toString(),
      );

  /// 网页端分组: 工作区与个人技能 / Plugin 技能
  bool get isPlugin => scope == 'plugin' || id.startsWith('glm:plugin:');

  String get scopeLabel => isPlugin
      ? (pluginName != null && pluginName!.isNotEmpty ? '插件 · $pluginName' : '插件')
      : (scope == 'workspace' ? '工作区' : '个人');

  SkillEntry copyWith({bool? enabled}) => SkillEntry(
        id: id,
        name: name,
        description: description,
        body: body,
        path: path,
        sourcePath: sourcePath,
        scope: scope,
        enabled: enabled ?? this.enabled,
        pluginName: pluginName,
      );
}

// ================================================================
// 子智能体
// ================================================================

class SubagentEntry {
  final String id;
  final String name;
  final String description;
  final String systemPrompt;
  final String? color;
  final String? model; // 形如 custom:builtin%3Azai:GLM-5-Turbo 或纯 id
  final String? thoughtLevel;
  final List<String> tools;
  final List<String> disallowedTools;
  final List<String> skills;
  final String? permissionMode;
  final int? maxTurns;
  final bool? background;
  final bool? injectAgentsMd;
  final List<String> mcpServers;
  final String? path;
  final String scope; // built-in | user | workspace | plugin
  final String source; // built-in | user | plugin
  final bool enabled;
  final bool readOnly;

  const SubagentEntry({
    required this.id,
    required this.name,
    required this.description,
    this.systemPrompt = '',
    this.color,
    this.model,
    this.thoughtLevel,
    this.tools = const [],
    this.disallowedTools = const [],
    this.skills = const [],
    this.permissionMode,
    this.maxTurns,
    this.background,
    this.injectAgentsMd,
    this.mcpServers = const [],
    this.path,
    this.scope = 'user',
    this.source = 'user',
    this.enabled = true,
    this.readOnly = false,
  });

  static List<String> _strList(dynamic v) => v is List
      ? v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList()
      : const [];

  static SubagentEntry fromJson(Map<String, dynamic> j) => SubagentEntry(
        id: (j['id'] ?? j['name'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        systemPrompt: (j['systemPrompt'] ?? '').toString(),
        color: j['color']?.toString(),
        model: j['model']?.toString(),
        thoughtLevel: j['thoughtLevel']?.toString(),
        tools: _strList(j['tools']),
        disallowedTools: _strList(j['disallowedTools']),
        skills: _strList(j['skills']),
        permissionMode: j['permissionMode']?.toString(),
        maxTurns: j['maxTurns'] is int ? j['maxTurns'] as int : null,
        background: j['background'] is bool ? j['background'] as bool : null,
        injectAgentsMd:
            j['injectAgentsMd'] is bool ? j['injectAgentsMd'] as bool : null,
        mcpServers: _strList(j['mcpServers']),
        path: j['path']?.toString(),
        scope: (j['scope'] ?? 'user').toString(),
        source: (j['source'] ?? j['scope'] ?? 'user').toString(),
        enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
        readOnly: j['readOnly'] is bool ? j['readOnly'] as bool : false,
      );

  bool get isBuiltIn => scope == 'built-in' || source == 'built-in';
  bool get isPlugin => scope == 'plugin' || source == 'plugin';

  /// 模型徽章显示名: custom:builtin%3Azai:GLM-5-Turbo → GLM-5-Turbo
  String get modelLabel {
    final m = model;
    if (m == null || m.isEmpty) return '继承主模型';
    var s = m;
    if (s.startsWith('custom:')) s = s.substring(7);
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {}
    final parts = s.split(':');
    return parts.length >= 2 ? parts.sublist(2).join(':') : s;
  }

  String get thoughtLevelLabel => switch (thoughtLevel) {
        'max' => '深度思考',
        'medium' => '中等思考',
        'nothink' => '不思考',
        _ => '继承',
      };

  /// 生成 createAgent/updateAgent 的 config
  Map<String, dynamic> toConfig() => {
        'name': name,
        'description': description,
        'systemPrompt': systemPrompt,
        if (color != null) 'color': color,
        if (model != null && model!.isNotEmpty) 'model': model,
        if (thoughtLevel != null && thoughtLevel!.isNotEmpty)
          'thoughtLevel': thoughtLevel,
        if (tools.isNotEmpty) 'tools': tools,
        if (disallowedTools.isNotEmpty) 'disallowedTools': disallowedTools,
        if (skills.isNotEmpty) 'skills': skills,
        if (permissionMode != null) 'permissionMode': permissionMode,
        if (maxTurns != null) 'maxTurns': maxTurns,
        if (background != null) 'background': background,
        if (injectAgentsMd != null) 'injectAgentsMd': injectAgentsMd,
        if (mcpServers.isNotEmpty) 'mcpServers': mcpServers,
      };
}

// ================================================================
// 命令
// ================================================================

class CommandEntry {
  final String id;
  final String name; // /xxx 形式
  final String description;
  final String? argumentHint;
  final String content; // 命令文件正文 (prompt 模板)
  final String? filePath;
  final String source; // user | plugin | built-in
  final String scope; // user | workspace | project
  final bool enabled;

  const CommandEntry({
    required this.id,
    required this.name,
    this.description = '',
    this.argumentHint,
    this.content = '',
    this.filePath,
    this.source = 'user',
    this.scope = 'user',
    this.enabled = true,
  });

  static CommandEntry fromJson(Map<String, dynamic> j) => CommandEntry(
        id: (j['id'] ?? j['name'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        argumentHint: j['argumentHint']?.toString(),
        content: (j['content'] ?? j['prompt'] ?? j['body'] ?? '').toString(),
        filePath: (j['filePath'] ?? j['path'])?.toString(),
        source: (j['source'] ?? j['scope'] ?? 'user').toString(),
        scope: (j['scope'] ?? 'user').toString(),
        enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
      );

  bool get isPlugin => source == 'plugin';

  CommandEntry copyWith({bool? enabled}) => CommandEntry(
        id: id,
        name: name,
        description: description,
        argumentHint: argumentHint,
        content: content,
        filePath: filePath,
        source: source,
        scope: scope,
        enabled: enabled ?? this.enabled,
      );
}

// ================================================================
// 钩子
// ================================================================

class HookEntry {
  final String id;
  final String event; // PreToolUse / PostToolUse / ...
  final String? matcher;
  final String type; // command | process
  final String command;
  final List<String> args; // process 类型
  final bool runAsync;
  final String? shell;
  final String? statusMessage;
  final int? timeout; // 秒
  final bool enabled;
  final String? customJson;
  final String locationSource; // zcode | agents | claude
  final String locationScope; // user | project

  const HookEntry({
    required this.id,
    required this.event,
    this.matcher,
    required this.type,
    required this.command,
    this.args = const [],
    this.runAsync = false,
    this.shell,
    this.statusMessage,
    this.timeout,
    this.enabled = false,
    this.customJson,
    this.locationSource = 'zcode',
    this.locationScope = 'user',
  });

  static HookEntry fromJson(Map<String, dynamic> j) => HookEntry(
        id: (j['id'] ?? '').toString(),
        event: (j['event'] ?? '').toString(),
        matcher: j['matcher']?.toString(),
        type: (j['type'] ?? 'command').toString(),
        command: (j['command'] ?? '').toString(),
        args: j['args'] is List
            ? (j['args'] as List).map((e) => e.toString()).toList()
            : const [],
        runAsync: j['async'] is bool ? j['async'] as bool : false,
        shell: j['shell']?.toString(),
        statusMessage: j['statusMessage']?.toString(),
        timeout: j['timeout'] is int ? j['timeout'] as int : null,
        enabled: j['enabled'] is bool ? j['enabled'] as bool : false,
        customJson: j['custom']?.toString(),
        locationSource:
            ((j['location'] ?? const {}) as Map)['source']?.toString() ?? 'zcode',
        locationScope:
            ((j['location'] ?? const {}) as Map)['scope']?.toString() ?? 'user',
      );

  /// saveHooks 的 wire 条目
  Map<String, dynamic> toWireJson() => {
        'id': id,
        'event': event,
        if (matcher != null && matcher!.isNotEmpty) 'matcher': matcher,
        'type': type,
        'command': command,
        if (type == 'process' && args.isNotEmpty) 'args': args,
        if (runAsync) 'async': true,
        if (shell != null && shell!.isNotEmpty) 'shell': shell,
        if (statusMessage != null && statusMessage!.isNotEmpty)
          'statusMessage': statusMessage,
        if (timeout != null) 'timeout': timeout,
        'enabled': enabled,
        'location': {'source': locationSource, 'scope': locationScope},
      };

  HookEntry copyWith({bool? enabled}) => HookEntry(
        id: id,
        event: event,
        matcher: matcher,
        type: type,
        command: command,
        args: args,
        runAsync: runAsync,
        shell: shell,
        statusMessage: statusMessage,
        timeout: timeout,
        enabled: enabled ?? this.enabled,
        customJson: customJson,
        locationSource: locationSource,
        locationScope: locationScope,
      );
}

/// 常见钩子事件 (zcode 支持)
const kHookEvents = <String>[
  'PreToolUse',
  'PostToolUse',
  'UserPromptSubmit',
  'Notification',
  'SessionStart',
  'SessionEnd',
  'Stop',
  'SubagentStop',
  'PreCompact',
];

// ================================================================
// MCP
// ================================================================

enum McpServerType { stdio, sse, http, unknown }

class McpServerEntry {
  final String name;
  final String scope; // user | workspace
  final String source; // zcodeagentmcp | ...
  final McpServerType type;
  final String? command; // stdio
  final String? url; // sse/http
  final List<String> args;
  final Map<String, String> env;
  final Map<String, String> headers;
  final int? timeoutMs;
  final bool enabled;
  final String? filePath; // 配置文件路径
  final String? projectPath; // workspace 作用域时存在
  final Map<String, dynamic> rawConfig;

  const McpServerEntry({
    required this.name,
    this.scope = 'user',
    this.source = 'zcodeagentmcp',
    this.type = McpServerType.unknown,
    this.command,
    this.url,
    this.args = const [],
    this.env = const {},
    this.headers = const {},
    this.timeoutMs,
    this.enabled = true,
    this.filePath,
    this.projectPath,
    this.rawConfig = const {},
  });

  static Map<String, String> _strMap(dynamic v) {
    if (v is! Map) return const {};
    return v.map((k, e) => MapEntry(k.toString(), e?.toString() ?? ''));
  }

  static List<String> _strList(dynamic v) => v is List
      ? v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList()
      : const [];

  static McpServerType _typeOf(dynamic t) => switch (t?.toString()) {
        'stdio' => McpServerType.stdio,
        'sse' => McpServerType.sse,
        'http' => McpServerType.http,
        _ => McpServerType.unknown,
      };

  static McpServerEntry fromJson(Map<String, dynamic> j) {
    final cfg = (j['config'] ?? const {}) as Map;
    final type = _typeOf(cfg['type']);
    return McpServerEntry(
      name: (j['name'] ?? '').toString(),
      scope: (j['scope'] ?? 'user').toString(),
      source: (j['source'] ?? 'zcodeagentmcp').toString(),
      type: type,
      command: cfg['command']?.toString(),
      url: cfg['url']?.toString(),
      args: _strList(cfg['args']),
      env: _strMap(cfg['env']),
      headers: _strMap(cfg['headers']),
      timeoutMs: cfg['timeoutMs'] is int ? cfg['timeoutMs'] as int : null,
      enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
      filePath: ((j['file'] ?? const {}) as Map)['filePath']?.toString(),
      projectPath: j['projectPath']?.toString(),
      rawConfig: Map<String, dynamic>.from(cfg),
    );
  }

  /// upsert 用的 config
  Map<String, dynamic> toConfig() => {
        'type': type == McpServerType.unknown
            ? 'stdio'
            : type.name,
        if (command != null && command!.isNotEmpty) 'command': command,
        if (url != null && url!.isNotEmpty) 'url': url,
        if (args.isNotEmpty) 'args': args,
        if (env.isNotEmpty) 'env': env,
        if (headers.isNotEmpty) 'headers': headers,
        if (timeoutMs != null) 'timeoutMs': timeoutMs,
      };

  String get typeLabel => switch (type) {
        McpServerType.stdio => 'stdio',
        McpServerType.sse => 'SSE',
        McpServerType.http => 'HTTP',
        McpServerType.unknown => '未知',
      };

  /// 副标题: stdio 显示命令, 远程显示域名
  String get endpointLabel {
    if (type == McpServerType.stdio) {
      final cmd = command ?? '';
      return args.isNotEmpty ? '$cmd ${args.join(' ')}' : cmd;
    }
    if (url != null && url!.isNotEmpty) {
      try {
        return Uri.parse(url!).host;
      } catch (_) {
        return url!;
      }
    }
    return '';
  }

  McpServerEntry copyWith({bool? enabled}) => McpServerEntry(
        name: name,
        scope: scope,
        source: source,
        type: type,
        command: command,
        url: url,
        args: args,
        env: env,
        headers: headers,
        timeoutMs: timeoutMs,
        enabled: enabled ?? this.enabled,
        filePath: filePath,
        projectPath: projectPath,
        rawConfig: rawConfig,
      );
}

/// MCP 服务器运行状态 (listMcpServerStatuses 单项)
class McpServerStatus {
  final String name;
  final String status; // active | connecting | connected | disconnected | ...
  final int? toolCount;
  final String? error;
  final String? authorizationUrl; // 需要 OAuth 授权时存在

  const McpServerStatus({
    required this.name,
    required this.status,
    this.toolCount,
    this.error,
    this.authorizationUrl,
  });

  static McpServerStatus fromJson(Map<String, dynamic> j) => McpServerStatus(
        name: (j['name'] ?? j['id'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        toolCount: j['toolCount'] is int ? j['toolCount'] as int : null,
        error: j['error']?.toString(),
        authorizationUrl:
            ((j['authorization'] ?? const {}) as Map)['authorizationUrl']
                ?.toString(),
      );

  bool get isConnected =>
      status == 'active' || status == 'connected' || status == 'plugin.active';
}

// ================================================================
// 外部 Agent 导入 (settings-sync)
// ================================================================

class ImportCandidate {
  final String agent; // claudeCode / codexCli / ...
  final String category; // skills / commands / plugins / mcpServers
  final String? sourceScope; // global / project
  final String resourcePath;
  final String name;
  final String? version;

  const ImportCandidate({
    required this.agent,
    required this.category,
    this.sourceScope,
    required this.resourcePath,
    required this.name,
    this.version,
  });

  /// 选择键 (与网页端一致: JSON {agent, category, sourceScope?, resourcePath})
  String get selectionKey => jsonKey;

  String get jsonKey => sourceScope == null
      ? '{"agent":"$agent","category":"$category","resourcePath":"$resourcePath"}'
      : '{"agent":"$agent","category":"$category","sourceScope":"$sourceScope","resourcePath":"$resourcePath"}';
}

class ImportAgent {
  final String agent;
  final List<ImportCandidate> candidates;

  const ImportAgent({required this.agent, this.candidates = const []});
}

/// 解析 settings-sync/detect 响应 (防御式, 字段名以 3.7.7 实现为准)
List<ImportAgent> parseImportDiscovery(Map<String, dynamic> resp) {
  final agents = <ImportAgent>[];
  final rawAgents = resp['agents'];
  if (rawAgents is! List) return agents;
  for (final a in rawAgents) {
    if (a is! Map) continue;
    final agentKey = (a['agent'] ?? a['key'] ?? a['id'] ?? '').toString();
    if (agentKey.isEmpty) continue;
    final cands = <ImportCandidate>[];
    final categories = a['categories'];
    if (categories is List) {
      for (final c in categories) {
        if (c is! Map) continue;
        final category = (c['category'] ?? c['key'] ?? '').toString();
        _collectItems(c, agentKey, category, cands);
      }
    }
    // 兜底: agent 层直接挂 items
    _collectItems(a, agentKey, '', cands, skipKnownKeys: true);
    if (cands.isNotEmpty) agents.add(ImportAgent(agent: agentKey, candidates: cands));
  }
  return agents;
}

void _collectItems(Map node, String agentKey, String category,
    List<ImportCandidate> out,
    {bool skipKnownKeys = false}) {
  for (final entry in node.entries) {
    final k = entry.key.toString();
    if (skipKnownKeys &&
        ['agent', 'categories', 'name', 'key', 'id', 'importableCount']
            .contains(k)) {
      continue;
    }
    final v = entry.value;
    List? items;
    String cat = category;
    if (v is List) {
      items = v;
    } else if (v is Map && v['items'] is List) {
      items = v['items'] as List;
      cat = category.isNotEmpty ? category : k;
    }
    if (items == null || cat.isEmpty) continue;
    for (final it in items) {
      if (it is! Map) continue;
      final path =
          (it['resourcePath'] ?? it['sourcePath'] ?? it['path'] ?? it['directoryName'] ?? '')
              .toString();
      if (path.isEmpty) continue;
      out.add(ImportCandidate(
        agent: agentKey,
        category: cat == 'mcp' ? 'mcpServers' : cat,
        sourceScope: it['sourceScope']?.toString() ??
            node['sourceScope']?.toString(),
        resourcePath: path,
        name: (it['name'] ?? it['directoryName'] ?? path.split('/').last)
            .toString(),
        version: it['version']?.toString(),
      ));
    }
  }
}

/// 外部 Agent 显示名
String importAgentLabel(String key) => switch (key) {
      'claudeCode' => 'Claude Code',
      'codexCli' => 'Codex CLI',
      'openCode' => 'OpenCode',
      'openClaw' => 'OpenClaw',
      'augment' => 'Augment',
      'continue' => 'Continue',
      'goose' => 'Goose',
      'qwenCode' => 'Qwen Code',
      'qode' => 'Qode',
      'qodeCn' => 'Qode CN',
      'windsurf' => 'Windsurf',
      'trae' => 'Trae',
      'traeCn' => 'Trae CN',
      'kiroCli' => 'Kiro CLI',
      'roo' => 'Roo',
      'codeBuddy' => 'CodeBuddy',
      _ => key,
    };

String importCategoryLabel(String category) => switch (category) {
      'skills' => '技能',
      'commands' => '命令',
      'plugins' => '插件',
      'mcpServers' => 'MCP 服务器',
      _ => category,
    };

// ================================================================
// 插件 (overview schema: installedPlugins/availablePlugins/marketplaces)
// ================================================================

/// 已安装 / 市场中的插件条目
class PluginEntry {
  final String id;
  final String name;
  final String marketplace;
  final String description;
  final String? version;
  final bool installed; // availablePlugins 用
  final bool enabled; // installedPlugins 用
  final String scope;
  final List<String> componentTypes;
  final String? updateStatus; // none | update-available | version-changed
  final String? latestVersion;
  // listing 元数据
  final String displayName;
  final String? icon; // emoji 或 URL
  final String? category;
  final String? author;
  final String? homepage;

  /// listPlugins 视角推导的组件类型 (与 componentTypes 二选一)
  final List<String>? componentTypesFromDetail;

  const PluginEntry({
    required this.id,
    required this.name,
    required this.marketplace,
    this.description = '',
    this.version,
    this.installed = false,
    this.enabled = true,
    this.scope = 'user',
    this.componentTypes = const [],
    this.componentTypesFromDetail,
    this.updateStatus,
    this.latestVersion,
    this.displayName = '',
    this.icon,
    this.category,
    this.author,
    this.homepage,
  });

  String get label =>
      displayName.isNotEmpty ? displayName : name;

  /// 展示用的组件类型 (overview 的 componentTypes 优先, 否则用推导)
  List<String> get displayComponentTypes =>
      componentTypes.isNotEmpty ? componentTypes : (componentTypesFromDetail ?? const []);

  static List<String> _typesFromDetail(Map<String, dynamic> j) {
    final out = <String>[];
    if (((j['skillCount'] as num?)?.toInt() ?? 0) > 0) out.add('skills');
    if (((j['commandRootCount'] as num?)?.toInt() ?? 0) > 0) {
      out.add('commands');
    }
    if (j['mcpServerNames'] is List && (j['mcpServerNames'] as List).isNotEmpty) {
      out.add('mcpServers');
    }
    if (j['hookDetails'] is List && (j['hookDetails'] as List).isNotEmpty) {
      out.add('hooks');
    }
    return out;
  }

  static PluginEntry fromJson(Map<String, dynamic> j) {
    final listing = (j['listing'] ?? const {}) as Map;
    // author 可能是字符串或 {name, url} 对象 (官方市场为对象)
    final rawAuthor = listing['author'] ?? j['author'];
    final author = rawAuthor is Map
        ? (rawAuthor['name'] ?? rawAuthor['url'])?.toString()
        : rawAuthor?.toString();
    final homepage =
        (listing['homepage'] ?? (j['author'] is Map ? j['author']['url'] : null))
            ?.toString();
    return PluginEntry(
      id: (j['id'] ?? j['name'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      marketplace: (j['marketplace'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      version: j['version']?.toString(),
      installed: j['installed'] == true,
      enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
      scope: (j['scope'] ?? 'user').toString(),
      componentTypes: j['componentTypes'] is List
          ? (j['componentTypes'] as List).map((e) => e.toString()).toList()
          : const [],
      updateStatus: j['updateStatus']?.toString(),
      latestVersion: j['latestVersion']?.toString(),
      // listPlugins 来源没有 componentTypes — 从计数/名单推导
      componentTypesFromDetail: j['componentTypes'] is List ? null : _typesFromDetail(j),
      // 官方市场的 marketplace.json 里这些字段在条目顶层而非 listing 下 — 两层兼容
      displayName:
          (listing['displayName'] ?? j['displayName'])?.toString() ?? '',
      icon: (listing['icon'] ?? j['icon'])?.toString(),
      category: (listing['category'] ?? j['category'])?.toString(),
      author: author,
      homepage: homepage,
    );
  }

  bool get hasUpdate =>
      updateStatus == 'update-available' || updateStatus == 'version-changed';

  /// 用 overview 同 id 条目补齐展示元数据 (icon/分类/更新状态)
  PluginEntry mergeOverview(PluginEntry o) => PluginEntry(
        id: id,
        name: name,
        marketplace: marketplace,
        description: description.isNotEmpty ? description : o.description,
        version: version ?? o.version,
        installed: installed,
        enabled: enabled,
        scope: scope,
        componentTypes: componentTypes,
        componentTypesFromDetail: componentTypesFromDetail,
        updateStatus: o.updateStatus ?? updateStatus,
        latestVersion: o.latestVersion ?? latestVersion,
        displayName: o.displayName.isNotEmpty ? o.displayName : displayName,
        icon: o.icon ?? icon,
        category: o.category ?? category,
        author: o.author ?? author,
        homepage: o.homepage ?? homepage,
      );
}

/// 插件市场
class MarketplaceEntry {
  final String id;
  final String name;
  final String source;
  final int pluginCount;
  final bool isOfficial;
  final String? lastUpdated;
  final List<String> featured; // 精选插件名

  const MarketplaceEntry({
    required this.id,
    required this.name,
    required this.source,
    this.pluginCount = 0,
    this.isOfficial = false,
    this.lastUpdated,
    this.featured = const [],
  });

  static MarketplaceEntry fromJson(Map<String, dynamic> j) => MarketplaceEntry(
        id: (j['id'] ?? j['name'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        source: (j['source'] is Map)
            ? ((j['source'] as Map)['source'] ?? j['source']).toString()
            : (j['source'] ?? '').toString(),
        pluginCount:
            j['pluginCount'] is int ? j['pluginCount'] as int : 0,
        isOfficial: j['isOfficial'] == true,
        lastUpdated: j['lastUpdated']?.toString(),
        featured: j['featured'] is List
            ? (j['featured'] as List).map((e) => e.toString()).toList()
            : const [],
      );
}

/// 插件分类 (listing.category → 中文)
///
/// ★ wire 值是 kebab-case (网页端 r0t 映射实测):
/// developer-tools / productivity / utilities / guides / template / other
String pluginCategoryLabel(String? category) => switch (category) {
      'developer-tools' || 'developerTools' => '开发者工具',
      'productivity' => '生产力',
      'utilities' => '实用工具',
      'guides' => '指南',
      'template' => '模板',
      _ => '其他',
    };

/// 分类归一 (空值 → other, camelCase 兼容 → kebab)
String pluginCategoryOf(String? category) {
  final c = category?.trim() ?? '';
  if (c.isEmpty) return 'other';
  return switch (c) {
    'developerTools' => 'developer-tools',
    _ => kPluginCategories.containsKey(c) ? c : 'other',
  };
}

const kPluginCategories = <String, String>{
  'developer-tools': '开发者工具',
  'productivity': '生产力',
  'utilities': '实用工具',
  'guides': '指南',
  'template': '模板',
};

// ── 公开/个人与个人分组标准 (网页端实测) ──

/// zcode 官方市场 → 「公开」段; 其余 (claude-plugins-official / 自建) → 「个人」
const kOfficialMarketplace = 'zcode-plugins-official';

/// Claude 官方兼容市场 → 个人段里显示为「Claude Code 插件」
const kClaudeMarketplace = 'claude-plugins-official';

/// 个人段「推荐」组名单 (claude-plugins-official 内, 固定顺序)
const kRecommendedPlugins = <String>[
  'context7',
  'code-review',
  'playwright',
  'feature-dev',
  'commit-commands',
  'superpowers',
];

/// 组件类型 → 中文
String pluginComponentLabel(String type) => switch (type) {
      'command' || 'commands' => '命令',
      'skill' || 'skills' => '技能',
      'hook' || 'hooks' => '钩子',
      'mcp' || 'mcpServers' => 'MCP',
      'agent' || 'agents' => '子智能体',
      'lsp' => 'LSP',
      _ => type,
    };
