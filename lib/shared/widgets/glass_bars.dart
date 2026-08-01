import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';

/// 毛玻璃 AppBar (采纳 Apple HIG glassmorphism)
///
/// 滚动时导航栏透出模糊内容, 营造层次感。
/// 用 BackdropFilter + 半透明背景实现。
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool centerTitle;

  const GlassAppBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.centerTitle = false,
  });

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 深色: 实色深底 + blur (不用半透明 surface, 那会偏白)
    // 浅色: 半透明白
    final bg = isDark
        ? const Color(0xF008090A)  // 深底 #08090A @94% alpha (留 6% 透出模糊)
        : Colors.white.withValues(alpha: 0.72);
    final borderColor = isDark
        ? const Color(0x14FFFFFF)  // 半透明白边框
        : Colors.black.withValues(alpha: 0.08);
    final inkColor = isDark ? const Color(0xFFF7F8F8) : Colors.black;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              bottom: BorderSide(color: borderColor),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 56,
              child: NavigationToolbar(
                leading: leading,
                middle: DefaultTextStyle.merge(
                  style: TextStyle(
                    fontSize: AppTextSizes.titleSm,
                    fontWeight: FontWeight.w600,
                    color: inkColor,
                  ),
                  child: title,
                ),
                trailing: actions != null
                    ? Row(mainAxisSize: MainAxisSize.min, children: actions!)
                    : null,
                centerMiddle: centerTitle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃底部输入栏容器 (对话页输入区)
class GlassBottomBar extends StatelessWidget {
  final Widget child;
  const GlassBottomBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? const Color(0xF008090A)
        : Colors.white.withValues(alpha: 0.72);
    final borderColor = isDark
        ? const Color(0x14FFFFFF)
        : Colors.black.withValues(alpha: 0.08);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              top: BorderSide(color: borderColor),
            ),
          ),
          child: SafeArea(top: false, child: child),
        ),
      ),
    );
  }
}
