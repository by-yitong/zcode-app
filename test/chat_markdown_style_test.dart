import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/shared/theme/chat_markdown_style.dart';

/// chatMarkdownStyleSheet 冒烟测试:
/// 用覆盖全部块级/内联元素的 markdown 过一遍, 确认样式表无空断言崩溃。
void main() {
  testWidgets('chatMarkdownStyleSheet 渲染全部块级/内联元素', (tester) async {
    const sample = '''
# H1 标题
## H2 标题
### H3 标题
#### H4 标题
##### H5 标题
###### H6 标题

正文段落, 含 **粗体**、*斜体*、~~删除线~~、`行内代码` 和
[链接](https://example.com)。

- 无序列表项
- 第二项
  - 嵌套项

1. 有序列表
2. 第二项

> 引用块内容

---


| 列A | 列B |
| --- | --- |
| a1 | b1 |
| a2 | b2 |

```
代码块
second line
```
''';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBody(
              data: sample,
              styleSheet: chatMarkdownStyleSheet(
                ThemeData(brightness: Brightness.dark, useMaterial3: true),
                ink: Colors.white,
                codeBg: Colors.black26,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('H1 标题'), findsOneWidget);
    expect(find.text('H2 标题'), findsOneWidget);
    expect(find.textContaining('引用块内容'), findsOneWidget);
    expect(find.textContaining('无序列表项'), findsOneWidget);
    expect(find.textContaining('代码块'), findsWidgets);
  });
}
