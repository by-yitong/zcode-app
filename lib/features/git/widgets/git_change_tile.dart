// lib/features/git/widgets/git_change_tile.dart

import 'package:flutter/material.dart';

import '../../../core/relay/git_api.dart';
import '../../../shared/theme/app_design_tokens.dart';

/// 单个变更行: leading kind 色块 + 路径 + 增删统计 + 行内操作菜单。
///
/// 回调为 null 表示对应操作不可用 (busy 中 / 不适用), 菜单项随之隐藏或禁用:
/// - [onTap] — Task 4 的 diff 页接入 (untracked/conflicted 传 null);
/// - [onStage] / [onUnstage] — 按 section 二选一传;
/// - [onDiscard] — 确认弹窗在调用方 (GitScreen) 做。
class GitChangeTile extends StatelessWidget {
  final GitChange change;
  final VoidCallback? onStage;
  final VoidCallback? onUnstage;
  final VoidCallback? onDiscard;
  final VoidCallback? onTap;

  const GitChangeTile({
    super.key,
    required this.change,
    required this.onStage,
    required this.onUnstage,
    required this.onDiscard,
    required this.onTap,
  });

  /// kind → 色块颜色 (冲突优先于 kind)。
  Color get _kindColor {
    if (change.isConflicted || change.section == 'conflicted') {
      return AppColors.warning;
    }
    return switch (change.kind) {
      'added' => AppColors.success,
      'deleted' => AppColors.danger,
      _ => AppColors.accent, // modified / renamed 等
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasMenu = onStage != null || onUnstage != null || onDiscard != null;

    return ListTile(
      onTap: onTap,
      dense: true,
      leading: Container(
        width: 4,
        height: 28,
        decoration: BoxDecoration(
          color: _kindColor,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
      title: Text(
        change.workspaceRelativePath,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.mono(context, size: AppTextSizes.bodySm),
      ),
      subtitle: Text(
        '+${change.added} −${change.removed}',
        style: AppText.mono(
          context,
          size: AppTextSizes.monoXs,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: hasMenu
          ? PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) {
                switch (v) {
                  case 'stage':
                    onStage?.call();
                  case 'unstage':
                    onUnstage?.call();
                  case 'discard':
                    onDiscard?.call();
                }
              },
              itemBuilder: (_) => [
                if (onStage != null)
                  const PopupMenuItem<String>(
                    value: 'stage',
                    child: Text('暂存'),
                  ),
                if (onUnstage != null)
                  const PopupMenuItem<String>(
                    value: 'unstage',
                    child: Text('取消暂存'),
                  ),
                if (onDiscard != null)
                  const PopupMenuItem<String>(
                    value: 'discard',
                    child: Text('丢弃'),
                  ),
              ],
            )
          : null,
    );
  }
}
