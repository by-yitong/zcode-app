// lib/features/git/widgets/git_change_tile.dart

import 'package:flutter/material.dart';

import '../../../core/relay/git_api.dart';
import '../../../shared/theme/app_design_tokens.dart';

/// 单个变更行: 路径 (mono 单行省略) + 右侧彩色 diffstat / 状态小标签 +
/// 行内操作菜单, 单行紧凑无 leading。
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

  /// 是否 untracked (无 diffstat, 显示灰「未跟踪」标签)。
  bool get _isUntracked =>
      change.isUntracked || change.section == 'untracked';

  /// 是否 conflicted (无 diffstat, 显示琥珀「冲突」标签; 优先于 untracked)。
  bool get _isConflicted =>
      change.isConflicted || change.section == 'conflicted';

  /// 右侧状态/统计富文本: conflicted → 「冲突」(warning w600); untracked →
  /// 「未跟踪」(灰); 其余 added+removed>0 → `+n −n` (增绿删红, U+2212 负号)。
  Widget? _statusOrStat(BuildContext context) {
    final theme = Theme.of(context);
    if (_isConflicted) {
      return Text(
        '冲突',
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: AppColors.warning,
        ),
      );
    }
    if (_isUntracked) {
      return Text(
        '未跟踪',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    if (change.added + change.removed > 0) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '+${change.added}',
              style: const TextStyle(color: AppColors.success),
            ),
            TextSpan(
              text: ' −${change.removed}',
              style: const TextStyle(color: AppColors.danger),
            ),
          ],
        ),
        style: AppText.mono(
          context,
          size: AppTextSizes.monoXs,
          weight: FontWeight.w600,
        ),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hasMenu = onStage != null || onUnstage != null || onDiscard != null;
    final status = _statusOrStat(context);

    return ListTile(
      onTap: onTap,
      dense: true,
      visualDensity: VisualDensity.compact,
      // 行包在 CapsCard 里, md 内缩对齐卡内节奏 (水波纹由卡裁圆角)。
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      title: Text(
        change.workspaceRelativePath,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.mono(context, size: AppTextSizes.bodySm),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status != null) status,
          if (hasMenu)
            PopupMenuButton<String>(
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
            ),
        ],
      ),
    );
  }
}
