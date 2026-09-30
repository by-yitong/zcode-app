import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/shared/widgets/ai_markdown.dart';

/// AiMarkdown 冒烟测试 (取代旧 chatMarkdownStyleSheet 冒烟测试):
/// 用覆盖全部块级/内联元素的 markdown 过一遍全量样式, 确认无空断言崩溃,
/// 关键内容可见, 表格走包默认渲染 (Table + 横向滚动容器)。
void main() {
  testWidgets('AiMarkdown 全量样式渲染全部块级/内联元素', (tester) async {
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

```dart
代码块
second line
```
''';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: AiMarkdown(
              data: sample,
              ink: Colors.white,
              codeBg: Colors.black26,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AiMarkdown), findsOneWidget);
    expect(find.text('H1 标题'), findsOneWidget);
    expect(find.text('H2 标题'), findsOneWidget);
    expect(find.textContaining('引用块内容'), findsOneWidget);
    expect(find.textContaining('无序列表项'), findsOneWidget);
    // 表格走包默认路径: Table + 横向滚动
    expect(find.byType(Table), findsOneWidget);
  });

  testWidgets('AiMarkdown minimal 模式 (用户气泡形态) 渲染正文与行内代码', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiMarkdown(
            data: '含 `代码` 的白字正文',
            ink: Colors.white,
            codeBg: Colors.black26,
            minimal: true,
            bodyStyle: TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 段落渲染为 RichText 子类, 需 findRichText: true
    expect(find.textContaining('含', findRichText: true), findsOneWidget);
    expect(find.textContaining('代码', findRichText: true), findsOneWidget);
  });
}
