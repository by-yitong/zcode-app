import 'dart:async';

import 'package:flutter/material.dart';

import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import 'thought_block.dart';

class TurnStatusLine extends StatefulWidget {
  final bool running;
  final int? workedMs;
  final DateTime? startedAt;
  final ThemeData theme;

  /// 折叠历史的展开态 (显示旋转箭头); null = 不作为折叠头
  final bool? expanded;
  final VoidCallback? onToggle;

  const TurnStatusLine({
    required this.running,
    required this.workedMs,
    required this.startedAt,
    required this.theme,
    this.expanded,
    this.onToggle,
  });

  @override
  State<TurnStatusLine> createState() => TurnStatusLineState();
}

class TurnStatusLineState extends State<TurnStatusLine> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant TurnStatusLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running) _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 运行中且有起点 → 每秒跳动刷新 "工作中 X"
  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (widget.running && widget.startedAt != null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final ms =
        widget.workedMs ??
        (widget.running && widget.startedAt != null
            ? DateTime.now().difference(widget.startedAt!).inMilliseconds
            : null);
    final duration = ms != null ? formatWorkDuration(ms) : '';
    final label = widget.running
        ? (duration.isEmpty ? '工作中' : '工作中 $duration')
        : '已工作${duration.isEmpty ? '' : ' $duration'}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: InkWell(
        onTap: widget.onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTextSizes.label,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (widget.expanded != null) ...[
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: widget.expanded! ? 0.25 : 0,
                  duration: AppDur.fast,
                  curve: AppEase.inOut,
                  child: Icon(
                    Icons.chevron_right,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 轮次历史折叠区 (ZCode "自动隐藏" 机制):
/// 运行中默认展开实时滚动; 完成后自动折叠到状态行后面, 点按可再展开。
/// 手动开关在运行态翻转时重置 (对齐 ZCode defaultOpen 同步)。
class WorkHistory extends StatefulWidget {
  final DisplayMessage message;
  final ThemeData theme;
  final bool defaultOpen;
  final Widget child;

  /// 内容很大时跳过展开动画 (动画期间列表项高度逐帧变化,
  /// 大轮次会造成持续 relayout; 直接切换只花一帧)
  final bool animate;

  const WorkHistory({
    required this.message,
    required this.theme,
    required this.defaultOpen,
    required this.child,
    this.animate = true,
  });

  @override
  State<WorkHistory> createState() => WorkHistoryState();
}

class WorkHistoryState extends State<WorkHistory> {
  /// null = 跟随 defaultOpen
  bool? _userOpen;

  @override
  void didUpdateWidget(covariant WorkHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.defaultOpen != widget.defaultOpen) {
      _userOpen = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _userOpen ?? widget.defaultOpen;
    final tappable = !widget.defaultOpen;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TurnStatusLine(
            running: widget.message.isStreaming,
            workedMs: widget.message.workedMs,
            startedAt: widget.message.turnStartedAt,
            theme: widget.theme,
            expanded: tappable ? open : null,
            onToggle: tappable ? () => setState(() => _userOpen = !open) : null,
          ),
          widget.animate
              ? AnimatedSize(
                  duration: AppDur.base,
                  curve: AppEase.inOut,
                  child: open ? widget.child : const SizedBox.shrink(),
                )
              : (open ? widget.child : const SizedBox.shrink()),
        ],
      ),
    );
  }
}

/// 思考过程折叠块 (ZCode 风格: 可带耗时, 左侧发丝线, 弱化墨色)
