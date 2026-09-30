import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/features/chat/widgets/message_bubble.dart';
import 'package:zcode_app/providers/chat_provider.dart';

const _table = '| 订单号 | 下单时间 | 客户姓名 | 商品名称 | 数量 | 单价(元) | 总金额(元) | 支付方式 | 配送方式 | 订单状态 |\n'
    '|--------|----------|----------|----------|------|-----------|-------------|----------|----------|----------|\n'
    '| A001 | 09:15 | 张三 | 机械键盘 | 1 | 399 | 399 | 微信 | 顺丰 | 已发货 |\n'
    '| A002 | 10:32 | 李四 | 显示器 | 2 | 1299 | 2598 | 支付宝 | 京东 | 待发货 |\n';

Future<double> _dragTable(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final hStates = tester
      .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
      .where((w) => w.scrollDirection == Axis.horizontal)
      .map((w) => tester.state<ScrollableState>(find.descendant(
            of: find.byWidget(w),
            matching: find.byType(Scrollable),
          ).first))
      .toList();
  final target = hStates.firstWhere(
      (s) => s.position.maxScrollExtent > 0,
      orElse: () => hStates.first);
  final before = target.position.pixels;
  // 起点必须在 HSV 视口可见区内: gpt_markdown 的 Table 渲染盒可超出
  // 裁剪边界, getCenter 会落在视口外导致手势无效
  final tableTopLeft = tester.getTopLeft(find.byType(Table).first);
  final gesture = await tester.startGesture(
    tableTopLeft + const Offset(40, 10),
    kind: PointerDeviceKind.touch,
  );
  await gesture.moveBy(const Offset(-40, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(const Offset(-80, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(const Offset(-80, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.up();
  await tester.pumpAndSettle();
  print('=== extent=${target.position.maxScrollExtent} before=$before after=${target.position.pixels}');
  return target.position.pixels - before;
}

Widget _bubble() {
  final msg = DisplayMessage(
    id: 'm1',
    role: 'assistant',
    content: _table,
    parts: const [TextPart(_table)],
    createdAt: DateTime(2026, 9, 29),
  );
  return MessageBubble(
    message: msg,
    theme: ThemeData.light(),
    isLastUserMessage: false,
    isResponding: false,
  );
}

void main() {
  testWidgets('A: 裸 Align+ConstrainedBox (对照, 预期可滚)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _bubble(),
          ),
        ),
      ),
    ));
    final delta = await _dragTable(tester);
    expect(delta, greaterThan(0));
  });

  testWidgets('B: 普通 CustomScrollView (无 reverse)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _bubble(),
                  childCount: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    final delta = await _dragTable(tester);
    expect(delta, greaterThan(0));
  });

  testWidgets('C: reverse CustomScrollView + center (真机结构)', (tester) async {
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
                  (context, index) => _bubble(),
                  childCount: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    final delta = await _dragTable(tester);
    expect(delta, greaterThan(0));
  });
}
