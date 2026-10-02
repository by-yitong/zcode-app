import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/app_design_tokens.dart';

/// 推开式 (Reveal) 导航抽屉 — 取代 Scaffold.drawer 的覆盖式抽屉。
///
/// 交互契约来自 `demos/navigation-drawer.html` (其 CSS 参数即下方动效参数):
///
/// - 抽屉垫在 Stack 底层从左滑入, 背后露出深色底 ([AppColors.darkBg]);
/// - 主页面在上层被向右推开并缩小 (scale 0.94, origin 左中), 全程可见、
///   无蒙层压暗; 打开时页面左上/左下圆角渐现 + 左侧投影;
/// - 关闭态: 全屏右滑**跟手**拖拽打开。不入手势竞技场 (Listener 不注册
///   识别器), 并保留原 DrawerSwipeGate 的两处真机踩坑让路:
///   ① 起点命中 RenderEditable (输入框选词) 让路; ② 手势期间内容发生
///   横向滚动 (消息里表格/代码块接管) 让路。松手按位置 settle + 速度辅助;
/// - 打开态 (t ≥ 0.5): 页面内容被 [AbsorbPointer] 屏蔽, 点页面任意处
///   关闭, 页面自身可左拖跟手关闭并 settle;
/// - 使用方职责: Android 返回键先关抽屉 (在 PopScope 里查 [isOpen] 后调
///   [close]); 抽屉内条目通过注入的 onClose 回调关抽屉 (原 Navigator.pop
///   语义迁移, 因抽屉不再是路由 overlay)。
class RevealDrawer extends StatefulWidget {
  const RevealDrawer({super.key, required this.drawer, required this.child});

  /// 抽屉内容 (不含宽度/背景壳, 由本组件负责)
  final Widget drawer;

  /// 被推开的主页面
  final Widget child;

  @override
  State<RevealDrawer> createState() => RevealDrawerState();
}

class RevealDrawerState extends State<RevealDrawer>
    with SingleTickerProviderStateMixin {
  // ── 布局/动效参数 (对齐 demos/navigation-drawer.html, 契约值勿随手改) ──

  /// 抽屉宽度 = min(可用宽度 80%, 330) — demo `--drawer-w: min(80%, 330px)`
  static const double _kDrawerWidthRatio = 0.80;
  static const double _kDrawerMaxWidth = 330;

  /// 打开时主页面缩小量 6% (demo `scale(0.94)`), transform-origin 左中
  static const double _kPageScaleDelta = 0.06;

  /// 打开时主页面左缘投影 (demo `box-shadow: -24px 0 48px` 黑色投影)
  static const double _kShadowAlpha = 0.18;
  static const double _kShadowBlur = 48;
  static const Offset _kShadowOffset = Offset(-24, 0);

  /// settle 位置阈值: 松手时进度过半则开, 否则合
  static const double _kSettleT = 0.5;

  /// 速度辅助阈值 (逻辑 px/s): 右甩超过它直接开, 左甩超过它直接合 —
  /// 用 VelocityTracker 而非纯位置阈值: 慢拖不过半不误开, 快甩短距也能开。
  static const double _kFlingVelocity = 600;

  /// 跟手拖拽启动阈值 (逻辑 px): 横移超过它且横移 ≥ 2 倍纵移 (与原
  /// DrawerSwipeGate 的方向判据一致) 才认作开抽屉手势 — 纵向滚动聊天
  /// 列表零干扰; 认定后跟手 (允许手指轻微纵向漂移)。
  static const double _kLatchMinDx = 8;
  static const int _kLatchDyRatio = 2;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDur.slow,
  );

  /// 抽屉宽度 (LayoutBuilder 布局后回填; 手势只可能发生在布局之后)
  double? _drawerWidth;

  // ── 关闭态右滑跟手状态 (只跟第一根手指) ──
  int? _pointer;
  Offset? _start;

  /// 起点在输入框上 (选词/光标拖拽) → 让路。
  bool _blocked = false;

  /// 已认定横向拖拽, 之后跟手。
  bool _latched = false;

  /// 本手势期间子树发生过横向滚动 (表格/代码块等已接管) → 让路。
  bool _sawHorizontalScroll = false;

  /// 手势开始时新建 (不复用上次的采样历史, 避免速度被上次手势污染)
  VelocityTracker? _tracker;

  // ── 打开态页面左拖跟手状态 ──
  double _pageDragStartT = 0;

  /// 抽屉是否可见 (进度 t > 0, 含开关动画途中)。
  ///
  /// "先关抽屉"类判断 (Android 返回键) 应使用本值而非 t == 1,
  /// 否则开启动画 360ms 途中按返回会绕过关抽屉直接进退出流程。
  bool get isOpen => _controller.value > 0.0;

  /// 打开抽屉 (输入框统一失焦: 原先由 HistoryDrawer initState 的
  /// postFrame unfocus 承担, 抽屉不再是路由 overlay 后移到这里)
  void open() {
    FocusManager.instance.primaryFocus?.unfocus();
    _controller.animateTo(1.0, duration: AppDur.slow, curve: AppEase.out);
  }

  /// 关闭抽屉
  void close() {
    _controller.animateTo(0.0, duration: AppDur.slow, curve: AppEase.in_);
  }

  /// 开 ↔ 关
  void toggle() => isOpen ? close() : open();

  // ── 关闭态: 全屏右滑跟手 (观察式, 不入竞技场) ──

  /// 让路信号①: 起点命中输入框。
  bool _hitsEditable(PointerEvent e) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, e.position, e.viewId);
    for (final entry in result.path) {
      if (entry.target is RenderEditable) return true;
    }
    return false;
  }

  void _onPointerDown(PointerDownEvent e) {
    if (_pointer != null) return; // 只跟第一根手指
    if (_controller.value > 0) return; // 只在完全关闭态跟手开 (开态关闭走页面手势)
    _pointer = e.pointer;
    _start = e.position;
    _latched = false;
    _sawHorizontalScroll = false;
    _blocked = _hitsEditable(e);
    _tracker = VelocityTracker.withKind(PointerDeviceKind.touch);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointer || _blocked) return;
    final dx = e.position.dx - _start!.dx;
    final dy = e.position.dy - _start!.dy;
    if (!_latched) {
      // 横向明显占优才认作开抽屉拖拽 (纵向滚动列表零干扰)
      if (dx > _kLatchMinDx && dx > dy.abs() * _kLatchDyRatio) {
        _latched = true;
      } else {
        return;
      }
    }
    _tracker?.addPosition(e.timeStamp, e.position);
    final w = _drawerWidth;
    if (w == null || w <= 0) return; // 与页面拖拽路径同款防御 (布局前不可达)
    _controller.value = (dx / w).clamp(0.0, 1.0);
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _start = null;
    if (!_latched) return;
    _latched = false;
    // settle: 位置阈值 (过半开) 为主, 速度辅助 (快甩直接开)
    final flung =
        (_tracker?.getVelocity().pixelsPerSecond.dx ?? 0) > _kFlingVelocity;
    if (flung || _controller.value > _kSettleT) {
      open();
    } else {
      close();
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _start = null;
    if (_latched) {
      _latched = false;
      close(); // 手势被系统打断 → 弹回关闭
    }
  }

  /// 让路信号②: 内容的横向识别器 accept 后立刻冒泡横向滚动通知
  /// (命中测试分发子先于父, 顺序有保证), 本组件才收到该 move 事件。
  bool _onScrollNotification(ScrollNotification n) {
    // 只在跟踪手势期间标记; 横向才让路 (纵向聊天列表滚动不算)
    if (_pointer != null && n.metrics.axis == Axis.horizontal) {
      if (!_sawHorizontalScroll) {
        _sawHorizontalScroll = true;
        _blocked = true;
        if (_latched) {
          // 抽屉已被拖出部分距离时内容才接管 → 立即弹回关闭
          _latched = false;
          close();
        }
      }
    }
    return false;
  }

  // ── 打开态: 页面左拖跟手关 + 点页面关 ──

  void _onPageDragStart(DragStartDetails d) {
    _pageDragStartT = _controller.value;
  }

  void _onPageDragUpdate(DragUpdateDetails d) {
    final w = _drawerWidth;
    if (w == null || w <= 0) return;
    _controller.value = (_pageDragStartT - d.primaryDelta! / w).clamp(
      0.0,
      1.0,
    );
  }

  void _onPageDragEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dx;
    if (v < -_kFlingVelocity) {
      close(); // 快速左甩关闭
    } else if (v > _kFlingVelocity) {
      open(); // 快速右甩收回
    } else {
      _controller.value > _kSettleT ? open() : close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final drawerWidth = math.min(
            constraints.maxWidth * _kDrawerWidthRatio,
            _kDrawerMaxWidth,
          );
          _drawerWidth = drawerWidth;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              // 开态 (t 过半): 屏蔽页面内容交互 + 挂页面级关闭手势。
              // GestureDetector 常驻只切换回调 (不增删子树), 跨过 0.5
              // 阈值时页面 Element 稳定, 主页面状态不重建。
              final settled = t >= _kSettleT;
              // 打开时页面左上/左下圆角渐现 (demo: 18px 0 0 18px, 走 AppRadius.xl)
              final radius = Radius.circular(AppRadius.xl * t);
              final leftRadius = BorderRadius.only(
                topLeft: radius,
                bottomLeft: radius,
              );
              return Stack(
                children: [
                  // 底层: 深色底 — 页面被推开后四周露出的就是它
                  const Positioned.fill(
                    child: ColoredBox(color: AppColors.darkBg),
                  ),
                  // 抽屉: 垫底层从左滑入 (关闭时整体平移出屏, Stack 裁剪)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: drawerWidth,
                    child: Transform.translate(
                      offset: Offset(-drawerWidth * (1 - t), 0),
                      child: ExcludeSemantics(
                        excluding: t == 0,
                        child: widget.drawer,
                      ),
                    ),
                  ),
                  // 上层: 被推开的主页面 (全程可见, 无蒙层压暗)
                  Listener(
                    onPointerDown: _onPointerDown,
                    onPointerMove: (e) {
                      // 内容横向滚动已接管 (表格/代码块) → 本手势让路
                      if (_sawHorizontalScroll) return;
                      _onPointerMove(e);
                    },
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    child: Transform.translate(
                      offset: Offset(drawerWidth * t, 0),
                      child: Transform.scale(
                        scale: 1 - _kPageScaleDelta * t,
                        alignment: Alignment.centerLeft,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            // 打开时页面左上/左下圆角渐现 + 左缘投影
                            borderRadius: leftRadius,
                            boxShadow: t == 0
                                ? const <BoxShadow>[]
                                : <BoxShadow>[
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: _kShadowAlpha * t,
                                      ),
                                      blurRadius: _kShadowBlur,
                                      offset: _kShadowOffset,
                                    ),
                                  ],
                          ),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: settled ? close : null,
                            onHorizontalDragStart: settled
                                ? _onPageDragStart
                                : null,
                            onHorizontalDragUpdate: settled
                                ? _onPageDragUpdate
                                : null,
                            onHorizontalDragEnd: settled
                                ? _onPageDragEnd
                                : null,
                            child: AbsorbPointer(
                              absorbing: settled,
                              child: ClipRRect(
                                borderRadius: leftRadius,
                                child: widget.child,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
