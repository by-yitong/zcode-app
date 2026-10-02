// 流式长文本卡顿基准 (诊断用, 非断言测试):
// 量化每 tick 成分, 供修复前后对比。debug JIT 环境, 绝对值偏大,
// 但同一环境下前后/变体间的比值有效。
//
// 运行: flutter test test/stream_perf_bench_test.dart
// 输出: 各成分单 tick 耗时 mean/p50/p95/max (ms)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/features/chat/widgets/message_bubble.dart';
import 'package:zcode_app/providers/chat_provider.dart' show DisplayMessage;

const _sentences = [
  '在分布式系统中，一致性模型决定了副本之间状态收敛的语义边界，'
      '线性一致性要求所有操作看起来像在某个瞬时点原子完成。',
  'Flutter 的渲染管线分为 build、layout、paint 三个阶段，'
      '任意阶段超出帧预算都会直接表现为掉帧与滚动卡顿。',
  '增量渲染的核心思路是把已稳定的内容缓存为不可变段，'
      '只对仍在变化的尾部重新解析与排版，成本从 O(n) 降到 O(tail)。',
  '手势竞技场中，识别器按加入顺序竞争，先声明胜利者独占指针流，'
      '因此全屏横向识别器会饿死内部可滚动内容的横向手势。',
  '文本整形（shaping）按段落整体执行，段落每追加一个字符，'
      '整段的字形布局就要重算一次，这是长段落流式输出卡顿的根源。',
  'Markdown 解析通常占渲染总成本的小头，排版与整形才是大头，'
      '优化应当优先减少重复排版范围而不是替换解析器。',
  '观测者模式的手势门控不参与竞技场，只在指针事件层做判定，'
      '因此不会与内容的滚动识别器产生竞争关系。',
  '节流合并把高频增量压到固定节奏重建，帧成本不随 token 到达频率变化，'
      '但单帧成本仍随文档规模增长，需要配合分段缓存。',
];

String _para(int i) {
  final b = StringBuffer();
  for (var k = 0; k < 5; k++) {
    b.write(_sentences[(i * 5 + k) % _sentences.length]);
  }
  return b.toString();
}

/// 真实感文档: 标题 + 加粗/行内代码 + 列表 + 多个段落。
String _baselineDoc({int paras = 10}) {
  final b = StringBuffer();
  b.write('# 性能基准文档\n\n');
  for (var i = 0; i < paras; i++) {
    if (i == 3) {
      b.write('- 要点 `one`：观测 `build` 阶段耗时\n');
      b.write('- 要点 `two`：观测 `layout` 阶段耗时\n\n');
      continue;
    }
    if (i == 6) {
      b.write('## 小节标题 ${i}\n\n');
    }
    b.write(_para(i));
    b.write('\n\n');
  }
  return b.toString();
}

void _report(String label, List<int> us, {int warmup = 5}) {
  final s = (us.length > warmup ? us.sublist(warmup) : us)
    ..sort();
  double mean(List<int> v) => v.fold(0, (a, b) => a + b) / v.length;
  final p = (List<int> v, double q) => v[(q * (v.length - 1)).floor()];
  String ms(num v) => (v / 1000).toStringAsFixed(2);
  // ignore: avoid_print
  print(
    '$label: n=${s.length} '
    'mean=${ms(mean(s))}ms '
    'p50=${ms(p(s, .5))}ms '
    'p95=${ms(p(s, .95))}ms '
    'max=${ms(s.last)}ms',
  );
}

// 静态外壳 + 可换气泡子树: 真实 app 每 tick 只重建流式消息子树
// (MaterialApp/Scaffold/列表不重建), 宿主整体每 tick 重建会引入
// 不真实的常量开销。
class _Swap extends StatefulWidget {
  const _Swap({super.key, required this.child});
  final Widget child;
  @override
  State<_Swap> createState() => _SwapState();
}

class _SwapState extends State<_Swap> {
  Widget? _child;
  void setChild(Widget w) => setState(() => _child = w);
  @override
  Widget build(BuildContext context) => _child ?? widget.child;
}

Widget _shell(GlobalKey<_SwapState> swap) => MaterialApp(
  theme: ThemeData.light(),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: _Swap(key: swap, child: const SizedBox.shrink()),
      ),
    ),
  ),
);

Widget _bubble(DisplayMessage m) => MessageBubble(
  message: m,
  theme: ThemeData.light(),
  isResponding: true,
  workspacePath: '/ws',
);

DisplayMessage _msg(String content) => DisplayMessage(
  id: 'bench',
  role: 'assistant',
  content: content,
  isStreaming: true,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.window.physicalSizeTestValue = const Size(1080, 2400);
  binding.window.devicePixelRatioTestValue = 3.0;

  testWidgets('stream tick bench', (tester) async {
    final imgRegex = RegExp(r'!\[[^\]]*\]\((data:image/[^)]+)\)');
    final kb20 = _baselineDoc(paras: 55); // ~20KB 纯文本

    // ── 成分 1: _extractImages 正则 vs contains 快扫 (20KB, 无图片) ──
    {
      final timesA = <int>[];
      for (var i = 0; i < 60; i++) {
        final t = Stopwatch()..start();
        imgRegex.allMatches(kb20).toList();
        kb20.replaceAll(imgRegex, '');
        timesA.add(t.elapsedMicroseconds);
      }
      final timesB = <int>[];
      for (var i = 0; i < 60; i++) {
        final t = Stopwatch()..start();
        kb20.contains('data:image');
        timesB.add(t.elapsedMicroseconds);
      }
      _report('regex_extract_20kb   ', timesA, warmup: 5);
      _report('contains_scan_20kb   ', timesB, warmup: 5);
    }

    // ── 成分 2: 多段落流式 tick (尾段短, 每 3 tick 合段) ──
    final swap = GlobalKey<_SwapState>();
    await tester.pumpWidget(_shell(swap));
    {
      var text = _baselineDoc(paras: 10);
      swap.currentState!.setChild(_bubble(_msg(text)));
      await tester.pump();
      final times = <int>[];
      var step = 0;
      for (var i = 0; i < 40; i++) {
        text += _para(100 + step);
        if (++step % 3 == 0) text += '\n\n';
        final t = Stopwatch()..start();
        swap.currentState!.setChild(_bubble(_msg(text)));
        await tester.pump();
        times.add(t.elapsedMicroseconds);
      }
      _report('tick_multi_para(${text.length}B)   ', times);
      await tester.pump(const Duration(seconds: 3));
    }

    // ── 成分 3: 巨尾段流式 tick (同量追加, 不分段) ──
    {
      var text = _baselineDoc(paras: 6);
      swap.currentState!.setChild(_bubble(_msg(text)));
      await tester.pump();
      final times = <int>[];
      for (var i = 0; i < 40; i++) {
        text += _para(200 + i);
        final t = Stopwatch()..start();
        swap.currentState!.setChild(_bubble(_msg(text)));
        await tester.pump();
        times.add(t.elapsedMicroseconds);
      }
      _report('tick_giant_tail(${text.length}B)  ', times);
      await tester.pump(const Duration(seconds: 3));
    }

    // ── 成分 4: n 倍增对照 (尾段行为一致, 只有全文变大) ──
    // 若 per-tick 随 n 线性涨 → 全文级 O(n) (normalize/split) 占主导,
    // 值得做应用层 settled/tail 冻结; 若基本持平 → 成本在尾段本身。
    for (final paras in [10, 40]) {
      var text = _baselineDoc(paras: paras);
      swap.currentState!.setChild(_bubble(_msg(text)));
      await tester.pump();
      final times = <int>[];
      var step = 0;
      for (var i = 0; i < 24; i++) {
        text += _para(300 + step);
        if (++step % 3 == 0) text += '\n\n';
        final t = Stopwatch()..start();
        swap.currentState!.setChild(_bubble(_msg(text)));
        await tester.pump();
        times.add(t.elapsedMicroseconds);
      }
      _report('tick_n${paras}p(${text.length}B)      ', times);
      await tester.pump(const Duration(seconds: 1));
    }
    swap.currentState!.setChild(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    // ignore: avoid_print
    print('BENCH DONE');
  });
}
