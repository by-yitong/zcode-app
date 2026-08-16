import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/relay/relay_client.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../../shared/widgets/app_tile_group.dart';
import '../../agent/widgets/caps_widgets.dart';

/// 远程设置页 — 查看 + 编辑 ZCode 桌面端配置 (setting.get / setting.update)
///
/// 可编辑项使用抓包确认过的真实 key; 未确认的键保持只读。
class RemoteSettingsScreen extends ConsumerStatefulWidget {
  final String workspacePath;

  const RemoteSettingsScreen({super.key, required this.workspacePath});

  @override
  ConsumerState<RemoteSettingsScreen> createState() =>
      _RemoteSettingsScreenState();
}

class _RemoteSettingsScreenState extends ConsumerState<RemoteSettingsScreen> {
  Map<String, dynamic>? _settings;
  bool _loading = true;
  String? _error;
  String _savingKey = '';

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
      final settings = await relay.getSettings();
      setState(() {
        _settings = settings;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  RelayClient? get _relay => ref.read(relayClientProvider);

  /// 更新单个设置 (乐观 + 失败回滚提示)
  Future<void> _update(String key, Object value) async {
    final old = _settings?[key];
    setState(() {
      _savingKey = key;
      _settings = {...?_settings, key: value};
    });
    try {
      await _relay!.updateSettings({key: value});
    } catch (e) {
      appLog.w('[RemoteSettings] 更新 $key 失败: $e');
      setState(() => _settings = {...?_settings, key: old});
      _snack('保存失败: $e');
    } finally {
      if (mounted) setState(() => _savingKey = '');
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
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

  // ================================================================
  // 分区
  // ================================================================

  List<Widget> _buildSections(ThemeData theme) {
    final s = _settings ?? {};
    final sections = <Widget>[];

    // 常规
    sections.add(const AppSectionHeader(title: '常规'));
    sections.add(AppTileGroup(tiles: [
      _pickerTile(
        icon: Icons.language_rounded,
        title: '界面语言',
        value: _localeLabel(s['localePreference'] ?? s['locale']),
        options: const {
          'zh-CN': '简体中文',
          'en': 'English',
          'system': '跟随系统',
        },
        current: (s['localePreference'] ?? s['locale'] ?? 'zh-CN').toString(),
        onPick: (v) => _update('localePreference', v),
      ),
      _pickerTile(
        icon: Icons.queue_rounded,
        title: '交互行为',
        value: _interactionLabel(s['zcodeInteractionBehavior']),
        options: const {'queue': '队列', 'guide': '引导'},
        current: (s['zcodeInteractionBehavior'] ?? 'queue').toString(),
        onPick: (v) => _update('zcodeInteractionBehavior', v),
      ),
      _switchTile(
        icon: Icons.psychology_rounded,
        title: '显示思考过程',
        value: s['messageStreamShowReasoning'] == true,
        key: 'messageStreamShowReasoning',
        onChanged: (v) => _update('messageStreamShowReasoning', v),
      ),
      _switchTile(
        icon: Icons.checklist_rounded,
        title: '显示待办',
        value: s['messageStreamShowTodos'] == true,
        key: 'messageStreamShowTodos',
        onChanged: (v) => _update('messageStreamShowTodos', v),
      ),
      _switchTile(
        icon: Icons.notifications_rounded,
        title: '离线时自动确认交互',
        value: s['askUserQuestionAutoResolutionEnabled'] == true,
        key: 'askUserQuestionAutoResolutionEnabled',
        onChanged: (v) => _update('askUserQuestionAutoResolutionEnabled', v),
      ),
      _switchTile(
        icon: Icons.terminal_rounded,
        title: '继承系统终端',
        value: s['terminalInheritSystemProfile'] == true,
        key: 'terminalInheritSystemProfile',
        onChanged: (v) => _update('terminalInheritSystemProfile', v),
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
    ]));

    // 自动归档
    sections.add(const AppSectionHeader(title: '自动归档'));
    sections.add(AppTileGroup(tiles: [
      _switchTile(
        icon: Icons.archive_outlined,
        title: '自动归档旧任务',
        value: s['taskAutoArchiveEnabled'] == true,
        key: 'taskAutoArchiveEnabled',
        onChanged: (v) => _update('taskAutoArchiveEnabled', v),
      ),
      _pickerTile(
        icon: Icons.schedule_rounded,
        title: '归档保留时长',
        value: '${s['taskAutoArchiveOlderThanDays'] ?? 7} 天',
        options: const {'1': '1 天', '3': '3 天', '7': '7 天', '14': '14 天', '30': '30 天'},
        current: (s['taskAutoArchiveOlderThanDays'] ?? 7).toString(),
        onPick: (v) =>
            _update('taskAutoArchiveOlderThanDays', int.tryParse(v) ?? 7),
      ),
    ]));

    // 网络 (只读 — 键未在协议中确认)
    sections.add(const AppSectionHeader(title: '网络'));
    sections.add(AppTileGroup(tiles: [
      AppTile(
        icon: Icons.network_ping_rounded,
        title: 'HTTP 代理',
        value: (s['httpProxy'] as String?)?.isNotEmpty == true ? s['httpProxy'] : '直连',
      ),
      AppTile(
        icon: Icons.vpn_lock_rounded,
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

    // 其他
    sections.add(const AppSectionHeader(title: '其他'));
    sections.add(AppTileGroup(tiles: [
      AppTile(
        icon: Icons.speed_rounded,
        title: '优化体验',
        value: (s['telemetryOptIn'] as bool? ?? false) ? '开启' : '关闭',
      ),
      _switchTile(
        icon: Icons.close_rounded,
        title: '关闭到托盘 (Windows)',
        value: s['closeToTrayOnWindows'] == true,
        key: 'closeToTrayOnWindows',
        onChanged: (v) => _update('closeToTrayOnWindows', v),
      ),
    ]));

    sections.add(const SizedBox(height: AppSpacing.xxl));
    return sections;
  }

  // ================================================================
  // 可编辑 tile
  // ================================================================

  AppTile _switchTile({
    required IconData icon,
    required String title,
    required bool value,
    required String key,
    required ValueChanged<bool> onChanged,
  }) {
    return AppTile(
      icon: icon,
      title: title,
      trailing: _savingKey == key
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : CapsSwitch(value: value, onChanged: onChanged),
    );
  }

  AppTile _pickerTile({
    required IconData icon,
    required String title,
    required String value,
    required Map<String, String> options,
    required String current,
    required ValueChanged<String> onPick,
  }) {
    return AppTile(
      icon: icon,
      title: title,
      value: value,
      showChevron: true,
      onTap: () {
        final theme = Theme.of(context);
        showModalBottomSheet(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg),
                  child: Text(title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                for (final e in options.entries)
                  ListTile(
                    title: Text(e.value),
                    dense: true,
                    trailing: current == e.key
                        ? Icon(Icons.check_rounded,
                            size: 20, color: AppColors.accent)
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (e.key != current) onPick(e.key);
                    },
                  ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ),
          ),
        );
      },
    );
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
