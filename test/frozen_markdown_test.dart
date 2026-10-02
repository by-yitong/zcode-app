// FrozenTailMarkdown 正确性测试:
// - 终态渲染与 AiMarkdown 单文档一致 (无重复/丢失内容);
// - 流式期间内容全部可见 (冻结前缀 + 尾段);
// - 代码围栏跨边界不被切断 (围栏奇偶保护);
// - 完成后接缝自愈 (哨兵只出现一次);
// - 静态消息 (isLive=false) 不进冻结路径。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/features/chat/widgets/frozen_markdown.dart';

const _ink = Color(0xFF111111);
const _bg = Color(0xFFEEEEEE);

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData.light(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// 树内所有文本的拼接 (Text + 独立 RichText; Text 内部的 RichText
/// 是同一内容, 跳过防重复计数)。
String _allText(WidgetTester tester) {
  final b = StringBuffer();
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    b.writeln(t.data ?? t.textSpan?.toPlainText() ?? '');
  }
  final standaloneRich = find
      .byType(RichText)
      .evaluate()
      .where((e) {
        var underText = false;
        e.visitAncestorElements((a) {
          if (a.widget is Text) {
            underText = true;
            return false;
          }
          return true;
        });
        return !underText;
      })
      .map((e) => e.widget as RichText);
  for (final r in standaloneRich) {
    b.writeln(r.text.toPlainText());
  }
  return b.toString();
}

void main() {
  testWidgets('终态: 与整段渲染等价, 不进冻结路径', (tester) async {
    const doc = '第一段文字内容甲。\n\n第二段文字内容乙。\n\n第三段文字内容丙。';
    await tester.pumpWidget(
      _host(
        const FrozenTailMarkdown(data: doc, isLive: false, ink: _ink, codeBg: _bg, maxTail: 40),
      ),
    );
    await tester.pump();
    final text = _allText(tester);
    expect(text, contains('第一段文字内容甲'));
    expect(text, contains('第三段文字内容丙'));
    // 无重复渲染 (哨兵恰好一次)
    expect('第二段文字内容乙'.allMatches(text).length, 1);
  });

  testWidgets('流式: 冻结前缀 + 尾段内容都可见', (tester) async {
    var doc = '开头段落, 哨兵一。\n\n';
    await tester.pumpWidget(
      _host(FrozenTailMarkdown(data: doc, isLive: true, ink: _ink, codeBg: _bg, maxTail: 40)),
    );
    await tester.pump();
    // 追加新段落 → 前一段被冻结, 新段是尾段
    doc += '流式中正在增长的尾段, 哨兵二。';
    await tester.pumpWidget(
      _host(FrozenTailMarkdown(data: doc, isLive: true, ink: _ink, codeBg: _bg, maxTail: 40)),
    );
    await tester.pump();
    final text = _allText(tester);
    expect(text, contains('哨兵一'));
    expect(text, contains('哨兵二'));
  });

  testWidgets('流式: 未闭合代码围栏跨空行不被切断', (tester) async {
    // 围栏内有空行: 朴素的 lastIndexOf('\n\n') 会切在围栏中间
    const doc = '围栏前的段落。\n\n```dart\nvoid a() {}\n\nvoid b() {}';
    await tester.pumpWidget(
      _host(const FrozenTailMarkdown(data: doc, isLive: true, ink: _ink, codeBg: _bg, maxTail: 40)),
    );
    await tester.pump();
    // 两个函数体都必须渲染出来 (围栏保持完整, 没被当普通段落拆开)
    final text = _allText(tester);
    expect(text, contains('void a() {}'));
    expect(text, contains('void b() {}'));
  });

  testWidgets('流式: 尾段首行是列表时边界回退, 列表不拆散', (tester) async {
    var doc = '正文段落甲。\n\n- 列表项一\n- 列表项二\n';
    await tester.pumpWidget(
      _host(FrozenTailMarkdown(data: doc, isLive: true, ink: _ink, codeBg: _bg, maxTail: 40)),
    );
    await tester.pump();
    // 追加一个普通段落: 新边界若落在列表后会拆散列表 — 应回退到列表前
    doc += '\n正文段落乙, 哨兵三。';
    await tester.pumpWidget(
      _host(FrozenTailMarkdown(data: doc, isLive: true, ink: _ink, codeBg: _bg, maxTail: 40)),
    );
    await tester.pump();
    final text = _allText(tester);
    expect(text, contains('列表项一'));
    expect(text, contains('列表项二'));
    expect(text, contains('哨兵三'));
    // 完成后整体自愈: 哨兵只出现一次
    await tester.pumpWidget(
      _host(FrozenTailMarkdown(data: doc, isLive: false, ink: _ink, codeBg: _bg, maxTail: 40)),
    );
    await tester.pump();
    expect('哨兵三'.allMatches(_allText(tester)).length, 1);
  });

  testWidgets('流式: 文本未变的 tick 原样复用 (无重建异常)', (tester) async {
    const doc = '稳定内容, 哨兵四。\n\n尾段内容, 哨兵五。';
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(
        _host(const FrozenTailMarkdown(data: doc, isLive: true, ink: _ink, codeBg: _bg, maxTail: 40)),
      );
      await tester.pump();
    }
    final text = _allText(tester);
    expect(text, contains('哨兵四'));
    expect(text, contains('哨兵五'));
  });

  testWidgets('流式: 非追加改写 (全量刷新) 冻结重置不串内容', (tester) async {
    var doc = '旧内容第一段。\n\n旧内容第二段。';
    await tester.pumpWidget(
      _host(FrozenTailMarkdown(data: doc, isLive: true, ink: _ink, codeBg: _bg, maxTail: 40)),
    );
    await tester.pump();
    // V4 快照整体替换: 内容完全不同
    doc = '全新内容第一段。\n\n全新内容第二段。';
    await tester.pumpWidget(
      _host(FrozenTailMarkdown(data: doc, isLive: true, ink: _ink, codeBg: _bg, maxTail: 40)),
    );
    await tester.pump();
    final text = _allText(tester);
    expect(text, contains('全新内容第一段'));
    expect(text, contains('全新内容第二段'));
    expect(text, isNot(contains('旧内容')));
  });
}
