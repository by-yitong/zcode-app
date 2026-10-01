import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zcode_app/core/services/pip_service.dart';
import 'package:zcode_app/providers/chat_provider.dart';
import 'package:zcode_app/providers/pip_providers.dart';
import 'package:zcode_app/shared/theme/app_design_tokens.dart';
import 'package:zcode_app/shared/widgets/ai_markdown.dart';
import 'package:zcode_app/shared/widgets/pip_overlay_card.dart';

// ================================================================
// 悬浮窗进度监视器 widget 测试
// 注入 snapshotStream / onSend / onClose / pip, 不触碰插件平台通道
// (信箱测试用 SharedPreferences mock; IPC 契约 v3: session 载荷为 text
//  markdown 源文本, 无 refresh 动作)。
// 注意: 运行中会话有呼吸动画 (无限), 全部用显式 pump, 不用 pumpAndSettle。
// ================================================================

PipSessionSnapshot _session({
  required String key,
  String title = '会话',
  bool running = true,
  bool error = false,
  String text = '',
}) {
  return PipSessionSnapshot(
    key: key,
    title: title,
    running: running,
    error: error,
    text: text,
  );
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required StreamController<dynamic> controller,
  void Function(String)? onSend,
  PipService? pip,
  required Size size,
  required List<PipSessionSnapshot> sessions,
  int index = 0,
  bool collapsed = false,
  int? screenW,
  int? screenH,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox.fromSize(
            size: size,
            // 覆盖 MediaQuery 尺寸 = 窗口尺寸 (真机上悬浮窗引擎的 MediaQuery
            // 反映窗口自身; 收拢态 108×44 即由此判定宽<160 高<56 出胶囊)
            child: MediaQuery(
              data: MediaQueryData(size: size),
              child: PipOverlayCard(
                snapshotStream: controller.stream,
                onSend: onSend,
                onClose: () async {},
                pip: pip,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // initState: 订阅快照流
  controller.add(
    jsonEncode(
      PipSnapshot(
        v: 1,
        index: index,
        sessions: sessions,
        collapsed: collapsed,
        screenW: screenW,
        screenH: screenH,
      ).toJson(),
    ),
  );
  await tester.pump(); // 应用快照
  await tester.pump(const Duration(milliseconds: 50)); // postFrame 跳底
}

/// 正文段落渲染为 RichText 子类 (BidiRichText), 用 findRichText 定位
Finder _bodyText(String substring) =>
    find.textContaining(substring, findRichText: true);

/// 迭代式深度优先遍历 span 树 (流式 reveal 的 span 树可能很深, 不递归),
/// [test] 命中即停; 回调携带祖先是否加粗 (粗体样式常挂在父 span 上)
bool _visitSpans(
  InlineSpan? root,
  bool Function(TextSpan span, bool inheritedBold) test,
) {
  if (root == null) return false;
  final stack = <(InlineSpan, bool)>[(root, false)];
  while (stack.isNotEmpty) {
    final (span, inheritedBold) = stack.removeLast();
    if (span is! TextSpan) continue;
    final bold =
        inheritedBold ||
        (span.style?.fontWeight?.value ?? 0) >= FontWeight.w600.value;
    if (test(span, bold)) return true;
    final children = span.children;
    if (children == null) continue;
    for (final child in children) {
      stack.add((child, bold));
    }
  }
  return false;
}

/// 粗体渲染证据: 自身/祖先 ≥w600 字重的 span 直接持有 [needle] 文本
bool _spanTreeHasBold(InlineSpan span, String needle) => _visitSpans(
  span,
  (s, bold) => bold && s.text != null && s.text!.contains(needle),
);

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

  test('pipSizeStepFromPref: 空/损坏/越界回落默认 0', () {
    expect(pipSizeStepFromPref(null), 0);
    expect(pipSizeStepFromPref('abc'), 0);
    expect(pipSizeStepFromPref(-1), 0);
    expect(pipSizeStepFromPref(4), 0);
    expect(pipSizeStepFromPref(99), 0);
    expect(pipSizeStepFromPref(0), 0);
    expect(pipSizeStepFromPref(3), 3);
    expect(pipSizeStepFromPref('2'), 2);
  });

  test('尺寸档位: 宽度 fraction 与高度公式 (倍率 + 上下钳制)', () {
    // 宽度 fraction: 0 常规 0.84 → 3 超大 1.00
    expect(pipWindowWidthFractionForStep(0), 0.84);
    expect(pipWindowWidthFractionForStep(1), 0.92);
    expect(pipWindowWidthFractionForStep(2), 0.96);
    expect(pipWindowWidthFractionForStep(3), 1.0);
    // 高度 = 80 + 行数*20*倍率; 常规档与无档位公式一致
    expect(pipWindowHeightForStep(4, 0, 800), pipWindowHeight(4));
    expect(pipWindowHeightForStep(4, 1, 800), 80.0 + 4 * 20 * 3);
    // 超大档 80+4*20*9=800 超过屏高钳制 (800*0.9=720) → 取 720
    expect(pipWindowHeightForStep(4, 3, 800), 720.0);
    // 超高钳到屏高 dp*0.9 (80+10*20*9=1880 > 300*0.9=270)
    expect(pipWindowHeightForStep(10, 3, 300), 270.0);
    // 下限 80+20 (80+1*20*1=100 恰在下限)
    expect(pipWindowHeightForStep(1, 0, 800), 100.0);
  });

  test('IPC 动作契约 v4: home/size/collapse/expand/minimize 编解码', () {
    // 编码: 无载荷动作输出 {"action": "<名>"}
    expect(
      jsonDecode(encodePipAction(const PipHomeAction())) as Map<String, dynamic>,
      <String, dynamic>{'action': 'home'},
    );
    expect(
      jsonDecode(encodePipAction(const PipSizeAction())) as Map<String, dynamic>,
      <String, dynamic>{'action': 'size'},
    );
    expect(
      jsonDecode(encodePipAction(const PipCollapseAction()))
          as Map<String, dynamic>,
      <String, dynamic>{'action': 'collapse'},
    );
    expect(
      jsonDecode(encodePipAction(const PipMinimizeAction()))
          as Map<String, dynamic>,
      <String, dynamic>{'action': 'minimize'},
    );
    expect(
      jsonDecode(encodePipAction(const PipExpandAction())) as Map<String, dynamic>,
      <String, dynamic>{'action': 'expand'},
    );
    // pillMoved: 钳后胶囊左上角坐标 (逻辑 dp) 随载荷
    expect(
      jsonDecode(encodePipAction(const PipPillMovedAction(12.5, 34))) as Map<String, dynamic>,
      <String, dynamic>{'action': 'pillMoved', 'x': 12.5, 'y': 34.0},
    );
    // 解码回原类型; open 仍兼容
    expect(decodePipAction('{"action":"home"}'), isA<PipHomeAction>());
    expect(decodePipAction('{"action":"size"}'), isA<PipSizeAction>());
    expect(decodePipAction('{"action":"collapse"}'), isA<PipCollapseAction>());
    expect(decodePipAction('{"action":"minimize"}'), isA<PipMinimizeAction>());
    expect(decodePipAction('{"action":"expand"}'), isA<PipExpandAction>());
    expect(
      decodePipAction('{"action":"open","key":"k"}'),
      isA<PipOpenAction>(),
    );
    // pillMoved 解码: x/y 为 num (int/double 皆可) → double; 缺失/类型错 → null
    final moved = decodePipAction('{"action":"pillMoved","x":8,"y":40.5}');
    expect(moved, isA<PipPillMovedAction>());
    expect((moved as PipPillMovedAction).x, 8.0);
    expect(moved.y, 40.5);
    expect(decodePipAction('{"action":"pillMoved","y":2}'), isNull);
    expect(decodePipAction('{"action":"pillMoved","x":1}'), isNull);
    expect(decodePipAction('{"action":"pillMoved","x":"a","y":2}'), isNull);
    expect(decodePipAction('{"action":"pillMoved"}'), isNull);
    // 未知动作 / 非法 JSON → null
    expect(decodePipAction('{"action":"bogus"}'), isNull);
    expect(decodePipAction('not-json'), isNull);
  });

  test('IPC 契约 v3: session 载荷为 text 字段, 快照 JSON 不含 lines', () {
    const session = PipSessionSnapshot(
      key: 'k',
      title: 't',
      running: true,
      error: false,
      text: '**md** `code`',
    );
    final json = jsonEncode(
      const PipSnapshot(
        v: kPipSnapshotVersion,
        index: 1,
        sessions: [session],
      ).toJson(),
    );
    // v3 直接切换: 不再有序列化 lines
    expect(json.contains('"lines"'), isFalse);
    expect(json.contains('"text":"**md** `code`"'), isTrue);

    final decoded = PipSnapshot.decode(json);
    expect(decoded, isNotNull);
    expect(decoded!.index, 1);
    expect(decoded.sessions.single.key, 'k');
    expect(decoded.sessions.single.text, '**md** `code`');

    // text 缺失/类型错 → 空串; v 不符 → null; 非 JSON → null
    final missing = PipSnapshot.decode(
      '{"v":1,"index":0,"sessions":[{"key":"k","title":"t"}]}',
    );
    expect(missing!.sessions.single.text, '');
    expect(PipSnapshot.decode('{"v":2,"index":0,"sessions":[]}'), isNull);
    expect(PipSnapshot.decode('not-json'), isNull);
  });

  test('IPC 契约 v4.1: collapsed 字段编解码 (缺省 false 向后兼容)', () {
    // collapsed=true → 'co':true; false 不输出字段
    final collapsedJson = jsonEncode(
      const PipSnapshot(
        v: kPipSnapshotVersion,
        index: 0,
        sessions: [],
        collapsed: true,
      ).toJson(),
    );
    expect(collapsedJson.contains('"co":true'), isTrue);
    expect(PipSnapshot.decode(collapsedJson)!.collapsed, isTrue);
    // 旧格式 (无 co) → false
    expect(
      PipSnapshot.decode('{"v":1,"index":0,"sessions":[]}')!.collapsed,
      isFalse,
    );
    // false 不序列化字段
    final plainJson = jsonEncode(
      const PipSnapshot(
        v: kPipSnapshotVersion,
        index: 0,
        sessions: [],
      ).toJson(),
    );
    expect(plainJson.contains('"co"'), isFalse);
  });

  group('extractPipTailText (契约 v3 提取端)', () {
    DisplayMessage msg(String content) =>
        DisplayMessage(id: content, role: 'assistant', content: content);

    test('markdown 源文本原样保留 (不做单行/单字段截断)', () {
      const source = '# 标题\n\n**加粗** 与 `code` 行内代码';
      final text = extractPipTailText(
        ChatState(messages: [msg(source)]),
        running: true,
      );
      expect(text, source);
    });

    test('无 AI 文本: 运行中给状态占位, 非运行空串', () {
      expect(
        extractPipTailText(const ChatState(isResponding: true), running: true),
        '思考中…',
      );
      expect(extractPipTailText(const ChatState(), running: true), '运行中…');
      expect(extractPipTailText(const ChatState(), running: false), '');
    });

    test('尾部 60 逻辑行截断 (80 行 → 保留最后 60 行)', () {
      final lines = List<String>.generate(80, (i) => 'line-${i + 1}');
      final text = extractPipTailText(
        ChatState(messages: [msg(lines.join('\n'))]),
        running: false,
      );
      final got = text.split('\n');
      expect(got.length, pipBufferLines);
      expect(got.first, 'line-21');
      expect(got.last, 'line-80');
    });

    test('跨消息补足: 最多跨 3 条 assistant 消息, 更早的忽略', () {
      final text = extractPipTailText(
        ChatState(
          messages: [
            msg('old-1\nold-2'), // 第 4 旧消息, 应被忽略
            msg('m1-1\nm1-2'),
            msg('m2-1\nm2-2'),
            msg('m3-1\nm3-2'),
          ],
        ),
        running: false,
      );
      expect(text, 'm1-1\nm1-2\nm2-1\nm2-2\nm3-1\nm3-2');
      expect(text.contains('old-'), isFalse);
    });

    test('≤4000 字符截断 (从头部截掉, 保留尾部原文)', () {
      final lines = List<String>.generate(
        100,
        (i) => List.filled(100, 'a${i % 10}').join(),
      );
      final source = lines.join('\n');
      expect(source.length, greaterThan(pipMaxTextChars));
      final text = extractPipTailText(
        ChatState(messages: [msg(source)]),
        running: false,
      );
      expect(text.length, pipMaxTextChars);
      expect(source.endsWith(text), isTrue);
    });
  });

  testWidgets('home 钮写入 SharedPreferences 信箱 (默认通道): pip.action = open JSON', (
    tester,
  ) async {
    // 默认回传通道走 SharedPreferences 信箱 (IPC 契约 v2/v3), 用 mock prefs 验证
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', text: 'alpha-line-1'),
      ],
    );

    // 点标题栏 home 钮 (正文单点已不再回跳) → _defaultSend 写信箱
    await tester.tap(find.byTooltip('返回应用'));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kPipActionPrefKey);
    expect(raw, isNotNull);
    expect(jsonDecode(raw!) as Map<String, dynamic>, <String, dynamic>{
      'action': 'open',
      'key': 'task-a',
    });
  });

  testWidgets('home 钮: 有会话回传 open 携带当前页 key (注入通道)', (tester) async {
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
          text: 'alpha-line-1\n\nalpha-line-2',
        ),
        _session(key: 'task-b', title: '任务Beta'),
      ],
    );
    await tester.tap(find.byTooltip('返回应用'));
    await tester.pump();
    final last = jsonDecode(sent.last) as Map<String, dynamic>;
    expect(last['action'], 'open');
    expect(last['key'], 'task-a');

    // 最小化钮 (home 左) → minimize 动作 (手动收拢为顶部胶囊)
    await tester.tap(find.byTooltip('最小化'));
    await tester.pump();
    expect(
      jsonDecode(sent.last) as Map<String, dynamic>,
      <String, dynamic>{'action': 'minimize'},
    );
  });

  // 空态单独一个用例: 同一 testWidgets 内二次 pumpWidget 换流注入会被
  // Element 复用吞掉 (State 不重建, 旧 stream 订阅仍在), 拆开才各自纯净
  testWidgets('home 钮: 空态回传 home 仅回前台 (注入通道)', (tester) async {
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
    await tester.tap(find.byTooltip('返回应用'));
    await tester.pump();
    expect(
      jsonDecode(sent.last) as Map<String, dynamic>,
      <String, dynamic>{'action': 'home'},
    );
  });

  testWidgets('正文单点不回传任何动作, 双击回传 size (注入通道)', (tester) async {
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: sent.add,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', text: 'alpha-line-1'),
      ],
    );

    // 单点正文: 无 onTap (回跳已改由 home 钮), 不发任何动作
    await tester.tap(_bodyText('alpha-line-1'));
    await tester.pump();
    expect(sent, isEmpty, reason: '正文单点不再回传 open');

    // 双击正文 (两次 tap 间隔 ≥ kDoubleTapMinTime) → size 动作
    await tester.tap(_bodyText('alpha-line-1'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(_bodyText('alpha-line-1'));
    await tester.pump();
    expect(sent, hasLength(1));
    expect(
      jsonDecode(sent.last) as Map<String, dynamic>,
      <String, dynamic>{'action': 'size'},
    );
    // 泵过双击识别器的 kDoubleTapTimeout Timer, 否则用例结束留 pending timer
    await tester.pump(const Duration(milliseconds: 350));
  });

  testWidgets('收拢态: 108×44 顶部胶囊渲染 (无标题栏/正文), 点击回传 expand', (tester) async {
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: sent.add,
      // 窗口被主 App resize 成 108×44 (顶部胶囊) → 宽<160 且高<56 → 收拢态
      size: const Size(108, 44),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', running: true, text: 'x'),
      ],
    );

    // 出胶囊 (状态点 + 会话标题), 不出标题栏/正文/页码结构
    expect(find.byKey(const ValueKey('pip-collapsed-pill')), findsOneWidget);
    expect(find.byTooltip('关闭悬浮窗'), findsNothing);
    expect(find.byTooltip('返回应用'), findsNothing);
    expect(find.byType(PageView), findsNothing);
    expect(find.text('任务Alpha'), findsOneWidget);

    // 点胶囊 → expand 动作 (主 App resize 回档位尺寸 + move 回记忆位置)
    await tester.tap(find.byKey(const ValueKey('pip-collapsed-pill')));
    await tester.pump();
    expect(sent, hasLength(1));
    expect(
      jsonDecode(sent.last) as Map<String, dynamic>,
      <String, dynamic>{'action': 'expand'},
    );
  });

  // 真机实测: resize 后悬浮窗引擎 MediaQuery 可能不刷新 (窗口 108×44 而
  // MediaQuery 仍报展开尺寸) → 完整卡被裁成一条缝。收拢渲染必须由快照
  // collapsed 字段驱动, 窗口尺寸判定只作兜底。
  testWidgets('快照 collapsed=true + 窗口尺寸未刷新 (仍展开尺寸) → 照样渲染胶囊', (
    tester,
  ) async {
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      onSend: sent.add,
      // MediaQuery 故意保持展开态尺寸 (模拟 resize 未传播)
      size: const Size(320, 160),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', running: true, text: 'x'),
      ],
      collapsed: true,
    );

    expect(find.byKey(const ValueKey('pip-collapsed-pill')), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    expect(find.text('任务Alpha'), findsOneWidget);
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
        _session(key: 'task-a', title: '任务Alpha', text: 'alpha-line-1'),
        _session(key: 'task-b', title: '任务Beta', text: 'beta-line-1'),
      ],
    );

    // 第 1 页可见: 标题 + 页码 + 内容
    expect(find.text('任务Alpha'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(_bodyText('alpha-line-1'), findsOneWidget);
    // PageView 只构建当前页, 第 2 页标题不可见
    expect(find.text('任务Beta'), findsNothing);

    // 左滑 → 第 2 页
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('任务Beta'), findsOneWidget);
    expect(_bodyText('beta-line-1'), findsOneWidget);
  });

  testWidgets('内容区 markdown 渲染: 粗体/行内代码/标题, 标记不落屏', (tester) async {
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      size: Size(320, pipWindowHeight(6)),
      sessions: <PipSessionSnapshot>[
        _session(
          key: 'task-a',
          title: '任务Alpha',
          running: true,
          text: '## 进度标题\n\n**加粗内容** 与 `inline_code` 行内代码混排',
        ),
      ],
    );

    // 标题降为小号基准但仍走标题渲染
    expect(find.text('进度标题'), findsOneWidget);
    // 段落文本可见, markdown 标记 (** 和 `) 不落屏
    expect(_bodyText('加粗内容'), findsOneWidget);
    expect(_bodyText('inline_code'), findsOneWidget);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('`', findRichText: true), findsNothing);

    // 粗体证据: 段落 (BidiRichText, RichText 子类) span 树中含目标文本且 ≥w600 字重
    final richTexts = tester.widgetList<RichText>(
      find.byWidgetPredicate((w) => w is RichText),
    );
    RichText? paragraph;
    for (final r in richTexts) {
      if (_visitSpans(
        r.text,
        (s, _) => s.text != null && s.text!.contains('加粗内容'),
      )) {
        paragraph = r;
        break;
      }
    }
    expect(paragraph, isNotNull, reason: '找到含正文的段落 RichText');
    expect(_spanTreeHasBold(paragraph!.text, '加粗内容'), isTrue);
    // 行内代码证据: 包级 CodeTextSpan 存在, 且 chip 底色走悬浮窗深色 codeBg
    CodeTextSpan? codeSpan;
    _visitSpans(paragraph.text, (s, _) {
      if (s is CodeTextSpan && s.text == 'inline_code') {
        codeSpan = s;
        return true;
      }
      return false;
    });
    expect(codeSpan, isNotNull, reason: '行内代码渲染为 CodeTextSpan');
    expect(codeSpan!.codeStyle.backgroundColor, AppColors.darkSurfaceHigh);

    // 流式期间 isStreaming 接该会话 running 态; 字号比主 App 档小一号 (bodySm)
    expect(
      tester.widget<AiMarkdown>(find.byType(AiMarkdown)).isStreaming,
      isTrue,
    );
    expect(
      tester.widget<GptMarkdown>(find.byType(GptMarkdown)).style?.fontSize,
      AppTextSizes.bodySm,
    );
  });

  testWidgets('完成会话 isStreaming=false', (tester) async {
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-done', title: '已完成', running: false, text: 'done'),
      ],
    );

    expect(
      tester.widget<AiMarkdown>(find.byType(AiMarkdown)).isStreaming,
      isFalse,
    );
  });

  testWidgets('视口行数生效: N=2 时正文视口恰好 2 行高, 初始停最底部', (tester) async {
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    // 多段 markdown (6 段 > 2 行视口, 保证可滚动)
    final text = List.generate(6, (i) => '第${i + 1}段内容').join('\n\n');
    await _pumpCard(
      tester,
      controller: controller,
      // pipWindowHeight(2) = 80 + 2*20 = 120 → 标题栏 36 + 页码条 24 → 正文 40 = 2 行
      size: Size(320, pipWindowHeight(2)),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', running: false, text: text),
      ],
    );

    final scrollableFinder = find.descendant(
      of: find.byType(PageView),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scrollableFinder, findsOneWidget);

    // 视口高度 = 2 行 * 20px (行高系数仅决定窗口高度, 实际行高由 markdown 布局)
    final scrollable = tester.getSize(scrollableFinder);
    expect(scrollable.height, moreOrLessEquals(pipLineExtent * 2));

    // 初始停在最底部 (markdown 整体重建, postFrame 跳 maxScrollExtent)
    final view = tester.widget<SingleChildScrollView>(scrollableFinder);
    final controller2 = view.controller!;
    expect(controller2.position.maxScrollExtent, greaterThan(0));
    expect(
      controller2.position.pixels,
      moreOrLessEquals(controller2.position.maxScrollExtent),
    );

    // 完整缓冲仍在 (向上滑可看历史): 首段仍在树里
    expect(_bodyText('第1段内容'), findsOneWidget);
    expect(_bodyText('第6段内容'), findsOneWidget);
  });

  testWidgets('状态点: 运行中 accent / 完成 success / 出错 danger', (tester) async {
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    Future<Color> dotColor(PipSessionSnapshot session) async {
      await _pumpCard(
        tester,
        controller: controller,
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
      size: Size(320, pipWindowHeight(4)),
      sessions: const <PipSessionSnapshot>[],
    );

    expect(find.text('暂无进行中会话'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    // 空态必须保留标题栏 (拖动手柄 + X 关闭 + 中性灰点), 不能整树替换
    expect(find.text('ZCode'), findsOneWidget, reason: '空态标题栏标题');
    expect(find.byTooltip('关闭悬浮窗'), findsOneWidget, reason: '空态 X 关闭在');
    expect(find.byKey(const ValueKey('pip-dot-empty')), findsOneWidget);
    expect(find.text('1/1'), findsNothing, reason: '空态无页码指示');
  });

  testWidgets('内容→空 防抖: 1.5s 内来新内容不闪空态, 超时才真正切空', (tester) async {
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', running: true, text: 'v1'),
      ],
    );
    expect(find.text('任务Alpha'), findsOneWidget);

    // 推空快照 → 防抖挂起, 内容仍在
    controller.add(
      jsonEncode(const PipSnapshot(v: 1, index: 0, sessions: []).toJson()),
    );
    await tester.pump();
    expect(find.text('任务Alpha'), findsOneWidget, reason: '防抖期内不切空态');

    // 防抖期内新内容到达 → 取消防抖, 立即应用 (会话状态翻转不闪空)
    controller.add(
      jsonEncode(
        PipSnapshot(
          v: 1,
          index: 0,
          sessions: [
            _session(
              key: 'task-a',
              title: '任务Alpha',
              running: true,
              text: 'v2',
            ),
          ],
        ).toJson(),
      ),
    );
    await tester.pump();
    expect(find.text('v2'), findsOneWidget, reason: '新内容立即应用, 防抖取消');

    // 再次推空 → 1.5s 内不切, 超时后真正进入空态
    controller.add(
      jsonEncode(const PipSnapshot(v: 1, index: 0, sessions: []).toJson()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('任务Alpha'), findsOneWidget, reason: '防抖窗口内维持内容');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('暂无进行中会话'), findsOneWidget, reason: '超时后切空态');
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

  testWidgets('拖动中冻结快照重建, 松手后一次性应用', (tester) async {
    final pip = _FakePipService();
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      pip: pip,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', running: true, text: '旧内容v1'),
      ],
    );

    // 按住标题栏拖动 (进入 _dragging, 冻结 rebuild)
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('任务Alpha')),
    );
    await gesture.moveBy(const Offset(20, 10));
    await tester.pump();

    // 拖动中推送新快照 → 挂起不应用 (旧内容仍在屏)
    controller.add(
      jsonEncode(
        PipSnapshot(
          v: 1,
          index: 0,
          sessions: [
            _session(
              key: 'task-a',
              title: '任务Alpha',
              running: true,
              text: '新内容v2',
            ),
          ],
        ).toJson(),
      ),
    );
    await tester.pump();
    expect(find.text('旧内容v1'), findsOneWidget, reason: '拖动中快照被冻结');
    expect(find.text('新内容v2'), findsNothing);

    // 松手 → 冻结的快照一次性应用
    await gesture.up();
    await tester.pump();
    expect(find.text('新内容v2'), findsOneWidget, reason: '松手后应用挂起快照');
    expect(find.text('旧内容v1'), findsNothing);
  });

  testWidgets('标题栏拖动走原生 enableDrag: 按下开, 松手关', (tester) async {
    final pip = _FakePipService();
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      pip: pip,
      size: Size(320, pipWindowHeight(4)),
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', running: false, text: 'x'),
      ],
    );

    // 从标题栏起手拖动 → onPanStart: 原生拖动开关打开 (不触发 relayout)
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('任务Alpha')),
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(pip.dragToggles, [true], reason: '按下开启原生拖动');

    // 继续拖动不产生额外开关 (原生层自己搬窗口, Dart 不参与)
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(40, 0));
    expect(pip.dragToggles, [true]);

    // 松手 → 关回 enableDrag=false (正文手势不被原生拖动抢)
    await gesture.up();
    await tester.pump();
    expect(pip.dragToggles, [true, false]);
  });

  testWidgets('胶囊拖拽: pan 开关原生拖动, 松手钳制回屏并回传 pillMoved', (tester) async {
    final pip = _FakePipService();
    // 原生拖动把胶囊甩到屏外右下 (悬浮窗引擎 dpr=1 → 物理 px 即 dp)
    pip.position = const OverlayPosition(280, 590);
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      pip: pip,
      onSend: sent.add,
      // 窗口 108×44 (胶囊) + 快照屏幕 320×600 物理 px (dpr=1 → dp 同值)
      size: const Size(108, 44),
      screenW: 320,
      screenH: 600,
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', running: true, text: 'x'),
      ],
    );
    expect(find.byKey(const ValueKey('pip-collapsed-pill')), findsOneWidget);

    // 拖胶囊: 起手开原生拖动 (移动超过 slop 后 pan 竞技场胜出)
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('pip-collapsed-pill'))),
    );
    await gesture.moveBy(const Offset(30, 10));
    await tester.pump();
    expect(pip.dragToggles, [true], reason: '胶囊拖拽起手开启原生拖动');

    // 松手 → 关原生拖动 + 按屏钳制 (x∈[0,320-108], y∈[0,600-44]) + 回传 pillMoved
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(pip.dragToggles, [true, false], reason: '松手关回原生拖动');
    expect(pip.moves, hasLength(1), reason: '屏外坐标被钳回屏内');
    expect(pip.moves.single.x, 212); // 320 - 108
    expect(pip.moves.single.y, 556); // 600 - 44
    expect(
      jsonDecode(sent.last) as Map<String, dynamic>,
      <String, dynamic>{'action': 'pillMoved', 'x': 212.0, 'y': 556.0},
      reason: '钳后坐标回传, 主 App 持久化为胶囊记忆位',
    );
  });

  testWidgets('胶囊 tap 与 pan 共存: 轻点 (无位移) 不触发拖拽, 仍发 expand', (tester) async {
    final pip = _FakePipService();
    final sent = <String>[];
    final controller = StreamController<dynamic>();
    addTearDown(controller.close);

    await _pumpCard(
      tester,
      controller: controller,
      pip: pip,
      onSend: sent.add,
      size: const Size(108, 44),
      screenW: 320,
      screenH: 600,
      sessions: <PipSessionSnapshot>[
        _session(key: 'task-a', title: '任务Alpha', running: true, text: 'x'),
      ],
    );

    // 轻点无位移: pan 未过 slop 被弃, tap 胜出 → expand; 原生拖动开关不被触碰
    await tester.tap(find.byKey(const ValueKey('pip-collapsed-pill')));
    await tester.pump();
    expect(
      jsonDecode(sent.last) as Map<String, dynamic>,
      <String, dynamic>{'action': 'expand'},
    );
    expect(pip.dragToggles, isEmpty, reason: '轻点不触发 pan 起手');
    expect(pip.moves, isEmpty, reason: '轻点不产生钳制移动/pillMoved');
  });
}

/// 假 PipService: 记录 setNativeDrag 开关 / moveOverlay 调用,
/// getOverlayPosition 返回注入位置 (缺省 null = 原生侧查询失败)
class _FakePipService extends PipService {
  final List<bool> dragToggles = <bool>[];
  final List<OverlayPosition> moves = <OverlayPosition>[];
  OverlayPosition? position;

  @override
  Future<void> setNativeDrag(bool enabled) async {
    dragToggles.add(enabled);
  }

  @override
  Future<OverlayPosition?> getOverlayPosition() async => position;

  @override
  Future<void> moveOverlay(OverlayPosition position) async {
    moves.add(position);
  }
}
