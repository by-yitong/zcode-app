/// Agent 能力域 providers (技能/子智能体/命令/钩子/MCP/插件/外部导入)
///
/// 统一从 selectedWorkspaceProvider 取当前工作区;
/// 写操作采用"乐观更新 + 静默刷新"或直接抛错由 UI 呈现。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/relay/relay_client.dart';
import '../../../providers/app_providers.dart';
import '../models/capability_models.dart';

/// 当前工作区 (path, identity); 无工作区时抛异常
(RelayClient, String, String?) _ctx(Ref ref) {
  final client = ref.read(relayClientProvider);
  if (client == null) throw const NoRelayException();
  final ws = ref.read(selectedWorkspaceProvider);
  if (ws == null) throw const NoWorkspaceException();
  return (client, ws.workspacePath, ws.workspaceIdentity);
}

class NoRelayException implements Exception {
  const NoRelayException();
  @override
  String toString() => '未连接到 ZCode';
}

class NoWorkspaceException implements Exception {
  const NoWorkspaceException();
  @override
  String toString() => '未选择工作区';
}

// ================================================================
// 技能
// ================================================================

class SkillsCapsNotifier
    extends StateNotifier<AsyncValue<List<SkillEntry>>> {
  SkillsCapsNotifier(this._ref) : super(const AsyncValue.loading()) {
    if (_ref.read(relayClientProvider) != null) load();
  }

  final Ref _ref;

  Future<void> load() async {
    try {
      final (client, path, identity) = _ctx(_ref);
      final resp = await client.getSkills(
          workspacePath: path, workspaceIdentity: identity);
      final raw = resp['skills'];
      final list = raw is List
          ? raw
              .whereType<Map>()
              .map((m) => SkillEntry.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : <SkillEntry>[];
      state = AsyncValue.data(list);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 启停 (乐观)
  Future<void> setEnabled(SkillEntry skill, bool enabled) async {
    await _mutate(skill, enabled, (client, path, identity) async {
      await client.setSkillEnabled(
        workspacePath: path,
        workspaceIdentity: identity,
        skillId: skill.id.isNotEmpty ? skill.id : skill.name,
        enabled: enabled,
        scope: skill.scope,
      );
    });
  }

  /// 删除
  Future<void> delete(SkillEntry skill) async {
    final (client, path, identity) = _ctx(_ref);
    await client.deleteSkill(
      workspacePath: path,
      workspaceIdentity: identity,
      skillId: skill.id.isNotEmpty ? skill.id : skill.name,
    );
    await load();
  }

  Future<void> copyToCommon(SkillEntry skill) async {
    final (client, path, identity) = _ctx(_ref);
    await client.copySkillToCommon(
      workspacePath: path,
      workspaceIdentity: identity,
      skillId: skill.id.isNotEmpty ? skill.id : skill.name,
    );
    await load();
  }

  Future<void> removeFromCommon(SkillEntry skill) async {
    final (client, path, identity) = _ctx(_ref);
    await client.removeSkillFromCommon(
      workspacePath: path,
      workspaceIdentity: identity,
      skillId: skill.id.isNotEmpty ? skill.id : skill.name,
    );
    await load();
  }

  Future<void> _mutate(SkillEntry skill, bool enabled, Future<void> Function(
      RelayClient, String, String?) action) async {
    // 乐观更新
    state.whenData((list) {
      state = AsyncValue.data([
        for (final s in list)
          if (identical(s, skill) || s.id == skill.id) s.copyWith(enabled: enabled) else s
      ]);
    });
    try {
      final (client, path, identity) = _ctx(_ref);
      await action(client, path, identity);
    } catch (e) {
      appLog.w('[AgentCaps] 技能启停失败: $e');
      rethrow;
    } finally {
      load(); // 静默刷新对齐服务端
    }
  }
}

final skillsCapsProvider =
    StateNotifierProvider<SkillsCapsNotifier, AsyncValue<List<SkillEntry>>>(
        (ref) => SkillsCapsNotifier(ref));

// ================================================================
// 子智能体
// ================================================================

class SubagentsNotifier extends StateNotifier<AsyncValue<List<SubagentEntry>>> {
  SubagentsNotifier(this._ref) : super(const AsyncValue.loading()) {
    if (_ref.read(relayClientProvider) != null) load();
  }

  final Ref _ref;

  Future<void> load() async {
    try {
      final (client, path, identity) = _ctx(_ref);
      final resp = await client.listSubagents(
          workspacePath: path, workspaceIdentity: identity);
      final raw = resp['agents'];
      final list = raw is List
          ? raw
              .whereType<Map>()
              .map((m) => SubagentEntry.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : <SubagentEntry>[];
      state = AsyncValue.data(list);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> setEnabled(SubagentEntry agent, bool enabled) async {
    state.whenData((list) {
      state = AsyncValue.data([
        for (final a in list)
          if (a.id == agent.id)
            SubagentEntry(
              id: a.id, name: a.name, description: a.description,
              systemPrompt: a.systemPrompt, color: a.color, model: a.model,
              thoughtLevel: a.thoughtLevel, tools: a.tools,
              disallowedTools: a.disallowedTools, skills: a.skills,
              permissionMode: a.permissionMode, maxTurns: a.maxTurns,
              background: a.background, injectAgentsMd: a.injectAgentsMd,
              mcpServers: a.mcpServers, path: a.path, scope: a.scope,
              source: a.source, enabled: enabled, readOnly: a.readOnly,
            )
          else
            a
      ]);
    });
    try {
      final (client, _, _) = _ctx(_ref);
      await client.setSubagentEnabled(agentId: agent.id, enabled: enabled);
    } catch (e) {
      appLog.w('[AgentCaps] 子智能体启停失败: $e');
      rethrow;
    } finally {
      load();
    }
  }

  /// 内置 agent 的模型/思考级别覆盖; model=null 清除覆盖
  Future<void> setBuiltInOverride(
      String agentName, String? model, String? thoughtLevel) async {
    final (client, _, _) = _ctx(_ref);
    await client.setSubagentBuiltInModelOverride(
        agentName: agentName, model: model, thoughtLevel: thoughtLevel);
    await load();
  }

  Future<void> create(Map<String, dynamic> config) async {
    final (client, _, _) = _ctx(_ref);
    await client.createSubagent(config: config);
    await load();
  }

  Future<void> update(SubagentEntry agent, Map<String, dynamic> config) async {
    final (client, _, _) = _ctx(_ref);
    await client.updateSubagent(
        agentId: agent.id, config: config, oldFilePath: agent.path);
    await load();
  }

  Future<void> delete(SubagentEntry agent) async {
    final (client, _, _) = _ctx(_ref);
    await client.deleteSubagent(
        agentId: agent.id, filePath: agent.path ?? '');
    await load();
  }
}

final subagentsProvider =
    StateNotifierProvider<SubagentsNotifier, AsyncValue<List<SubagentEntry>>>(
        (ref) => SubagentsNotifier(ref));

// ================================================================
// 命令
// ================================================================

class CommandsNotifier extends StateNotifier<AsyncValue<List<CommandEntry>>> {
  CommandsNotifier(this._ref) : super(const AsyncValue.loading()) {
    if (_ref.read(relayClientProvider) != null) load();
  }

  final Ref _ref;

  Future<void> load() async {
    try {
      final (client, path, identity) = _ctx(_ref);
      final resp = await client.listCommands(
          workspacePath: path, workspaceIdentity: identity);
      final merged = <CommandEntry>[];
      for (final key in ['commands', 'userCommands', 'pluginCommands']) {
        final raw = resp[key];
        if (raw is List) {
          merged.addAll(raw
              .whereType<Map>()
              .map((m) => CommandEntry.fromJson(Map<String, dynamic>.from(m))));
        }
      }
      state = AsyncValue.data(merged);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> create(Map<String, dynamic> config) async {
    final (client, _, path) = _ctx(_ref);
    await client.writeCommandFile(config: config, workspacePath: path);
    await load();
  }

  Future<void> update(CommandEntry cmd, Map<String, dynamic> config) async {
    final (client, _, path) = _ctx(_ref);
    await client.updateCommandFile(
        config: config,
        oldFilePath: cmd.filePath ?? '',
        workspacePath: path);
    await load();
  }

  Future<void> delete(CommandEntry cmd) async {
    final (client, _, _) = _ctx(_ref);
    await client.deleteCommandFile(filePath: cmd.filePath ?? '');
    await load();
  }

  Future<void> setEnabled(CommandEntry cmd, bool enabled) async {
    state.whenData((list) {
      state = AsyncValue.data([
        for (final c in list)
          if (c.id == cmd.id) c.copyWith(enabled: enabled) else c
      ]);
    });
    try {
      final (client, _, _) = _ctx(_ref);
      await client.setCommandEnabled(filePath: cmd.filePath ?? '', enabled: enabled);
    } catch (e) {
      appLog.w('[AgentCaps] 命令启停失败: $e');
      rethrow;
    }
  }
}

final commandsProvider =
    StateNotifierProvider<CommandsNotifier, AsyncValue<List<CommandEntry>>>(
        (ref) => CommandsNotifier(ref));

// ================================================================
// 钩子
// ================================================================

class HooksNotifier extends StateNotifier<AsyncValue<List<HookEntry>>> {
  HooksNotifier(this._ref) : super(const AsyncValue.loading()) {
    if (_ref.read(relayClientProvider) != null) load();
  }

  final Ref _ref;

  Future<void> load() async {
    try {
      final (client, path, identity) = _ctx(_ref);
      final resp = await client.loadHooks(
          workspacePath: path, workspaceIdentity: identity);
      final raw = resp['hooks'];
      final list = raw is List
          ? raw
              .whereType<Map>()
              .map((m) => HookEntry.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : <HookEntry>[];
      state = AsyncValue.data(list);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 保存整表 (增删改后调用)
  Future<void> saveAll(List<HookEntry> hooks) async {
    final (client, path, identity) = _ctx(_ref);
    await client.saveHooks(
      workspacePath: path,
      workspaceIdentity: identity,
      hooks: [for (final h in hooks) h.toWireJson()],
    );
    await load();
  }

  Future<void> setEnabled(HookEntry hook, bool enabled) async {
    final list = state.valueOrNull ?? const <HookEntry>[];
    await saveAll([
      for (final h in list)
        if (h.id == hook.id) h.copyWith(enabled: enabled) else h
    ]);
  }

  Future<void> upsert(HookEntry hook, {String? oldId}) async {
    final list = state.valueOrNull ?? const <HookEntry>[];
    final next = <HookEntry>[];
    var replaced = false;
    for (final h in list) {
      if (h.id == (oldId ?? hook.id)) {
        next.add(hook);
        replaced = true;
      } else {
        next.add(h);
      }
    }
    if (!replaced) next.add(hook);
    await saveAll(next);
  }

  Future<void> delete(HookEntry hook) async {
    final list = state.valueOrNull ?? const <HookEntry>[];
    await saveAll([for (final h in list) if (h.id != hook.id) h]);
  }
}

final hooksProvider =
    StateNotifierProvider<HooksNotifier, AsyncValue<List<HookEntry>>>(
        (ref) => HooksNotifier(ref));

// ================================================================
// MCP
// ================================================================

class McpState {
  final List<McpServerEntry> servers;
  final Map<String, McpServerStatus> statuses; // name → status
  const McpState({this.servers = const [], this.statuses = const {}});
}

class McpNotifier extends StateNotifier<AsyncValue<McpState>> {
  McpNotifier(this._ref) : super(const AsyncValue.loading()) {
    if (_ref.read(relayClientProvider) != null) load();
  }

  final Ref _ref;

  Future<void> load({bool withStatus = true}) async {
    try {
      final (client, path, identity) = _ctx(_ref);
      final resp = await client.loadMcpServers(
          workspacePath: path, workspaceIdentity: identity);
      final raw = resp['servers'];
      final servers = raw is List
          ? raw
              .whereType<Map>()
              .map((m) => McpServerEntry.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : <McpServerEntry>[];
      var statuses = <String, McpServerStatus>{};
      if (withStatus && servers.isNotEmpty) {
        try {
          final st = await client.listMcpServerStatuses(
              workspacePath: path, workspaceIdentity: identity);
          statuses = _parseStatuses(st);
        } catch (e) {
          appLog.i('[AgentCaps] MCP 状态获取失败(忽略): $e');
        }
      }
      state = AsyncValue.data(McpState(servers: servers, statuses: statuses));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Map<String, McpServerStatus> _parseStatuses(Map<String, dynamic> resp) {
    final out = <String, McpServerStatus>{};
    List? list;
    for (final k in ['servers', 'statuses', 'results']) {
      if (resp[k] is List) {
        list = resp[k] as List;
        break;
      }
    }
    // 也可能是 {mcpServers: {...}} 映射
    if (list == null) {
      for (final k in ['mcpServers', 'serverStatuses']) {
        final v = resp[k];
        if (v is Map) {
          v.forEach((name, st) {
            if (st is Map) {
              out[name.toString()] = McpServerStatus.fromJson(
                  Map<String, dynamic>.from(st));
            }
          });
          return out;
        }
      }
    }
    if (list != null) {
      for (final it in list) {
        if (it is Map) {
          final s = McpServerStatus.fromJson(Map<String, dynamic>.from(it));
          if (s.name.isNotEmpty) out[s.name] = s;
        }
      }
    }
    return out;
  }

  Future<void> upsert(McpServerEntry server) async {
    final (client, _, _) = _ctx(_ref);
    await client.saveMcpServer(
      action: 'upsert',
      name: server.name,
      config: server.toConfig(),
      projectPath: server.scope == 'workspace' ? server.projectPath : null,
    );
    await load();
  }

  Future<void> delete(McpServerEntry server) async {
    final (client, _, _) = _ctx(_ref);
    await client.saveMcpServer(
      action: 'delete',
      name: server.name,
      projectPath: server.scope == 'workspace' ? server.projectPath : null,
    );
    await load();
  }

  Future<void> setEnabled(McpServerEntry server, bool enabled) async {
    // 乐观
    state.whenData((s) {
      state = AsyncValue.data(McpState(
        servers: [
          for (final e in s.servers)
            if (e.name == server.name) e.copyWith(enabled: enabled) else e
        ],
        statuses: s.statuses,
      ));
    });
    try {
      final (client, _, _) = _ctx(_ref);
      await client.saveMcpServer(
        action: 'set-enabled',
        name: server.name,
        enabled: enabled,
        projectPath: server.scope == 'workspace' ? server.projectPath : null,
      );
    } catch (e) {
      appLog.w('[AgentCaps] MCP 启停失败: $e');
      rethrow;
    }
  }
}

final mcpProvider = StateNotifierProvider<McpNotifier, AsyncValue<McpState>>(
    (ref) => McpNotifier(ref));

// ================================================================
// 插件 (overview schema: installedPlugins / availablePlugins / marketplaces)
// ================================================================

class PluginsState {
  final List<PluginEntry> installed;
  final List<PluginEntry> available; // 市场可安装 (含 listing 元数据)
  final List<MarketplaceEntry> marketplaces;
  const PluginsState({
    this.installed = const [],
    this.available = const [],
    this.marketplaces = const [],
  });
}

class PluginsNotifier extends StateNotifier<AsyncValue<PluginsState>> {
  PluginsNotifier(this._ref) : super(const AsyncValue.loading()) {
    if (_ref.read(relayClientProvider) != null) load();
  }

  final Ref _ref;

  Future<void> load() async {
    try {
      final (client, path, identity) = _ctx(_ref);
      // 已安装以 listPlugins 为准 (含官方内置 seed 插件;
      // overview 的 installedPlugins 只登记市场安装, 会漏)
      final listResp = await client.listPlugins(
          workspacePath: path, workspaceIdentity: identity);
      final installed =
          _list(listResp, 'plugins', PluginEntry.fromJson);

      // 市场数据用 overview; 失败不阻塞已安装展示
      Map<String, dynamic>? overview;
      try {
        overview = await client.getPluginsOverview(
            workspacePath: path, workspaceIdentity: identity);
      } catch (e) {
        appLog.i('[AgentCaps] overview 失败(仅市场数据受影响): $e');
      }
      final ovState = _parse(overview ?? {});

      // 用 overview 的同 id 条目补 icon/分类/更新状态
      final ovInstalled = {
        for (final p in ovState.installed) p.id: p
      };
      state = AsyncValue.data(PluginsState(
        installed: [
          for (final p in installed)
            ovInstalled[p.id]?.mergeOverview(p) ?? p
        ],
        available: ovState.available,
        marketplaces: ovState.marketplaces,
      ));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  static List<T> _list<T>(Map<String, dynamic> m, String key,
      T Function(Map<String, dynamic>) fromJson) {
    final v = m[key];
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  PluginsState _parse(Map<String, dynamic> overview) {
    // capability.supported == false 时 overview 是退役空壳 → 走 listPlugins 兜底
    final capability = (overview['capability'] ?? const {}) as Map;
    if (capability['supported'] == false) {
      return const PluginsState();
    }
    return PluginsState(
      installed: _list(overview, 'installedPlugins', PluginEntry.fromJson),
      available: _list(overview, 'availablePlugins', PluginEntry.fromJson),
      marketplaces: _list(overview, 'marketplaces', MarketplaceEntry.fromJson),
    );
  }

  /// listPlugins 兜底 (overview 不支持时)
  Future<void> loadFromList() async {
    try {
      final (client, path, identity) = _ctx(_ref);
      final resp = await client.listPlugins(
          workspacePath: path, workspaceIdentity: identity);
      final installed = _list(resp, 'plugins', PluginEntry.fromJson);
      state = AsyncValue.data(PluginsState(installed: installed));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> setEnabled(PluginEntry plugin, bool enabled) async {
    final (client, path, identity) = _ctx(_ref);
    await client.setPluginEnabled(
        workspacePath: path, workspaceIdentity: identity,
        pluginId: plugin.id, enabled: enabled);
    await load();
  }

  Future<void> uninstall(PluginEntry plugin, {bool removeCache = false}) async {
    final (client, path, identity) = _ctx(_ref);
    await client.uninstallPlugin(
      workspacePath: path,
      workspaceIdentity: identity,
      pluginId: plugin.id,
      pluginName: plugin.name,
      marketplace: plugin.marketplace,
      removeCache: removeCache,
    );
    await load();
  }

  Future<void> update(PluginEntry plugin) async {
    final (client, _, _) = _ctx(_ref);
    await client.updatePlugin(pluginId: plugin.id);
    await load();
  }

  Future<void> restoreBuiltin(PluginEntry plugin) async {
    final (client, _, _) = _ctx(_ref);
    await client.restoreBuiltinPlugin(pluginId: plugin.id);
    await load();
  }

  Future<void> addMarketplace(String source) async {
    final (client, path, identity) = _ctx(_ref);
    await client.addPluginMarketplace(
        workspacePath: path, workspaceIdentity: identity, source: source);
    await load();
  }

  Future<void> removeMarketplace(MarketplaceEntry marketplace) async {
    final (client, path, identity) = _ctx(_ref);
    await client.removePluginMarketplace(
      workspacePath: path,
      workspaceIdentity: identity,
      marketplace: marketplace.name,
    );
    await load();
  }

  Future<void> updateMarketplace(MarketplaceEntry marketplace) async {
    final (client, path, identity) = _ctx(_ref);
    await client.updatePluginMarketplace(
      workspacePath: path,
      workspaceIdentity: identity,
      marketplace: marketplace.name,
    );
    await load();
  }

  /// 安装市场插件
  Future<void> install(PluginEntry plugin) async {
    final (client, path, identity) = _ctx(_ref);
    await client.installPlugin(
      workspacePath: path,
      workspaceIdentity: identity,
      pluginName: plugin.name,
      marketplace: plugin.marketplace,
    );
    await load();
  }
}

final pluginsProvider =
    StateNotifierProvider<PluginsNotifier, AsyncValue<PluginsState>>(
        (ref) => PluginsNotifier(ref));

// ================================================================
// 外部 Agent 导入
// ================================================================

class ImportNotifier extends StateNotifier<AsyncValue<List<ImportAgent>>> {
  ImportNotifier(this._ref) : super(const AsyncValue.data([]));

  final Ref _ref;

  Future<void> detect(List<String> categories) async {
    state = const AsyncValue.loading();
    try {
      final (client, path, identity) = _ctx(_ref);
      final resp = await client.detectExternalAgents(
        workspacePath: path,
        workspaceIdentity: identity,
        categories: categories,
      );
      state = AsyncValue.data(parseImportDiscovery(resp));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 导入所选; 返回结果摘要
  Future<Map<String, dynamic>> importSelected(
    Set<String> selectionKeys, {
    String targetScope = 'global',
    String importMode = 'copy',
  }) async {
    final (client, path, identity) = _ctx(_ref);
    // 按类别分组
    final groups = <String, Map<String, dynamic>>{};
    for (final key in selectionKeys) {
      final Map<String, dynamic> item;
      try {
        item = Map<String, dynamic>.from(jsonDecode(key) as Map);
      } catch (_) {
        continue;
      }
      final agent = item['agent']?.toString() ?? '';
      final category = item['category']?.toString() ?? '';
      final resourcePath = item['resourcePath']?.toString() ?? '';
      final sourceScope = item['sourceScope']?.toString();
      if (agent.isEmpty || category.isEmpty || resourcePath.isEmpty) continue;
      final gk = '$agent|$category|${sourceScope ?? ''}';
      final g = groups.putIfAbsent(gk, () => {
            'agent': agent,
            'category': category,
            if (sourceScope != null) 'sourceScope': sourceScope,
            'targetScope': targetScope,
            'importMode': importMode,
          });
      final listKey = switch (category) {
        'skills' => 'skillPaths',
        'commands' => 'commandPaths',
        'plugins' => 'pluginPaths',
        _ => 'mcpServerPaths',
      };
      final arr = (g[listKey] as List?) ?? [];
      arr.add(resourcePath);
      g[listKey] = arr;
    }
    return client.importExternalAgents(
      workspacePath: path,
      workspaceIdentity: identity,
      selections: [for (final g in groups.values) g],
    );
  }
}

final importProvider =
    StateNotifierProvider<ImportNotifier, AsyncValue<List<ImportAgent>>>(
        (ref) => ImportNotifier(ref));
