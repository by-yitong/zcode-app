import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 全屏右滑开抽屉的观察式门卫 (与 Scaffold 左缘原生拉取互补)。
///
/// 背景: `Scaffold.drawerEdgeDragWidth` 设为全屏宽时, 抽屉的横向拖拽
/// 识别器会盖满全屏, 在手势竞技场上恒压过消息内表格/代码块的横向滚动
/// (真机实测宽表格完全不可滑)。因此原生拉取区只留左缘 [_edgeZone]dp,
/// 其余区域由本组件实现:
///
/// - **不入手势竞技场** (Listener 不注册识别器), 不与任何内容手势竞争;
/// - 让路信号用内容自己冒泡的滚动通知: 命中测试分发子先于父, 内容的
///   横向识别器 accept 后立刻冒泡 ScrollNotification, 本 gate 才收到
///   该 move 事件 — 顺序有保证, 不依赖渲染对象类型识别;
/// - 位移明确向右 (超过 [_threshold] 且横占优) 且期间无横向滚动发生
///   才回调 [onOpen]。
class DrawerSwipeGate extends StatefulWidget {
  const DrawerSwipeGate({super.key, required this.onOpen, required this.child});

  final VoidCallback onOpen;
  final Widget child;

  @override
  State<DrawerSwipeGate> createState() => _DrawerSwipeGateState();
}

class _DrawerSwipeGateState extends State<DrawerSwipeGate> {
  /// 与 Scaffold.drawerEdgeDragWidth 保持一致: 左缘这段归原生跟手拖拽,
  /// gate 在此区间让路, 避免与 DrawerController 的交互式拖动打架。
  static const double _edgeZone = 100;

  /// 触发开抽屉的最小水平位移 (逻辑像素), 兼顾误触与灵敏度。
  static const double _threshold = 48;

  int? _pointer;
  Offset? _start;
  bool _blocked = false;
  bool _triggered = false;

  /// 本手势期间子树发生过横向滚动 (表格/代码块等已接管) → 让路。
  bool _sawHorizontalScroll = false;

  /// 起点在输入框上 (选词/光标拖拽) → 让路。
  bool _hitsEditable(PointerEvent e) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, e.position, e.viewId);
    for (final entry in result.path) {
      if (entry.target is RenderEditable) return true;
    }
    return false;
  }

  void _onDown(PointerDownEvent e) {
    if (_pointer != null) return; // 只跟第一根手指
    _pointer = e.pointer;
    _start = e.position;
    _triggered = false;
    _sawHorizontalScroll = false;
    _blocked = e.position.dx < _edgeZone || _hitsEditable(e);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer || _triggered || _blocked) return;
    final dx = e.position.dx - _start!.dx;
    final dy = e.position.dy - _start!.dy;
    if (dx > _threshold && dx > dy.abs() * 2) {
      _triggered = true;
      widget.onOpen();
    }
  }

  void _onEnd(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _start = null;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // 只在跟蹤手势期间标记; axis 为横向才让路 (纵向聊天列表滚动不算)
        if (_pointer != null && n.metrics.axis == Axis.horizontal) {
          _sawHorizontalScroll = true;
        }
        return false;
      },
      child: Listener(
        onPointerDown: _onDown,
        onPointerMove: (e) {
          if (_sawHorizontalScroll) return;
          _onMove(e);
        },
        onPointerUp: _onEnd,
        onPointerCancel: _onEnd,
        child: widget.child,
      ),
    );
  }
}
