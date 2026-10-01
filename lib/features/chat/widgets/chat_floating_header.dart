import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/app_design_tokens.dart';

/// 聊天页三段式悬浮胶囊 Header (非连续式 AppBar)
///
/// [左圆钮: 菜单(=打开会话抽屉)] 12px [中间胶囊: 会话标题 + 状态行] 弹性空隙
/// [右圆钮: 更多菜单]。两侧为正圆 (44×44), 中间为毛玻璃胶囊且宽度贴内容
/// (不撑满), 三者等高 44。每个胶囊独立毛玻璃 (ClipRRect + BackdropFilter),
/// 无边框; 超长标题在剩余空间内省略。
///
/// 纯展示 + 回调组件 (无 ref 依赖): 标题/状态行数据与动作均由 ChatScreen
/// 组装传入。配色与 GlassAppBar 一致 (亮: 半透明白 0.72; 暗: #08090A @94%)。
class ChatFloatingHeader extends StatelessWidget
    implements PreferredSizeWidget {
  final String title;

  /// 上下文用量指示 (会话有消息时由 ChatScreen 传入, 空会话传 null 不占位)
  final Widget? contextIndicator;

  /// GLM 用量 pill (无配额数据时 UsagePill 自身渲染为空)
  final Widget? usagePill;

  /// 返回按钮 (= 打开历史会话抽屉; 聊天页是根页面无上级可返回)
  final VoidCallback onMenuTap;

  /// 更多菜单 → 新对话 (跳回不带 task 的聊天页)
  final VoidCallback onNewChat;

  /// 更多菜单 → 悬浮窗监视 (null = 非 Android, 菜单项隐藏)
  final VoidCallback? onOpenPip;

  /// 更多菜单 → 设置页
  final VoidCallback onOpenSettings;

  const ChatFloatingHeader({
    super.key,
    required this.title,
    this.contextIndicator,
    this.usagePill,
    required this.onMenuTap,
    required this.onNewChat,
    this.onOpenPip,
    required this.onOpenSettings,
  });

  /// 主体高度 (不含状态栏); body 顶部占位 = padding.top + 该值
  static const double barHeight = 64;

  /// 三枚胶囊统一高度 (等高且紧凑, 两侧宽度=高度 → 正圆)
  static const double pillHeight = 44;

  @override
  Size get preferredSize => const Size.fromHeight(barHeight);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 深色: 实色深底 + blur (不用半透明 surface, 那会偏白); 浅色: 半透明白
    final bg = isDark
        ? const Color(0xF008090A)
        : Colors.white.withValues(alpha: 0.72);
    final inkColor = isDark ? const Color(0xFFF7F8F8) : Colors.black;

    // 本组件是聊天页状态栏样式的唯一来源 (非真正 AppBar, 需 AnnotatedRegion
    // 跟随主题切换状态栏图标亮度), 不能丢。
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: barHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 左圆钮: 菜单 (= 打开会话列表抽屉); 44×44 正圆
                _GlassPill(
                  key: const ValueKey('chatHeaderPillLeft'),
                  bg: bg,
                  child: IconButton(
                    icon: Icon(Icons.menu, size: 22, color: inkColor),
                    tooltip: '会话列表',
                    onPressed: onMenuTap,
                    style: IconButton.styleFrom(
                      foregroundColor: inkColor,
                      minimumSize: const Size(44, 44),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // 中间胶囊: 会话信息卡片 (标题 + 上下文/用量状态行)。
                // 贴左侧排列: Expanded 吃掉全部剩余空间, Align 让卡片在
                // 剩余空间内贴左且宽度贴内容 — 空隙只会出现在卡片与右圆钮
                // 之间 (Flexible+Spacer 的组合会把没用完的弹性配额堆到行尾,
                // 右圆钮就悬在半路了); 超长标题被钳到可用宽后省略。
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _GlassPill(
                      key: const ValueKey('chatHeaderPillCenter'),
                      bg: bg,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 3,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppTextSizes.titleSm,
                                fontWeight: FontWeight.w600,
                                height: 1.2, // 收紧行高, 保证两行内容塞进 44 高
                                color: inkColor,
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (contextIndicator != null) ...[
                                  contextIndicator!,
                                  const SizedBox(width: 6),
                                ],
                                if (usagePill != null) usagePill!,
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // 右圆钮: 更多菜单; 44×44 正圆
                _GlassPill(
                  key: const ValueKey('chatHeaderPillRight'),
                  bg: bg,
                  child: IconButton(
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 20,
                      color: inkColor,
                    ),
                    tooltip: '更多',
                    onPressed: () => _openMoreMenu(context),
                    style: IconButton.styleFrom(
                      foregroundColor: inkColor,
                      minimumSize: const Size(44, 44),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 更多菜单 (风格对齐 ModeSelector 的 sheet: showDragHandle + 混合底色)
  void _openMoreMenu(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('更多', style: theme.textTheme.titleMedium),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: const Text('新对话'),
                onTap: () {
                  Navigator.pop(ctx);
                  onNewChat();
                },
              ),
              if (onOpenPip != null)
                ListTile(
                  leading: const Icon(Icons.picture_in_picture_alt_rounded),
                  title: const Text('悬浮窗监视'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onOpenPip!();
                  },
                ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置'),
                onTap: () {
                  Navigator.pop(ctx);
                  onOpenSettings();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// 单个悬浮胶囊: 圆角 + 毛玻璃, 无边框 (三段共用)。
/// 最小高度 44 (三段等高); 宽度贴内容 — 关键是容器不用 alignment
/// (alignment 会让 Container 撑满父给的宽松约束 → 中间胶囊变全宽的根因)。
/// 两侧 44×44 时半径钳到半高 → 正圆; 中间内容更高时按内容撑高。
class _GlassPill extends StatelessWidget {
  final Color bg;
  final Widget child;

  const _GlassPill({super.key, required this.bg, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: ChatFloatingHeader.pillHeight,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(32),
          ),
          child: child,
        ),
      ),
    );
  }
}
