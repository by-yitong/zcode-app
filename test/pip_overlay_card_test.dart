import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_test/flutter_test.dart';
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
              pip: pip,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // initState: 订阅快照流
  controller.add(
    jsonEncode(PipSnapshot(v: 1, index: index, sessions: sessions).toJson()),
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

  testWidgets('轻点写入 SharedPreferences 信箱 (默认通道): pip.action = open JSON', (
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

    // 轻点正文 (markdown 段落) → _defaultSend 写信箱
    await tester.tap(_bodyText('alpha-line-1'));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kPipActionPrefKey);
    expect(raw, isNotNull);
    expect(jsonDecode(raw!) as Map<String, dynamic>, <String, dynamic>{
      'action': 'open',
      'key': 'task-a',
    });
  });

  testWidgets('轻点某页回传 {"action":"open","key":...} JSON (注入通道)', (tester) async {
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

    // 轻点第 1 页正文 (非拖动/滑动)
    await tester.tap(_bodyText('alpha-line-2'));
    await tester.pump();

    final last = jsonDecode(sent.last) as Map<String, dynamic>;
    expect(last['action'], 'open');
    expect(last['key'], 'task-a');
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
    final pip = _FakePipService(const OverlayPosition(100, 200));
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

  testWidgets('拖动 in-flight 串行节流: 在途时吞中间目标, 完成后补发最终位置', (tester) async {
    final pip = _FakePipService(const OverlayPosition(100, 200));
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

    // 从标题栏起手 → onPanStart 拉基准位置 (异步微任务)
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('任务Alpha')),
    );
    await tester.pump(); // 基准就绪

    // 第一发 moveOverlay 被闸门挂起 (模拟 MethodChannel 在途);
    // 发送发生在下一帧的 postFrameCallback 里, 先 pump 出帧
    pip.gate = Completer<void>();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(pip.moves.length, 1, reason: '首目标立即发出');
    final firstX = pip.moves.first.x;

    // 在途期间继续移动: 只更新目标, 不再发 (吞中间帧)
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(40, 0));
    expect(pip.moves.length, 1, reason: '在途时中间目标被节流吞掉');

    // 松手 → 闸门放行 → 完成回调回查 → 下一帧补发最终目标 (不丢尾帧)。
    // 两次被吞的位移 (40*2) 全部并入最终目标
    await gesture.up();
    pip.gate!.complete();
    // 两帧: 第一帧让闸门 Future 完成 → 完成回调回查排队, 第二帧帧回调发送
    await tester.pump();
    await tester.pump();
    expect(pip.moves.length, 2, reason: '完成后补发最新目标');
    expect(pip.moves.last.x, moreOrLessEquals(firstX + 80));
    expect(pip.moves.last.y, pip.moves.first.y);
    await tester.pump();
    expect(pip.moves.length, 2, reason: '目标收敛后不再空发');
  });
}

/// 假 PipService: 记录 moveOverlay 调用; [gate] 未完成时模拟通道在途
class _FakePipService extends PipService {
  _FakePipService(this.origin);

  final OverlayPosition origin;
  final List<OverlayPosition> moves = <OverlayPosition>[];
  Completer<void>? gate;

  @override
  Future<OverlayPosition?> getOverlayPosition() async => origin;

  @override
  Future<void> moveOverlay(OverlayPosition position) {
    moves.add(position);
    final gate = this.gate;
    if (gate != null) return gate.future;
    return Future<void>.value();
  }
}
