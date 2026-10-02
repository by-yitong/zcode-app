// lib/features/git/screens/git_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/relay/git_api.dart';
import '../../../providers/git_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../agent/widgets/caps_page_chrome.dart';
import '../../agent/widgets/caps_widgets.dart';
import '../widgets/commit_sheet.dart';
import '../widgets/git_branches_tab.dart';
import '../widgets/git_change_list.dart';
import '../widgets/git_history_tab.dart';
import 'git_diff_screen.dart' show GitDiffScreen, confirmDiscard;

/// Git 全屏页 — 更改 / 分支 / 历史 三 Tab。
///
/// Task 3: 骨架 + 更改 Tab; Task 5: 分支 Tab (切换/新建) + 历史 Tab (分页)。
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

  /// 已展示过的 error 原文。只弹与上次不同的错误, 避免反复弹 SnackBar;
  /// error 被清空 (refresh 成功写 error: null) 时复位 → 重试后同样的
  /// 错误文案也能再次弹出。
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
      if (err == null) {
        _shownError = null; // error 清空即复位, 允许下次同文案错误再弹
        return;
      }
      if (err != _shownError) {
        _shownError = err;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(err)),
          );
        });
      }
    });

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: CapsPageHeader.overlayStyle(context),
      child: Scaffold(
        appBar: const CapsPageHeader(title: 'Git'),
        body: switch (state.phase) {
          GitPhase.loading => const Center(child: CircularProgressIndicator()),
          GitPhase.empty => const AppEmptyState(
              icon: Icons.folder_off_rounded,
              title: '当前工作区不是 Git 仓库或 git 不可用',
            ),
          GitPhase.ready => _ReadyView(
              controller: ref.read(gitProvider(widget.gitRef).notifier),
              state: state,
              tabController: _tab,
              gitRef: widget.gitRef,
              onCommitTap: () => showCommitSheet(context, ref, widget.gitRef),
              onDiscardConfirm: confirmDiscard,
              onOpenDiff: (change) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GitDiffScreen(
                    gitRef: widget.gitRef,
                    change: change,
                  ),
                ),
              ),
            ),
        },
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
  final GitRef gitRef;
  final VoidCallback onCommitTap;
  final void Function(
    BuildContext context, {
    required GitChange change,
    required GitController controller,
    required bool staged,
  }) onDiscardConfirm;
  final void Function(GitChange change) onOpenDiff;

  const _ReadyView({
    required this.controller,
    required this.state,
    required this.tabController,
    required this.gitRef,
    required this.onCommitTap,
    required this.onDiscardConfirm,
    required this.onOpenDiff,
  });

  @override
  Widget build(BuildContext context) {
    final summary = state.summary;
    return Column(
      children: [
        if (summary != null) _headerCard(context, summary),
        // TabBar 放 body (头部卡片之下), 吃全局 tabBarTheme; 仅 ready 态渲染。
        TabBar(
          controller: tabController,
          tabs: const [
            Tab(text: '更改'),
            Tab(text: '分支'),
            Tab(text: '历史'),
          ],
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: controller.refresh,
            child: TabBarView(
              controller: tabController,
              children: [
                _changesTab(context),
                GitBranchesTab(gitRef: gitRef),
                GitHistoryTab(gitRef: gitRef),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 头部卡片: 分支名 / ↑ahead ↓behind 徽标 / 「提交」钮 / 刷新。
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
      child: CapsCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
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
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                onPressed: onCommitTap,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                  ),
                ),
                child: const Text('提交'),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
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

  /// 更改 Tab: 未暂存/已暂存两段列表 (「提交」入口已并入头部卡片)。
  Widget _changesTab(BuildContext context) {
    return ListView(
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
          onTap: onOpenDiff,
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
          onTap: onOpenDiff,
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

