import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/relay/relay_protocol.dart';
import '../../../core/feedback/notification_sound.dart';
import '../../../core/services/display_service.dart';
import '../../../core/services/pip_service.dart';
import '../../../core/services/update_service.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/pip_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/update_dialog.dart';
import '../../agent/screens/cap_pages.dart';
import '../../agent/widgets/caps_page_chrome.dart';
import 'connections_screen.dart';
import 'remote_settings_screen.dart';

/// 设置页 — DNA 提取自参考截图 (hallmark study):
/// - 页面底: 浅紫灰分组底 #F2F2F7 (仅浅色), 白卡无边框/无阴影, 圆角 20
/// - 分组标题: 斜体灰字, 左缘与行内图标对齐
/// - 行: 描边图标 24 + 标题 17 + 右灰值/细箭头 20, 行高 ~56
/// - 底部独立操作卡 (断开连接): 黑字 + logout 图标, 无箭头 (同截图退出登录)
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    // 提示音开关回填: 进入设置页时读一次持久化偏好 (默认开)。
    // 实际播放以触发时的偏好为准, provider 仅驱动开关 UI 显示。
    SharedPreferences.getInstance()
        .then(
          (prefs) =>
              prefs.getBool(kNotificationSoundPrefKey) != false, // null 视为开
        )
        .then((on) {
          if (!mounted) return;
          ref.read(soundOnProvider.notifier).state = on;
        })
        .catchError((_) {}); // 偏好读取失败保持默认开
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final connectionAsync = ref.watch(relayConnectionStateProvider);

    final user = session.valueOrNull;
    final userName = user?.deviceName ?? '未登录';
    final deviceId = user?.deviceSid ?? '—';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: CapsPageHeader.overlayStyle(context),
      child: Scaffold(
        // 浅色换参考截图的紫灰分组底; 深色沿用全局主题
        backgroundColor: theme.brightness == Brightness.light
            ? const Color(0xFFF2F2F7)
            : null,
        appBar: const CapsPageHeader(title: '设置', plain: true),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          children: [
            // 用户卡 — 头像 + 设备名/SID + 连接状态; 整卡点击 → 远程连接管理
            _SettingsCard(
              child: InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ConnectionsScreen()),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  AppColors.accentHover,
                                  AppColors.accent,
                                ],
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.person_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  userName,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'SID · $deviceId',
                                  style: AppText.mono(
                                    context,
                                    size: AppTextSizes.monoXs,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      // 连接状态 pill (mono)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: AppSpacing.xs,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.cloud_done_rounded,
                              size: 14,
                              color: connectionAsync.maybeWhen(
                                data: (s) => s == RelayConnectionState.ready
                                    ? AppColors.success
                                    : AppColors.warning,
                                orElse: () => AppColors.warning,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Text(
                              connectionAsync.maybeWhen(
                                data: (state) {
                                  final s = state;
                                  return switch (s) {
                                    RelayConnectionState.ready =>
                                      '已连接到 ZCode',
                                    RelayConnectionState.connecting =>
                                      '正在连接...',
                                    RelayConnectionState.reconnecting =>
                                      '正在重连...',
                                    RelayConnectionState.disconnected =>
                                      '未连接',
                                    _ => '—',
                                  };
                                },
                                orElse: () => '—',
                              ),
                              style: AppText.mono(
                                context,
                                size: AppTextSizes.monoXs,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
            // GLM 用量已下线 (用量见聊天页顶部 UsagePill), 仅保留「通用 · GLM 配置」
                    ],
                  ),
                ),
              ),
            ),

            _sectionLabel(context, 'Agent 能力'),
            _SettingsCard(
              child: Column(
                children: [
                  _SettingsRow(
                    icon: Icons.auto_awesome_outlined,
                    title: '技能',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SkillsPage(
                          onNewSkill: () {
                            Navigator.of(context).popUntil(
                              (r) => r.isFirst || r is! MaterialPageRoute,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  _SettingsRow(
                    icon: Icons.smart_toy_outlined,
                    title: '子智能体',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SubagentsPage()),
                    ),
                  ),
                  _SettingsRow(
                    icon: Icons.dns_outlined,
                    title: 'MCP',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const McpPage()),
                    ),
                  ),
                  _SettingsRow(
                    icon: Icons.terminal_rounded,
                    title: '命令',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CommandsPage()),
                    ),
                  ),
                  _SettingsRow(
                    icon: Icons.webhook_outlined,
                    title: '钩子',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HooksPage()),
                    ),
                  ),
                  _SettingsRow(
                    icon: Icons.extension_outlined,
                    title: '插件',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PluginsPage()),
                    ),
                  ),
                ],
              ),
            ),

            _sectionLabel(context, '通用'),
            _SettingsCard(
              child: Column(
                children: [
                  _SettingsRow(
                    icon: Icons.dark_mode_outlined,
                    title: '主题',
                    value: themeModeLabel(ref.watch(themeModeProvider)),
                    onTap: () => _showThemePicker(context, ref),
                  ),
                  _SettingsRow(
                    icon: Icons.picture_in_picture_alt_rounded,
                    title: '悬浮窗行数',
                    value: '${ref.watch(pipLinesProvider)} 行',
                    onTap: () => _showPipLinesPicker(context, ref),
                  ),
                  // 后台自动打开小窗 (悬浮窗 v2): 切后台且有进行中会话时自动
                  // 弹出; 无悬浮窗权限静默跳过只落日志, 不打扰
                  _SettingsRow(
                    icon: Icons.add_to_home_screen_outlined,
                    title: '后台自动打开小窗',
                    subtitle: '切到其他应用时自动弹出悬浮窗 (需有进行中会话)',
                    trailing: Switch(
                      value: ref.watch(pipAutoOpenProvider),
                      onChanged: (v) => _applyPipAutoOpen(ref, v),
                    ),
                  ),
                  _SettingsRow(
                    icon: Icons.brightness_high_outlined,
                    title: '屏幕常亮',
                    trailing: Switch(
                      value: ref.watch(keepScreenOnProvider),
                      onChanged: (v) => _applyKeepScreenOn(ref, v),
                    ),
                  ),
                  // 任务事件提示音 (对齐桌面端): 完成/AI 提问/权限请求各响一声
                  _SettingsRow(
                    icon: Icons.music_note_outlined,
                    title: '提示音',
                    subtitle: '任务完成/AI 提问/权限请求时响铃',
                    trailing: Switch(
                      value: ref.watch(soundOnProvider),
                      onChanged: (v) => _applySoundOn(ref, v),
                    ),
                  ),
                  _SettingsRow(
                    icon: Icons.settings_remote_rounded,
                    title: '远程设置',
                    onTap: () {
                      final ws =
                          ref.read(workspaceListProvider).valueOrNull ?? [];
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RemoteSettingsScreen(
                            workspacePath: ws.isNotEmpty
                                ? ws.first.workspacePath
                                : '',
                          ),
                        ),
                      );
                    },
                  ),
                  _SettingsRow(
                    icon: Icons.key_outlined,
                    title: 'GLM 配置',
                    value: (ref.watch(glmCredentialProvider)?.isValid ?? false)
                        ? '已配置'
                        : '未配置',
                    onTap: () => _showGlmCredentialEditor(context, ref),
                  ),
                ],
              ),
            ),

            _sectionLabel(context, '关于'),
            _SettingsCard(
              child: Column(
                children: [
                  FutureBuilder<String>(
                    future: UpdateService.localVersion(),
                    builder: (_, snap) => _SettingsRow(
                      icon: Icons.info_outline_rounded,
                      title: '版本',
                      value: 'v${snap.data ?? '…'}',
                    ),
                  ),
                  _SettingsRow(
                    icon: Icons.system_update_alt_rounded,
                    title: '检查更新',
                    onTap: () => _checkUpdate(context),
                  ),
                  _SettingsRow(
                    icon: Icons.code_rounded,
                    title: 'GitHub',
                    onTap: () =>
                        _openUrl('https://github.com/by-yitong/zcode-app'),
                  ),
                  _SettingsRow(
                    icon: Icons.description_outlined,
                    title: '开源协议',
                    value: 'MIT',
                    onTap: () => _showLicenseDialog(context),
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSpacing.xl),
            // 断开连接 — 底部独立操作卡 (对齐截图退出登录: 黑字 logout, 无箭头)
            _SettingsCard(
              child: _SettingsRow(
                icon: Icons.logout,
                title: '断开连接',
                showChevron: false,
                onTap: () => _logout(context, ref),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分组标题 (参考截图: 浅灰斜体小字, 左缘与行内图标对齐, 无大写/无箭头)
  Widget _sectionLabel(BuildContext context, String label) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: dark ? AppColors.darkInkMuted : AppColors.lightInkMuted,
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('确定断开与 ZCode 的连接?已保存的设备不受影响, 可随时重连。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(sessionProvider.notifier).logout();
    }
  }

  /// 打开外部链接 (浏览器 / GitHub app)
  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 无可处理的应用时静默忽略
    }
  }

  /// 手动检查更新 (GitHub Releases)
  Future<void> _checkUpdate(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在检查更新…'), duration: Duration(seconds: 1)),
    );
    final info = await UpdateService.check();
    if (!context.mounted) return;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已是最新版本 v${await UpdateService.localVersion()}'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    await UpdateService.markChecked();
    if (!context.mounted) return;
    final dismissed = await showUpdateDialog(context, info);
    if (dismissed) await UpdateService.dismiss(info.tag);
  }

  /// MIT 开源协议弹窗 (完整协议文本)
  void _showLicenseDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('MIT License'),
        content: SingleChildScrollView(
          child: Text(
            kMitLicenseText,
            style: AppText.mono(
              context,
              size: AppTextSizes.monoSm,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 弹出主题选择器 (深色 / 浅色 / 跟随系统)
  void _showThemePicker(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // ⚠️ 不透明背景, 避免深色主题的半透明 surface 透出底层卡片重叠。
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppColors.darkBg
          : AppColors.lightSurface,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '选择主题',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              for (final entry in const [
                (ThemeMode.dark, '深色', '默认'),
                (ThemeMode.light, '浅色', null),
                (ThemeMode.system, '跟随系统', '随设备设置自动切换'),
              ])
                Consumer(
                  builder: (context, ref, _) {
                    final current = ref.watch(themeModeProvider);
                    final selected = entry.$1 == current;
                    return ListTile(
                      leading: Icon(
                        entry.$1 == ThemeMode.dark
                            ? Icons.dark_mode_outlined
                            : entry.$1 == ThemeMode.light
                            ? Icons.light_mode_outlined
                            : Icons.brightness_auto_outlined,
                      ),
                      title: Text(entry.$2),
                      subtitle: entry.$3 != null ? Text(entry.$3!) : null,
                      trailing: selected
                          ? Icon(
                              Icons.check,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () => _applyTheme(sheetContext, ref, entry.$1),
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 应用主题: 更新 provider 状态 + 持久化到 SharedPreferences, 然后关闭选择器
  Future<void> _applyTheme(
    BuildContext sheetContext,
    WidgetRef ref,
    ThemeMode mode,
  ) async {
    ref.read(themeModeProvider.notifier).state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kThemeModePrefKey, themeModeToString(mode));
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
  }

  /// 弹出悬浮窗行数选择器 (1–10, 交互仿主题选择)
  void _showPipLinesPicker(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // ⚠️ 不透明背景, 避免深色主题的半透明 surface 透出底层卡片重叠。
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppColors.darkBg
          : AppColors.lightSurface,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '悬浮窗行数',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '画中画小窗正文的可视行数, 修改后即时生效',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              // 1–10 选项
              for (var n = pipMinLines; n <= pipMaxLines; n++)
                Consumer(
                  builder: (context, ref, _) {
                    final current = ref.watch(pipLinesProvider);
                    final selected = n == current;
                    return ListTile(
                      leading: const Icon(Icons.picture_in_picture_alt_rounded),
                      title: Text('$n 行'),
                      trailing: selected
                          ? Icon(
                              Icons.check,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () => _applyPipLines(sheetContext, ref, n),
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 应用悬浮窗行数: 更新 provider 状态 + 持久化, 然后关闭选择器。
  /// 悬浮窗开着时由 PipMonitorService 监听 pipLinesProvider 自动
  /// resizeOverlay + 立即重推, 无需在此处理。
  Future<void> _applyPipLines(
    BuildContext sheetContext,
    WidgetRef ref,
    int lines,
  ) async {
    ref.read(pipLinesProvider.notifier).state = lines;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPipLinesPrefKey, lines);
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
  }

  /// 应用屏幕常亮: 更新 provider 状态 + 持久化 + 同步原生
  /// FLAG_KEEP_SCREEN_ON (重启后由 main() 恢复)。
  Future<void> _applyKeepScreenOn(WidgetRef ref, bool enabled) async {
    ref.read(keepScreenOnProvider.notifier).state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kKeepScreenOnPrefKey, enabled);
    await DisplayService.setKeepScreenOn(enabled);
  }

  /// 应用提示音: 更新 provider 状态 + 持久化
  /// (播放侧 NotificationSound 触发时直读同一 key, 关闭即时生效;
  /// 重启后由 initState 回填)。
  Future<void> _applySoundOn(WidgetRef ref, bool enabled) async {
    ref.read(soundOnProvider.notifier).state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kNotificationSoundPrefKey, enabled);
  }

  /// 应用后台自动打开小窗: 更新 provider 状态 + 持久化
  /// (重启后由 main() 恢复; 生效逻辑在 ZcodeApp 生命周期 paused 分支)。
  Future<void> _applyPipAutoOpen(WidgetRef ref, bool enabled) async {
    ref.read(pipAutoOpenProvider.notifier).state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPipAutoOpenPrefKey, enabled);
  }
}

/// 白色分组卡片 (无边框; 深色 darkSurfaceElevated), 圆角 20。
/// 用 Material 而非 Container: 行内 InkWell 的水波纹才能透出。
class _SettingsCard extends StatelessWidget {
  final Widget child;
  const _SettingsCard({required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: dark ? AppColors.darkSurfaceElevated : Colors.white,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 设置行 — 描边图标 + 标题 (+ 可选副标题) + 右侧灰值/自定义尾部/箭头,
/// 单行无分隔线。行高 ~56 (图标 24 + 上下 16), 与参考截图的舒展节奏一致。
class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;

  /// 可选副标题 (标题下方小灰字, 如「后台自动打开小窗」的说明)
  final String? subtitle;
  final String? value;
  final Widget? trailing; // Switch 等, 给定后不再画箭头

  /// null = 跟随 onTap (可点才画); false = 强制不画 (如断开连接)
  final bool? showChevron;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.showChevron,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 16,
        ),
        child: Row(
          children: [
            Icon(icon, size: 24, color: cs.onSurface),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: subtitle == null
                  ? Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
            ),
            if (value != null) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(
                value!,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing!,
            ] else if (onTap != null && (showChevron ?? true)) ...[
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 凭据编辑 BottomSheet (Base URL + API Key)
Future<void> _showGlmCredentialEditor(
  BuildContext context,
  WidgetRef ref,
) async {
  final cred = ref.read(glmCredentialProvider);
  final baseUrlCtrl = TextEditingController(
    text: cred?.baseUrl ?? SecureStorageService.defaultGlmBaseUrl,
  );
  final apiKeyCtrl = TextEditingController(text: cred?.apiKey);
  var obscure = true;

  final theme = Theme.of(context);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '配置 GLM Coding Plan',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'API Key 在智谱开放平台 → API Keys 获取。'
                  '默认走 open.bigmodel.cn, z.ai 国际站可改 Base URL。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: baseUrlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: apiKeyCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.key_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setSheetState(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (cred != null)
                      TextButton(
                        onPressed: () async {
                          await ref
                              .read(glmCredentialProvider.notifier)
                              .clear();
                          await ref.read(glmQuotaProvider.notifier).refresh();
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        child: const Text(
                          '清除',
                          style: TextStyle(color: AppColors.danger),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                    FilledButton(
                      onPressed: () async {
                        await ref
                            .read(glmCredentialProvider.notifier)
                            .save(
                              baseUrl: baseUrlCtrl.text,
                              apiKey: apiKeyCtrl.text,
                            );
                        await ref.read(glmQuotaProvider.notifier).refresh();
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      );
    },
  );
}

/// MIT 协议全文 (与仓库根 LICENSE 一致)
const String kMitLicenseText = '''
MIT License

Copyright (c) 2026 zcode-app contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
''';
