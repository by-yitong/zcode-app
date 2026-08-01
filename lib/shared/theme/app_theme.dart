import 'package:flutter/material.dart';

import 'app_design_tokens.dart';

/// ZCode 主题
///
/// 开发者工具气质: 精确、密度友好、代码优先。
/// 深色为主场 (dev tool 默认 dark), 浅色完整可用。
/// 设计令牌见 app_design_tokens.dart。
class AppTheme {
  AppTheme._();

  static ThemeData get dark => _build(brightness: Brightness.dark);
  static ThemeData get light => _build(brightness: Brightness.light);

  static ThemeData _build({required Brightness brightness}) {
    final isDark = brightness == Brightness.dark;

    // ── 颜色 (深色采纳 Linear 半透明白叠加体系) ──
    final bg = isDark ? AppColors.darkBg : AppColors.lightBg;
    // 深色: 卡片用半透明白叠加在 bg 上; 浅色用实色
    final surface = isDark ? AppColors.darkSurface : AppColors.lightSurface;
    final surfaceLow = isDark ? AppColors.darkSurface : AppColors.lightSurface;
    final surfaceHigh =
        isDark ? AppColors.darkSurfaceHigh : AppColors.lightSurfaceHigh;
    final surfaceHighest = isDark
        ? AppColors.darkSurfaceHighest
        : AppColors.lightSurfaceHigh;
    final border = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final borderSubtle = isDark ? AppColors.darkBorderSubtle : AppColors.lightBorder;
    final ink = isDark ? AppColors.darkInk : AppColors.lightInk;
    final inkSecondary =
        isDark ? AppColors.darkInkSecondary : AppColors.lightInk;
    final inkMuted = isDark ? AppColors.darkInkMuted : AppColors.lightInkMuted;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: AppColors.accent,
      onPrimary: Colors.white,
      primaryContainer: AppColors.accentContainer,
      onPrimaryContainer: AppColors.accent,
      secondary: AppColors.accent,
      onSecondary: Colors.white,
      tertiary: AppColors.success,
      onTertiary: Colors.white,
      error: AppColors.danger,
      onError: Colors.white,
      surface: surface,
      onSurface: ink,
      // Linear 式 luminance 阶梯: lowest → highest 逐渐提亮
      surfaceContainerLowest: bg,
      surfaceContainerLow: surfaceLow,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceHighest,
      onSurfaceVariant: inkSecondary,
      outline: border,
      outlineVariant: borderSubtle,
    );

    // ── 字体 (本地打包, 不依赖网络) ──
    final baseTextTheme = isDark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;
    final uiTextTheme = baseTextTheme.apply(
      fontFamily: kUiFont,
      fontFamilyFallback: const ['SF Pro Display', 'system-ui', 'sans-serif'],
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      textTheme: uiTextTheme,
      fontFamily: kUiFont,
      // 等宽字体作为整体 fallback 的补充 (代码用 AppText.mono 显式指定)
      fontFamilyFallback: const ['SF Pro Display', 'system-ui', 'sans-serif'],

      // ── AppBar: 无阴影, 与背景融合 ──
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ink,
        titleTextStyle: uiTextTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),

      // ── Card: Linear 式半透明面 + 细半透明边框 ──
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: borderSubtle),
        ),
        margin: EdgeInsets.zero,
      ),

      // ── 输入框: 填充式, 圆角 ──
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
      ),

      // ── 按钮 ──
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          textStyle: uiTextTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accent,
          side: const BorderSide(color: AppColors.accent),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
        ),
      ),

      // ── 底部导航 ──
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: AppColors.accentContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.accent : inkMuted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? AppColors.accent : inkMuted,
          );
        }),
      ),

      // ── 分割线 ──
      dividerTheme: DividerThemeData(
        color: border.withValues(alpha: 0.5),
        thickness: 1,
        space: 1,
      ),

      // ── 对话框/底部弹层 (不透明提升面, 与页面背景分离) ──
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
      ),

      // ── SnackBar ──
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceHigh,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),

      // ── 图标默认色 ──
      iconTheme: IconThemeData(color: ink, size: 22),

      // ── ListTile (18+ 处使用, 统一间距与形状) ──
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
      ),

      // ── Chip / ActionChip (chat 选择器 / 标签) ──
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        side: BorderSide(color: borderSubtle),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        labelStyle: uiTextTheme.labelLarge?.copyWith(
          fontSize: AppTextSizes.label,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
      ),

      // ── Switch (skills 启停) ──
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? AppColors.accent
              : surfaceHighest;
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: EdgeInsets.zero,
      ),

      // ── 进度条 (用量条 / 12+ 处) ──
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: surfaceHigh,
        linearMinHeight: 4,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xs)),
      ),

      // ── TabBar (Agent 设置 / 可滚动 tab) ──
      tabBarTheme: TabBarThemeData(
        labelColor: ink,
        unselectedLabelColor: inkMuted,
        labelStyle: uiTextTheme.labelLarge?.copyWith(
          fontSize: AppTextSizes.bodySm,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: uiTextTheme.labelLarge?.copyWith(
          fontSize: AppTextSizes.bodySm,
          fontWeight: FontWeight.w500,
        ),
        indicator: UnderlineTabIndicator(
          borderSide: const BorderSide(color: AppColors.accent, width: 2),
          insets: EdgeInsets.zero,
        ),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      ),

      // ── 对话框 (不透明提升面, 与页面背景分离) ──
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
      ),
    );
  }
}
