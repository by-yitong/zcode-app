/// 插件市场 — 公开/个人 + 分组导航 + 已安装速览 + 直装 + 底部假搜索 pill
///
/// 数据: pluginsProvider.available (overview 的 availablePlugins, 含 listing
/// 元数据 icon/category/author); overview 空时兜底 getPluginReferenceCatalog。
/// 实时搜索移至 PluginSearchPage, 本页底部为纯展示 pill 入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/logging/app_logger.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../widgets/caps_page_chrome.dart';
import '../widgets/caps_widgets.dart';
import '../widgets/plugin_list_tile.dart';
import 'cap_pages.dart';
import 'plugin_group_page.dart';
import 'plugin_search_page.dart';

class PluginsBrowserPage extends ConsumerStatefulWidget {
  const PluginsBrowserPage({super.key});

  @override
  ConsumerState<PluginsBrowserPage> createState() => _PluginsBrowserPageState();
}

class _PluginsBrowserPageState extends ConsumerState<PluginsBrowserPage> {
  String _segment = 'public'; // public | personal
  bool _fallbackLoaded = false;

  @override
  void initState() {
    super.initState();
    // overview 可能还没拉, 触发一次
    final st = ref.read(pluginsProvider).valueOrNull;
    if (st == null || st.available.isEmpty) {
      ref.read(pluginsProvider.notifier).load();
    }
  }

  /// available 为空时用 catalog 兜底 (无 listing 元数据但有基本字段)
  Future<void> _ensureFallback() async {
    if (_fallbackLoaded) return;
    final st = ref.read(pluginsProvider).valueOrNull;
    if (st != null && st.available.isNotEmpty) return;
    _fallbackLoaded = true;
    try {
      final client = ref.read(relayClientProvider);
      final ws = ref.read(selectedWorkspaceProvider);
      if (client == null || ws == null) return;
      final resp = await client.getPluginReferenceCatalog(
        workspacePath: ws.workspacePath,
        workspaceIdentity: ws.workspaceIdentity,
      );
      final raw = resp['plugins'];
      if (raw is List && raw.isNotEmpty) {
        // 合成 available (provider 状态不动, 本地用 State 存)
        setState(() {
          _catalogFallback = raw
              .whereType<Map>()
              .map((m) => PluginEntry.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        });
      }
    } catch (e) {
      appLog.i('[PluginsBrowser] catalog 兜底失败(忽略): $e');
    }
  }

  List<PluginEntry>? _catalogFallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pluginsAsync = ref.watch(pluginsProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: CapsPageHeader.overlayStyle(context),
      child: Scaffold(
        appBar: const CapsPageHeader(title: '插件市场'),
        body: pluginsAsync.when(
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          error: (e, _) => AppEmptyState(
            icon: Icons.cloud_off_rounded,
            title: '加载失败',
            subtitle: e.toString(),
            iconTint: AppColors.danger,
            actionLabel: '重试',
            onAction: () => ref.read(pluginsProvider.notifier).load(),
          ),
          data: (state) {
            var available = state.available;
            if (available.isEmpty && _catalogFallback != null) {
              available = _catalogFallback!;
            } else if (available.isEmpty && !_fallbackLoaded) {
              _ensureFallback();
            }
            final marketplaces = state.marketplaces;
            // 精选集合 (各市场 featured 汇总)
            final featured = <String>{};
            for (final m in marketplaces) {
              featured.addAll(m.featured);
            }

            // 筛选 (标准与网页端一致):
            //   公开 = zcode 官方市场 (zcode-plugins-official)
            //   个人 = 其余市场 (claude-plugins-official / 自建)
            final list =
                available
                    .where(
                      (p) =>
                          (p.marketplace == kOfficialMarketplace) ==
                          (_segment == 'public'),
                    )
                    .toList()
                  ..sort((a, b) => a.label.compareTo(b.label));

            final installedNames = state.installed
                .map((p) => '${p.marketplace}/${p.name}')
                .toSet();

            return Column(
              children: [
                // 公开 / 个人 (pill chips, 顶部筛选)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      _segChip('公开', 'public'),
                      const SizedBox(width: AppSpacing.sm),
                      _segChip('个人', 'personal'),
                    ],
                  ),
                ),
                Expanded(
                  child: available.isEmpty
                      ? const AppEmptyState(
                          icon: Icons.storefront_outlined,
                          title: '目录为空',
                          subtitle: '先在「插件」页添加插件市场后下拉刷新',
                        )
                      : RefreshIndicator(
                          onRefresh: () async {
                            _fallbackLoaded = false;
                            _catalogFallback = null;
                            await ref.read(pluginsProvider.notifier).load();
                          },
                          child: list.isEmpty
                              ? ListView(
                                  children: [
                                    SizedBox(
                                      height:
                                          MediaQuery.of(context).size.height *
                                          0.4,
                                      child: const AppEmptyState(
                                        icon: Icons.search_off_rounded,
                                        title: '没有匹配的插件',
                                        subtitle: '换个分类或关键词试试',
                                      ),
                                    ),
                                  ],
                                )
                              : ListView(
                                  padding: const EdgeInsets.fromLTRB(
                                    AppSpacing.lg,
                                    0,
                                    AppSpacing.lg,
                                    AppSpacing.xxl,
                                  ),
                                  children: [
                                    ..._installedSection(state, installedNames),
                                    if (_segment == 'public')
                                      ..._publicChildren(
                                        list,
                                        featured,
                                        installedNames,
                                      )
                                    else
                                      ..._personalChildren(
                                        list,
                                        marketplaces,
                                        installedNames,
                                      ),
                                  ],
                                ),
                        ),
                ),
                // 底部假搜索 pill: 点击进搜索页, 不在本页弹键盘
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.sm,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PluginSearchPage(),
                        ),
                      ),
                      child: IgnorePointer(
                        child: TextField(
                          readOnly: true,
                          enableInteractiveSelection: false,
                          showCursor: false,
                          style: theme.textTheme.bodyMedium,
                          decoration: InputDecoration(
                            hintText: '搜索插件…',
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              size: 20,
                              color: cs.onSurfaceVariant,
                            ),
                            isDense: true,
                            filled: true,
                            fillColor: cs.surfaceContainerHigh,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 顶部「已安装」速览: 最多 3 行; 标题始终可点进插件管理页,
  /// 箭头只在 > 3 个时显示 (≤3 时全量已在眼前, 箭头会误导); 0 个隐藏
  List<Widget> _installedSection(
    PluginsState state,
    Set<String> installedNames,
  ) {
    final installed = state.installed;
    if (installed.isEmpty) return const [];
    return [
      CapsSectionHeader(
        '已安装',
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const PluginsPage())),
        showChevron: installed.length > 3,
      ),
      for (final p in installed.take(3))
        PluginListTile(
          plugin: p,
          installedNames: installedNames,
          onTap: () => _openDetail(p),
        ),
      const SizedBox(height: AppSpacing.md),
    ];
  }

  /// 公开段 children: Featured (官方市场 featured 名单) 置顶, 其余按分类分组
  /// (other 最后)。每组标题 > 3 个时可点进分组页, 正文只渲染前 3 个。
  List<Widget> _publicChildren(
    List<PluginEntry> list,
    Set<String> featured,
    Set<String> installedNames,
  ) {
    final featuredVisible = list
        .where((p) => featured.contains(p.name))
        .toList();
    final byCategory = <String, List<PluginEntry>>{};
    for (final p in list) {
      if (featured.contains(p.name)) continue;
      byCategory.putIfAbsent(pluginCategoryOf(p.category), () => []).add(p);
    }
    // other 排最后 (与网页端一致)
    final catKeys = byCategory.keys.toList()
      ..sort((a, b) {
        if (a == 'other') return 1;
        if (b == 'other') return -1;
        return pluginCategoryLabel(a).compareTo(pluginCategoryLabel(b));
      });
    return [
      if (featuredVisible.isNotEmpty) ...[
        CapsSectionHeader(
          'Featured',
          onTap: featuredVisible.length > 3
              ? () => _openGroup('Featured', featuredVisible, installedNames)
              : null,
        ),
        _cards(featuredVisible.take(3), installedNames),
        const SizedBox(height: AppSpacing.md),
      ],
      for (final k in catKeys) ...[
        CapsSectionHeader(
          pluginCategoryLabel(k),
          onTap: byCategory[k]!.length > 3
              ? () => _openGroup(
                  pluginCategoryLabel(k),
                  byCategory[k]!,
                  installedNames,
                )
              : null,
        ),
        _cards(byCategory[k]!.take(3), installedNames),
        const SizedBox(height: AppSpacing.md),
      ],
    ];
  }

  /// 个人段 children: 「推荐」(固定名单顺序) + 按市场分组 (claude-plugins-official
  /// 显示为「Claude Code 插件」, 其余用市场名; 组按标题排序)。同公开段截前 3 个。
  List<Widget> _personalChildren(
    List<PluginEntry> list,
    List<MarketplaceEntry> marketplaces,
    Set<String> installedNames,
  ) {
    final byName = {for (final p in list) p.name.toLowerCase(): p};
    final recommended = <PluginEntry>[];
    for (final name in kRecommendedPlugins) {
      final p = byName[name.toLowerCase()];
      if (p != null && p.marketplace == kClaudeMarketplace) {
        recommended.add(p);
      }
    }
    final rest = list.where((p) => !recommended.contains(p));
    final byMarket = <String, List<PluginEntry>>{};
    for (final p in rest) {
      byMarket.putIfAbsent(p.marketplace, () => []).add(p);
    }
    final marketNames = {for (final m in marketplaces) m.id: m.name};
    String groupTitle(String market) => market == kClaudeMarketplace
        ? 'Claude Code 插件'
        : (marketNames[market]?.isNotEmpty == true
              ? marketNames[market]!
              : market);
    final groups = byMarket.entries.toList()
      ..sort((a, b) => groupTitle(a.key).compareTo(groupTitle(b.key)));
    return [
      if (recommended.isNotEmpty) ...[
        CapsSectionHeader(
          '推荐',
          onTap: recommended.length > 3
              ? () => _openGroup('推荐', recommended, installedNames)
              : null,
        ),
        _cards(recommended.take(3), installedNames),
        const SizedBox(height: AppSpacing.md),
      ],
      for (final g in groups) ...[
        CapsSectionHeader(
          groupTitle(g.key),
          onTap: g.value.length > 3
              ? () => _openGroup(groupTitle(g.key), g.value, installedNames)
              : null,
        ),
        _cards(g.value.take(3), installedNames),
        const SizedBox(height: AppSpacing.md),
      ],
    ];
  }

  /// 分组标题 → 分组全量列表页
  void _openGroup(
    String title,
    List<PluginEntry> plugins,
    Set<String> installedNames,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PluginGroupPage(
          title: title,
          plugins: plugins,
          installedNames: installedNames,
        ),
      ),
    );
  }

  /// 公开/个人切换 chip (左对齐紧凑 pill, 选中 accent 底白字)
  Widget _segChip(String label, String value) {
    final selected = _segment == value;
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() => _segment = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTextSizes.bodySm,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _cards(Iterable<PluginEntry> plugins, Set<String> installedNames) {
    return Column(
      children: [
        for (final p in plugins)
          PluginListTile(
            plugin: p,
            installedNames: installedNames,
            onTap: () => _openDetail(p),
            onInstall: _install,
          ),
      ],
    );
  }

  void _openDetail(PluginEntry p) {
    capsSheet(context, child: PluginDetailSheet(plugin: p));
  }

  Future<void> _install(PluginEntry p) async {
    try {
      await ref.read(pluginsProvider.notifier).install(p);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已安装 ${p.label}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      appLog.w('[PluginsBrowser] 安装失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('安装失败: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

/// 插件详情: 图标 + 作者/分类/主页 + 组件清单 + 安装
///
/// 市场页 / 分组页 / 搜索页共用 (公开类)。
class PluginDetailSheet extends ConsumerStatefulWidget {
  final PluginEntry plugin;
  const PluginDetailSheet({super.key, required this.plugin});

  @override
  ConsumerState<PluginDetailSheet> createState() => _PluginDetailSheetState();
}

class _PluginDetailSheetState extends ConsumerState<PluginDetailSheet> {
  bool _installing = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = widget.plugin;

    return Padding(
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
              PluginIconBox(icon: p.icon, name: p.label, size: 48),
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
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        if (p.category != null)
                          CapsBadge(pluginCategoryLabel(p.category)),
                        if (p.author != null && p.author!.isNotEmpty)
                          CapsBadge(p.author!),
                      ],
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
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
          if (p.componentTypes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              '包含组件',
              style: TextStyle(
                fontSize: AppTextSizes.label,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
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
          if (p.homepage != null && p.homepage!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            GestureDetector(
              onTap: () {
                final uri = Uri.tryParse(p.homepage!);
                if (uri != null) {
                  launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: Row(
                children: [
                  const Icon(
                    Icons.open_in_new_rounded,
                    size: 16,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: AppSpacing.xs + 2),
                  Expanded(
                    child: Text(
                      p.homepage!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppTextSizes.bodySm,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: p.installed || _installing ? null : _install,
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
              icon: _installing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      p.installed
                          ? Icons.check_rounded
                          : Icons.download_rounded,
                      size: 18,
                    ),
              label: Text(p.installed ? '已安装' : (_installing ? '安装中…' : '安装')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    try {
      await ref.read(pluginsProvider.notifier).install(widget.plugin);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      appLog.w('[PluginsBrowser] 安装失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('安装失败: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }
}
