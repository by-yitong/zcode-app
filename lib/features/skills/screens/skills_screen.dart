import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../../shared/widgets/app_section_header.dart';

/// 技能管理页 — 从 RPC skill.list 加载, 展示技能列表 + 开关
class SkillsScreen extends ConsumerStatefulWidget {
  const SkillsScreen({super.key});

  @override
  ConsumerState<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends ConsumerState<SkillsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skillsAsync = ref.watch(skillsProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.primary,
                          theme.colorScheme.primary.withValues(alpha: 0.6),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Icon(Icons.auto_awesome,
                        size: 22, color: Colors.white),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('技能中心',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text('管理可用的 AI 编码技能',
                            style: TextStyle(
                                fontSize: AppTextSizes.bodySm,
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  // 手动刷新
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: '刷新',
                    onPressed: () => ref.read(skillsProvider.notifier).refresh(),
                  ),
                ],
              ),
            ),
            // 列表 (支持下拉刷新)
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => ref.read(skillsProvider.notifier).refresh(),
                child: skillsAsync.when(
                  loading: () => _buildLoading(theme),
                  error: (error, _) => _buildError(theme, error.toString()),
                  data: (skills) {
                    if (skills.isEmpty) {
                      return AppEmptyState(
                        icon: Icons.auto_awesome_outlined,
                        title: '暂无可用技能',
                        subtitle: '在 ZCode 桌面端安装技能后\n下拉刷新即可查看',
                      );
                    }
                    return _buildSkillsList(theme, skills);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 状态视图 ──

  Widget _buildLoading(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: 6,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: _ShimmerCard(theme: theme),
        );
      },
    );
  }

  Widget _buildError(ThemeData theme, String error) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 80),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadius.xl),
                  ),
                  child: Icon(Icons.cloud_off_outlined,
                      size: 32, color: theme.colorScheme.outline),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text('技能列表加载失败',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '请确认设备已连接到 ZCode 桌面端',
                  style: TextStyle(
                      fontSize: AppTextSizes.bodySm, color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: () => ref.read(skillsProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 技能列表 ──

  Widget _buildSkillsList(ThemeData theme, List<SkillItem> skills) {
    // 按启用状态分组: 启用的在上, 禁用的在下
    final enabled = skills.where((s) => s.enabled).toList();
    final disabled = skills.where((s) => !s.enabled).toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xl),
      children: [
        if (enabled.isNotEmpty) ...[
          AppSectionHeader(title: '已启用'),
          const SizedBox(height: AppSpacing.sm),
          _skillGroup(theme, enabled),
        ],
        if (disabled.isNotEmpty) ...[
          if (enabled.isNotEmpty) const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(title: '已禁用'),
          const SizedBox(height: AppSpacing.sm),
          _skillGroup(theme, disabled),
        ],
      ],
    );
  }

  Widget _skillGroup(ThemeData theme, List<SkillItem> skills) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < skills.length; i++) ...[
            _SkillTile(
              skill: skills[i],
              theme: theme,
              onToggle: (value) => _toggleSkill(skills[i], value),
            ),
            if (i < skills.length - 1)
              Divider(
                height: 1,
                indent: AppSpacing.lg,
                endIndent: 0,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
          ],
        ],
      ),
    );
  }

  /// 切换技能启用状态 (乐观更新 + RPC)
  void _toggleSkill(SkillItem skill, bool value) async {
    final client = ref.read(relayClientProvider);
    final workspaces = ref.read(workspaceListProvider).valueOrNull;
    if (client == null || workspaces == null || workspaces.isEmpty) return;

    final ws = workspaces.first;
    try {
      await client.setSkillEnabled(
        workspacePath: ws.workspacePath,
        workspaceIdentity: ws.workspaceIdentity,
        skillId: skill.id ?? skill.name,
        enabled: value,
        scope: skill.scope,
      );
    } catch (e) {
      // RPC 失败也刷新列表 (服务器状态为准)
      appLog.w('[Skills] ${value ? '启用' : '禁用'}技能 "${skill.name}" 失败: $e');
    }
    ref.read(skillsProvider.notifier).refresh();
  }
}

// ── 子组件 ──

class _SkillTile extends StatelessWidget {
  final SkillItem skill;
  final ThemeData theme;
  final ValueChanged<bool> onToggle;

  const _SkillTile({
    required this.skill,
    required this.theme,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          // 技能图标
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: skill.enabled
                  ? AppColors.accentContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              Icons.extension_outlined,
              size: 20,
              color: skill.enabled
                  ? AppColors.accent
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // 名称 + 描述
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  skill.name,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: skill.enabled
                        ? null
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (skill.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    skill.description,
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 开关
          Transform.scale(
            scale: 0.85,
            child: Switch(
              value: skill.enabled,
              onChanged: onToggle,
              activeColor: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }
}

/// 加载骨架屏 (shimmer 占位)
class _ShimmerCard extends StatefulWidget {
  final ThemeData theme;
  const _ShimmerCard({required this.theme});

  @override
  State<_ShimmerCard> createState() => _ShimmerCardState();
}

class _ShimmerCardState extends State<_ShimmerCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.theme.colorScheme.surfaceContainerHigh;
    final highlightColor =
        widget.theme.colorScheme.surfaceContainerHighest;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = (_controller.value * 2 - 1).abs();
        return Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: Color.lerp(baseColor, highlightColor, t * 0.5),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border:
                Border.all(color: widget.theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Color.lerp(baseColor, highlightColor, t * 0.5),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: 120,
                      decoration: BoxDecoration(
                        color:
                            Color.lerp(baseColor, highlightColor, t * 0.5),
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 10,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color:
                            Color.lerp(baseColor, highlightColor, t * 0.5),
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Container(
                width: 40,
                height: 24,
                decoration: BoxDecoration(
                  color: Color.lerp(baseColor, highlightColor, t * 0.5),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
