import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/chat_markdown_style.dart';
import '../../../shared/widgets/code_highlight.dart';

class CodeBlockBuilder extends MarkdownElementBuilder {
  final ThemeData theme;
  CodeBlockBuilder({required this.theme});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String code = '';
    String? language;
    final codeNode = element.children?.first;
    if (codeNode is md.Element && codeNode.tag == 'code') {
      code = codeNode.textContent;
      final cls = codeNode.attributes['class'] ?? '';
      final match = RegExp(r'language-(\w+)').firstMatch(cls);
      language = match?.group(1);
    }
    return CodeBlock(code: code, language: language, theme: theme);
  }
}

/// 代码块 widget: 顶栏(语言+复制+行数) + 语法高亮 + 折叠展开
class CodeBlock extends StatefulWidget {
  final String code;
  final String? language;
  final ThemeData theme;
  const CodeBlock({required this.code, this.language, required this.theme});
  @override
  State<CodeBlock> createState() => CodeBlockState();
}

class CodeBlockState extends State<CodeBlock> {
  bool _copied = false;
  bool _expanded = false;

  /// 超过此行数默认折叠
  static const _collapseThreshold = 15;

  int get _lineCount => '\n'.allMatches(widget.code).length + 1;
  bool get _shouldCollapse => _lineCount > _collapseThreshold;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = theme.brightness == Brightness.dark;
    final showCollapsed = _shouldCollapse && !_expanded;
    // 折叠时只显示前 N 行
    final displayCode = showCollapsed
        ? widget.code.split('\n').take(_collapseThreshold).join('\n')
        : widget.code;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerLowest
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶栏: 语言标签 + 行数 + 复制按钮
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF161719) : const Color(0xFFEFF2F5),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Row(
              children: [
                if (widget.language != null)
                  Text(
                    widget.language!,
                    style: TextStyle(
                      fontSize: AppTextSizes.caption,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 8),
                Text(
                  '$_lineCount 行',
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: _copy,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check : Icons.copy,
                          size: 14,
                          color: _copied
                              ? Colors.green
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? '已复制' : '复制',
                          style: TextStyle(
                            fontSize: AppTextSizes.caption,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 代码内容: 语法高亮 + 横向滚动
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: CodeHighlightView(
              code: displayCode,
              language: widget.language,
              isDark: isDark,
            ),
          ),
          // 折叠/展开按钮
          if (_shouldCollapse)
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _expanded
                          ? '收起'
                          : '展开剩余 ${_lineCount - _collapseThreshold} 行',
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 历史会话抽屉 (左滑出)
