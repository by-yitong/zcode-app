import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:zcode_app/features/chat/widgets/message_bubble.dart';
import 'package:zcode_app/providers/chat_provider.dart';

const _table = '| 订单号 | 下单时间 | 客户姓名 | 商品名称 | 数量 | 单价(元) | 总金额(元) | 支付方式 | 配送方式 | 订单状态 |\n'
    '|--------|----------|----------|----------|------|-----------|-------------|----------|----------|----------|\n'
    '| A001 | 09:15 | 张三 | 机械键盘 | 1 | 399 | 399 | 微信 | 顺丰 | 已发货 |\n'
    '| A002 | 10:32 | 李四 | 显示器 | 2 | 1299 | 2598 | 支付宝 | 京东 | 待发货 |\n';

Widget _bareTable() => const GptMarkdown(_table, isStreaming: false);

Widget _bubble(ThemeData theme) {
  final msg = DisplayMessage(
    id: 'm1',
    role: 'assistant',
    content: _table,
    parts: const [TextPart(_table)],
    createdAt: DateTime(2026, 9, 29),
  );
  return MessageBubble(
    message: msg,
    theme: theme,
    isLastUserMessage: false,
    isResponding: false,
  );
}

Future<double> _drag(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final hStates = tester
      .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
      .where((w) => w.scrollDirection == Axis.horizontal)
      .map((w) => tester.state<ScrollableState>(find.descendant(
            of: find.byWidget(w),
            matching: find.byType(Scrollable),
          ).first))
      .toList();
  final target = hStates.firstWhere((s) => s.position.maxScrollExtent > 0);
  final before = target.position.pixels;
  final topLeft = tester.getTopLeft(find.byType(Table).first);
  final gesture = await tester.startGesture(topLeft + const Offset(40, 10),
      kind: PointerDeviceKind.touch);
  await gesture.moveBy(const Offset(-40, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(const Offset(-80, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(const Offset(-80, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.up();
  await tester.pumpAndSettle();
  return target.position.pixels - before;
}

void main() {
  testWidgets('D4: MessageBubble + reverse+center 列表 (真机结构)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    const centerKey = Key('center');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          reverse: true,
          center: centerKey,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverPadding(
              key: centerKey,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _bubble(ThemeData.light()),
                  childCount: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    final delta = await _drag(tester);
    print('=== D4 气泡+reverse+center delta=$delta');
    expect(delta, greaterThan(0));
  });

  testWidgets('D5: 思考part在前 + 气泡 (WorkHistory 路径)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final msg = DisplayMessage(
      id: 'm1',
      role: 'assistant',
      content: _table,
      parts: const [
        ThoughtPart('先分析一下需求'),
        TextPart(_table),
      ],
      createdAt: DateTime(2026, 9, 29),
    );
    const centerKey = Key('center');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          reverse: true,
          center: centerKey,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverPadding(
              key: centerKey,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => MessageBubble(
                    message: msg,
                    theme: ThemeData.light(),
                    isLastUserMessage: false,
                    isResponding: false,
                  ),
                  childCount: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    final delta = await _drag(tester);
    print('=== D5 思考+表格 delta=$delta');
    expect(delta, greaterThan(0));
  });

  testWidgets('D1: 裸表格 + reverse+center 列表', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    const centerKey = Key('center');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          reverse: true,
          center: centerKey,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverPadding(
              key: centerKey,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _bareTable(),
                  childCount: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    final delta = await _drag(tester);
    print('=== D1 裸表+列表 delta=$delta');
    expect(delta, greaterThan(0));
  });

  testWidgets('D2: MessageBubble + 普通列表(无 reverse/center)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [_bubble(ThemeData.light())],
        ),
      ),
    ));
    final delta = await _drag(tester);
    print('=== D2 气泡+普通列表 delta=$delta');
    expect(delta, greaterThan(0));
  });

  testWidgets('D3: MessageBubble 无列表(裸 Align)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _bubble(ThemeData.light()),
          ),
        ),
      ),
    ));
    final delta = await _drag(tester);
    print('=== D3 气泡无列表 delta=$delta');
    expect(delta, greaterThan(0));
  });
}
