import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'app_design_tokens.dart';

/// AI 消息气泡内的 Markdown 排版 (正文/表格两种渲染路径共用)。
///
/// 设计约定 (不接管的项目会回落到 flutter_markdown 的 Material 默认值):
/// - 标题在气泡语境下降阶: 最大 18sp, 与正文拉开靠字重而非字号
///   (默认 h1=headlineSmall 24sp / h2=titleLarge 22sp, 在窄气泡里非常突兀);
/// - 颜色/字号/间距全部取自 [AppTextSizes]/[AppSpacing]/[AppColors] 令牌;
/// - 引用块用左侧强调竖线, 不用默认的浅蓝整块背景 (深色模式下刺眼);
/// - 分隔线 1px 发丝线, 不用默认 5px 粗线;
/// - 链接用品牌电光蓝, 不用默认硬编码的 Colors.blue。
MarkdownStyleSheet chatMarkdownStyleSheet(
  ThemeData theme, {
  required Color ink,
  required Color codeBg,
}) {
  final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.4);

  return MarkdownStyleSheet(
    p: TextStyle(color: ink, fontSize: AppTextSizes.bodyMd, height: 1.6),
    pPadding: EdgeInsets.zero,

    // 标题阶梯 (气泡内降阶): 18 → 16 → 14, 四级以下与正文同号靠字重
    h1: TextStyle(
      color: ink,
      fontSize: AppTextSizes.title,
      fontWeight: FontWeight.w700,
      height: 1.4,
    ),
    h1Padding: const EdgeInsets.only(
      top: AppSpacing.sm,
      bottom: AppSpacing.xs,
    ),
    h2: TextStyle(
      color: ink,
      fontSize: AppTextSizes.titleSm,
      fontWeight: FontWeight.w700,
      height: 1.4,
    ),
    h2Padding: const EdgeInsets.only(
      top: AppSpacing.sm,
      bottom: AppSpacing.xs,
    ),
    h3: TextStyle(
      color: ink,
      fontSize: AppTextSizes.bodyMd,
      fontWeight: FontWeight.w700,
      height: 1.5,
    ),
    h3Padding: const EdgeInsets.only(top: AppSpacing.xs + 2, bottom: 2),
    h4: TextStyle(
      color: ink,
      fontSize: AppTextSizes.bodyMd,
      fontWeight: FontWeight.w600,
      height: 1.5,
    ),
    h4Padding: const EdgeInsets.only(top: AppSpacing.xs + 2, bottom: 2),
    h5: TextStyle(
      color: ink.withValues(alpha: 0.85),
      fontSize: AppTextSizes.bodySm,
      fontWeight: FontWeight.w600,
      height: 1.5,
    ),
    h5Padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: 2),
    h6: TextStyle(
      color: ink.withValues(alpha: 0.7),
      fontSize: AppTextSizes.label,
      fontWeight: FontWeight.w600,
      height: 1.5,
    ),
    h6Padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: 2),

    // 链接: 品牌电光蓝 (替代默认 Colors.blue)
    a: const TextStyle(
      color: AppColors.accent,
      fontWeight: FontWeight.w500,
    ),
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: const TextStyle(fontWeight: FontWeight.w700),
    del: const TextStyle(decoration: TextDecoration.lineThrough),

    // 引用块: 左侧强调竖线 + 墨色降一档, 不用默认浅蓝底
    blockquote: TextStyle(
      color: ink.withValues(alpha: 0.8),
      fontSize: AppTextSizes.bodyMd,
      height: 1.6,
    ),
    blockquotePadding: const EdgeInsets.only(
      left: AppSpacing.sm + 2,
      top: 2,
      bottom: 2,
    ),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          width: 3,
          color: AppColors.accent.withValues(alpha: 0.45),
        ),
      ),
    ),

    code: TextStyle(
      color: ink,
      backgroundColor: codeBg,
      fontSize: AppTextSizes.monoSm,
      fontFamily: kMonoFont,
      height: 1.5,
    ),
    codeblockPadding: const EdgeInsets.all(AppSpacing.sm + 2),
    codeblockDecoration: BoxDecoration(
      color: codeBg,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      border: Border.all(color: borderColor),
    ),

    blockSpacing: AppSpacing.sm,
    listIndent: AppSpacing.xl,
    listBullet: TextStyle(
      color: ink,
      fontSize: AppTextSizes.bodyMd,
      height: 1.6,
    ),
    listBulletPadding: const EdgeInsets.only(right: AppSpacing.xs),
    checkbox: TextStyle(color: AppColors.accent, fontSize: AppTextSizes.bodyMd),

    // 分隔线: 1px 发丝线 (默认 5px 粗)
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(width: 1, color: borderColor)),
    ),

    // 表格 (GFM 表格段横向滚动路径共用)
    tableHead: TextStyle(
      fontWeight: FontWeight.w700,
      color: ink,
      fontSize: AppTextSizes.bodySm,
    ),
    tableBody: TextStyle(color: ink, fontSize: AppTextSizes.bodySm),
    tableHeadAlign: TextAlign.center,
    tableColumnWidth: const IntrinsicColumnWidth(),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tableBorder: TableBorder(
      top: BorderSide(color: borderColor),
      bottom: BorderSide(color: borderColor),
      left: BorderSide(color: borderColor),
      right: BorderSide(color: borderColor),
      horizontalInside: BorderSide(color: borderColor.withValues(alpha: 0.5)),
      verticalInside: BorderSide(color: borderColor.withValues(alpha: 0.5)),
    ),
  );
}
