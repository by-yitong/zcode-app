import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:highlight/languages/all.dart' as highlight;

import '../theme/app_design_tokens.dart';

/// 语法高亮代码视图
///
/// 使用 highlight.dart 做分词, flutter_highlight 渲染 RichText。
/// 自动适配深色/浅色主题色方案。
class CodeHighlightView extends StatelessWidget {
  final String code;
  final String? language;
  final bool isDark;

  const CodeHighlightView({
    super.key,
    required this.code,
    this.language,
    this.isDark = true,
  });

  @override
  Widget build(BuildContext context) {
    // 无语言 → 退化为纯等宽文本
    if (language == null || language!.isEmpty) {
      return SelectableText(
        code,
        style: TextStyle(
          fontFamily: kMonoFont,
          fontFamilyFallback: const ['monospace'],
          fontSize: AppTextSizes.bodySm,
          height: 1.5,
          color: isDark ? const Color(0xFFE8EAED) : Colors.black87,
        ),
      );
    }

    final themeMap = isDark ? _darkTheme : _lightTheme;
    final resolved = _resolveLanguage(language!);

    return HighlightView(
      code,
      // 未知语言 highlight.dart 自动回退 plaintext, 不会崩溃
      language: resolved ?? 'plaintext',
      theme: themeMap,
      padding: EdgeInsets.zero,
      textStyle: const TextStyle(
        fontFamily: kMonoFont,
        fontFamilyFallback: ['monospace'],
        fontSize: AppTextSizes.bodySm,
        height: 1.5,
      ),
    );
  }

  /// 解析语言名 → highlight.dart 注册的 languageId
  /// 处理常见别名 (py→python, js→javascript, sh→bash, etc.)
  String? _resolveLanguage(String? lang) {
    if (lang == null || lang.isEmpty) return null;
    final lower = lang.toLowerCase();

    // 常见别名映射
    const aliases = {
      'py': 'python',
      'js': 'javascript',
      'ts': 'typescript',
      'sh': 'bash',
      'shell': 'bash',
      'zsh': 'bash',
      'yml': 'yaml',
      'golang': 'go',
      'kt': 'kotlin',
      'rs': 'rust',
      'dockerfile': 'dockerfile',
    };

    final resolved = aliases[lower] ?? lower;

    // 检查 highlight.dart 是否注册了该语言
    if (highlight.allLanguages.containsKey(resolved)) {
      return resolved;
    }
    if (highlight.allLanguages.containsKey(lower)) {
      return lower;
    }
    return null;
  }
}

// ================================================================
// 深色代码主题 (GitHub Dark 调色, 和 APP 深色底搭配)
// ================================================================
const _darkTheme = {
  'root': TextStyle(color: Color(0xFFE8EAED), backgroundColor: Colors.transparent),
  'comment': TextStyle(color: Color(0xFF8B949E), fontStyle: FontStyle.italic),
  'quote': TextStyle(color: Color(0xFF8B949E), fontStyle: FontStyle.italic),
  'keyword': TextStyle(color: Color(0xFFFF7B72), fontWeight: FontWeight.w600),
  'selector-tag': TextStyle(color: Color(0xFFFF7B72), fontWeight: FontWeight.w600),
  'literal': TextStyle(color: Color(0xFF79C0FF)),
  'number': TextStyle(color: Color(0xFF79C0FF)),
  'string': TextStyle(color: Color(0xFFA5D6FF)),
  'subst': TextStyle(color: Color(0xFFE8EAED)),
  'title': TextStyle(color: Color(0xFFD2A8FF), fontWeight: FontWeight.w600),
  'section': TextStyle(color: Color(0xFFD2A8FF), fontWeight: FontWeight.w600),
  'name': TextStyle(color: Color(0xFF7EE787)),
  'type': TextStyle(color: Color(0xFFFFA657)),
  'attribute': TextStyle(color: Color(0xFF79C0FF)),
  'variable': TextStyle(color: Color(0xFFFFA657)),
  'built_in': TextStyle(color: Color(0xFFFFA657)),
  'symbol': TextStyle(color: Color(0xFF79C0FF)),
  'bullet': TextStyle(color: Color(0xFF79C0FF)),
  'link': TextStyle(color: Color(0xFFA5D6FF), decoration: TextDecoration.underline),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
  'strong': TextStyle(fontWeight: FontWeight.w700),
  'addition': TextStyle(color: Color(0xFF7EE787)),
  'deletion': TextStyle(color: Color(0xFFFF7B72)),
  'meta': TextStyle(color: Color(0xFF8B949E)),
  'params': TextStyle(color: Color(0xFFE8EAED)),
  'regexp': TextStyle(color: Color(0xFFA5D6FF)),
  'tag': TextStyle(color: Color(0xFF7EE787)),
  'title.function': TextStyle(color: Color(0xFFD2A8FF), fontWeight: FontWeight.w600),
  'title.class': TextStyle(color: Color(0xFFFFA657), fontWeight: FontWeight.w600),
  'property': TextStyle(color: Color(0xFF79C0FF)),
  'operator': TextStyle(color: Color(0xFFFF7B72)),
  'punctuation': TextStyle(color: Color(0xFFC9D1D9)),
};

// ================================================================
// 浅色代码主题 (GitHub Light 调色)
// ================================================================
const _lightTheme = {
  'root': TextStyle(color: Color(0xFF24292F), backgroundColor: Colors.transparent),
  'comment': TextStyle(color: Color(0xFF6E7781), fontStyle: FontStyle.italic),
  'quote': TextStyle(color: Color(0xFF6E7781), fontStyle: FontStyle.italic),
  'keyword': TextStyle(color: Color(0xFFCF222E), fontWeight: FontWeight.w600),
  'selector-tag': TextStyle(color: Color(0xFFCF222E), fontWeight: FontWeight.w600),
  'literal': TextStyle(color: Color(0xFF0550AE)),
  'number': TextStyle(color: Color(0xFF0550AE)),
  'string': TextStyle(color: Color(0xFF0A3069)),
  'subst': TextStyle(color: Color(0xFF24292F)),
  'title': TextStyle(color: Color(0xFF8250DF), fontWeight: FontWeight.w600),
  'section': TextStyle(color: Color(0xFF8250DF), fontWeight: FontWeight.w600),
  'name': TextStyle(color: Color(0xFF116329)),
  'type': TextStyle(color: Color(0xFF953800)),
  'attribute': TextStyle(color: Color(0xFF0550AE)),
  'variable': TextStyle(color: Color(0xFF953800)),
  'built_in': TextStyle(color: Color(0xFF953800)),
  'symbol': TextStyle(color: Color(0xFF0550AE)),
  'bullet': TextStyle(color: Color(0xFF0550AE)),
  'link': TextStyle(color: Color(0xFF0969DA), decoration: TextDecoration.underline),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
  'strong': TextStyle(fontWeight: FontWeight.w700),
  'addition': TextStyle(color: Color(0xFF116329)),
  'deletion': TextStyle(color: Color(0xFFCF222E)),
  'meta': TextStyle(color: Color(0xFF6E7781)),
  'params': TextStyle(color: Color(0xFF24292F)),
  'regexp': TextStyle(color: Color(0xFF0A3069)),
  'tag': TextStyle(color: Color(0xFF116329)),
  'title.function': TextStyle(color: Color(0xFF8250DF), fontWeight: FontWeight.w600),
  'title.class': TextStyle(color: Color(0xFF953800), fontWeight: FontWeight.w600),
  'property': TextStyle(color: Color(0xFF0550AE)),
  'operator': TextStyle(color: Color(0xFF0550AE)),
  'punctuation': TextStyle(color: Color(0xFF24292F)),
};
