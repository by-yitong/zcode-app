import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/shared/widgets/ai_markdown.dart';

/// 迁移到 gpt_markdown 后的宽表验收:
/// 10 列中文表格在 360 逻辑像素宽视口下必须可以横向拖动
/// (包默认表格视口 maxScrollExtent > 0, 拖拽后 pixels 增加)。
void main() {
  const wideTable = '| 订单号 | 下单时间 | 客户姓名 | 商品名称 | 数量 | 单价(元) | 总金额(元) | 支付方式 | 配送方式 | 订单状态 |\n'
      '|--------|----------|----------|----------|------|-----------|-------------|----------|----------|----------|\n'
      '| A001 | 09:15 | 张三 | 机械键盘 | 1 | 399 | 399 | 微信 | 顺丰 | 已发货 |\n'
      '| A002 | 10:32 | 李四 | 显示器 | 2 | 1299 | 2598 | 支付宝 | 京东 | 待发货 |\n';

  testWidgets('10列中文宽表: 360 逻辑像素视口 maxScrollExtent>0 且拖动可滚',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0; // → 360 x 780 逻辑像素
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: const AiMarkdown(
              data: wideTable,
              ink: Color(0xFF111111),
              codeBg: Color(0xFFEEEEEE),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Table), findsOneWidget);

    final hStates = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((w) => w.scrollDirection == Axis.horizontal)
        .map((w) => tester.state<ScrollableState>(find.descendant(
              of: find.byWidget(w),
              matching: find.byType(Scrollable),
            ).first))
        .toList();
    expect(hStates, isNotEmpty, reason: '表格应包在横向滚动容器里');
    final target = hStates.firstWhere((s) => s.position.maxScrollExtent > 0);
    expect(target.position.maxScrollExtent, greaterThan(0),
        reason: '10 列中文表在 360 宽视口下必然超宽');

    // 模拟真机触摸: 分步移动, 帧间等待
    final before = target.position.pixels;
    final topLeft = tester.getTopLeft(find.byType(Table).first);
    final gesture = await tester.startGesture(
      topLeft + const Offset(40, 10),
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

    expect(target.position.pixels, greaterThan(before),
        reason: '拖动后 pixels 应增加 (宽表可滚)');
  });
}
