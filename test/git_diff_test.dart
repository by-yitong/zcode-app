// test/git_diff_test.dart
// Task 4: buildDiffView 行级着色 (+绿 / −红 / @@accent / diff|index 灰)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/features/git/widgets/git_diff_view.dart';
import 'package:zcode_app/shared/theme/app_design_tokens.dart';

const _patch = 'diff --git a/a.dart b/a.dart\n' // 0
    'index 1234567..89abcde 100644\n' // 1
    '--- a/a.dart\n' // 2
    '+++ b/a.dart\n' // 3
    '@@ -1,2 +1,3 @@\n' // 4
    ' context\n' // 5
    '+added line\n' // 6
    '-removed line\n'; // 7

/// 同一 context 树下的元信息灰色 (diff/index 行预期用 onSurfaceVariant)。
Color _metaGray = Colors.transparent;

Future<void> pumpDiff(WidgetTester tester) async {
  _metaGray = Colors.transparent;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            _metaGray = Theme.of(context).colorScheme.onSurfaceVariant;
            return buildDiffView(_patch);
          },
        ),
      ),
    ),
  );
  await tester.pump();
}

Container _lineContainer(WidgetTester tester, int i) =>
    tester.widget<Container>(find.byKey(Key('diff-line-$i')));

SelectableText _lineText(WidgetTester tester, int i) =>
    tester.widget<SelectableText>(
      find.descendant(
        of: find.byKey(Key('diff-line-$i')),
        matching: find.byType(SelectableText),
      ),
    );

void main() {
  testWidgets('+ 行: 绿底 + success 绿字', (tester) async {
    await pumpDiff(tester);
    expect(_lineContainer(tester, 6).color, const Color(0x1F22C55E));
    expect(_lineText(tester, 6).style?.color, AppColors.success);
  });

  testWidgets('- 行: 红底 + danger 红字', (tester) async {
    await pumpDiff(tester);
    expect(_lineContainer(tester, 7).color, const Color(0x1FEF4444));
    expect(_lineText(tester, 7).style?.color, AppColors.danger);
  });

  testWidgets('@@ hunk 行: accent 蓝字, 无底色', (tester) async {
    await pumpDiff(tester);
    expect(_lineContainer(tester, 4).color, isNull);
    expect(_lineText(tester, 4).style?.color, AppColors.accent);
  });

  testWidgets('diff / index / 文件头(+++/---) 元信息行: 灰字', (tester) async {
    await pumpDiff(tester);
    expect(_lineText(tester, 0).style?.color, _metaGray);
    expect(_lineText(tester, 1).style?.color, _metaGray);
    // 文件头行不命中 +/- 增删色: 灰字且无绿/红底 (spec §3.1 文件头灰字)。
    expect(_lineText(tester, 2).style?.color, _metaGray); // --- a/a.dart
    expect(_lineContainer(tester, 2).color, isNull);
    expect(_lineText(tester, 3).style?.color, _metaGray); // +++ b/a.dart
    expect(_lineContainer(tester, 3).color, isNull);
  });
}
