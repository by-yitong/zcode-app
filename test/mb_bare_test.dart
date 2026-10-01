import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:zcode_app/features/chat/widgets/message_bubble.dart';
import 'package:zcode_app/providers/chat_provider.dart';

void main() {
  testWidgets('裸 MessageBubble 渲染表格探针', (tester) async {
    final table =
        '| A | B | C | D | E | F |\n|---|---|---|---|---|---|\n'
        '| 1 | 2 | 3 | 4 | 5 | 6 |\n';
    final msg = DisplayMessage(
      id: 'm1',
      role: 'assistant',
      content: table,
      parts: [TextPart(table)],
      createdAt: DateTime(2026, 9, 29),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageBubble(
                message: msg,
                theme: ThemeData.light(),
                isLastUserMessage: false,
                isResponding: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    debugPrint(
      '=== bare: MD=${find.byType(GptMarkdown).evaluate().length} '
      'Tbl=${find.byType(Table).evaluate().length} '
      'HSV=${find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal).evaluate().length}',
    );
    expect(true, isTrue);
  });
}
