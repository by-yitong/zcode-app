import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/relay/relay_client.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../../shared/widgets/app_tile_group.dart';

/// 远程设置页 — 只读查看 ZCode 桌面端的配置
class RemoteSettingsScreen extends ConsumerStatefulWidget {
  final String workspacePath;

  const RemoteSettingsScreen({super.key, required this.workspacePath});

  @override
  ConsumerState<RemoteSettingsScreen> createState() => _RemoteSettingsScreenState();
}

class _RemoteSettingsScreenState extends ConsumerState<RemoteSettingsScreen> {
  Map<String, dynamic>? _settings;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final relay = ref.read(relayClientProvider);
      if (relay == null) throw Exception('未连接');
      final resp = await relay.rpcCall('setting', 'get', []);
      setState(() {
        _settings = resp.body is Map ? Map<String, dynamic>.from(resp.body as Map) : null;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('远程设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('加载失败', style: theme.textTheme.titleMedium),
                      const SizedBox(height: AppSpacing.sm),
                      Text(_error!, style: theme.textTheme.bodySmall),
                      const SizedBox(height: AppSpacing.md),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.md,
                    ),
                    children: _buildSections(theme),
                  ),
                ),
    );
  }

  List<Widget> _buildSections(ThemeData theme) {
    final s = _settings ?? {};
    final sections = <Widget>[];

    // 常规
    sections.add(const AppSectionHeader(title: '常规'));
    sections.add(AppTileGroup(tiles: [
      AppTile(
        icon: Icons.language_rounded,
        title: '界面语言',
        value: _localeLabel(s['locale']),
      ),
      AppTile(
        icon: Icons.terminal_rounded,
        title: '继承系统终端',
        value: (s['terminalInheritSystemProfile'] as bool? ?? false) ? '开启' : '关闭',
      ),
      AppTile(
        icon: Icons.text_fields_rounded,
        title: '终端字体',
        value: (s['terminalFontFamily'] as String?)?.isNotEmpty == true
            ? s['terminalFontFamily']
            : '自动',
      ),
      AppTile(
        icon: Icons.code_rounded,
        title: '集成终端 Shell',
        value: s['integratedTerminalShell'] ?? '自动选择',
      ),
      AppTile(
        icon: Icons.notifications_rounded,
        title: '任务通知',
        value: (s['taskNotificationEnabled'] as bool? ?? false) ? '开启' : '关闭',
      ),
      AppTile(
        icon: Icons.volume_up_rounded,
        title: '通知声音',
        value: (s['notificationSoundEnabled'] as bool? ?? false) ? '开启' : '关闭',
      ),
      AppTile(
        icon: Icons.queue_rounded,
        title: '交互行为',
        value: _interactionLabel(s['interactionBehavior']),
      ),
      AppTile(
        icon: Icons.psychology_rounded,
        title: '显示思考过程',
        value: (s['showFullThinking'] as bool? ?? false) ? '开启' : '关闭',
      ),
      AppTile(
        icon: Icons.checklist_rounded,
        title: '显示待办',
        value: (s['showTodo'] as bool? ?? false) ? '开启' : '关闭',
      ),
    ]));

    // 自动归档
    sections.add(const AppSectionHeader(title: '自动归档'));
    sections.add(AppTileGroup(tiles: [
      AppTile(
        icon: Icons.archive_outlined,
        title: '自动归档旧任务',
        value: (s['taskAutoArchiveEnabled'] as bool? ?? false) ? '开启' : '关闭',
      ),
      AppTile(
        icon: Icons.schedule_rounded,
        title: '归档保留时长',
        value: '${s['taskAutoArchiveOlderThanDays'] ?? 7} 天',
      ),
    ]));

    // 网络
    sections.add(const AppSectionHeader(title: '网络'));
    sections.add(AppTileGroup(tiles: [
      AppTile(
        icon: Icons.network_ping_rounded,
        title: 'HTTP 代理',
        value: (s['httpProxy'] as String?)?.isNotEmpty == true ? s['httpProxy'] : '直连',
      ),
      AppTile(
        icon: Icons.vpn_lock_outlined,
        title: '代理例外',
        value: (s['httpProxyBypass'] as String?)?.isNotEmpty == true
            ? s['httpProxyBypass']
            : '无',
      ),
      AppTile(
        icon: Icons.verified_user_outlined,
        title: '自定义证书',
        value: (s['customCaCertPath'] as String?)?.isNotEmpty == true
            ? s['customCaCertPath']
            : '无',
      ),
    ]));

    // 数据目录
    sections.add(const AppSectionHeader(title: '存储'));
    sections.add(AppTileGroup(tiles: [
      AppTile(
        icon: Icons.folder_outlined,
        title: '数据目录',
        value: s['dataBaseDir'] ?? '默认',
      ),
    ]));

    // 优化
    sections.add(const AppSectionHeader(title: '其他'));
    sections.add(AppTileGroup(tiles: [
      AppTile(
        icon: Icons.speed_rounded,
        title: '优化体验',
        value: (s['telemetryOptIn'] as bool? ?? false) ? '开启' : '关闭',
      ),
      AppTile(
        icon: Icons.close_rounded,
        title: '关闭到托盘 (Windows)',
        value: (s['closeToTrayOnWindows'] as bool? ?? false) ? '开启' : '关闭',
      ),
    ]));

    sections.add(const SizedBox(height: AppSpacing.xxl));
    return sections;
  }

  String _localeLabel(String? locale) {
    switch (locale) {
      case 'zh-CN':
        return '简体中文';
      case 'en':
        return 'English';
      case 'system':
        return '跟随系统';
      default:
        return locale ?? '简体中文';
    }
  }

  String _interactionLabel(String? behavior) {
    switch (behavior) {
      case 'queue':
        return '队列';
      case 'guide':
        return '引导';
      default:
        return behavior ?? '队列';
    }
  }
}
