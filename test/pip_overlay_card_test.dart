import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/core/services/pip_service.dart';
import 'package:zcode_app/shared/theme/app_design_tokens.dart';
import 'package:zcode_app/shared/widgets/pip_overlay_card.dart';

// ================================================================
// 悬浮窗进度监视器 widget 测试
// 注入 snapshotStream / onSend / onClose, 不触碰插件平台通道。
// 注意: 运行中会话有呼吸动画 (无限), 全部用显式 pump, 不用 pumpAndSettle。
// ================================================================

PipSessionSnapshot _session({
  required String key,
  String title = '会话',
  bool running = true,
  bool error = false,
  List<String> lines = const <String>[],
}) {
  return PipSessionSnapshot(
    key: key,
    title: title,
    running: running,
    error: error,
    lines: lines,
  );
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required StreamController<dynamic> controller,
  required void Function(String) onSend,
  required Size size,
  required List<PipSessionSnapshot> sessions,
  int index = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox.fromSize(
            size: size,
            child: PipOverlayCard(
              snapshotStream: controller.stream,
              onSend: onSend,
              onClose: () async {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // initState: 回传 refresh + 订阅
  controller.add(
    jsonEncode(PipSnapshot(v: 1, index: index, sessions: sessions).toJson()),
  );
  await tester.pump(); // 应用快照
  await tester.pump(const Duration(milliseconds: 50)); // postFrame 跳底
}

void main() {
  test('pipLinesFromPref: 空/损坏/越界回落默认 4', () {
    expect(pipLinesFromPref(null), pipDefaultLines);
    expect(pipLinesFromPref('abc'), pipDefaultLines);
    expect(pipLinesFromPref(0), pipDefaultLines);
    expect(pipLinesFromPref(99), pipDefaultLines);
    expect(pipLinesFromPref(1), 1);
    expect(pipLinesFromPref(7), 7);
    expect(pipLinesFromPref(10), 10);
    expect(pipLinesFromPref('5'), 5);
  });

  testWidgets('启动即回传 refresh 动作 (防白屏)', (tester) async {
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: sent.add,
      size: Size(320, pipWindowHeight(4)),
      sessions: const <PipSessionSnapshot>[],
    );

    expect(sent, isNotEmpty);
    expect(sent.first, jsonEncode(<String, dynamic>{'action': 'refresh'}));
  });

  testWidgets('双会话快照渲染 + 左右滑动切换 + 页码指示', (tester) async {
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: sent.add,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(
          key: 'task-a',
          title: '任务Alpha',
          lines: <String>['alpha-line-1'],
        ),
        _session(
          key: 'task-b',
          title: '任务Beta',
          lines: <String>['beta-line-1'],
        ),
      ],
    );

    // 第 1 页可见: 标题 + 页码 + 内容
    expect(find.text('任务Alpha'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('alpha-line-1'), findsOneWidget);
    // PageView 只构建当前页, 第 2 页标题不可见
    expect(find.text('任务Beta'), findsNothing);

    // 左滑 → 第 2 页
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('任务Beta'), findsOneWidget);
    expect(find.text('beta-line-1'), findsOneWidget);
  });

  testWidgets('视口行数生效: N=2 时正文视口恰好 2 行高, 初始停最底部', (tester) async {
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: (_) {},
      // pipWindowHeight(2) = 88 + 2*20 = 128 → 标题栏 44 + 页码条 24 → 正文 40 = 2 行
      size: Size(320, pipWindowHeight(2)),
      sessions: <PipSessionSnapshot>[
        _session(
          key: 'task-a',
          title: '任务Alpha',
          lines: <String>['line-1', 'line-2', 'line-3', 'line-4', 'line-5'],
        ),
      ],
    );

    final scrollableFinder = find.descendant(
      of: find.byType(PageView),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scrollableFinder, findsOneWidget);

    // 视口高度 = 2 行 * 20px
    final scrollable = tester.getSize(scrollableFinder);
    expect(scrollable.height, moreOrLessEquals(pipLineExtent * 2));

    // 初始停在最底部: line-5 行盒在视口第 2 行, line-1 行盒完全在视口上方
    // (量行 SizedBox 而非 Text: Align 居中会让 Text 顶部偏移 (20-11)/2)
    Finder rowBox(String text) => find
        .ancestor(of: find.text(text), matching: find.byType(SizedBox))
        .first;
    final bodyTop = tester.getTopLeft(scrollableFinder).dy;
    final line5Top = tester.getTopLeft(rowBox('line-5')).dy;
    final line1Top = tester.getTopLeft(rowBox('line-1')).dy;
    expect(line5Top - bodyTop, moreOrLessEquals(pipLineExtent));
    expect(line1Top - bodyTop, lessThan(0));

    // 完整缓冲仍在 (向上滑可看历史): 5 行都在树里
    expect(find.text('line-3'), findsOneWidget);
  });

  testWidgets('状态点: 运行中 accent / 完成 success / 出错 danger', (tester) async {
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    Future<Color> dotColor(PipSessionSnapshot session) async {
      await _pumpCard(
        tester,
        controller: controller,
        onSend: (_) {},
        size: Size(320, pipWindowHeight(2)),
        sessions: <PipSessionSnapshot>[session],
      );
      final container = tester.widget<Container>(
        find.byKey(ValueKey('pip-dot-${session.key}')),
      );
      return (container.decoration! as BoxDecoration).color!;
    }

    expect(
      await dotColor(_session(key: 'k-running', title: '运行中', running: true)),
      AppColors.accent,
    );
    expect(
      await dotColor(_session(key: 'k-done', title: '已完成', running: false)),
      AppColors.success,
    );
    expect(
      await dotColor(
        _session(key: 'k-error', title: '出错', running: false, error: true),
      ),
      AppColors.danger,
    );
  });

  testWidgets('空态: 无会话显示"暂无进行中会话"', (tester) async {
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: (_) {},
      size: Size(320, pipWindowHeight(4)),
      sessions: const <PipSessionSnapshot>[],
    );

    expect(find.text('暂无进行中会话'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('轻点某页回传 {"action":"open","key":...} JSON', (tester) async {
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: sent.add,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(
          key: 'task-a',
          title: '任务Alpha',
          lines: <String>['alpha-line-1', 'alpha-line-2'],
        ),
        _session(key: 'task-b', title: '任务Beta'),
      ],
    );

    // 轻点第 1 页正文 (非拖动/滑动)
    await tester.tap(find.text('alpha-line-2'));
    await tester.pump();

    final last = jsonDecode(sent.last) as Map<String, dynamic>;
    expect(last['action'], 'open');
    expect(last['key'], 'task-a');
  });

  testWidgets('集合变化: index 夹紧到合法范围 (2 页 → 1 页停在第 1 页)', (tester) async {
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: sent.add,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha'),
        _session(key: 'task-b', title: '任务Beta'),
      ],
      index: 1, // 假设停在第 2 页
    );
    // 先滑到第 2 页再让集合缩到 1 页 → index 夹紧
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2/2'), findsOneWidget);

    controller.add(
      jsonEncode(
        PipSnapshot(
          v: 1,
          index: 0,
          sessions: <PipSessionSnapshot>[
            _session(key: 'task-a', title: '任务Alpha'),
          ],
        ).toJson(),
      ),
    );
    await tester.pump();

    expect(find.text('1/1'), findsOneWidget);
  });
}
