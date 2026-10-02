import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/ai_markdown.dart';

/// 流式 Markdown 冻结渲染: 把仍在增长的文本切成「冻结前缀 + 活尾段」。
///
/// 问题: 流式消息每个节流 tick 整段重建, gpt_markdown 的增量视图虽然
/// 按顶层块缓存了已稳定段落, 但每次重建仍要对全文做 normalize/分段/
/// 前缀比较, 且整条子树 (样式配置、span、字符串) 随全文大小重新分配 —
/// 回复越长单 tick 越贵、GC 压力越大 (长回复期间列表卡顿的主因)。
///
/// 方案: 在气泡层把文本按「安全块边界」切成两份独立文档 — 前缀渲染成
/// AiMarkdown 后冻结 widget 实例 (Element 见到 identical 实例会跳过整棵
/// 子树 rebuild, 配 RepaintBoundary 重绘也隔离), 尾段保持小文档增量
/// 重建, 单 tick 成本被钳在尾段大小内、不随全文增长。终态 (isLive=false)
/// 整体重渲染一次, 与全文单文档完全一致, 流式期间的临时接缝自行愈合。
///
/// 冻结点只在「尾段超过 [_maxTail]」时推进: 推进 = 新前缀整篇冷解析
/// (一次性尖峰), 若每个新段落都推进, 会把包内增量视图的廉价追加变成
/// 周期性全量重建, 反而更卡。
///
/// 边界安全规则 (找不全就整段当尾段, 正确性优先):
/// - 只在 '\n\n' 处切;
/// - 前缀的 ``` 围栏计数必须为偶数 (不在代码块中间切);
/// - 尾段首行不得是列表/引用/表格/标题/缩进 (不拆散跨空行构造);
/// - 冻结点只前进不后退 (一旦冻结, 尾段即使暂时不安全也不解冻)。
class FrozenTailMarkdown extends StatefulWidget {
  /// Markdown 源文本 (整段)。
  final String data;

  /// 该消息是否仍在流式增长 (用 message.isStreaming, 不是全局 isResponding
  /// — 历史静态消息不应进冻结路径)。
  final bool isLive;

  /// 样式参数, 透传给内部两个 AiMarkdown (见其注释)。
  final Color ink;
  final Color codeBg;
  final void Function(String url, String title)? onLinkTap;

  /// 尾段长度上限 (字符), 超过才推进冻结。测试可调小强制走切分路径。
  final int maxTail;

  const FrozenTailMarkdown({
    super.key,
    required this.data,
    required this.isLive,
    required this.ink,
    required this.codeBg,
    this.onLinkTap,
    this.maxTail = 3200,
  });

  @override
  State<FrozenTailMarkdown> createState() => _FrozenTailMarkdownState();
}

class _FrozenTailMarkdownState extends State<FrozenTailMarkdown> {
  /// 已冻结的前缀文本 (以 '\n\n' 结尾) 与其渲染实例。
  String _frozen = '';
  Widget? _frozenWidget;

  /// 上 tick 的全文与返回的 widget — 文本未变时原样复用。
  String? _lastData;
  Widget? _lastResult;

  /// 从末尾往回找安全块边界, 返回切点 (前缀长度, 含结尾 '\n\n');
  /// 0 = 无安全边界。
  int _safeCut(String text) {
    var cut = text.lastIndexOf('\n\n');
    var tries = 0;
    while (cut > 0 && tries++ < 5) {
      if ('```'.allMatches(text.substring(0, cut)).length.isEven) {
        final tail = text.substring(cut + 2);
        final nl = tail.indexOf('\n');
        if (!_continuesConstruct(nl < 0 ? tail : tail.substring(0, nl))) {
          return cut + 2;
        }
      }
      cut = text.lastIndexOf('\n\n', cut - 1);
    }
    return 0;
  }

  /// 尾段首行是否会与前文合并成一个构造 (列表/引用/表格/标题/缩进)。
  bool _continuesConstruct(String line) {
    if (line.isEmpty) return false;
    final c = line.codeUnitAt(0);
    if (c == 0x20 || c == 0x09) return true; // 缩进: 嵌套列表/缩进代码
    final t = line.trimLeft();
    if (t.isEmpty) return false;
    final h = t.codeUnitAt(0);
    if (h == 0x2D || h == 0x2A || h == 0x2B) return true; // - * +
    if (h == 0x3E || h == 0x7C || h == 0x23) return true; // > | #
    if (h >= 0x30 && h <= 0x39) {
      final rest = t.substring(1);
      return rest.startsWith('.') || rest.startsWith(')'); // 1. 1)
    }
    return false;
  }

  AiMarkdown _md(String data, {required bool streaming}) => AiMarkdown(
    data: data,
    ink: widget.ink,
    codeBg: widget.codeBg,
    isStreaming: streaming,
    onLinkTap: widget.onLinkTap,
  );

  @override
  Widget build(BuildContext context) {
    final data = widget.data;

    // 终态: 整段一次渲染并清空冻结 — 输出与全文单文档渲染完全一致。
    if (!widget.isLive) {
      _frozen = '';
      _frozenWidget = null;
      _lastData = null;
      _lastResult = null;
      return _md(data, streaming: false);
    }

    // 本 tick 文本没变 (别处的 delta 触发的重建): 原样复用。
    if (data == _lastData && _lastResult != null) return _lastResult!;

    // 非追加改写 (全量刷新/重写): 冻结失效, 重置。
    if (_frozen.isNotEmpty && !data.startsWith(_frozen)) {
      _frozen = '';
      _frozenWidget = null;
    }

    // 尾段超上限才推进冻结 (只前进)。推进 = 新前缀整篇冷解析的
    // 一次性尖峰; 频繁推进会把增量追加退化成周期性全量重建。
    if (data.length - _frozen.length > widget.maxTail) {
      final cut = _safeCut(data);
      if (cut > _frozen.length) {
        _frozen = data.substring(0, cut);
        _frozenWidget = RepaintBoundary(child: _md(_frozen, streaming: false));
      }
    }

    final tail = data.substring(_frozen.length);
    final Widget result;
    if (tail.trim().isEmpty) {
      result = _frozenWidget!;
    } else if (_frozenWidget == null) {
      result = _md(tail, streaming: true);
    } else {
      result = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _frozenWidget!,
          // 两份文档拼接处补块间距 — 等于单文档内 '\n\n' 的段距,
          // 与包内 StreamingMarkdown 的 seamGap 同源。
          SizedBox(
            height: blockGap(
              context,
              GptMarkdownConfig(
                style: TextStyle(
                  color: widget.ink,
                  fontSize: AppTextSizes.bodyMd,
                  height: 1.6,
                ),
              ),
            ),
          ),
          _md(tail, streaming: true),
        ],
      );
    }
    _lastData = data;
    _lastResult = result;
    return result;
  }
}
