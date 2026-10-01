/// 插件 Tab — 分类 (插件/MCP/技能) + 范围 (用户/工作区) + 已安装管理 + 插件市场
///
/// 对齐网页端「插件」设置页: 三个分类 tab (命令 tab 本次不做), 用户/工作区
/// scope 过滤; MCP 分「插件提供」与「已安装 (手动配置)」两组; 技能 tab 只列
/// 插件技能 (跟随插件自身, 不受 scope 影响)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/widgets/app_empty_state.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../screens/cap_pages.dart';
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

  /// 分类 tab: plugins | mcp | skills (命令 tab 本次不做)
  String _tab = 'plugins';

  /// 范围: user | workspace
  String _scope = 'user';

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
        return Column(
          children: [
            // 分类 tab: 插件 / MCP / 技能
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                0,
              ),
              child: Row(
                children: [
                  _tabChip('插件', 'plugins'),
                  const SizedBox(width: AppSpacing.sm),
                  _tabChip('MCP', 'mcp'),
                  const SizedBox(width: AppSpacing.sm),
                  _tabChip('技能', 'skills'),
                ],
              ),
            ),
            // 范围: 用户 / 工作区
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                6,
                AppSpacing.lg,
                0,
              ),
              child: Row(
                children: [
                  _scopeChip('用户', 'user'),
                  const SizedBox(width: AppSpacing.sm),
                  _scopeChip('工作区', 'workspace'),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refreshAll,
                child: switch (_tab) {
                  'mcp' => _buildMcpTab(context),
                  'skills' => _buildSkillsTab(context),
                  _ => _buildPluginsTab(context, cs, data),
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // ================================================================
  // 分类 / 范围 chips
  // ================================================================

  /// 分类 chip (选中 accent 底白字, 未选中 surfaceContainerHigh 底)
  Widget _tabChip(String label, String value) {
    return _pill(
      label,
      selected: _tab == value,
      small: false,
      onTap: () => setState(() => _tab = value),
    );
  }

  /// 范围 chip (同款小号)
  Widget _scopeChip(String label, String value) {
    return _pill(
      label,
      selected: _scope == value,
      small: true,
      onTap: () => setState(() => _scope = value),
    );
  }

  /// 紧凑左对齐 pill
  Widget _pill(
    String label, {
    required bool selected,
    required bool small,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppDur.fast,
        padding: EdgeInsets.symmetric(
          horizontal: small ? AppSpacing.sm + 2 : AppSpacing.md,
          vertical: small ? 3 : 6,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: small ? AppTextSizes.caption : AppTextSizes.bodySm,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? Colors.white : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  // ================================================================
  // 下拉刷新 / 异步辅助态
  // ================================================================

  /// 下拉刷新: 三个域全刷 (最简单, 切 tab 数据也保新)
  Future<void> _refreshAll() async {
    await Future.wait([
      ref.read(pluginsProvider.notifier).load(),
      ref.read(mcpProvider.notifier).load(),
      ref.read(skillsCapsProvider.notifier).load(),
    ]);
  }

  Widget _loadingView() =>
      const Center(child: CircularProgressIndicator(strokeWidth: 2.5));

  Widget _errorView(Object e, Future<void> Function() retry) => ListView(
    children: [
      SizedBox(
        height: MediaQuery.of(context).size.height * 0.4,
        child: AppEmptyState(
          icon: Icons.cloud_off_rounded,
          title: '加载失败',
          subtitle: e.toString(),
          iconTint: AppColors.danger,
          actionLabel: '重试',
          actionIcon: Icons.refresh_rounded,
          onAction: () => retry(),
        ),
      ),
    ],
  );

  // ================================================================
  // 插件 tab
  // ================================================================

  /// 插件 tab: 当前范围已装插件行列表 + 尾部插件市场管理区 (仅插件 tab 显示)
  Widget _buildPluginsTab(
    BuildContext context,
    ColorScheme cs,
    PluginsState data,
  ) {
    // 已装插件图标兜底: 从 availablePlugins 的 listing 里找
    final iconOf = <String, String?>{};
    for (final a in data.available) {
      iconOf['${a.marketplace}/${a.name}'] = a.icon;
    }
    final installed = [
      for (final p in data.installed)
        if (p.scope == _scope) p,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      children: [
        if (installed.isEmpty)
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.4,
            child: const AppEmptyState(
              icon: Icons.extension_outlined,
              title: '当前范围尚未安装插件',
              subtitle: '去插件市场逛逛',
            ),
          )
        else
          // 行列表 (对齐网页端): 图标 + 名称/版本 + 启停开关, 点击弹详情
          for (final p in installed)
            CapsPlainTile(
              leading: PluginIconBox(
                icon: iconOf['${p.marketplace}/${p.name}'],
                name: p.label,
                size: 44,
              ),
              title: p.label,
              subtitle: p.hasUpdate
                  ? '有更新 · v${p.latestVersion ?? '?'}'
                  : (p.version?.isNotEmpty == true ? 'v${p.version}' : null),
              trailing: CapsSwitch(
                value: p.enabled,
                onChanged: (v) => _run(
                  () => ref.read(pluginsProvider.notifier).setEnabled(p, v),
                ),
              ),
              onTap: () => _pluginActions(context, p),
            ),
        // 插件市场管理区 (全局数据, 视觉跟在插件列表尾部)
        const CapsSectionHeader('插件市场'),
        for (final m in data.marketplaces) _marketRow(cs, m),
        // 添加市场入口行
        CapsPlainTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: const Icon(
              Icons.add_rounded,
              size: 20,
              color: AppColors.accent,
            ),
          ),
          title: '添加插件市场',
          onTap: _addMarketSheet,
        ),
      ],
    );
  }

  // ================================================================
  // MCP tab
  // ================================================================

  /// MCP tab: 「插件」(插件提供) + 「已安装」(手动配置) 两组, 均按 scope 过滤
  Widget _buildMcpTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ref
        .watch(mcpProvider)
        .when(
          loading: _loadingView,
          error: (e, _) =>
              _errorView(e, () => ref.read(mcpProvider.notifier).load()),
          data: (data) {
            final fromPlugin = [
              for (final m in data.servers)
                if (m.scope == _scope && m.source != 'zcodeagentmcp') m,
            ];
            final manual = [
              for (final m in data.servers)
                if (m.scope == _scope && m.source == 'zcodeagentmcp') m,
            ];
            if (fromPlugin.isEmpty && manual.isEmpty) {
              return ListView(
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.4,
                    child: const AppEmptyState(
                      icon: Icons.dns_outlined,
                      title: '尚未安装 MCP 服务器',
                      subtitle: '插件提供的 MCP 会出现在这里',
                    ),
                  ),
                ],
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xxl,
              ),
              children: [
                if (fromPlugin.isNotEmpty) ...[
                  const CapsSectionHeader('插件'),
                  // 网页端同款说明 (settings.plugin.mcp.pluginsDescription)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, AppSpacing.sm),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '这些 MCP 来自已安装的插件',
                        style: TextStyle(
                          fontSize: AppTextSizes.caption,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  for (final m in fromPlugin)
                    _mcpRow(context, cs, m, data, fromPlugin: true),
                ],
                if (manual.isNotEmpty) ...[
                  const CapsSectionHeader('已安装'),
                  for (final m in manual) _mcpRow(context, cs, m, data),
                ],
              ],
            );
          },
        );
  }

  /// MCP 行: 不放假开关 (插件 MCP 配置跟随插件管理), 点击进 MCP 服务器页
  Widget _mcpRow(
    BuildContext context,
    ColorScheme cs,
    McpServerEntry m,
    McpState data, {
    bool fromPlugin = false,
  }) {
    return CapsPlainTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Icon(
          fromPlugin ? Icons.extension_outlined : Icons.dns_outlined,
          size: 20,
          color: cs.onSurfaceVariant,
        ),
      ),
      title: m.name,
      subtitle: m.endpointLabel.isNotEmpty
          ? m.endpointLabel
          : (m.scope == 'workspace' ? '工作区' : '用户'),
      trailing: _statusDot(cs, data.statuses[m.name]),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const McpPage())),
    );
  }

  /// MCP 运行状态: 圆点 + 文字 (需 OAuth 处理 > 已连接 > 未连接)
  Widget _statusDot(ColorScheme cs, McpServerStatus? status) {
    final Color color;
    final String label;
    if (status != null && (status.authorizationUrl?.isNotEmpty ?? false)) {
      color = AppColors.warning;
      label = '需要处理';
    } else if (status?.isConnected ?? false) {
      color = AppColors.success;
      label = '已连接';
    } else {
      color = cs.onSurfaceVariant;
      label = '未连接';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: AppTextSizes.caption,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  // ================================================================
  // 技能 tab
  // ================================================================

  /// 技能 tab: 仅插件提供的技能 (跟随插件自身, 不受 scope 影响)
  Widget _buildSkillsTab(BuildContext context) {
    return ref
        .watch(skillsCapsProvider)
        .when(
          loading: _loadingView,
          error: (e, _) =>
              _errorView(e, () => ref.read(skillsCapsProvider.notifier).load()),
          data: (list) {
            final pluginSkills = [
              for (final s in list)
                if (s.isPlugin) s,
            ];
            if (pluginSkills.isEmpty) {
              return ListView(
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.4,
                    child: const AppEmptyState(
                      icon: Icons.auto_awesome_outlined,
                      title: '尚未安装技能',
                      subtitle: '启用的插件所提供的技能会出现在这里',
                    ),
                  ),
                ],
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xxl,
              ),
              children: [
                for (final s in pluginSkills)
                  CapsPlainTile(
                    leading: PluginIconBox(icon: null, name: s.name, size: 44),
                    title: s.name,
                    subtitle: s.description.isNotEmpty
                        ? s.description
                        : '插件提供的技能',
                    trailing: CapsSwitch(
                      value: s.enabled,
                      onChanged: (v) => _run(
                        () => ref
                            .read(skillsCapsProvider.notifier)
                            .setEnabled(s, v),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
  }

  // ================================================================
  // 插件市场 / 详情弹窗 (原有逻辑保留)
  // ================================================================

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
          borderRadius: BorderRadius.circular(AppRadius.md),
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
              leading: const Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: AppColors.danger,
              ),
              title: const Text(
                '卸载',
                style: TextStyle(color: AppColors.danger),
              ),
              subtitle: Text(
                '其提供的技能/命令将一并移除',
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _uninstallConfirm(context, p);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 卸载二级确认 sheet: 可选同时清除插件缓存, 危险按钮执行
  void _uninstallConfirm(BuildContext context, PluginEntry p) {
    final theme = Theme.of(context);
    var removeCache = false;
    capsSheet(
      context,
      child: StatefulBuilder(
        builder: (context, setSheetState) => Padding(
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
              Text(
                '卸载插件',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.xs + 2),
              Text(
                '其提供的技能/命令将一并移除',
                style: TextStyle(
                  fontSize: AppTextSizes.bodySm,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _sheetActionRow(
                theme,
                icon: Icons.delete_sweep_rounded,
                label: '卸载后同时清除插件缓存',
                trailing: CapsSwitch(
                  value: removeCache,
                  onChanged: (v) => setSheetState(() => removeCache = v),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _run(
                      () => ref
                          .read(pluginsProvider.notifier)
                          .uninstall(p, removeCache: removeCache),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('卸载'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 添加插件市场 sheet: source 输入 + 取消/添加
  void _addMarketSheet() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final controller = TextEditingController();
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
            Text(
              '添加插件市场',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              autofocus: true,
              style: theme.textTheme.bodyMedium,
              cursorColor: AppColors.accent,
              decoration: InputDecoration(
                hintText: '市场 source(GitHub 仓库 或 .json/.yaml 地址)',
                hintStyle: TextStyle(
                  fontSize: AppTextSizes.bodySm,
                  color: cs.onSurfaceVariant,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm + 2,
                ),
                filled: true,
                fillColor: cs.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: cs.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: AppColors.accent.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _submitMarket(controller),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                    ),
                    child: const Text('添加'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _submitMarket(TextEditingController controller) async {
    final source = controller.text.trim();
    if (source.isEmpty) {
      _snack('请输入市场 source');
      return;
    }
    Navigator.pop(context);
    try {
      // addMarketplace 内部成功后自带 load() 刷新
      await ref.read(pluginsProvider.notifier).addMarketplace(source);
      _snack('已添加市场');
    } catch (e) {
      appLog.w('[PluginsTab] 添加市场失败: $e');
      _snack('添加失败: $e');
    }
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
              leading: const Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: AppColors.danger,
              ),
              title: const Text(
                '移除市场',
                style: TextStyle(color: AppColors.danger),
              ),
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
