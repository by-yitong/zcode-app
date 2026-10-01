/// Agent 能力详情页页面骨架组件 — 浅色极简风 (大留白 / 无卡片边框)
///
/// 参考 Gemini 插件页设计 DNA:
/// - 顶部白色圆形返回钮 + 绝对居中标题, 无 AppBar 背景条
/// - 分组标题: 灰色中字号 + 右侧小箭头
/// - 列表行: 无边框全宽, 左图标盒 + 标题/灰描述 + 右动作元素
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../shared/theme/app_design_tokens.dart';

/// 能力页自定义头部 (替代传统 AppBar 背景条)
///
/// Stack 布局: 左白色圆形返回钮 (padding left 12) / 标题绝对居中 /
/// 右侧可选动作圆钮。页面用法:
/// ```dart
/// AnnotatedRegion<SystemUiOverlayStyle>(
///   value: CapsPageHeader.overlayStyle(context),
///   child: Scaffold(appBar: CapsPageHeader(title: '技能', ...)),
/// )
/// ```
class CapsPageHeader extends StatelessWidget implements PreferredSizeWidget {
  final String title;

  /// 右上角动作圆钮 (CapsCircleIconButton)
  final List<Widget>? actions;

  /// 返回回调, 默认 Navigator.maybePop
  final VoidCallback? onBack;

  /// true = 朴素风格: 返回用裸箭头 (无白色圆底), 标题加大 (22px)。
  /// 设置页等按参考截图使用; 默认 false = 白圆钮 + 标准标题。
  final bool plain;

  const CapsPageHeader({
    super.key,
    required this.title,
    this.actions,
    this.onBack,
    this.plain = false,
  });

  /// 自定义 header 后状态栏样式须页面自给: 暗色底亮图标 / 亮色底暗图标
  static SystemUiOverlayStyle overlayStyle(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
  }

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionList = actions ?? const <Widget>[];
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 64,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 绝对居中标题 (忽略点击, 不挡左右按钮)
            IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 56),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: plain ? 22 : null,
                  ),
                ),
              ),
            ),
            Positioned(
              left: plain ? 4 : AppSpacing.md,
              child: plain
                  ? IconButton(
                      icon: const Icon(Icons.chevron_left_rounded, size: 28),
                      tooltip: '返回',
                      onPressed: onBack ?? () => Navigator.maybePop(context),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    )
                  : CapsCircleIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: '返回',
                      onTap: onBack ?? () => Navigator.maybePop(context),
                    ),
            ),
            if (actionList.isNotEmpty)
              Positioned(
                right: AppSpacing.md,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < actionList.length; i++) ...[
                      if (i > 0) const SizedBox(width: AppSpacing.sm),
                      actionList[i],
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 40px 圆形按钮 — 浅色白底黑图标 / 暗色 darkSurfaceElevated 底亮图标
class CapsCircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  const CapsCircleIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget btn = Material(
      color: dark ? AppColors.darkSurfaceElevated : Colors.white,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 20,
            color: dark ? AppColors.darkInk : Colors.black,
          ),
        ),
      ),
    );
    // 阴影只给浅色 (黑影在暗色上不可见)
    if (!dark) {
      btn = DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 6,
              offset: Offset(0, 1.5),
            ),
          ],
        ),
        child: btn,
      );
    }
    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}

/// 分组标题 — 灰色中字号常规字重 + 右侧小箭头 (非大写 mono 小字)
class CapsSectionHeader extends StatelessWidget {
  final String title;

  const CapsSectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 12),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 17, // AppTextSizes 无 bodyLarge, 按设计稿取 17
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// 无边框全宽极简列表行 — 左图标盒 + 标题/灰单行描述 + 右动作元素
class CapsPlainTile extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle; // 单行省略
  final Widget? trailing;
  final VoidCallback? onTap;

  const CapsPlainTile({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          leading,
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTextSizes.bodySm,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
    if (onTap != null) {
      return InkWell(onTap: onTap, child: content);
    }
    return content;
  }
}
