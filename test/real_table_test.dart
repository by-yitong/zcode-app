import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/features/chat/widgets/message_bubble.dart';
import 'package:zcode_app/providers/chat_provider.dart';

void main() {
  testWidgets('分块 TextPart (wire 流式切碎) 合并后表格可渲染可滚', (tester) async {
    // wire 形态: 表头+分隔行一段, 数据行另一段 — 单段无完整表格结构。
    // (旧拆分器 splitMarkdownByTables 已随迁移删除: gpt_markdown 默认表格
    //  自带横向滚动, 整段一次渲染, 拆分器无存在必要。)
    const part1 =
        '| 订单号 | 下单时间 | 客户姓名 | 商品名称 | 数量 | 单价(元) | 总金额(元) | 支付方式 | 配送方式 | 订单状态 |\n'
        '|--------|----------|----------|----------|------|-----------|-------------|----------|----------|----------|\n';
    const part2 = '| A20260929001 | 2026-09-29 09:15 | 张三 | 机械键盘 | 1 | '
        '399.00 | 399.00 | 微信支付 | 顺丰速运 | 已发货 |\n'
        '| A20260929002 | 2026-09-29 10:32 | 李四 | 显示器 | 2 | 1299.00 | '
        '2598.00 | 支付宝 | 京东物流 | 待发货 |\n';

    // 数据层回归: 连续 text 增量必须合并 (表格不被切断的根)
    final msg = DisplayMessage(
      id: 'm1',
      role: 'assistant',
      content: part1 + part2,
      parts: const [TextPart(part1 + part2)],
      createdAt: DateTime(2026, 9, 29),
    );
    // 数据层回归: 连续 text 增量必须合并 (表格不被切断的根)
    final merged = <MessagePart>[];
    appendTextPart(merged, part1);
    appendTextPart(merged, part2);
    expect(merged.length, 1, reason: '连续 text 增量应合并为单个 TextPart');
    expect((merged.single as TextPart).text, part1 + part2);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 380,
            child: MessageBubble(
              message: msg,
              theme: ThemeData.light(),
              isLastUserMessage: false,
              isResponding: false,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // 合并渲染 → 完整表格被解析成 Table 且包在横向滚动容器里
    expect(find.byType(Table), findsOneWidget);
    final hsvs = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((w) => w.scrollDirection == Axis.horizontal)
        .toList();
    expect(hsvs, isNotEmpty, reason: '表格应包在横向滚动容器里');
  });
}
