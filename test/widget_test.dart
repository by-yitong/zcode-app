import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/main.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    // ZcodeApp 是 ConsumerStatefulWidget (initState 订阅悬浮窗动作流), 必须包 scope
    await tester.pumpWidget(const ProviderScope(child: ZcodeApp()));

    // 等待至少一帧
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
    // 卸载树 + 快进烧掉启动路径的一次性延迟链 (splash 重试等, unmount 后不再续期);
    // 周期 Timer 由 ProviderScope dispose 的 onDispose 取消, 否则 teardown invariant 挂
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
  });
}
