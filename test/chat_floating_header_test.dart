// 聊天页三段式悬浮胶囊 Header + 上下文用量弹窗"压缩"按钮 widget 测试。
// (不跑 golden; 只验结构存在性与回调触发)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/features/chat/widgets/chat_floating_header.dart';
import 'package:zcode_app/features/chat/widgets/composer.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('三段独立胶囊 (左返回 / 中标题+状态行 / 右更多)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: ChatFloatingHeader(
            title: '工作区',
            contextIndicator: const ContextLengthIndicator(
              usage: (input: 1200, output: 300, max: 128000),
            ),
            usagePill: const Text('QUOTA_PILL'),
            onMenuTap: () {},
            onNewChat: () {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );

    expect(find.byType(ChatFloatingHeader), findsOneWidget);
    // 三段胶囊各自存在
    expect(find.byKey(const ValueKey('chatHeaderPillLeft')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatHeaderPillCenter')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatHeaderPillRight')), findsOneWidget);
    // 中间胶囊: 标题 + 上下文环 + 用量 pill
    expect(find.text('工作区'), findsOneWidget);
    expect(find.byType(ContextLengthIndicator), findsOneWidget);
    expect(find.text('QUOTA_PILL'), findsOneWidget);
  });

  testWidgets('左胶囊返回 → onMenuTap (打开会话抽屉)', (tester) async {
    var menuTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: ChatFloatingHeader(
            title: 't',
            onMenuTap: () => menuTaps++,
            onNewChat: () {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pump();
    expect(menuTaps, 1);
  });

  testWidgets('更多菜单: 新对话/设置触发回调; 非 Android 隐藏悬浮窗项', (tester) async {
    var newChats = 0;
    var settings = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: ChatFloatingHeader(
            title: 't',
            onMenuTap: () {},
            onNewChat: () => newChats++,
            onOpenPip: null, // 悬浮窗项应隐藏
            onOpenSettings: () => settings++,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('新对话'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('悬浮窗监视'), findsNothing);

    await tester.tap(find.text('新对话'));
    await tester.pumpAndSettle();
    expect(newChats, 1);
    expect(find.text('新对话'), findsNothing); // sheet 已关闭

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(settings, 1);
  });

  testWidgets('更多菜单: onOpenPip 非空时显示悬浮窗监视并触发', (tester) async {
    var pipTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: ChatFloatingHeader(
            title: 't',
            onMenuTap: () {},
            onNewChat: () {},
            onOpenPip: () => pipTaps++,
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('悬浮窗监视'), findsOneWidget);
    await tester.tap(find.text('悬浮窗监视'));
    await tester.pumpAndSettle();
    expect(pipTaps, 1);
  });

  testWidgets('上下文用量弹窗: 压缩按钮关闭弹窗并触发 onCompact', (tester) async {
    var compacted = false;
    await tester.pumpWidget(
      _wrap(
        ContextLengthIndicator(
          usage: (input: 1200, output: 300, max: 128000),
          onCompact: () => compacted = true,
        ),
      ),
    );

    await tester.tap(find.byType(ContextLengthIndicator));
    await tester.pumpAndSettle();
    expect(find.text('上下文用量'), findsOneWidget);
    expect(find.text('压缩'), findsOneWidget);

    await tester.tap(find.text('压缩'));
    await tester.pumpAndSettle();
    expect(compacted, isTrue);
    expect(find.text('上下文用量'), findsNothing); // 弹窗已关闭
  });

  testWidgets('onCompact 为 null → 压缩按钮隐藏', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const ContextLengthIndicator(
          usage: (input: 1200, output: 300, max: 128000),
        ),
      ),
    );
    await tester.tap(find.byType(ContextLengthIndicator));
    await tester.pumpAndSettle();
    expect(find.text('上下文用量'), findsOneWidget);
    expect(find.text('压缩'), findsNothing);
  });

  testWidgets('思考级别 chip 显示中文级别名并可选最高/中/不思考', (tester) async {
    var selected = '';
    await tester.pumpWidget(
      _wrap(ThoughtLevelSelector(level: 'max', onChanged: (l) => selected = l)),
    );
    // chip 本体显示中文
    expect(find.text('最高'), findsOneWidget);

    await tester.tap(find.byType(ThoughtLevelSelector));
    await tester.pumpAndSettle();
    // 菜单同样显示中文
    expect(find.text('不思考'), findsOneWidget);
    expect(find.text('中'), findsOneWidget);

    await tester.tap(find.text('不思考'));
    await tester.pumpAndSettle();
    expect(selected, 'nothink');
  });

  testWidgets('模型 chip: 有列表显示模型名 + 箭头; 空列表灰字默认禁点', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ModelSelector(
          models: const ['anthropic/claude-sonnet-4.6'],
          current: null,
          onSelected: (_) {},
        ),
      ),
    );
    expect(find.text('claude-sonnet-4.6'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

    // 空列表 + 非加载 → "默认" + 禁点 (点了不弹 sheet)
    await tester.pumpWidget(
      _wrap(ModelSelector(models: const [], current: null, onSelected: (_) {})),
    );
    expect(find.text('默认'), findsOneWidget);
    await tester.tap(find.text('默认'));
    await tester.pumpAndSettle();
    expect(find.text('选择模型'), findsNothing);
  });
}
