import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';

/// 统一分区标题
///
/// 取代三处不同实现: settings `_SectionHeader` (primary 色) /
/// chat `_HomeSectionHeader` (titleSmall + 可选按钮) /
/// skills `_sectionHeader` (onSurfaceVariant, 非 widget)。
///
/// 风格: mono、caption 字号、大写、字间距 0.06em, 色 onSurfaceVariant。
class AppSectionHeader extends StatelessWidget {
  final String title;

  /// 右侧可选操作 (如 "查看全部" 文字按钮)。
  final Widget? action;

  const AppSectionHeader({super.key, required this.title, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontFamily: kMonoFont,
                fontSize: AppTextSizes.caption,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.06,
              ),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}
