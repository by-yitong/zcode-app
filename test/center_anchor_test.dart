// center 锚定探针 B: 翻页插 older 块尾部 (远端) → sentinel 稳定;
// newest 块 child 视觉顺序; 贴底跟随数值。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('probe B: 尾部翻页稳定 + child 顺序 + 贴底跟随', (t) async {
    final ctrl = ScrollController();
    final centerKey = GlobalKey();
    var newestCount = 3;
    var olderCount = 20;
    var appendOlder = 0; // 翻页: older 块尾部追加
    final sentinelKey = GlobalKey();
    final tagKeys = <String, GlobalKey>{};

    GlobalKey tag(String s) => tagKeys.putIfAbsent(s, GlobalKey.new);

    Widget tree() => MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: ctrl,
              reverse: true,
              center: centerKey,
              slivers: [
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => Container(
                      key: tag('n$i'),
                      height: 80,
                      color: Colors.blue,
                      alignment: Alignment.center,
                      child: Text('n$i'),
                    ),
                    childCount: newestCount,
                  ),
                ),
                SliverList(
                  key: centerKey,
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      // i: 0..olderCount+append-1; 翻页内容在尾部 (最旧端)
                      final isPage = i >= olderCount;
                      final label = isPage ? 'p${i - olderCount}' : 'o$i';
                      return Container(
                        key: label == 'o5'
                            ? sentinelKey
                            : (isPage ? tag(label) : null),
                        height: 80,
                        color: Colors.grey,
                        alignment: Alignment.center,
                        child: Text(label),
                      );
                    },
                    childCount: olderCount + appendOlder,
                  ),
                ),
              ],
            ),
          ),
        );

    double dyOf(GlobalKey k) =>
        (k.currentContext!.findRenderObject() as RenderBox)
            .localToGlobal(Offset.zero)
            .dy;

    await t.pumpWidget(tree());
    await t.pump();
    // newest 块 child 视觉顺序 (dy 大 = 屏幕下方)
    // ignore: avoid_print
    print('ORDER n0=${dyOf(tag('n0'))} n1=${dyOf(tag('n1'))} n2=${dyOf(tag('n2'))}');

    ctrl.jumpTo(400);
    await t.pump();
    await t.pump();
    final before = dyOf(sentinelKey);
    // ignore: avoid_print
    print('BASE offset=${ctrl.offset} min=${ctrl.position.minScrollExtent} '
        'max=${ctrl.position.maxScrollExtent} sentinel=$before');

    newestCount = 5;
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('APPEND offset=${ctrl.offset} sentinel=${dyOf(sentinelKey)}');

    appendOlder = 5; // 翻页在 older 块尾部
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('PAGE   offset=${ctrl.offset} sentinel=${dyOf(sentinelKey)} '
        '(expect == $before)');
    expect(dyOf(sentinelKey), before, reason: '尾部翻页 sentinel 零位移');

    // 贴底: jumpTo(min), 追加后 min 变负, 记录 follow 所需的 jumpTo 数值
    ctrl.jumpTo(ctrl.position.minScrollExtent);
    await t.pump();
    // ignore: avoid_print
    print('BOTTOM offset=${ctrl.offset} min=${ctrl.position.minScrollExtent}');
    newestCount = 7;
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('AFTER-GROW offset=${ctrl.offset} '
        'min=${ctrl.position.minScrollExtent} (follow 需 jumpTo min)');
  });
}
