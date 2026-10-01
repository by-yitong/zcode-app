/// 插件 Tab — 已安装 (图标/组件/启停/更新) + 插件市场管理
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../screens/plugins_browser_page.dart';
import '../widgets/caps_page_chrome.dart';
import '../widgets/caps_widgets.dart';

class PluginsTab extends ConsumerStatefulWidget {
  const PluginsTab({super.key});

  @override
  ConsumerState<PluginsTab> createState() => PluginsTabState();
}

class PluginsTabState extends ConsumerState<PluginsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final plugins = ref.watch(pluginsProvider);

    return CapsAsyncView(
      value: plugins,
      onRetry: () => ref.read(pluginsProvider.notifier).load(),
      emptyIcon: Icons.extension_outlined,
      emptyTitle: '暂无插件',
      emptySubtitle: '点击右上角商店图标, 从插件市场安装',
      builder: (data) {
        // 已装插件图标兜底: 从 availablePlugins 的 listing 里找
        final iconOf = <String, String?>{};
        for (final a in data.available) {
          iconOf['${a.marketplace}/${a.name}'] = a.icon;
        }
        final installed = data.installed;
        return RefreshIndicator(
          onRefresh: () => ref.read(pluginsProvider.notifier).load(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            children: [
              const CapsSectionHeader('已安装'),
              if (installed.isNotEmpty)
                // 横向一排大图标 (无文字标签), 点击弹详情
                SizedBox(
                  height: 64,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < installed.length; i++)
                          Padding(
                            padding: EdgeInsets.only(
                              right: i == installed.length - 1 ? 0 : 16,
                            ),
                            child: _installedIcon(
                              installed[i],
                              iconOf['${installed[i].marketplace}/${installed[i].name}'],
                            ),
                          ),
                      ],
                    ),
                  ),
                )
              else
                CapsPlainTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.storefront_outlined,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  title: '暂无插件,点右上角商店逛逛市场',
                ),
              const CapsSectionHeader('插件市场'),
              for (final m in data.marketplaces) _marketRow(cs, m),
            ],
          ),
        );
      },
    );
  }

  /// 已装插件横向图标 (64px 圆角方块), 点击弹详情
  Widget _installedIcon(PluginEntry p, String? icon) {
    return GestureDetector(
      onTap: () => _pluginActions(context, p),
      child: PluginIconBox(icon: icon, name: p.label, size: 64),
    );
  }

  /// 市场行 (无边框极简)
  Widget _marketRow(ColorScheme cs, MarketplaceEntry m) {
    return CapsPlainTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: m.isOfficial
              ? AppColors.accentContainer
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          m.isOfficial ? Icons.verified_outlined : Icons.storefront_outlined,
          size: 20,
          color: m.isOfficial ? AppColors.accent : cs.onSurfaceVariant,
        ),
      ),
      title: m.name,
      subtitle: '${m.pluginCount} 个插件${m.isOfficial ? ' · 官方' : ''}',
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: cs.onSurfaceVariant,
      ),
      onTap: () => _marketActions(context, m),
    );
  }

  void _pluginActions(BuildContext context, PluginEntry p) {
    final theme = Theme.of(context);
    var enabled = p.enabled; // sheet 不随 provider 自动 rebuild, 局部维护视觉态
    capsSheet(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                PluginIconBox(icon: p.icon, name: p.label, size: 40),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (p.version != null && p.version!.isNotEmpty)
                        Text(
                          'v${p.version}${p.hasUpdate ? ' → v${p.latestVersion ?? '?'}' : ''}',
                          style: AppText.mono(
                            context,
                            size: AppTextSizes.monoXs,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (p.description.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                p.description,
                style: TextStyle(
                  fontSize: AppTextSizes.bodySm,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (p.componentTypes.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final c in p.componentTypes)
                    CapsBadge(pluginComponentLabel(c)),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            // 启停 (原列表行开关移入详情弹窗)
            StatefulBuilder(
              builder: (context, setSheetState) => _sheetActionRow(
                theme,
                icon: Icons.power_settings_new_rounded,
                label: '启用插件',
                trailing: CapsSwitch(
                  value: enabled,
                  onChanged: (v) {
                    setSheetState(() => enabled = v);
                    _run(
                      () => ref.read(pluginsProvider.notifier).setEnabled(p, v),
                    );
                  },
                ),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.refresh_rounded, size: 20),
              title: Text(
                p.hasUpdate ? '更新 (v${p.latestVersion ?? '?'})' : '检查更新并刷新',
              ),
              onTap: () {
                Navigator.pop(context);
                _run(() => ref.read(pluginsProvider.notifier).update(p));
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: AppColors.danger,
              ),
              title: Text('卸载', style: TextStyle(color: AppColors.danger)),
              subtitle: Text(
                '其提供的技能/命令将一并移除',
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              onTap: () async {
                Navigator.pop(context);
                final ok = await capsConfirm(
                  context,
                  title: '卸载插件',
                  message: '确定卸载「${p.label}」？其提供的技能/命令将一并移除。',
                  confirmLabel: '卸载',
                );
                if (!ok) return;
                _run(() => ref.read(pluginsProvider.notifier).uninstall(p));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 弹窗内动作行 (图标 + 标签 + 尾部控件), 与 skills 详情弹窗同风格
  Widget _sheetActionRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          trailing,
        ],
      ),
    );
  }

  void _marketActions(BuildContext context, MarketplaceEntry m) {
    capsSheet(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.refresh_rounded, size: 20),
              title: const Text('更新市场目录'),
              onTap: () {
                Navigator.pop(context);
                _run(
                  () => ref.read(pluginsProvider.notifier).updateMarketplace(m),
                );
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: AppColors.danger,
              ),
              title: Text('移除市场', style: TextStyle(color: AppColors.danger)),
              onTap: () async {
                Navigator.pop(context);
                final ok = await capsConfirm(
                  context,
                  title: '移除插件市场',
                  message: '确定移除「${m.name}」？',
                );
                if (!ok) return;
                _run(
                  () => ref.read(pluginsProvider.notifier).removeMarketplace(m),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 打开插件市场浏览页 (页面右上角入口)
  void openMarketplace() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const PluginsBrowserPage()));
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      appLog.w('[PluginsTab] 操作失败: $e');
      _snack('操作失败: $e');
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
    }
  }
}
