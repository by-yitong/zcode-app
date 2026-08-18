// center 锚定双 sliver 结构的验收测试 (与 chat_screen.dart 同构):
// 1) live 块追加消息 / 审批卡出现消失 / 流式 item 长高 → 阅读位置零位移
// 2) older 块尾部翻页 → 零位移
// 3) 贴底时增长 → 跟随处理器 jumpTo 新 min
// 4) 用户滚动后松手静止 → 增长仍零位移 (center 结构无需任何校正)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('center 锚定: 零位移 + 贴底跟随', (t) async {
    final ctrl = ScrollController();
    final centerKey = GlobalKey();
    // 数据模型: ids oldest→newest; live = 最后一条之后追加
    var ids = List<String>.generate(21, (i) => 'm$i'); // 20 older + live m20
    final boundaryId = 'm19';
    var permCount = 0;
    var growLast = 80.0; // live 消息高度 (流式长高)
    final sentinelKey = GlobalKey();
    var atBottom = false; // 与 chat_screen 的 _isAtBottom 同语义

    int bEnd(List<String> l) {
      final idx = l.lastIndexOf(boundaryId);
      return idx >= 0 ? idx + 1 : l.length - 1;
    }

    Widget tree() => MaterialApp(
          home: Scaffold(
            body: NotificationListener<ScrollMetricsNotification>(
              onNotification: (n) {
                // —— 与 chat_screen 的贴底跟随处理器同构 (静止门控) ——
                if (!ctrl.hasClients || !atBottom) return false;
                if (ctrl.position.isScrollingNotifier.value) return false;
                final pos = ctrl.position;
                if (pos.minScrollExtent.isFinite) {
                  pos.jumpTo(pos.minScrollExtent);
                }
                return false;
              },
              child: CustomScrollView(
                controller: ctrl,
                reverse: true,
                center: centerKey,
                slivers: [
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final liveCount = ids.length - bEnd(ids);
                        if (i < liveCount) {
                          final id = ids[bEnd(ids) + i];
                          final isLast = id == ids.last;
                          return Container(
                            key: isLast ? null : ValueKey(id),
                            height: isLast ? growLast : 80,
                            color: Colors.blue,
                            alignment: Alignment.center,
                            child: Text(id),
                          );
                        }
                        return Container(
                          key: ValueKey('perm$i'),
                          height: 100,
                          color: Colors.orange,
                          alignment: Alignment.center,
                          child: Text('perm$i'),
                        );
                      },
                      childCount:
                          ids.length - bEnd(ids) + permCount,
                    ),
                  ),
                  SliverList(
                    key: centerKey,
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final id = ids[bEnd(ids) - 1 - i];
                        return Container(
                          key: id == 'm10' ? sentinelKey : ValueKey(id),
                          height: 80,
                          color: Colors.grey,
                          alignment: Alignment.center,
                          child: Text(id),
                        );
                      },
                      childCount: bEnd(ids),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    double sentinelY() => (sentinelKey.currentContext!.findRenderObject()
            as RenderBox)
        .localToGlobal(Offset.zero)
        .dy;

    // 模拟滚动监听维护 atBottom (只在用户主动滚动时翻转)
    void userJump(double target) {
      ctrl.jumpTo(target);
      atBottom = ctrl.offset - ctrl.position.minScrollExtent < 60;
    }

    await t.pumpWidget(tree());
    await t.pump();
    atBottom = true; // 进入会话默认贴底
    userJump(400); // 用户上翻阅读 m10
    await t.pump();
    await t.pump();
    final before = sentinelY();
    // ignore: avoid_print
    print('BASE offset=${ctrl.offset} min=${ctrl.position.minScrollExtent} '
        'sentinel=$before');

    // 1) live 追加 2 条新消息 (流式新气泡)
    ids = [...ids, 'm21', 'm22'];
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('APPEND sentinel=${sentinelY()} (expect $before)');
    expect(sentinelY(), before, reason: 'live 追加必须零位移');

    // 2) live 最后一条长高 (流式 token)
    growLast = 300;
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('GROW sentinel=${sentinelY()} (expect $before)');
    expect(sentinelY(), before, reason: '流式长高必须零位移');

    // 3) 审批卡出现在 live 尾 (视觉最底)
    permCount = 2;
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('PERM+ sentinel=${sentinelY()} (expect $before)');
    expect(sentinelY(), before, reason: '审批卡出现必须零位移');

    // 4) 审批卡消失
    permCount = 0;
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('PERM- sentinel=${sentinelY()} (expect $before)');
    expect(sentinelY(), before, reason: '审批卡消失必须零位移');

    // 5) 翻页: 头部插入更旧消息 (older 块尾部追加)
    ids = ['p1', 'p2', 'p3', ...ids];
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('PAGE sentinel=${sentinelY()} (expect $before)');
    expect(sentinelY(), before, reason: '翻页插入必须零位移');

    // 6) 用户滚回底部 → 增长 → 贴底跟随 (jumpTo 新 min)
    userJump(ctrl.position.minScrollExtent); // atBottom → true
    await t.pump();
    growLast = 500;
    await t.pumpWidget(tree());
    await t.pump();
    // ignore: avoid_print
    print('FOLLOW offset=${ctrl.offset} '
        'min=${ctrl.position.minScrollExtent}');
    expect(
      ctrl.offset,
      ctrl.position.minScrollExtent,
      reason: '贴底时增长后应跟随到新 min',
    );

    // 7) 用户手势进行中 (isScrolling=true) 增长 → 不得跳底杀手势
    final anim = ctrl.animateTo(
      ctrl.position.minScrollExtent + 150,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    growLast = 700;
    await t.pumpWidget(tree());
    await t.pump(const Duration(milliseconds: 100)); // 动画进行中
    // ignore: avoid_print
    print('GESTURE offset=${ctrl.offset} isScrolling='
        '${ctrl.position.isScrollingNotifier.value}');
    expect(
      ctrl.position.isScrollingNotifier.value,
      isTrue,
      reason: '前置: 动画应仍在进行 (模拟用户手势)',
    );
    expect(
      ctrl.offset,
      greaterThan(ctrl.position.minScrollExtent + 100),
      reason: '跟随不得在手势进行中跳底',
    );
    await t.pumpAndSettle();
  });
}
