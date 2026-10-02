// lib/features/git/widgets/git_history_tab.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/relay/git_api.dart';
import '../../../providers/git_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';

/// 手写相对时间 (不引依赖): <60s 刚刚 / <60m n 分钟前 / <24h n 小时前 /
/// <30d n 天前 / 否则 yyyy-MM-dd; [ms] 为空返回空串。
String relativeTime(int? ms) {
  if (ms == null || ms <= 0) return '';
  final diff = DateTime.now().millisecondsSinceEpoch - ms;
  final seconds = diff < 0 ? 0 : diff ~/ 1000;
  if (seconds < 60) return '刚刚';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟前';
  final hours = minutes ~/ 60;
  if (hours < 24) return '$hours 小时前';
  final days = hours ~/ 24;
  if (days < 30) return '$days 天前';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final mm = t.month.toString().padLeft(2, '0');
  final dd = t.day.toString().padLeft(2, '0');
  return '${t.year}-$mm-$dd';
}

/// 历史 Tab (Task 5): 提交列表 (refresh 已拉第一页, 无需额外首拉) +
/// ScrollController 触底 (剩 200px) 调 [GitController.loadMoreCommits]
/// 分页追加 (防重入与 hasMore 守卫都在 controller)。
/// 行 = 短 hash (7 位 mono) + subject (ellipsis) + `作者 · 相对时间` 副标题
/// + refs Chip (当前分支 accent 底)。
class GitHistoryTab extends ConsumerStatefulWidget {
  final GitRef gitRef;

  const GitHistoryTab({super.key, required this.gitRef});

  @override
  ConsumerState<GitHistoryTab> createState() => _GitHistoryTabState();
}

class _GitHistoryTabState extends ConsumerState<GitHistoryTab> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 200) {
      ref.read(gitProvider(widget.gitRef).notifier).loadMoreCommits();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(gitProvider(widget.gitRef));
    final commits = state.commits;
    final loadingMore = state.busyOps.contains('commits');

    if (commits.isEmpty) {
      return ListView(
        children: [
          SizedBox(
            height: 160,
            child: Center(
              child: Text(
                '暂无提交',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      key: const Key('history-list'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xl,
      ),
      // 分页请求进行中追加一行底部加载指示。
      itemCount: commits.length + (loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == commits.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return _CommitTile(
          entry: commits[index],
          currentBranch: state.summary?.branchName,
        );
      },
    );
  }
}

/// 单条提交: 短 hash + subject + 作者·相对时间 + refs Chip 列。
class _CommitTile extends StatelessWidget {
  final GitCommitEntry entry;
  final String? currentBranch;

  const _CommitTile({required this.entry, required this.currentBranch});

  /// %D 原文 'HEAD -> main' / 'tag: v1.0' → 展示名 'main' / 'v1.0'。
  String _refLabel(String ref) {
    if (ref.startsWith('HEAD -> ')) return ref.substring('HEAD -> '.length);
    if (ref.startsWith('tag: ')) return ref.substring('tag: '.length);
    return ref;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hash = entry.hash.length <= 7 ? entry.hash : entry.hash.substring(0, 7);
    final author = entry.authorName ?? '';
    final time = relativeTime(entry.authoredAtMs);
    final subtitle = [author, time].where((p) => p.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              hash,
              style: AppText.mono(
                context,
                size: AppTextSizes.monoSm,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (entry.refs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        for (final r in entry.refs)
                          _RefChip(
                            label: _refLabel(r),
                            highlighted: _refLabel(r) == currentBranch,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ref 小胶囊; 当前分支 accent 底白字, 其余中性。
class _RefChip extends StatelessWidget {
  final String label;
  final bool highlighted;

  const _RefChip({required this.label, required this.highlighted});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: highlighted
            ? AppColors.accent
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: AppText.mono(
          context,
          size: AppTextSizes.monoXs,
          color: highlighted ? Colors.white : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
