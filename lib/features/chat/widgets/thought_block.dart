import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/logging/app_logger.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/chat_markdown_style.dart';


String formatWorkDuration(int ms) {
  final s = (ms / 1000).round();
  if (s < 1) return '1 秒';
  final d = s ~/ 86400;
  final h = (s % 86400) ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final units = <String>[];
  if (d > 0) units.add('$d 天');
  if (h > 0) units.add('$h 时');
  if (m > 0) units.add('$m 分');
  if (sec > 0 || units.isEmpty) units.add('$sec 秒');
  return units.take(2).join(' ');
}


class ThoughtBlock extends StatefulWidget {
  final String thought;
  final ThemeData theme;

  /// 思考耗时 (wire: reasoning.durationMs)
  final int? durationMs;

  const ThoughtBlock({
    required this.thought,
    required this.theme,
    this.durationMs,
  });

  @override
  State<ThoughtBlock> createState() => ThoughtBlockState();
}

class ThoughtBlockState extends State<ThoughtBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final duration = widget.durationMs != null
        ? ' · ${formatWorkDuration(widget.durationMs!)}'
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: AppDur.fast,
                    curve: AppEase.inOut,
                    child: Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '思考过程$duration',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Builder(
            builder: (context) {
              final body = _expanded
                  ? Container(
                      margin: const EdgeInsets.only(top: AppSpacing.xs),
                      padding: const EdgeInsets.only(left: AppSpacing.sm + 2),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            width: 2,
                            color: theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                      ),
                      child: Text(
                        widget.thought,
                        style: TextStyle(
                          fontSize: AppTextSizes.label,
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    )
                  : const SizedBox.shrink();
              // 超长思考文本跳过动画 (同 _WorkHistory.animate 理由)
              if (widget.thought.length > 1200) return body;
              return AnimatedSize(
                duration: AppDur.base,
                curve: AppEase.inOut,
                child: body,
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 从 data:image/...;base64,... URI 渲染图片
class DataImage extends StatelessWidget {
  final String dataUri;
  const DataImage({required this.dataUri});

  /// 解码结果 LRU: MemoryImage 以 identical(bytes) 判等, 不缓存的话
  /// 每次 build 的 base64Decode 都产生新 Uint8List → 图片缓存必 miss,
  /// 重复解码还重复占用 image cache。
  static final Map<String, Uint8List> _byteCache = {};
  static const _byteCacheMax = 24;

  @override
  Widget build(BuildContext context) {
    try {
      final bytes = _decode(dataUri);
      return Image.memory(bytes, fit: BoxFit.cover);
    } catch (e) {
      appLog.d('[Chat] data URI 图片解码失败: $e');
      return const SizedBox.shrink();
    }
  }

  static Uint8List _decode(String uri) {
    final cached = _byteCache[uri];
    if (cached != null) {
      // 触碰 LRU 顺序
      _byteCache.remove(uri);
      _byteCache[uri] = cached;
      return cached;
    }
    final commaIdx = uri.indexOf(',');
    if (commaIdx < 0) throw const FormatException('no data');
    final bytes = base64Decode(uri.substring(commaIdx + 1));
    if (_byteCache.length >= _byteCacheMax) {
      _byteCache.remove(_byteCache.keys.first);
    }
    _byteCache[uri] = bytes;
    return bytes;
  }
}

/// 打字光标动画
class TypingCursor extends StatefulWidget {
  final Color color;

  const TypingCursor({required this.color});

  @override
  State<TypingCursor> createState() => TypingCursorState();
}

class TypingCursorState extends State<TypingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 16,
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 代码块构建器: 带复制按钮 + 语言标签 + 等宽字体

class RunningDot extends StatefulWidget {
  /// 点径 (默认 8; AgentCard/工具行里用更小的 5-6)
  final double size;

  const RunningDot({super.key, this.size = 8});

  @override
  State<RunningDot> createState() => RunningDotState();
}

class RunningDotState extends State<RunningDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: AppDur.slow)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Opacity(
        opacity: 0.3 + 0.7 * _c.value,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: const BoxDecoration(
            color: AppColors.warning,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
