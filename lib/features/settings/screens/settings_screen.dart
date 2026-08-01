import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/relay/relay_protocol.dart';
import '../../../core/services/glm_quota_service.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../data/models/glm_quota.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../../shared/widgets/app_tile_group.dart';
import 'remote_settings_screen.dart';

/// 设置页
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final connectionAsync = ref.watch(relayConnectionStateProvider);

    final user = session.valueOrNull;
    final userName = user?.deviceName ?? '未登录';
    final deviceId = user?.deviceSid ?? '—';

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        children: [
          // 用户卡 — 深色面卡 (拒绝全宽蓝色渐变大卡)
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF8B5CF6), AppColors.accent],
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: const Icon(Icons.person_rounded,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(userName,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              )),
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
                      Icon(Icons.cloud_done_rounded,
                          size: 14,
                          color: connectionAsync.maybeWhen(
                            data: (s) => s == RelayConnectionState.ready
                                ? AppColors.success
                                : AppColors.warning,
                            orElse: () => AppColors.warning,
                          )),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        connectionAsync.maybeWhen(
                          data: (state) {
                            final s = state;
                            return switch (s) {
                              RelayConnectionState.ready => '已连接到 ZCode',
                              RelayConnectionState.connecting => '正在连接...',
                              RelayConnectionState.reconnecting => '正在重连...',
                              RelayConnectionState.disconnected => '未连接',
                              _ => '—',
                            };
                          },
                          orElse: () => '—',
                        ),
                        style: AppText.mono(context,
                            size: AppTextSizes.monoXs,
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                _GlmQuotaInlineSummary(),
              ],
            ),
          ),

          // GLM 用量分区
          const AppSectionHeader(title: 'GLM 用量'),
          _GlmQuotaCard(),

          // 模型与模式
          const AppSectionHeader(title: '模型与模式'),
          const AppTileGroup(tiles: [
            AppTile(
              icon: Icons.swap_horiz_rounded,
              title: '在对话内切换',
              subtitle: '打开任意工作区对话, 输入栏可切换模型 / 确认·自动模式',
            ),
          ]),

          // 外观
          const AppSectionHeader(title: '外观'),
          AppTileGroup(tiles: [
            AppTile(
              icon: Icons.dark_mode_rounded,
              title: '主题',
              value: themeModeLabel(ref.watch(themeModeProvider)),
              showChevron: true,
              onTap: () => _showThemePicker(context, ref),
            ),
          ]),

          // 桌面端设置 (只读查看)
          const AppSectionHeader(title: '桌面端设置'),
          AppTileGroup(tiles: [
            AppTile(
              icon: Icons.settings_remote_rounded,
              title: '远程设置',
              subtitle: '查看 ZCode 桌面端的配置',
              showChevron: true,
              onTap: () {
                final ws = ref.read(workspaceListProvider).valueOrNull ?? [];
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RemoteSettingsScreen(
                    workspacePath: ws.isNotEmpty ? ws.first.workspacePath : '',
                  ),
                ));
              },
            ),
          ]),

          // 关于
          const AppSectionHeader(title: '关于'),
          const AppTileGroup(tiles: [
            AppTile(
              icon: Icons.info_outline_rounded,
              title: '版本',
              value: 'v1.0.0',
            ),
            AppTile(
              icon: Icons.description_outlined,
              title: '开源协议',
              showChevron: true,
            ),
          ]),

          const SizedBox(height: AppSpacing.xl),

          // 登出 — danger 描边, 克制
          Padding(
            padding: EdgeInsets.zero,
            child: OutlinedButton.icon(
              onPressed: () => _logout(context, ref),
              icon: const Icon(Icons.logout_rounded, color: AppColors.danger),
              label: const Text('断开连接',
                  style: TextStyle(color: AppColors.danger)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.dangerContainer),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('确定要断开与 ZCode 的连接吗?需要重新登录。'),
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
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
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
                          ? Icon(Icons.check,
                              color: Theme.of(context).colorScheme.primary)
                          : null,
                      onTap: () =>
                          _applyTheme(sheetContext, ref, entry.$1),
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
}

// ================================================================
// GLM 用量 widgets
// ================================================================

/// 用户卡片内的精简摘要 (一行, mono 字体, 白字)
/// 无数据 (未配置 / 失败 / loading) 时不渲染, 不占位。
class _GlmQuotaInlineSummary extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quotaAsync = ref.watch(glmQuotaProvider);
    final quota = quotaAsync.valueOrNull;
    if (quota == null || !quota.hasData) return const SizedBox.shrink();

    final weekly = quota.weeklyTier;
    final fiveHour = quota.fiveHourTier;
    final parts = <String>[];
    if (weekly != null) parts.add('本周 ${_fmtPct(weekly.utilization)}');
    if (fiveHour != null) parts.add('5h ${_fmtPct(fiveHour.utilization)}');
    if (parts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Text(
        parts.join(' · '),
        style: AppText.mono(context,
            size: AppTextSizes.monoSm,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// GLM 用量分区卡片
class _GlmQuotaCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cred = ref.watch(glmCredentialProvider);
    final quotaAsync = ref.watch(glmQuotaProvider);

    final configured = cred != null && cred.isValid;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行 + 刷新按钮
              Row(
                children: [
                  Icon(Icons.bolt_outlined,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Coding Plan 余量',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (configured)
                    _RefreshButton(
                      loading: quotaAsync.isLoading,
                      onTap: () =>
                          ref.read(glmQuotaProvider.notifier).refresh(),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (!configured)
                _buildNotConfigured(context, ref)
              else
                _buildBody(context, ref, quotaAsync, cred),
            ],
          ),
        ),
    );
  }

  Widget _buildNotConfigured(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        const Expanded(
          child: Text('未配置 GLM API Key', style: TextStyle(fontSize: AppTextSizes.bodySm)),
        ),
        TextButton.icon(
          onPressed: () => _showGlmCredentialEditor(context, ref),
          icon: const Icon(Icons.key_outlined, size: 18),
          label: const Text('配置'),
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<GlmQuota?> quotaAsync,
    GlmCredential cred,
  ) {
    final theme = Theme.of(context);
    return quotaAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (e, _) => _ErrorRow(
        message: '查询失败: $e',
        onEdit: () => _showGlmCredentialEditor(context, ref),
      ),
      data: (quota) {
        if (quota == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('暂无数据', style: TextStyle(fontSize: AppTextSizes.bodySm)),
          );
        }
        if (!quota.success) {
          final expired = quota.credentialStatus == GlmCredentialStatus.expired;
          return _ErrorRow(
            message: quota.error ?? '查询失败',
            hint: expired ? 'API Key 失效, 点此更新' : '点此检查配置',
            onEdit: () => _showGlmCredentialEditor(context, ref),
          );
        }
        // 套餐等级 + 两窗口 tier
        final level = quota.credentialMessage;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (level != null && level.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('套餐: $level',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            for (final tier in quota.tiers) ...[
              _TierRow(tier: tier),
              if (tier != quota.tiers.last) const SizedBox(height: 14),
            ],
            const SizedBox(height: 8),
            // 更新时间 + 编辑入口
            Row(
              children: [
                if (quota.queriedAt != null)
                  Expanded(
                    child: Text(
                      '更新于 ${_fmtTime(quota.queriedAt!)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                else
                  const Spacer(),
                TextButton(
                  onPressed: () => _showGlmCredentialEditor(context, ref),
                  child: const Text('编辑配置'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 单窗口 tier 行 (标签 + 进度条 + 已用% + 重置时间)
class _TierRow extends StatelessWidget {
  final GlmQuotaTier tier;
  const _TierRow({required this.tier});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = tier.name == GlmQuotaTier.fiveHour ? '5 小时窗口' : '每周窗口';
    final color = _utilizationColor(tier.utilization);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500)),
            ),
            Text(
              '${_fmtPct(tier.utilization)}%',
              style: AppText.mono(context,
                  size: 13, weight: FontWeight.w600, color: color),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: LinearProgressIndicator(
            value: (tier.utilization / 100).clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            color: color,
          ),
        ),
        if (tier.resetsAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '重置: ${_fmtRelative(tier.resetsAt!)}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _RefreshButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;
  const _RefreshButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return IconButton(
      onPressed: onTap,
      icon: const Icon(Icons.refresh, size: 20),
      tooltip: '刷新',
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String message;
  final String? hint;
  final VoidCallback onEdit;
  const _ErrorRow({required this.message, this.hint, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message,
                      style: const TextStyle(
                          color: AppColors.danger, fontSize: AppTextSizes.bodySm)),
                  if (hint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(hint!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.warning)),
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 凭据编辑 BottomSheet (Base URL + API Key)
Future<void> _showGlmCredentialEditor(BuildContext context, WidgetRef ref) async {
  final cred = ref.read(glmCredentialProvider);
  final baseUrlCtrl =
      TextEditingController(text: cred?.baseUrl ?? SecureStorageService.defaultGlmBaseUrl);
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
              16, 0, 16,
              16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('配置 GLM Coding Plan',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
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
                      icon: Icon(obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setSheetState(() => obscure = !obscure),
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
                          await ref
                              .read(glmQuotaProvider.notifier)
                              .refresh();
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        child: const Text('清除',
                            style: TextStyle(color: AppColors.danger)),
                      )
                    else
                      const SizedBox.shrink(),
                    FilledButton(
                      onPressed: () async {
                        await ref.read(glmCredentialProvider.notifier).save(
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

// ── 格式化 helpers ──────────────────────────────────────────

String _fmtPct(double v) {
  // 取整数部分, 避免 42.0001% 之类噪声; 负/超 100 原样透传
  final rounded = (v * 10).roundToDouble() / 10;
  if (rounded == rounded.roundToDouble()) {
    return rounded.toInt().toString();
  }
  return rounded.toStringAsFixed(1);
}

String _fmtTime(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}';
}

String _fmtRelative(String iso) {
  try {
    final target = DateTime.parse(iso);
    final diff = target.difference(DateTime.now());
    if (diff.isNegative) return '已重置';
    final h = diff.inHours;
    if (h >= 24) return '${diff.inDays} 天后';
    if (h >= 1) return '$h 小时后';
    return '${diff.inMinutes} 分钟后';
  } catch (_) {
    return iso;
  }
}

Color _utilizationColor(double utilization) {
  if (utilization >= 90) return AppColors.danger;
  if (utilization >= 70) return AppColors.warning;
  return AppColors.accent;
}
