// lib/features/git/screens/git_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/relay/git_api.dart';
import '../../../providers/git_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../widgets/git_change_list.dart';

/// Git 全屏页 — 更改 / 分支 / 历史 三 Tab。
///
/// Task 3: 骨架 + 更改 Tab 完整操作; 分支 / 历史 Tab 为占位, 下一任务接入。
class GitScreen extends ConsumerStatefulWidget {
  final GitRef gitRef;

  const GitScreen({super.key, required this.gitRef});

  @override
  ConsumerState<GitScreen> createState() => _GitScreenState();
}

class _GitScreenState extends ConsumerState<GitScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    // 必须在 initState 里创建 (active 树上); 若用字段级 lazy 初始化,
    // empty 态下 TabBar 不渲染, 首次触碰会发生在 dispose (deactivated 树)。
    _tab = TabController(length: 3, vsync: this);
  }

  /// 已展示过的 error 原文。GitState.error 不会自动清空 (copyWith null 合并),
  /// 这里一次性消费: 只弹与上次不同的错误, 避免反复弹 SnackBar。
  String? _shownError;

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(gitProvider(widget.gitRef));

    ref.listen<GitState>(gitProvider(widget.gitRef), (_, next) {
      final err = next.error;
      if (err != null && err != _shownError) {
        _shownError = err;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(err)),
          );
        });
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Git'),
        bottom: state.phase == GitPhase.ready
            ? TabBar(
                controller: _tab,
                tabs: const [
                  Tab(text: '更改'),
                  Tab(text: '分支'),
                  Tab(text: '历史'),
                ],
              )
            : null,
      ),
      body: switch (state.phase) {
        GitPhase.loading => const Center(child: CircularProgressIndicator()),
        GitPhase.empty => const _EmptyRepoView(),
        GitPhase.ready => _ReadyView(
            controller: ref.read(gitProvider(widget.gitRef).notifier),
            state: state,
            tabController: _tab,
            onCommitTap: _showCommitPlaceholder,
            onDiscardConfirm: _confirmDiscard,
          ),
      },
    );
  }

  /// 「提交」按钮 — Task 3 分阶段边界: 弹占位提示, Task 4 换 showCommitSheet。
  void _showCommitPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('提交弹窗在下一任务接入')),
    );
  }

  /// 丢弃确认弹窗 (文案必含 '不可恢复') → 确认后调 controller.discard。
  Future<void> _confirmDiscard(
    BuildContext context, {
    required GitChange change,
    required GitController controller,
    required bool staged,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('丢弃更改'),
        content: Text(
          '将丢弃 ${change.workspaceRelativePath} 的'
          '${staged ? '已暂存' : '未暂存'}更改, 此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('丢弃'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.discard([change.path], staged: staged);
    }
  }
}

// ================================================================
// 非仓库空态
// ================================================================

class _EmptyRepoView extends StatelessWidget {
  const _EmptyRepoView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_rounded,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '当前工作区不是 Git 仓库或 git 不可用',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// ready 态: 头部卡片 + 三 Tab
// ================================================================

class _ReadyView extends StatelessWidget {
  final GitController controller;
  final GitState state;
  final TabController tabController;
  final VoidCallback onCommitTap;
  final void Function(
    BuildContext context, {
    required GitChange change,
    required GitController controller,
    required bool staged,
  }) onDiscardConfirm;

  const _ReadyView({
    required this.controller,
    required this.state,
    required this.tabController,
    required this.onCommitTap,
    required this.onDiscardConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final summary = state.summary;
    return Column(
      children: [
        if (summary != null) _headerCard(context, summary),
        Expanded(
          child: RefreshIndicator(
            onRefresh: controller.refresh,
            child: TabBarView(
              controller: tabController,
              children: [
                _changesTab(context),
                const _PlaceholderTab('分支'),
                const _PlaceholderTab('历史'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 头部卡片: 分支名 / ↑ahead ↓behind 徽标 / 刷新。
  Widget _headerCard(BuildContext context, GitSummary summary) {
    final branch = summary.branchName;
    final label = (branch == null || branch.isEmpty)
        ? 'HEAD (detached)'
        : branch;
    final refreshing = state.busyOps.contains('refresh');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.xs,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono(
                    context,
                    size: AppTextSizes.bodyMd,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              if (summary.ahead > 0)
                _Badge(
                  text: '↑${summary.ahead}',
                  color: AppColors.accent,
                  bg: AppColors.accentContainer,
                ),
              if (summary.behind > 0) ...[
                const SizedBox(width: AppSpacing.xs),
                _Badge(
                  text: '↓${summary.behind}',
                  color: AppColors.warning,
                  bg: AppColors.warningContainer,
                ),
              ],
              IconButton(
                tooltip: '刷新',
                onPressed: refreshing ? null : controller.refresh,
                icon: refreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 更改 Tab: 右上角「提交」+ 未暂存/已暂存两段列表。
  Widget _changesTab(BuildContext context) {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: TextButton(
              onPressed: onCommitTap,
              child: const Text('提交'),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.xl,
            ),
            children: [
              GitChangeList(
                title: '未暂存 (${state.unstaged.length})',
                changes: state.unstaged,
                emptyHint: '没有未暂存的更改',
                busyOps: state.busyOps,
                onStage: (c) => controller.stage([c.path]),
                onDiscard: (c) => onDiscardConfirm(
                  context,
                  change: c,
                  controller: controller,
                  staged: false,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              GitChangeList(
                title: '已暂存 (${state.staged.length})',
                changes: state.staged,
                emptyHint: '没有已暂存的更改',
                busyOps: state.busyOps,
                onUnstage: (c) => controller.unstage([c.path]),
                onDiscard: (c) => onDiscardConfirm(
                  context,
                  change: c,
                  controller: controller,
                  staged: true,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// ahead/behind 徽标。
class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final Color bg;

  const _Badge({required this.text, required this.color, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        style: AppText.mono(context, size: AppTextSizes.monoXs, color: color)
            .copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 分支 / 历史 Tab 占位 (下一任务接入)。
class _PlaceholderTab extends StatelessWidget {
  final String label;

  const _PlaceholderTab(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        SizedBox(
          height: 160,
          child: Center(
            child: Text(
              '$label 面板在下一任务接入',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
