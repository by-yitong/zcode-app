// lib/features/git/widgets/git_diff_view.dart

import 'package:flutter/material.dart';

import '../../../shared/theme/app_design_tokens.dart';

/// 单行着色规则 (按行首前缀):
/// - `^+` → 绿底 `Color(0x1F22C55E)` + [AppColors.success] 字;
/// - `^-` → 红底 `Color(0x1FEF4444)` + [AppColors.danger] 字;
/// - `^@@` → [AppColors.accent] 字;
/// - `^diff|^index` → 元信息灰 ([ColorScheme.onSurfaceVariant]);
/// - 其余 (上下文行) → 默认前景色。
(Color?, Color?) _lineColors(String line, Color metaColor) {
  if (line.startsWith('+')) return (const Color(0x1F22C55E), AppColors.success);
  if (line.startsWith('-')) return (const Color(0x1FEF4444), AppColors.danger);
  if (line.startsWith('@@')) return (null, AppColors.accent);
  if (line.startsWith('diff') || line.startsWith('index')) {
    return (null, metaColor);
  }
  return (null, null);
}

/// diff patch 渲染 (纯函数组件, 可复用): 纵向单列表滚动, 超长行整体横向滚。
///
/// 行 Key = `Key('diff-line-<n>')` (按 `'\n'` 切分, 0 起; 测试定位用)。
Widget buildDiffView(String patch) {
  return Builder(
    builder: (context) {
      final lines = patch.split('\n');
      final metaColor = Theme.of(context).colorScheme.onSurfaceVariant;
      // 纵向外层 + 横向内层: 超长行不折行, 整列横向滚;
      // IntrinsicWidth + minWidth(屏宽) 保证短 patch 时底色条铺满屏宽。
      return SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: MediaQuery.sizeOf(context).width,
            ),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < lines.length; i++)
                    _DiffLine(line: lines[i], index: i, metaColor: metaColor),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _DiffLine extends StatelessWidget {
  final String line;
  final int index;
  final Color metaColor;

  const _DiffLine({
    required this.line,
    required this.index,
    required this.metaColor,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _lineColors(line, metaColor);
    return Container(
      key: Key('diff-line-$index'),
      color: bg,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 1,
      ),
      child: SelectableText(
        line.isEmpty ? ' ' : line,
        style: AppText.mono(context, size: AppTextSizes.monoSm, color: fg),
      ),
    );
  }
}
