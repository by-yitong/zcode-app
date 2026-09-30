import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/features/chat/widgets/drawer_swipe.dart';

Widget _host(Widget body, GlobalKey<ScaffoldState> key) => MaterialApp(
      home: Scaffold(
        key: key,
        drawer: const Drawer(child: SizedBox.expand()),
        body: DrawerSwipeGate(
          onOpen: () => key.currentState?.openDrawer(),
          child: body,
        ),
      ),
    );

Future<void> _drag(WidgetTester tester, Offset at, Offset delta) async {
  final gesture = await tester.startGesture(at);
  // 分多步 move, 贴近真实手势 (每步都过 Listener.onPointerMove)
  for (var i = 0; i < 4; i++) {
    await gesture.moveBy(delta / 4);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空白区域右滑 → 打开抽屉', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final key = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(_host(
      const ColoredBox(color: Colors.white, child: SizedBox.expand()),
      key,
    ));
    await _drag(tester, const Offset(240, 200), const Offset(120, 0));
    expect(key.currentState!.isDrawerOpen, isTrue,
        reason: '非左缘、非滚动内容上的右滑应打开抽屉');
  });

  testWidgets('横向滚动内容上右滑 → 让路, 不开抽屉', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final key = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(_host(
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
      key,
    ));
    // 起点在横向滚动条上: 右滑 (在 0 位置被钳制, 无滚动) 不应开抽屉
    await _drag(tester, const Offset(200, 400), const Offset(120, 0));
    expect(key.currentState!.isDrawerOpen, isFalse,
        reason: '起点在横向滚动内容上时 gate 必须让路');
    // 左滑: 内容正常滚动
    final hsv = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    await _drag(tester, const Offset(200, 400), const Offset(-120, 0));
    expect(
      hsv.position.pixels,
      greaterThan(0),
      reason: '横向内容左滑应正常滚动',
    );
  });

  testWidgets('纵向滑动不开抽屉', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final key = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(_host(
      const ColoredBox(color: Colors.white, child: SizedBox.expand()),
      key,
    ));
    await _drag(tester, const Offset(240, 200), const Offset(60, 240));
    expect(key.currentState!.isDrawerOpen, isFalse,
        reason: '横向不占优的滑动不应触发');
  });
}
