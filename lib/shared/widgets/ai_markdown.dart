/// AI Markdown 统一渲染入口 (gpt_markdown)。
///
/// 取代 vendored 旧 markdown 包 (chatMarkdownStyleSheet + 手动表格拆段):
/// gpt_markdown 的默认表格自带横向滚动容器, 整段文本一次渲染即可。
/// 样式令牌迁移自旧 `lib/shared/theme/chat_markdown_style.dart`, 设计约定不变:
/// - 标题在气泡语境下降阶: 18/16/14, 四级以下与正文同号靠字重;
/// - 引用块用左侧电光蓝 45% 竖线, 无底色;
/// - 分隔线 1px 发丝线;
/// - 链接品牌电光蓝 w500;
/// - 行内代码 codeBg 底 + kMonoFont;
/// - 表格 1px outlineVariant 40% 网格 + h10 v6 单元格内边距, 表头加粗不加底。
///
/// [AiMarkdown.minimal] 模式 (用户气泡/计划卡/审批卡): 只接管正文/标题基准/
/// 行内代码, 其余块级样式交给包默认 — 不复制第二套样式表。
library;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../features/chat/widgets/code_block.dart';
import '../theme/app_design_tokens.dart';

class AiMarkdown extends StatefulWidget {
  const AiMarkdown({
    super.key,
    required this.data,
    required this.ink,
    required this.codeBg,
    this.bodyStyle,
    this.headingBase,
    this.inlineCode,
    this.minimal = false,
    this.isStreaming = false,
    this.onLinkTap,
  });

  /// Markdown 源文本 (整段, 含表格 — 不再拆段)。
  final String data;

  /// 正文墨色 (标题/引用/表头/行内代码前景的基准)。
  final Color ink;

  /// 行内代码底色。
  final Color codeBg;

  /// 覆盖正文字体 (用户气泡白字 / 计划卡 bodySmall); null = ink bodyMd。
  final TextStyle? bodyStyle;

  /// 标题基准样式: 整体覆盖 h1-h6 降阶阶梯 (计划卡/审批卡用 titleSmall 等)。
  final TextStyle? headingBase;

  /// 覆盖行内代码样式 (用户气泡白字黑底)。
  final InlineCodeStyle? inlineCode;

  /// true = 简化模式: 只配置正文/标题/行内代码, 其余交给包默认。
  final bool minimal;

  /// 是否仍在流式输出 (实时响应中 true; 静态内容必须传 false)。
  final bool isStreaming;

  /// 链接点击回调; null = 链接不可点 (与旧计划卡/审批卡行为一致)。
  final void Function(String url, String title)? onLinkTap;

  @override
  State<AiMarkdown> createState() => _AiMarkdownState();
}

class _AiMarkdownState extends State<AiMarkdown> {
  // ── 样式记忆化 ──
  // GptMarkdownThemeData 工厂内部要建 ThemeData.light/dark (开销大), 且它
  // 无 == 重载 (ThemeExtension 默认恒等比较), 每次 build 新建实例会让
  // GptMarkdownTheme.updateShouldNotify 恒真。同一输入组合下复用同一实例,
  // 流式逐 token 重建时不重复建主题。
  Brightness? _brightness;
  Color? _ink;
  Color? _codeBg;
  TextStyle? _body;
  TextStyle? _heading;
  InlineCodeStyle? _inline;
  bool? _minimal;

  GptMarkdownThemeData? _gptTheme;
  GptMarkdownStyleSheet? _sheet;
  TextStyle? _resolvedBody;

  void _ensureStyles(ThemeData theme) {
    if (_gptTheme != null &&
        theme.brightness == _brightness &&
        widget.ink == _ink &&
        widget.codeBg == _codeBg &&
        widget.bodyStyle == _body &&
        widget.headingBase == _heading &&
        widget.inlineCode == _inline &&
        widget.minimal == _minimal) {
      return;
    }
    final ink = widget.ink;
    final codeBg = widget.codeBg;
    final minimal = widget.minimal;
    final heading = widget.headingBase;
    final body = widget.bodyStyle ??
        TextStyle(
          color: ink,
          fontSize: AppTextSizes.bodyMd,
          height: minimal ? 1.5 : 1.6,
        );
    final borderColor =
        theme.colorScheme.outlineVariant.withValues(alpha: 0.4);

    _brightness = theme.brightness;
    _ink = ink;
    _codeBg = codeBg;
    _body = widget.bodyStyle;
    _heading = heading;
    _inline = widget.inlineCode;
    _minimal = minimal;
    _resolvedBody = body;

    _gptTheme = GptMarkdownThemeData(
      brightness: theme.brightness,
      linkColor: AppColors.accent,
      linkHoverColor: AppColors.accentHover,
      // 旧观感没有 h1 底部分隔线, 关掉包默认的 h1 rule
      autoAddDividerLineAfterH1: false,
      // 标题降阶阶梯 (迁移自旧 chatMarkdownStyleSheet h1-h6)
      h1: heading ?? _h(ink, AppTextSizes.title, FontWeight.w700, 1.4),
      h2: heading ?? _h(ink, AppTextSizes.titleSm, FontWeight.w700, 1.4),
      h3: heading ?? _h(ink, AppTextSizes.bodyMd, FontWeight.w700, 1.5),
      h4: heading ?? _h(ink, AppTextSizes.bodyMd, FontWeight.w600, 1.5),
      h5: heading ??
          _h(ink.withValues(alpha: 0.85), AppTextSizes.bodySm,
              FontWeight.w600, 1.5),
      h6: heading ??
          _h(ink.withValues(alpha: 0.7), AppTextSizes.label,
              FontWeight.w600, 1.5),
    );

    _sheet = minimal
        ? GptMarkdownStyleSheet(
            inlineCode: widget.inlineCode ??
                InlineCodeStyle(
                  fontFamily: kMonoFont,
                  backgroundColor: codeBg,
                  borderColor: Colors.transparent,
                ),
          )
        : GptMarkdownStyleSheet(
            // 引用块: 左侧电光蓝 45% 竖线 + 墨色降一档, 无底色
            blockQuote: BlockQuoteStyle(
              barWidth: 3,
              barColor: AppColors.accent.withValues(alpha: 0.45),
              padding: const EdgeInsets.only(
                left: AppSpacing.sm + 2,
                top: 2,
                bottom: 2,
              ),
              margin: const EdgeInsets.symmetric(vertical: 2),
              textStyle: TextStyle(
                color: ink.withValues(alpha: 0.8),
                fontSize: AppTextSizes.bodyMd,
                height: 1.6,
              ),
            ),
            // 标题留白 (包只支持全级别统一 padding, 取 h1/h2 档)
            heading: const HeadingStyle(
              padding: EdgeInsets.only(
                top: AppSpacing.sm,
                bottom: AppSpacing.xs,
              ),
            ),
            // 链接: 品牌电光蓝 (替代包默认硬编码 blue/red)
            link: const LinkStyle(
              color: AppColors.accent,
              fontWeight: FontWeight.w500,
            ),
            inlineCode: widget.inlineCode ??
                InlineCodeStyle(
                  fontFamily: kMonoFont,
                  color: ink,
                  backgroundColor: codeBg,
                  borderColor: Colors.transparent,
                  fontSizeFactor: AppTextSizes.monoSm / AppTextSizes.bodyMd,
                ),
            list: const ListStyle(indent: AppSpacing.xl),
            checkbox: const CheckboxStyle(checkedColor: AppColors.accent),
            // 表格: 1px 发丝网格 + 圆角, 表头加粗无底色 (默认即带横向滚动)
            table: TableStyle(
              borderColor: borderColor,
              borderWidth: 1,
              borderRadius: const Radius.circular(AppRadius.sm),
              cellPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              headerBackground: Colors.transparent,
              rowStripeColor: Colors.transparent,
              headerTextStyle: TextStyle(
                fontWeight: FontWeight.w700,
                color: ink,
                fontSize: AppTextSizes.bodySm,
              ),
            ),
            // 分隔线: 1px 发丝线
            hr: HrStyle(thickness: 1, color: borderColor),
          );
  }

  static TextStyle _h(
    Color color,
    double size,
    FontWeight weight,
    double height,
  ) {
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _ensureStyles(theme);
    return GptMarkdownTheme(
      gptThemeData: _gptTheme!,
      child: GptMarkdown(
        widget.data,
        style: _resolvedBody,
        styleSheet: _sheet,
        isStreaming: widget.isStreaming,
        onLinkTap: widget.onLinkTap,
        codeBuilder: (ctx, name, code, closed) => CodeBlock(
          code: code,
          language: name.isEmpty ? null : name,
          theme: Theme.of(ctx),
        ),
      ),
    );
  }
}
