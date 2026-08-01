import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';

/// iOS 风设置组 — 多个 [tile] 放一张半透明卡里, 元素间细分割。
///
/// 取代 settings 屏散落的 `Container(surfaceHighest, borderRadius)` 逐个独立卡。
/// 每个 tile 可有 leading 图标方块 / 标题 / 副标题 / 右侧值 / chevron。
class AppTileGroup extends StatelessWidget {
  final List<AppTile> tiles;

  const AppTileGroup({super.key, required this.tiles});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            tiles[i],
            if (i < tiles.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                color: theme.colorScheme.outlineVariant,
                indent: AppSpacing.lg + 28 + AppSpacing.md, // 对齐图标后
              ),
          ],
        ],
      ),
    );
  }
}

/// 单个设置项 tile (AppTileGroup 的子元素)。
class AppTile extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? subtitle;
  final String? value; // 右侧 mono 值 (如 "深色" / "v1.0.0")
  final Widget? trailing; // 完全自定义尾部 (覆盖 value)
  final bool showChevron;
  final VoidCallback? onTap;
  final Color? iconTint;

  const AppTile({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.showChevron = false,
    this.onTap,
    this.iconTint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = iconTint ?? AppColors.accent;
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(icon, size: 16, color: tint),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null)
            trailing!
          else if (value != null)
            Text(
              value!,
              style: AppText.mono(
                context,
                size: AppTextSizes.monoSm,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (showChevron)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.xs),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(onTap: onTap, child: content);
    }
    return content;
  }
}
