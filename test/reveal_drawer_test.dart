import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/shared/widgets/reveal_drawer.dart';

/// 测试视口: 1080x2400 物理像素 / dpr 3.0 → 逻辑 360x800。
/// 抽屉宽 = min(360 * 0.80, 330) = 288。
const double _dpr = 3.0;

void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);
}

Widget _host(GlobalKey<RevealDrawerState> key, Widget body) => MaterialApp(
  home: RevealDrawer(
    key: key,
    drawer: const Material(
      color: Colors.black,
      child: Center(child: Text('DRAWER')),
    ),
    child: body,
  ),
);

/// 主页面当前被推开的水平位移 (页面层 Transform 的矩阵平移 x 之和;
/// scale 的 alignment 是左中, 其矩阵 x 平移恒为 0, 不影响结果)
double _pagePushDx(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(
    find.ancestor(of: find.text('PAGE'), matching: find.byType(Transform)),
  );
  var dx = 0.0;
  for (final t in transforms) {
    dx += t.transform.getTranslation().x;
  }
  return dx;
}

Future<void> _drag(
  WidgetTester tester,
  Offset at,
  Offset delta, {
  Duration step = const Duration(milliseconds: 16),
}) async {
  final gesture = await tester.startGesture(at);
  // 分多步 move, 贴近真实手势 (每步都过 Listener.onPointerMove)
  for (var i = 0; i < 4; i++) {
    await gesture.moveBy(delta / 4);
    await tester.pump(step);
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空白区域右滑跟手 → 进度递增, 松手过半开抽屉', (tester) async {
    _usePhoneViewport(tester); // 抽屉宽 = min(360*0.8, 330) = 288
    final key = GlobalKey<RevealDrawerState>();
    await tester.pumpWidget(
      _host(
        key,
        const Scaffold(body: Center(child: Text('PAGE'))),
      ),
    );

    // 跟手: 页面随手指逐渐被推开
    final gesture = await tester.startGesture(const Offset(120, 200));
    await gesture.moveBy(const Offset(36, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final push1 = _pagePushDx(tester);
    await gesture.moveBy(const Offset(36, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final push2 = _pagePushDx(tester);
    expect(push1, greaterThan(0), reason: '右滑时页面应被跟手推开');
    expect(push2, greaterThan(push1), reason: '跟手进度应递增');
    // 总位移 222 > 288/2 = 144 → 松手后应停在全开
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isTrue, reason: '松手时进度过半应开抽屉');
  });

  testWidgets('慢拖未过半 → 松手合上 (速度辅助不误开)', (tester) async {
    _usePhoneViewport(tester);
    final key = GlobalKey<RevealDrawerState>();
    await tester.pumpWidget(
      _host(key, const Scaffold(body: Center(child: Text('PAGE')))),
    );
    // 100px / 100ms 步长 → 速度 ~250px/s (< 600 甩动阈值), 进度 100/288 ≈ 0.35
    await _drag(
      tester,
      const Offset(120, 200),
      const Offset(100, 0),
      step: const Duration(milliseconds: 100),
    );
    expect(key.currentState!.isOpen, isFalse, reason: '慢拖不过半应合上');
  });

  testWidgets('横向滚动内容上右滑 → 让路, 不开抽屉', (tester) async {
    _usePhoneViewport(tester);
    final key = GlobalKey<RevealDrawerState>();
    await tester.pumpWidget(
      _host(
        key,
        Center(
          child: SizedBox(
            height: 40,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 800,
                height: 40,
                child: ColoredBox(
                  color: Colors.blue.withValues(alpha: 0.2),
                  child: Row(
                    children: List.generate(
                      10,
                      (i) => SizedBox(
                        width: 80,
                        child: Center(child: Text('列$i')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 起点在横向滚动条上: 右滑 (在 0 位置被钳制, 无滚动) 不应开抽屉
    await _drag(tester, const Offset(200, 400), const Offset(120, 0));
    expect(
      key.currentState!.isOpen,
      isFalse,
      reason: '起点在横向滚动内容上时必须让路',
    );
    // 左滑: 内容正常滚动
    final hsv = tester.state<ScrollableState>(find.byType(Scrollable).first);
    await _drag(tester, const Offset(200, 400), const Offset(-120, 0));
    expect(hsv.position.pixels, greaterThan(0), reason: '横向内容左滑应正常滚动');
  });

  testWidgets('起点在 TextField (RenderEditable) 上 → 让路, 不开抽屉', (tester) async {
    _usePhoneViewport(tester);
    final key = GlobalKey<RevealDrawerState>();
    await tester.pumpWidget(
      _host(
        key,
        const Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: TextField(),
            ),
          ),
        ),
      ),
    );
    final fieldCenter = tester.getCenter(find.byType(TextField));
    await _drag(tester, fieldCenter, const Offset(120, 0));
    expect(key.currentState!.isOpen, isFalse, reason: '输入框上右滑应让路 (选词)');
    await _drag(tester, const Offset(120, 200), const Offset(240, 0));
    expect(
      key.currentState!.isOpen,
      isTrue,
      reason: '非输入框区域右滑仍应正常开抽屉',
    );
  });

  testWidgets('纵向滑动不开抽屉', (tester) async {
    _usePhoneViewport(tester);
    final key = GlobalKey<RevealDrawerState>();
    await tester.pumpWidget(
      _host(key, const Scaffold(body: Center(child: Text('PAGE')))),
    );
    await _drag(tester, const Offset(240, 200), const Offset(60, 240));
    expect(key.currentState!.isOpen, isFalse, reason: '横向不占优的滑动不应触发');
  });

  testWidgets('open 态点页面任意处 → 关抽屉', (tester) async {
    _usePhoneViewport(tester);
    final key = GlobalKey<RevealDrawerState>();
    await tester.pumpWidget(
      _host(key, const Scaffold(body: Center(child: Text('PAGE')))),
    );
    key.currentState!.open();
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isTrue);
    expect(_pagePushDx(tester), greaterThan(0), reason: '开态页面应被推开');

    // 开态下抽屉占 288/360, 可见页面只剩右缘窄条 — 点窄条任意处 (350, 400)
    final gesture = await tester.startGesture(const Offset(350, 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isFalse, reason: '点被推开的页面应关闭抽屉');
    expect(_pagePushDx(tester), 0.0, reason: '关闭后页面应回到原位');
  });

  testWidgets('open()/close()/toggle()/isOpen', (tester) async {
    _usePhoneViewport(tester);
    final key = GlobalKey<RevealDrawerState>();
    await tester.pumpWidget(
      _host(key, const Scaffold(body: Center(child: Text('PAGE')))),
    );
    expect(key.currentState!.isOpen, isFalse);

    key.currentState!.open();
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isTrue);

    key.currentState!.close();
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isFalse);

    key.currentState!.toggle();
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isTrue);

    key.currentState!.toggle();
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isFalse);
  });
}
