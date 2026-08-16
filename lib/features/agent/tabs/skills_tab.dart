/// 技能 Tab — 搜索/筛选/分组 + 详情弹窗 + 启停/删除/导入
///
/// 对齐网页端设置页 (分组: 工作区与个人技能 / Plugin 技能;
/// 新建技能 = 跳到对话让 skill-creator 引导创建)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/widgets/app_section_header.dart';
import '../../../../shared/widgets/app_tile_group.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../widgets/caps_widgets.dart';
import '../widgets/import_sheet.dart';

class SkillsTab extends ConsumerStatefulWidget {
  const SkillsTab({super.key});

  @override
  ConsumerState<SkillsTab> createState() => SkillsTabState();
}

class SkillsTabState extends ConsumerState<SkillsTab>
    with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  String _query = '';
  String? _filter; // null | enabled | disabled

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final skills = ref.watch(skillsCapsProvider);

    return CapsAsyncView(
      value: skills,
      onRetry: () => ref.read(skillsCapsProvider.notifier).load(),
      emptyIcon: Icons.auto_awesome_outlined,
      emptyTitle: '暂无可用技能',
      emptySubtitle: '在 ZCode 桌面端安装技能后\n点击右上角刷新即可查看',
      header: CapsFilterBar(
        searchController: _search,
        onSearch: (v) => setState(() => _query = v),
        filter: _filter,
        onFilter: (v) => setState(() => _filter = v),
      ),
      builder: (list) {
        final filtered = _applyFilter(list);
        final local = filtered.where((s) => !s.isPlugin).toList();
        final plugin = filtered.where((s) => s.isPlugin).toList();
        final enabledCount = filtered.where((s) => s.enabled).length;
        return RefreshIndicator(
          onRefresh: () => ref.read(skillsCapsProvider.notifier).load(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Text(
                  '共 ${filtered.length} 个技能 · $enabledCount 个已启用',
                  style: TextStyle(
                      fontSize: AppTextSizes.caption, color: cs.onSurfaceVariant),
                ),
              ),
              if (local.isNotEmpty) ...[
                const AppSectionHeader(title: '工作区与个人技能'),
                AppTileGroup(
                  tiles: [
                    for (final s in local)
                      AppTile(
                        icon: Icons.auto_awesome_outlined,
                        iconTint: s.enabled ? AppColors.accent : cs.onSurfaceVariant,
                        title: s.name,
                        subtitle:
                            s.description.isNotEmpty ? s.description : null,
                        subtitleMaxLines: 2,
                        showChevron: true,
                        onTap: () => _openDetail(context, s),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CapsBadge(
                                s.scope == 'workspace' ? '工作区' : '个人'),
                            const SizedBox(width: AppSpacing.sm),
                            CapsSwitch(
                              value: s.enabled,
                              onChanged: (v) => _toggle(s, v),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              if (plugin.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                const AppSectionHeader(title: 'Plugin 技能'),
                AppTileGroup(
                  tiles: [
                    for (final s in plugin)
                      AppTile(
                        icon: Icons.extension_outlined,
                        iconTint: s.enabled ? AppColors.accent : cs.onSurfaceVariant,
                        title: s.name,
                        subtitle:
                            s.description.isNotEmpty ? s.description : null,
                        subtitleMaxLines: 2,
                        showChevron: true,
                        onTap: () => _openDetail(context, s),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CapsBadge('插件'),
                            const SizedBox(width: AppSpacing.sm),
                            CapsSwitch(
                              value: s.enabled,
                              onChanged: (v) => _toggle(s, v),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 从外部 Agent 导入 (页面右上角入口)
  void openImport() {
    capsSheet(
      context,
      child: ImportSheet(
        category: 'skills',
        onImported: () => ref.read(skillsCapsProvider.notifier).load(),
      ),
    );
  }

  List<SkillEntry> _applyFilter(List<SkillEntry> list) {
    final q = _query.trim().toLowerCase();
    var out = list;
    if (q.isNotEmpty) {
      out = out
          .where((s) =>
              s.name.toLowerCase().contains(q) ||
              s.description.toLowerCase().contains(q))
          .toList();
    }
    if (_filter == 'enabled') {
      out = out.where((s) => s.enabled).toList();
    } else if (_filter == 'disabled') {
      out = out.where((s) => !s.enabled).toList();
    }
    return out;
  }

  void _openDetail(BuildContext context, SkillEntry skill) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    capsSheet(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(skill.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                CapsBadge(skill.scopeLabel),
              ],
            ),
            if (skill.description.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text(skill.description,
                  style: TextStyle(
                      fontSize: AppTextSizes.bodySm,
                      color: cs.onSurfaceVariant)),
            ],
            const SizedBox(height: AppSpacing.md),
            // 启停
            _actionRow(
              theme,
              icon: Icons.power_settings_new_rounded,
              label: skill.enabled ? '已启用' : '已禁用',
              trailing: CapsSwitch(
                value: skill.enabled,
                onChanged: (v) => _toggle(skill, v),
              ),
            ),
            if (!skill.isPlugin) ...[
              const Divider(height: 1),
              if (skill.scope == 'workspace')
                _actionTile(theme, Icons.copy_rounded, '复制到通用目录', () async {
                  Navigator.pop(context);
                  await _run('已复制到通用技能目录',
                      () => ref.read(skillsCapsProvider.notifier).copyToCommon(skill));
                }),
              if (skill.scope != 'workspace' && skill.path != null)
                _actionTile(theme, Icons.folder_off_outlined, '从通用目录移除', () async {
                  Navigator.pop(context);
                  await _run('已从通用技能移除', () => ref
                      .read(skillsCapsProvider.notifier)
                      .removeFromCommon(skill));
                }),
              const Divider(height: 1),
              _actionTile(theme, Icons.delete_outline_rounded, '删除技能',
                  () async {
                Navigator.pop(context);
                final ok = await capsConfirm(context,
                    title: '删除技能',
                    message: '确定删除「${skill.name}」？将从磁盘移除该技能目录，且无法撤销。');
                if (!ok) return;
                await _run('已删除', () => ref.read(skillsCapsProvider.notifier).delete(skill));
              }, AppColors.danger),
            ] else ...[
              const Divider(height: 1),
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 16, color: cs.onSurfaceVariant),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '插件提供的技能不可单独删除，请卸载对应插件。',
                        style: TextStyle(
                            fontSize: AppTextSizes.bodySm,
                            color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (skill.body.trim().isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    skill.body,
                    style: AppText.mono(context,
                        size: AppTextSizes.monoSm, color: cs.onSurface),
                  ),
                ),
              ),
            ],
            if (skill.path != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(skill.path!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono(context,
                      size: AppTextSizes.monoXs,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actionRow(ThemeData theme,
      {required IconData icon, required String label, required Widget trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.md),
          Expanded(
              child: Text(label, style: theme.textTheme.bodyMedium)),
          trailing,
        ],
      ),
    );
  }

  Widget _actionTile(ThemeData theme, IconData icon, String label,
      VoidCallback onTap, [Color? color]) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
        child: Row(
          children: [
            Icon(icon,
                size: 20,
                color: color ?? theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: color)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggle(SkillEntry skill, bool v) async {
    final n = ref.read(skillsCapsProvider.notifier);
    try {
      await n.setEnabled(skill, v);
    } catch (e) {
      appLog.w('[SkillsTab] 启停失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('操作失败: $e'),
            behavior: SnackBarBehavior.floating));
      }
    }
  }

  Future<void> _run(String okMsg, Future<void> Function() action) async {
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(okMsg), behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      appLog.w('[SkillsTab] 操作失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('操作失败: $e'),
            behavior: SnackBarBehavior.floating));
      }
    }
  }
}
