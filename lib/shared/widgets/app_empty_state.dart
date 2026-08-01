import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';

/// 统一空状态 / 错误状态
///
/// 取代各屏散落的 `_buildEmpty` / `_buildError` 内联实现
/// (workspace_list / skills / chat 各自拼了一遍)。
///
/// 结构: 圆角方块图标 + 标题 + 副标题 + 可选行动按钮, 居中。
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? actionIcon;

  /// [icon] 背景色; 默认强调容器, 错误态可传 [AppColors.dangerContainer]。
  final Color? iconTint;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.actionIcon,
    this.iconTint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = iconTint ?? AppColors.accent;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxl,
          vertical: AppSpacing.xxxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Icon(icon, size: 28, color: tint),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: AppTextSizes.titleSm,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: onAction,
                icon: actionIcon != null ? Icon(actionIcon, size: 18) : const SizedBox.shrink(),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
