// lib/features/git/widgets/git_change_list.dart

import 'package:flutter/material.dart';

import '../../../core/relay/git_api.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../agent/widgets/caps_page_chrome.dart' show CapsSectionHeader;
import '../../agent/widgets/caps_widgets.dart' show CapsCard;
import 'git_change_tile.dart';

/// 更改段列表: 段标题 (如 '未暂存 (3)') + 变更行; 空段显示提示行。
///
/// [busyOps] 为 GitState.busyOps, 行级键 'stage:<path>' / 'unstage:<path>' /
/// 'discard:<path>' 任一命中即视为该行 busy, 行内操作全部禁用 (传 null)。
class GitChangeList extends StatelessWidget {
  final String title;
  final List<GitChange> changes;
  final String emptyHint;
  final Set<String> busyOps;
  final void Function(GitChange change)? onStage;
  final void Function(GitChange change)? onUnstage;
  final void Function(GitChange change)? onDiscard;
  final void Function(GitChange change)? onTap;

  const GitChangeList({
    super.key,
    required this.title,
    required this.changes,
    required this.emptyHint,
    this.busyOps = const {},
    this.onStage,
    this.onUnstage,
    this.onDiscard,
    this.onTap,
  });

  bool _busy(GitChange c) =>
      busyOps.contains('stage:${c.path}') ||
      busyOps.contains('unstage:${c.path}') ||
      busyOps.contains('discard:${c.path}');

  /// untracked/conflicted 无行级 diff 内容, 按 GitChangeTile 契约不接 onTap
  /// (传 null, 不进 diff 详情页)。
  bool _noDiff(GitChange c) =>
      c.isUntracked ||
      c.isConflicted ||
      c.section == 'untracked' ||
      c.section == 'conflicted';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CapsSectionHeader(title, showChevron: false),
        CapsCard(
          child: changes.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.md,
                    AppSpacing.sm,
                  ),
                  child: Text(
                    emptyHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (final c in changes)
                      GitChangeTile(
                        change: c,
                        onTap:
                            onTap == null || _noDiff(c) ? null : () => onTap!(c),
                        onStage: onStage == null || _busy(c)
                            ? null
                            : () => onStage!(c),
                        onUnstage: onUnstage == null || _busy(c)
                            ? null
                            : () => onUnstage!(c),
                        onDiscard: onDiscard == null || _busy(c)
                            ? null
                            : () => onDiscard!(c),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
