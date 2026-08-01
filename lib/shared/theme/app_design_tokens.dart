import 'package:flutter/material.dart';

/// ZCode 设计令牌 (Design Tokens)
///
/// 集中管理所有视觉常量, 避免在组件里散落硬编码。
/// 设计方向: 开发者工具气质 — 精确、密度友好、代码优先、电光蓝强调。
///
/// 所有间距/圆角/字号都从这里取, 不在组件里写魔法数字。

class AppSpacing {
  AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

class AppRadius {
  AppRadius._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 999;
}

/// 移动端触摸目标 (Apple HIG: 最小 44pt)
class AppTouch {
  AppTouch._();
  static const double min = 44;
  static const double comfortable = 48;
}

/// ZCode 品牌色板
///
/// 不用 Material 默认 fromSeed 的 muddy 色, 手调一套精确的深色优先配色。
/// 主强调: 电光蓝 (比默认 #0066FF 更亮更冷, 在深色背景上有冲击力)
class AppColors {
  AppColors._();

  // ── 强调色 (亮暗共用) ──
  /// 电光蓝 — 主强调, 用于按钮/链接/激活态
  static const Color accent = Color(0xFF3B82F6);
  /// 强调悬浮态 (略亮)
  static const Color accentHover = Color(0xFF60A5FA);
  /// 强调按下态 (略暗)
  static const Color accentPressed = Color(0xFF2563EB);
  /// 强调容器背景 (低透明)
  static const Color accentContainer = Color(0x1F3B82F6);

  // ── 状态色 ──
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4444);

  // ── 状态容器色 (低透明填充, 取代散落的 .withValues(alpha:0.15) 重算) ──
  /// 成功容器背景 (~12% alpha)
  static const Color successContainer = Color(0x1F22C55E);
  /// 警告容器背景 (~12% alpha)
  static const Color warningContainer = Color(0x1FF59E0B);
  /// 危险容器背景 (~12% alpha)
  static const Color dangerContainer = Color(0x1FEF4444);

  // ── 深色主题 (主场, 采纳 Linear 深色质感) ──
  //
  // 核心原则 (Linear): 深色表面用半透明白叠加, 不用实色;
  // 边框用半透明白, 不用实色灰。这样在深色上有空气感。
  static const Color darkBg = Color(0xFF08090A);            // 最底层 (Linear marketing black)

  /// 提升面 (模态/底部弹窗用): 不透明, 比 bg 亮一档, 与背景分离。
  /// 不能用半透明 darkSurface (会透出底层内容), 弹窗必须实色。
  static const Color darkSurfaceElevated = Color(0xFF15161A);

  /// 卡片/面板: 半透明白 0.03 (Linear surface)
  static const Color darkSurface = Color(0x08FFFFFF);       // rgba(255,255,255,0.03)
  /// 高亮面: 半透明白 0.06 (Linear elevated)
  static const Color darkSurfaceHigh = Color(0x10FFFFFF);   // rgba(255,255,255,0.06)
  /// 最高面: 半透明白 0.09 (Linear hover)
  static const Color darkSurfaceHighest = Color(0x17FFFFFF); // rgba(255,255,255,0.09)

  /// 边框: 半透明白 (Linear border standard)
  static const Color darkBorder = Color(0x14FFFFFF);        // rgba(255,255,255,0.08)
  /// 细边框: 半透明白 0.05 (Linear subtle)
  static const Color darkBorderSubtle = Color(0x0DFFFFFF);  // rgba(255,255,255,0.05)

  // 文字 (采纳 Apple alpha 标签体系: 在任何背景上自适应)
  // Apple dark: rgba(235,235,245, alpha) — 微冷白带 alpha
  static const Color darkInk = Color(0xFFF7F8F8);              // 主文字 (近白)
  static const Color darkInkSecondary = Color(0x99EBEBF5);     // 次要 (alpha 0.60)
  static const Color darkInkMuted = Color(0x4DEBEBF5);         // 弱 (alpha 0.30)
  static const Color darkInkSubtle = Color(0x2EEBEBF5);        // 最弱 (alpha 0.18)

  // ── 浅色主题 ──
  static const Color lightBg = Color(0xFFF8FAFC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFF1F5F9);
  static const Color lightBorder = Color(0xFFE2E8F0);
  static const Color lightInk = Color(0xFF000000);
  // Apple light labels: rgba(60,60,67, alpha)
  static const Color lightInkSecondary = Color(0x993C3C43);   // alpha 0.60
  static const Color lightInkMuted = Color(0x4D3C3C43);       // alpha 0.30
  static const Color lightInkSubtle = Color(0x2E3C3C43);      // alpha 0.18
}

/// 等宽字体族名 (代码/路径/ID/taskId)
const String kMonoFont = 'JetBrains Mono';
/// UI 字体族名
const String kUiFont = 'Inter';

/// 代码/路径/ID 文本样式快捷构造
class AppText {
  AppText._();

  /// 等宽代码样式 (深色适配)
  static TextStyle mono(BuildContext context, {
    double size = 13,
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) {
    return TextStyle(
      fontFamily: kMonoFont,
      fontFamilyFallback: const ['monospace'],
      fontSize: size,
      fontWeight: weight,
      color: color ?? Theme.of(context).colorScheme.onSurface,
      height: 1.5,
    );
  }
}

/// 文字尺寸阶梯
///
/// 取代散落的 `fontSize: 11/12/13/15/16/18/20/24` 内联值。
/// 数值与 Material 3 / iOS type scale 对齐, mono 档比同档 UI 字小 1px
/// (等宽字视觉偏大)。用法: `AppTextSizes.body`, `AppTextSizes.monoSm`。
class AppTextSizes {
  AppTextSizes._();

  // UI (Inter)
  static const double display = 28;   // 大标题 (工作区名/页头)
  static const double headline = 24;  // 屏幕标题
  static const double title = 18;     // 卡片标题
  static const double titleSm = 16;   // 小标题 / ListTile 标题
  static const double body = 15;      // 正文 (消息/默认)
  static const double bodyMd = 14;    // 正文偏紧 (Markdown 段落 / 按钮文字)
  static const double bodySm = 13;    // 次要正文 / ListTile 副标题
  static const double label = 12;     // 标签 / 按钮
  static const double caption = 11;   // 最小 — 时间戳/计数/元信息

  // Mono (JetBrains Mono) — 元信息专用, 比同档 UI 字小 1px
  static const double mono = 13;      // 默认等宽 (代码/路径)
  static const double monoSm = 12;    // mono 元信息 (用量%/时间)
  static const double monoXs = 11;    // mono 最小 (SID/调试值)
}

/// 动效时长 (ms)
///
/// 取代散落的 `Duration(milliseconds: …)` 内联值。三档够用, 别再造新档。
class AppDur {
  AppDur._();
  static const Duration fast = Duration(milliseconds: 140);  // hover/press 反馈
  static const Duration base = Duration(milliseconds: 220);  // 默认 — 展开/切换
  static const Duration slow = Duration(milliseconds: 360);  // 大区/页面过渡
}

/// 缓动曲线
///
/// 与 AppDur 配合。禁止裸用 `Curves.ease` (浏览器默认, 偏机械)。
class AppEase {
  AppEase._();
  static const Curve out = Curves.easeOutCubic;     // 元素进场 / 默认
  static const Curve inOut = Curves.easeInOutCubic; // 状态切换
  static const Curve in_ = Curves.easeInCubic;      // 元素退场
}

