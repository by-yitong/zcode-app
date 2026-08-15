import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/relay/relay_client.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../../shared/widgets/app_tile_group.dart';

/// Agent 能力设置页面
/// 显示: 技能、子智能体、MCP、插件、命令、钩子
class AgentSettingsScreen extends ConsumerStatefulWidget {
  final String workspacePath;

  const AgentSettingsScreen({super.key, required this.workspacePath});

  @override
  ConsumerState<AgentSettingsScreen> createState() => _AgentSettingsScreenState();
}

class _AgentSettingsScreenState extends ConsumerState<AgentSettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Map<String, dynamic>? _skills;
  Map<String, dynamic>? _subagents;
  Map<String, dynamic>? _hooks;
  Map<String, dynamic>? _plugins;
  Map<String, dynamic>? _commands;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _loadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final relay = ref.read(relayClientProvider);
      if (relay == null) throw Exception('未连接');

      final ws = widget.workspacePath;
      final results = await Future.wait([
        _safeCall(relay, 'skills', 'list', [{'workspacePath': ws}]),
        _safeCall(relay, 'subagents', 'list', [{'workspacePath': ws}]),
        _safeCall(relay, 'hooks', 'loadHooks', [{'workspacePath': ws}]),
        _safeCall(relay, 'zcode-agent', 'listPlugins', [{'workspacePath': ws}]),
        _safeCall(relay, 'commands', 'list', [{'workspacePath': ws}]),
      ]);

      setState(() {
        _skills = results[0];
        _subagents = results[1];
        _hooks = results[2];
        _plugins = results[3];
        _commands = results[4];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 安全 RPC 调用, 失败返回 null
  Future<Map<String, dynamic>?> _safeCall(
    RelayClient relay,
    String channel,
    String method,
    List<dynamic> args,
  ) async {
    try {
      final resp = await relay.rpcCall(channel, method, args);
      if (resp.body is Map) return Map<String, dynamic>.from(resp.body as Map);
      return {'raw': resp.body};
    } catch (e) {
      appLog.w('[AgentSettings] $channel.$method failed: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent 设置'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '技能'),
            Tab(text: '子智能体'),
            Tab(text: '插件'),
            Tab(text: '命令'),
            Tab(text: '钩子'),
            Tab(text: 'MCP'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _loadAll,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? AppEmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: '加载失败',
                  subtitle: _error,
                  actionLabel: '重试',
                  actionIcon: Icons.refresh_rounded,
                  iconTint: AppColors.danger,
                  onAction: _loadAll,
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildSkillsTab(theme, colorScheme),
                    _buildSubagentsTab(theme, colorScheme),
                    _buildPluginsTab(theme, colorScheme),
                    _buildCommandsTab(theme, colorScheme),
                    _buildHooksTab(theme, colorScheme),
                    _buildMcpTab(theme, colorScheme),
                  ],
                ),
    );
  }

  // ================================================================
  // 技能
  // ================================================================
  Widget _buildSkillsTab(ThemeData theme, ColorScheme cs) {
    final skills = (_skills?['skills'] as List<dynamic>?) ?? [];
    return _buildCapabilityList(
      theme: theme,
      items: skills.cast<Map<String, dynamic>>(),
      emptyMessage: '暂无技能',
      badgeOf: (s) {
        final source = s['source'] as String? ?? '';
        if (source.isNotEmpty) return source;
        return s['scope'] as String? ?? '';
      },
    );
  }

  // ================================================================
  // 子智能体
  // ================================================================
  Widget _buildSubagentsTab(ThemeData theme, ColorScheme cs) {
    final agents = (_subagents?['agents'] as List<dynamic>?) ?? [];
    return _buildCapabilityList(
      theme: theme,
      items: agents.cast<Map<String, dynamic>>(),
      emptyMessage: '暂无子智能体',
      badgeOf: (a) => a['model'] as String? ?? '',
    );
  }

  // ================================================================
  // 插件
  // ================================================================
  Widget _buildPluginsTab(ThemeData theme, ColorScheme cs) {
    final plugins = (_plugins?['plugins'] as List<dynamic>?) ?? [];
    return _buildCapabilityList(
      theme: theme,
      items: plugins.cast<Map<String, dynamic>>(),
      emptyMessage: '暂无插件',
      badgeOf: (p) {
        final v = p['version'] as String? ?? '';
        return v.isNotEmpty ? 'v$v' : '';
      },
    );
  }

  // ================================================================
  // 命令
  // ================================================================
  Widget _buildCommandsTab(ThemeData theme, ColorScheme cs) {
    final commands = (_commands?['commands'] as List<dynamic>?) ?? [];
    final userCommands = (_commands?['userCommands'] as List<dynamic>?) ?? [];
    final pluginCommands = (_commands?['pluginCommands'] as List<dynamic>?) ?? [];
    final all = [...commands, ...userCommands, ...pluginCommands];
    return _buildCapabilityList(
      theme: theme,
      items: all.cast<Map<String, dynamic>>(),
      emptyMessage: '暂无命令',
      badgeOf: (_) => '',
    );
  }

  // ================================================================
  // 钩子
  // ================================================================
  Widget _buildHooksTab(ThemeData theme, ColorScheme cs) {
    final hooks = (_hooks?['hooks'] as List<dynamic>?) ?? [];
    final enabled = _hooks?['hooksEnabled'] as bool? ?? false;
    if (hooks.isEmpty) {
      return AppEmptyState(
        icon: Icons.webhook_outlined,
        title: enabled ? '钩子已启用, 暂无配置' : '钩子未启用',
      );
    }
    return _buildCapabilityList(
      theme: theme,
      items: hooks.cast<Map<String, dynamic>>(),
      emptyMessage: '暂无钩子',
      badgeOf: (_) => '',
    );
  }

  // ================================================================
  // MCP (待实现)
  // ================================================================
  Widget _buildMcpTab(ThemeData theme, ColorScheme cs) {
    return const AppEmptyState(
      icon: Icons.dns_outlined,
      title: 'MCP 服务器管理',
      subtitle: '待实现',
    );
  }

  // ================================================================
  // 通用组件
  // ================================================================

  /// 能力列表 (分组卡形式, 每个 item 一个 AppTile)
  Widget _buildCapabilityList({
    required ThemeData theme,
    required List<Map<String, dynamic>> items,
    required String emptyMessage,
    required String Function(Map<String, dynamic>) badgeOf,
  }) {
    if (items.isEmpty) {
      return AppEmptyState(
        icon: Icons.extension_outlined,
        title: emptyMessage,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xl),
      children: [
        AppTileGroup(
          tiles: [
            for (final item in items)
              AppTile(
                icon: _iconFor(item),
                title: item['name'] as String? ?? '',
                subtitle: (item['description'] as String?)?.isNotEmpty == true
                    ? item['description'] as String
                    : null,
                value: badgeOf(item),
                trailing: _enabledDot(theme, item['enabled'] as bool? ?? false),
              ),
          ],
        ),
      ],
    );
  }

  /// 根据条目内容选图标 (有 enabled 优先用激活态色)
  IconData _iconFor(Map<String, dynamic> item) {
    if (item['model'] != null) return Icons.smart_toy_outlined;   // 子智能体
    if (item['version'] != null) return Icons.extension_outlined;  // 插件
    if (item['event'] != null) return Icons.webhook_outlined;      // 钩子
    if (item['scope'] != null || item['source'] != null) {
      return Icons.auto_awesome_outlined;                          // 技能
    }
    return Icons.terminal_rounded;                                  // 命令
  }

  /// enabled 状态点 (强调色实心圆 = 启用, 描边圆 = 禁用)
  Widget _enabledDot(ThemeData theme, bool enabled) {
    return Container(
      width: 10, height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: enabled ? AppColors.success : Colors.transparent,
        border: Border.all(
          color: enabled ? AppColors.success : theme.colorScheme.outline,
          width: enabled ? 0 : 1.5,
        ),
      ),
    );
  }
}

