import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../../core/logging/app_logger.dart';
import '../../core/services/pip_service.dart';
import '../theme/app_design_tokens.dart';
import '../theme/app_theme.dart';
import 'ai_markdown.dart';

// ================================================================
// 悬浮窗进度监视器 UI (overlay 独立引擎侧)
//
// 由 main.dart 的 overlayMain() 挂载 (flutter_overlay_window 原生侧按
// "overlayMain" 名字创建独立引擎)。固定深色卡, 不依赖跨引擎主题同步。
//
// 布局预算 (与 pipWindowHeight 公式 80 + N*20 严格对齐):
//   上下 padding 10*2 + 标题栏 36 + 正文 N*20 + 页码条 24 = 80 + N*20
//   (正文为 markdown 流式布局, N 仅决定视口高度, 行高系数见 pipLineExtent)
// ================================================================

/// 悬浮窗引擎根 App (独立 ProviderScope 由 overlayMain 提供)
class PipOverlayApp extends StatelessWidget {
  const PipOverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const PipOverlayCard(),
    );
  }
}

/// 悬浮窗卡片 (交互 v5): 左右滑切会话 (PageView) / 上下滑看尾部缓冲 /
/// home 钮回 app / 双击正文循环尺寸档位 (仅展开态) / 拖出屏或最小化 →
/// 收拢为 108×44 胶囊 (可拖拽移动, 松手记忆位置) / 点胶囊 → 胶囊位原地展开
class PipOverlayCard extends StatefulWidget {
  const PipOverlayCard({
    super.key,
    this.snapshotStream,
    this.onSend,
    this.onClose,
    this.pip,
  });

  /// 快照流 (默认插件 overlayListener, 悬浮窗引擎侧占用该槽位收快照; 测试注入)
  final Stream<dynamic>? snapshotStream;

  /// 悬浮窗 → 主 App 回传通道 (默认写 SharedPreferences 信箱 pip.action;
  /// 测试注入捕获)
  final void Function(String json)? onSend;

  /// 关闭悬浮窗 (默认 closeOverlay; 测试注入)
  final Future<void> Function()? onClose;

  /// 插件封装 (拖动/关闭用; 测试注入)
  final PipService? pip;

  @override
  State<PipOverlayCard> createState() => _PipOverlayCardState();
}

class _PipOverlayCardState extends State<PipOverlayCard> {
  StreamSubscription<dynamic>? _sub;
  PipSnapshot? _snapshot;
  int _index = 0;

  // 拖动手柄: 插件原生拖动 (onTouch 在原生层直接搬窗口, 零通道往返 =
  // 官方例子的丝滑路径)。默认关 (原生监听挂在整窗上, 开着会抢正文手势);
  // 按下标题栏瞬间 setDragEnabled(true) (本地补丁: 只翻标志不 relayout),
  // 松手关回。曾用 Dart 侧 moveOverlay 逐帧搬窗, 通道延迟致抖动 — 已废弃。
  bool _dragging = false;
  PipSnapshot? _pendingSnapshot;
  Timer? _emptyDebounce;

  /// 收拢态翻转日志去重 (每帧 build 都会走到, 不去重会刷屏)
  bool? _lastCollapsedReported;

  /// 下一次形态翻转是否播变形动画 (v6.3): 带 mo 快照的翻转沿置 true,
  /// 场景据此 forward/reverse; v5 式直切快照 (自动打开/隐藏恢复) 为 false,
  /// 场景直接跳到目标形态。
  bool _animateNextFlip = false;

  /// 变形动画进行中 (v6.3): 期间冻结流式快照应用 — 温面板恒挂载后,
  /// 流式文本更新会触发 markdown 重排版 (10-40ms), 撞上动画帧预算就掉帧;
  /// 挂起待动画完成后一次性应用 (同 _dragging 冻结模式)。
  bool _morphAnimating = false;

  /// v6.6 小窗自治: 本地形态意图 (null = 跟随快照)。点胶囊/最小化在本地
  /// 立即翻转形态并执行窗口操作 (动画与窗口操作同一引擎同一帧, 无跨
  /// 引擎错帧/轮询死区), 主程序经信箱事后执行同几何参数的幂等操作收敛
  /// 状态。快照的 collapsed 追上本地意图时清空, 回归快照权威。
  bool? _formOverride;

  /// v6.6 收拢裁剪参数 (本地路径): (收拢前面板窗口位, 胶囊局部 x)。
  /// 动画结束帧 (onSettled) 执行裁剪 — 精确零间隙, 不再依赖主程序 340ms
  /// 估计时序。
  ({OverlayPosition winPos, double pillLocalX})? _pendingCrop;

  /// 原生裁剪落地后的几何钉死 (见场景字段注释); 展开起播立即复位
  bool _cropPinned = false;


  late void Function(String json) _send;
  late Future<void> Function() _close;
  late PipService _pip;

  @override
  void initState() {
    super.initState();
    _pip = widget.pip ?? const PipService();
    _send = widget.onSend ?? _defaultSend;
    _close = widget.onClose ?? _defaultClose;
    final stream =
        widget.snapshotStream ?? FlutterOverlayWindow.overlayListener;
    _sub = stream.listen(_onMessage);
    // 防白屏 (v2): 不再回传 refresh, 主 App 在 show 成功后立即主动推快照
  }

  /// 默认回传通道: 写 SharedPreferences 信箱 (key pip.action), 主 App 在
  /// 悬浮窗打开期间轮询取走。写失败在服务内吞掉落日志, 不炸悬浮窗。
  void _defaultSend(String json) {
    unawaited(_pip.writeActionMailbox(json));
  }

  static Future<void> _defaultClose() async {
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
  }

  @override
  void dispose() {
    _emptyDebounce?.cancel();
    _emptyDebounce = null;
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }

  void _onMessage(dynamic raw) {
    final snap = PipSnapshot.decode(raw);
    if (snap == null || !mounted) return;
    appLog.d('[Pip] ov recv pages=${snap.sessions.length} idx=${snap.index}');
    // 拖动/变形动画中冻结快照重建: 流式推送每 500ms 触发整卡 rebuild
    // (markdown 重新解析+布局), 撞上帧预算就会掉帧抖动; 挂起待结束一次性
    // 应用。带 mo 的翻转沿快照除外 (它就是动画的触发器)。
    if (snap.morph == null && (_dragging || _morphAnimating)) {
      _pendingSnapshot = snap;
      return;
    }
    _acceptSnapshot(snap);
  }

  /// 快照准入: 内容→空 延迟 1.5s 应用 (会话状态在 running/complete 间短暂
  /// 翻动时, 空态若立即上屏会反复闪烁"抖动"); 期间来新内容立即取消防抖。
  /// 带 mo 的变形快照不走防抖 — 它是形态翻转沿, 主 App 侧已按 340ms 时序
  /// 推进 (变形 260ms + 余量后才裁剪窗口), 拖 1.5s 会窗口先裁而内容未变形。
  void _acceptSnapshot(PipSnapshot snap) {
    final hadContent = (_snapshot?.sessions.isNotEmpty ?? false);
    if (snap.morph == null && hadContent && snap.sessions.isEmpty) {
      _emptyDebounce?.cancel();
      _emptyDebounce = Timer(const Duration(milliseconds: 1500), () {
        _emptyDebounce = null;
        if (mounted) _applySnapshot(snap);
      });
      return;
    }
    _emptyDebounce?.cancel();
    _applySnapshot(snap);
  }

  void _applySnapshot(PipSnapshot snap) {
    setState(() {
      final countChanged =
          _snapshot == null ||
          _snapshot!.sessions.length != snap.sessions.length;
      _snapshot = snap;
      if (countChanged && snap.sessions.isNotEmpty) {
        // 仅集合变化时跟随主 App 的 index (用户滑动中不被快照打断)
        _index = snap.index.clamp(0, snap.sessions.length - 1);
      }
      if (_index >= snap.sessions.length) {
        _index = snap.sessions.isEmpty ? 0 : snap.sessions.length - 1;
      }
      // v6.3 变形触发: 带 mo 的快照 = 形态翻转沿 → 场景播动画;
      // 其余快照 (含 v5 式直切) 直接落到目标形态。
      if (snap.morph != null) {
        _animateNextFlip = true;
      }
      // v6.6 小窗自治: 快照的 collapsed 追上本地意图 → 主程序已收敛,
      // 清空意图回归快照权威 (未追上时保留 — 主程序还在路上, 快照仍旧值)
      if (_formOverride != null && _formOverride == snap.collapsed) {
        _formOverride = null;
      }
    });
  }

  /// 变形动画起止回调 (场景侧调用): 起播置位冻结流式快照, 结束清位并把
  /// 冻结期间挂起的快照一次性应用。
  void _onSceneAnimating(bool animating) {
    _morphAnimating = animating;
    if (animating) return;
    final pending = _pendingSnapshot;
    _pendingSnapshot = null;
    if (pending != null && mounted) _acceptSnapshot(pending);
  }

  // ================================================================
  // v6.6 小窗自治变形: 点胶囊/最小化的动画与窗口操作在本地立即执行
  // (同一引擎同一帧, 无跨引擎错帧), 信箱动作退化为"通知 + 主程序幂等
  // 收敛"(主程序稍后按同公式重放 resizeMove/mo 推送, 已到位状态上是
  // 视觉空操作)。本地路径前置条件不足 (无 tw/th 或屏幕尺寸) 时回落
  // 纯信箱路径 (主程序老例程原样兜底)。
  // 几何公式与 pip_providers 的 expandPipFromPill/collapsePipToPill
  // 严格同源: 双边扩展 (窗口水平中心对齐胶囊中心)、顶对齐 (卡片顶=
  // 胶囊内容顶=局部 4)、裁剪落点 = winPos+(pillLocalX-4, 0)。
  // ================================================================

  /// 本地展开 (点胶囊): 翻形态起播动画 + 原子 resizeMove 换框 + 通知主程序。
  Future<void> _expandLocally() async {
    if (_morphAnimating) return;
    // 先解除钉死 (窗口未动前用居中公式才是正确位)
    if (_cropPinned && mounted) setState(() => _cropPinned = false);
    final snap = _snapshot;
    final tw = snap?.targetW ?? 0;
    final th = snap?.targetH ?? 0;
    final sw = snap?.screenW;
    final sh = snap?.screenH;
    if (tw <= 0 || th <= 0 || sw == null || sh == null) {
      // 本地路径前置条件不足: 纯信箱兜底 (主程序例程含窗口操作+变形)
      _send(encodePipAction(const PipExpandAction()));
      return;
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenW = sw / dpr;
    final screenH = sh / dpr;
    final pos = await _pip.getOverlayPosition();
    final maxX = (screenW - tw).clamp(0.0, screenW);
    final maxY = (screenH - th).clamp(0.0, screenH);
    // v6.10 双边扩展: 窗口水平中心对齐胶囊中心; 垂直顶对齐
    final pillCenterX = (pos?.x ?? 0) + pipCollapsedWidth / 2;
    final x = (pillCenterX - tw / 2).clamp(0.0, maxX).toDouble();
    final y = (pos?.y ?? 0).clamp(0.0, maxY).toDouble();
    if (!mounted) return;
    // 窗口换框先行、动画随后 (v6.6.1): 若动画先起播, 头 1-2 帧还跑在
    // 108 宽的旧窗口里而目标几何已是全宽 — 盒子右缘撞窗边被裁、左缘
    // 几乎不动, 视觉上是"单侧展开"。await 换框落地 (~20ms, 远低于感知
    // 阈值) 再翻形态, 起播即在最终框内, 双边对称。翻形态前的窗口居中
    // 平移对胶囊只是 4dp 级位移, 静止无感。
    await _pip.resizeMove(tw.round(), th.round(), OverlayPosition(x, y));
    if (!mounted) return;
    // 置动画标志 — 场景据此 forward() 播变形 (v6.8 修复: 本地路径漏置,
    // v6.6 起变形一直是瞬间直切, "点开一下子就变了" 的真因)
    setState(() {
      _animateNextFlip = true;
      _formOverride = false;
    });
    // 通知主程序: 同步状态 (主程序已不碰窗口, 见 expandPipFromPill)
    _send(encodePipAction(const PipExpandAction()));
  }

  /// 本地收拢 (最小化钮/拖出屏): 翻形态起播动画; 裁剪在动画结束帧
  /// (onSettled) 精确执行; 通知主程序收敛。
  Future<void> _collapseLocally(PipOverlayAction notify) async {
    if (_morphAnimating) return;
    final snap = _snapshot;
    final tw = snap?.targetW ?? 0;
    final sw = snap?.screenW;
    if (tw <= 0 || sw == null) {
      _send(encodePipAction(notify)); // 纯信箱兜底
      return;
    }
    final winPos = await _pip.getOverlayPosition();
    if (!mounted) return;
    // v6.10 双边扩展: 胶囊收拢落点 = 面板窗口居中位 (场景同一公式)
    final pillLocalX = (tw - (pipCollapsedWidth - 8)) / 2;
    _pendingCrop = winPos == null
        ? null
        : (winPos: winPos, pillLocalX: pillLocalX);
    setState(() {
      _animateNextFlip = true;
      _formOverride = true;
    });
    _send(encodePipAction(notify));
  }

  /// 场景动画落定回调 (v6.6): 收拢 → 精确在结束帧裁剪 + pillMoved 同步
  /// 胶囊落点记忆; 展开 → 无事 (换框已在起播时完成)。
  void _onSceneSettled(bool collapsed) {
    if (!collapsed) return;
    final crop = _pendingCrop;
    _pendingCrop = null;
    if (crop == null) return; // 主程序例程自行裁剪 (本地几何未知)
    // 裁剪: 窗口缩到 108×44, 原点平移 (pillLocalX-4, 0) — 胶囊从居中位
    // 对齐到裁剪窗口 (4,4), 绝对位置不动
    final pillAbs = OverlayPosition(
      crop.winPos.x + crop.pillLocalX - 4,
      crop.winPos.y,
    );
    unawaited(_cropToPill(pillAbs));
  }

  /// 裁剪到 108×44 胶囊窗 + 落点回传 (主程序更新胶囊记忆, 其例程稍后的
  /// 同值裁剪/持久化为幂等空操作)。
  Future<void> _cropToPill(OverlayPosition pillAbs) async {
    await _pip.resizeMove(
      pipCollapsedWidth.round(),
      pipCollapsedHeight.round(),
      pillAbs,
    );
    // 原生裁剪已落地 → 钉死胶囊常量位, 度过约束滞后的 1-2 帧
    if (mounted) setState(() => _cropPinned = true);
    _send(encodePipAction(PipPillMovedAction(pillAbs.x, pillAbs.y)));
  }

  void _onPanStart(DragStartDetails details) {
    _dragging = true;
    // 原生层拖动接管, 跟手零延迟 (开关不触发 relayout)
    unawaited(_pip.setNativeDrag(true));
  }

  void _onPanEnd(DragEndDetails details) {
    unawaited(_onDragFinished());
  }

  void _onPanCancel() {
    unawaited(_onDragFinished());
  }

  Future<void> _onDragFinished() async {
    _dragging = false;
    unawaited(_pip.setNativeDrag(false));
    // 应用拖动期间挂起的快照 (若无可省一次 rebuild)
    final pending = _pendingSnapshot;
    _pendingSnapshot = null;
    if (pending != null && mounted) _acceptSnapshot(pending);
    final size = context.size;
    if (size == null) return;
    // 拖出屏判定 (隐藏意图): 窗口中心被拖出屏外 → 回传 collapse 并跳过钳制
    // (主 App 收拢成 44×44 小边 pill; 用户意图优先, 之后 app 进后台不再自动
    // 弹出, 点小边恢复)
    if (await _collapseIfDraggedOut(size.width)) return;
    // 否则钳制回屏 (原生拖动对参数无边界, 窗口可被甩出屏)
    unawaited(_clampIntoScreen(size.width, size.height));
  }

  /// 拖出屏判定: 窗口中心 = pos.x + w/2 (getOverlayPosition 返回逻辑 dp,
  /// 屏幕宽由快照 sw 物理 px → dp), 中心出屏 (左 <0 / 右 >屏宽) = 隐藏意图
  /// → 回传 collapse 动作并返回 true (调用方跳过钳制)。快照无 sw 时跳过
  /// 判定 (向后兼容)。
  Future<bool> _collapseIfDraggedOut(double windowWDp) async {
    final sw = _snapshot?.screenW;
    if (sw == null) return false;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenWDp = sw / dpr;
    try {
      final pos = await _pip.getOverlayPosition();
      if (pos == null || !mounted) return false;
      final center = pos.x + windowWDp / 2;
      if (center >= 0 && center <= screenWDp) return false;
      appLog.d('[Pip] 窗口中心拖出屏外 ($center) → 隐藏意图');
      // v6.6: 本地收拢 (动画+裁剪自治), 信箱通知主程序收敛
      unawaited(
        _collapseLocally(const PipCollapseAction()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 松手后把窗口钳制回屏幕内 (仅松手一次, 不与拖动过程打架)。
  /// 原生拖动对参数无边界, 窗口可被甩出屏; 部分ROM对屏外参数存在
  /// "钳制显示/真实摆放"两套解释, 参数出屏即触屏就跳 — 保持参数恒在
  /// 屏内可根除。屏幕尺寸由快照 sw/sh 提供 (悬浮窗引擎拿不到真实屏宽),
  /// 缺失时跳过。
  Future<void> _clampIntoScreen(double windowWDp, double windowHDp) async {
    final snap = _snapshot;
    final sw = snap?.screenW;
    final sh = snap?.screenH;
    if (sw == null || sh == null) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenWDp = sw / dpr;
    final screenHDp = sh / dpr;
    try {
      final pos = await _pip.getOverlayPosition();
      if (pos == null || !mounted) return;
      final maxX = (screenWDp - windowWDp).clamp(0, screenWDp);
      final maxY = (screenHDp - windowHDp).clamp(0, screenHDp);
      final cx = pos.x.clamp(0, maxX).toDouble();
      final cy = pos.y.clamp(0, maxY).toDouble();
      if (cx == pos.x && cy == pos.y) return;
      appLog.d('[Pip] 钳制回屏 (${pos.x},${pos.y}) → ($cx,$cy)');
      await _pip.moveOverlay(OverlayPosition(cx, cy));
    } catch (_) {}
  }

  /// 胶囊拖拽是否真的起手过: 轻点时 tap 在手势竞技场胜出, pan 识别器只收到
  /// cancel 而非 start — 原生拖动从未打开, 松手收尾序列必须跳过
  /// (否则平白多一次 setDragEnabled(false) + pillMoved 查询)。
  bool _pillDragStarted = false;

  /// 胶囊拖拽起手 (v5): 开原生拖动 (同标题栏手柄模式 — onTouch 在原生层
  /// 直接搬窗口, 零通道往返 = 官方例子的丝滑路径), 并冻结快照重建
  /// (拖动帧预算不与 markdown 重建打架, 松手后一次性应用)。
  void _onPillPanStart(DragStartDetails details) {
    _pillDragStarted = true;
    _dragging = true;
    unawaited(_pip.setNativeDrag(true));
  }

  /// 胶囊拖拽松手: 关原生拖动 → 应用挂起快照 → 位置钳回屏内 → 回传
  /// pillMoved 让主 App 记忆胶囊位置 (持久化, 下次收拢/打开放回这里)。
  /// 钳制要求胶囊整体可见: x∈[0, sw-108], y∈[0, sh-44] (状态栏 inset
  /// 悬浮窗引擎拿不到, y≥0 即可 — 顶部胶囊本就常驻状态栏区)。
  /// 屏幕尺寸由快照 sw/sh 物理 px 按悬浮窗 dpr 换 dp, 缺失时只关拖动不记忆。
  Future<void> _onPillDragFinished() async {
    if (!_pillDragStarted) return; // 纯轻点: pan 未起手, 无需收尾
    _pillDragStarted = false;
    _dragging = false;
    unawaited(_pip.setNativeDrag(false));
    final pending = _pendingSnapshot;
    _pendingSnapshot = null;
    if (pending != null && mounted) _acceptSnapshot(pending);
    final snap = _snapshot;
    final sw = snap?.screenW;
    final sh = snap?.screenH;
    if (sw == null || sh == null) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final screenWDp = sw / dpr;
    final screenHDp = sh / dpr;
    try {
      final pos = await _pip.getOverlayPosition();
      if (pos == null || !mounted) return;
      final maxX = (screenWDp - pipCollapsedWidth).clamp(0.0, screenWDp);
      final maxY = (screenHDp - pipCollapsedHeight).clamp(0.0, screenHDp);
      final cx = pos.x.clamp(0.0, maxX).toDouble();
      final cy = pos.y.clamp(0.0, maxY).toDouble();
      if (cx != pos.x || cy != pos.y) {
        appLog.d('[Pip] 胶囊钳制回屏 (${pos.x},${pos.y}) → ($cx,$cy)');
        await _pip.moveOverlay(OverlayPosition(cx, cy));
      }
      // 钳后坐标回传 (与最终摆放一致), 主 App 更新胶囊记忆位 + 持久化
      _send(encodePipAction(PipPillMovedAction(cx, cy)));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _snapshot?.sessions ?? const <PipSessionSnapshot>[];
    final current = sessions.isEmpty
        ? null
        : sessions[_index.clamp(0, sessions.length - 1)];
    // 收拢态判定 (v4.1 双保险, 语义不变): 主 App 快照 collapsed 字段为主
    // (真机实测 resize 后 MediaQuery 可能不刷新 — 状态驱动渲染不赌窗口
    // 尺寸), 窗口尺寸判定 (108×44 命中, 展开态最小档 0.84 屏宽远大于
    // 160dp 不误判) 兜底快照未达的间隙。隐藏态窗口 1×1 同样命中 — 窗口
    // 在屏外不可见, 渲染什么都不上屏。
    final winSize = MediaQuery.of(context).size;
    final collapsed = _formOverride ??
        (_snapshot?.collapsed == true ||
            (winSize.width < 160 && winSize.height < 56));
    if (collapsed != _lastCollapsedReported) {
      _lastCollapsedReported = collapsed;
      appLog.d(
        '[Pip] collapsed=$collapsed win=${winSize.width}x${winSize.height} '
        'flag=${_snapshot?.collapsed}',
      );
    }
    // v6.3 常驻温面板场景: 真面板 + 胶囊恒挂载 (面板经 OverflowBox 按目标
    // 尺寸布局, 收拢态透明度 0 = 布局保留/绘制跳过), 展开/收拢 = 纯合成器
    // 动画 (几何 + 透明度插值, 不碰布局)。真面板挂载/重排版 ~100ms 的开销
    // 只在悬浮窗打开时付一次, 变形零冷成本。
    return _PipScene(
      key: const ValueKey('pip-scene'),
      collapsed: collapsed,
      animateNext: _animateNextFlip,
      targetW: _snapshot?.targetW ?? 0,
      targetH: _snapshot?.targetH ?? 0,
      panel: KeyedSubtree(
        key: _panelHostKey,
        child: _buildPanel(sessions: sessions, current: current),
      ),
      pill: _buildCollapsedPillLabel(current),
      glowColor: _statusColor(current),
      pinCollapsedGeometry: _cropPinned,
      onPillTap: () => unawaited(_expandLocally()),
      onPillPanStart: _onPillPanStart,
      onPillPanEnd: (_) => unawaited(_onPillDragFinished()),
      onPillPanCancel: () => unawaited(_onPillDragFinished()),
      onAnimating: _onSceneAnimating,
      onSettled: _onSceneSettled,
    );
  }

  /// 活面板宿主 key (v6.3 恒挂载于场景, key 供测试定位与语义锚点)
  final GlobalKey _panelHostKey = GlobalKey(debugLabel: 'pip-panel-host');

  /// 展开态面板子树 (v6.3 恒挂载于场景): 铺满父盒 (场景中的显式尺寸盒)。
  Widget _buildPanel({
    required List<PipSessionSnapshot> sessions,
    PipSessionSnapshot? current,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        // 卡片底色/描边/圆角全部由场景的变形形状承载 (v6.8 单一形体):
        // 面板自带卡片外观时, 交叉淡化中两块深色矩形叠加 = "还有底盒"
        // (真机慢速反馈)。Padding 只负责内容排版; 上 4 下 16 = 卡片内距
        // (上 4 与胶囊边距对齐 → 变形顶边不动, v6.5.2)。
        // 空态也保留标题栏: 拖动手柄与 X 关闭不能因无会话而失效
        // (曾因整树替换成 _EmptyBody 导致空态既不能拖也不能关)。
        padding: const EdgeInsets.only(top: 4, bottom: 16),
        child: Column(
          children: [
                _Header(
                  session: current,
                  onPanStart: _onPanStart,
                  onPanEnd: _onPanEnd,
                  onPanCancel: _onPanCancel,
                  onClose: () => unawaited(_close()),
                  onHome: () {
                    // 回 app (替代原"点正文回跳"): 有会话 → 跳对应会话;
                    // 空态 → 仅回前台
                    final session = current;
                    if (session != null) {
                      _send(encodePipAction(PipOpenAction(session.key)));
                    } else {
                      _send(encodePipAction(const PipHomeAction()));
                    }
                  },
                  // v6.6: 本地收拢 (动画+结束帧裁剪自治), 信箱通知主程序收敛
                  onMinimize: () => unawaited(
                    _collapseLocally(const PipMinimizeAction()),
                  ),
                ),
                // 空态也保留标题栏: 拖动手柄与 X 关闭不能因无会话而失效
                // (曾因整树替换成 _EmptyBody 导致空态既不能拖也不能关)。
                Expanded(
                  child: sessions.isEmpty
                      ? const _EmptyBody()
                      : PageView.builder(
                          itemCount: sessions.length,
                          onPageChanged: (value) =>
                              setState(() => _index = value),
                          itemBuilder: (context, index) {
                            final session = sessions[index];
                            return _SessionBody(
                              key: ValueKey('pip-page-${session.key}'),
                              session: session,
                              onSize: () =>
                                  _send(encodePipAction(const PipSizeAction())),
                            );
                          },
                        ),
                ),
                // 页码指示 (空态无页, 隐藏)
                if (sessions.isNotEmpty)
                  SizedBox(
                    height: 24,
                    child: Center(
                      child: Text(
                        '${_index + 1}/${sessions.length}',
                        style: const TextStyle(
                          fontFamily: kMonoFont,
                          fontSize: 10,
                          color: AppColors.darkInkMuted,
                        ),
                      ),
                    ),
                  ),
              ],
          ),
      ),
    );
  }

  /// 收拢态顶部胶囊 (灵动岛式): 深色玻璃胶囊 + 状态色柔光外晕 + 左侧呼吸
  /// 状态点 + 会话标题。窗口 108×44, 内容胶囊 100×36 (四周各留 4dp — 光晕
  /// 画在窗口 surface 上, 贴边会被矩形窗口裁掉一圈)。
  /// v5 交互: 轻点 → 回传 expand (胶囊位原地展开); 整体可拖拽 (原生拖动
  /// 搬窗, 松手钳回屏 + 回传 pillMoved 让主 App 记忆位置)。tap 与 pan 共存:
  /// 轻点无位移时 tap 在手势竞技场胜出 (pan 未过 slop 即被弃), 起手短暂
  /// 开关原生拖动无害。
  /// 胶囊状态色: 运行 accent / 完成 success / 出错 danger / 空态中性
  Color _statusColor(PipSessionSnapshot? s) => s == null
      ? AppColors.darkInkMuted
      : s.running
      ? AppColors.accent
      : s.error
      ? AppColors.danger
      : AppColors.success;

  /// 胶囊标签 (v6.8): 无底色版 — 胶囊的底色/描边/柔光由场景的变形形状
  /// 自身承载 (胶囊本体在变形, 没有独立"底盒"垫板); 尺寸 100×36 保持
  /// 手势区。Material 祖先必须有: 没有 DefaultTextStyle 来源的 Text 会
  /// 渲染出"未解析样式"双下划线 (真机反馈过)。
  Widget _buildCollapsedPillLabel(PipSessionSnapshot? session) {
    final s = session;
    final color = _statusColor(s);
    final running = s?.running ?? false;
    final glowDot = Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6),
        ],
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        key: const ValueKey('pip-collapsed-pill'),
        width: pipCollapsedWidth - 8,
        height: pipCollapsedHeight - 8,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2),
          child: Row(
            children: [
              running ? _Breathing(child: glowDot) : glowDot,
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  s?.title ?? 'ZCode',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.darkInk,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// v6.3 常驻温面板场景: 真面板与胶囊恒挂载。
///
/// - 面板层经 OverflowBox 按 [targetW]×[targetH] 布局 (收拢态窗口只有
///   108×44, 布局尺寸照样全尺寸), FadeTransition 透明度 0 时 Flutter 跳过
///   整个子树绘制 — 布局保留 (温)、光栅零开销。
/// - 展开/收拢 = 纯合成器动画: 几何 rect/圆角插值 + 双层交叉淡化, 不碰
///   任何子树布局。真面板挂载/重排版 ~100ms (markdown 解析+布局) 只在
///   悬浮窗打开时付一次, 变形零冷成本 (v6.2 真机帧计时: 收拢起播仍有
///   35-78ms 重排版一顿、展开结尾文字迟到 ~0.1s, 本版根除)。
/// - 目标形态翻转: [animateNext]=true (快照 mo 翻转沿) → 260ms 动画;
///   false (v5 式直切: 自动打开/隐藏恢复) → 直接跳到目标形态。
/// - 目标尺寸显式来自快照 (tw/th 恒携带) — resize 后悬浮窗引擎
///   MediaQuery 可能不刷新 (v4.1 真机教训), 不读窗口尺寸做几何。
/// - 变形期间 [onAnimating] 回调置位, 卡片冻结流式快照 (markdown 重排版
///   不与动画帧预算打架), 结束后一次性应用挂起快照。
/// - 几何锚点恒为窗口左上 (0,0): 胶囊态、变形终点、收拢裁剪后窗口原点
///   三点重合, 全程零跳变。
class _PipScene extends StatefulWidget {
  /// 目标形态: true = 胶囊 (收拢), false = 面板 (展开)
  final bool collapsed;

  /// 本次翻转是否播动画 (快照 mo 翻转沿 true; v5 式直切 false)
  final bool animateNext;

  /// 面板目标宽 (逻辑 dp, 快照显式传; 0 = 无记录回落布局约束)
  final double targetW;

  /// 面板目标高 (逻辑 dp)
  final double targetH;

  /// 真面板子树 (恒挂载, 带 _panelHostKey)
  final Widget panel;

  /// 胶囊视觉内容 (恒挂载, 无底色 — 外观由变形形状承载)
  final Widget pill;

  /// 胶囊态状态色 — 变形形状的柔光外晕用
  final Color glowColor;

  /// 原生裁剪"落地后"钉死胶囊窗口常量几何 (约束滞后帧兜底; 时序见
  /// build 内注释 — 必须落地后置位, 提前 = 胶囊左跳)
  final bool pinCollapsedGeometry;


  // 胶囊层手势 (tap=expand / pan=原生拖拽开关), 仅胶囊可见时生效
  final VoidCallback onPillTap;
  final void Function(DragStartDetails) onPillPanStart;
  final void Function(DragEndDetails) onPillPanEnd;
  final VoidCallback onPillPanCancel;

  /// 变形动画起止回调 (起播 true / 结束 false)
  final void Function(bool animating)? onAnimating;

  /// 动画落定回调 (v6.6): 携带落定形态 (true=胶囊) — 收拢的裁剪挂在
  /// 结束帧精确执行 (零间隙), 替代主程序 340ms 估计时序。
  final void Function(bool collapsed)? onSettled;

  const _PipScene({
    super.key,
    required this.collapsed,
    required this.animateNext,
    required this.targetW,
    required this.targetH,
    required this.panel,
    required this.pill,
    required this.glowColor,
    required this.pinCollapsedGeometry,
    required this.onPillTap,
    required this.onPillPanStart,
    required this.onPillPanEnd,
    required this.onPillPanCancel,
    this.onAnimating,
    this.onSettled,
  });

  @override
  State<_PipScene> createState() => _PipSceneState();
}

class _PipSceneState extends State<_PipScene>
    with SingleTickerProviderStateMixin {
  /// 变形时长; 收拢裁剪挂 onSettled 动画结束帧, 自动跟随时长
  static const Duration _duration = Duration(milliseconds: 300);

  /// 旧内容 (退场方) 淡出区间
  static const Interval _oldFade = Interval(0.2, 0.8, curve: Curves.easeInCubic);

  /// 新内容 (入场方) 淡入区间 (与 _oldFade 交叠 ~150ms)
  static const Interval _newFade = Interval(
    0.25,
    0.85,
    curve: Curves.easeOutCubic,
  );

  /// 进度: 0 = 胶囊, 1 = 面板 (controller 即进度, 曲线在几何采样处另变)
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _duration,
  );

  /// 当前静止形态 (翻转检测用)
  bool _restCollapsed = true;

  /// 双层淡化动画 (方向翻转时重配): 进度 0→1 为展开 (胶囊退场/面板入场),
  /// 收拢 = 同一进度反向播放 (面板退场/胶囊入场)。
  late Animation<double> _pillFade;
  late Animation<double> _panelFade;

  @override
  void initState() {
    super.initState();
    _restCollapsed = widget.collapsed;
    _c.value = widget.collapsed ? 0.0 : 1.0;
    _configureFades(expanding: !widget.collapsed);
    _c.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      widget.onSettled?.call(_restCollapsed);
      widget.onAnimating?.call(false);
    }
  }

  /// 按方向配置交叉淡化: 展开时胶囊=退场(_oldFade 反向)、面板=入场
  /// (_newFade); 收拢反过来。收拢是反向播放, 用 ReverseAnimation 对齐
  /// "反向播放时入场方从 0 淡入"的语义。
  void _configureFades({required bool expanding}) {
    final oldC = CurvedAnimation(parent: _c, curve: _oldFade);
    final newC = CurvedAnimation(parent: _c, curve: _newFade);
    if (expanding) {
      _pillFade = ReverseAnimation(oldC);
      _panelFade = newC;
    } else {
      _pillFade = ReverseAnimation(newC);
      _panelFade = oldC;
    }
  }

  @override
  void didUpdateWidget(covariant _PipScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.collapsed == _restCollapsed) return;
    _restCollapsed = widget.collapsed;
    final expanding = !widget.collapsed;
    _configureFades(expanding: expanding);
    if (widget.animateNext) {
      widget.onAnimating?.call(true);
      if (expanding) {
        _c.forward();
      } else {
        _c.reverse();
      }
    } else {
      // v5 式直切 (自动打开/隐藏恢复): 无动画, 静止落位
      _c.value = expanding ? 1.0 : 0.0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 目标尺寸: 快照显式值优先 (MediaQuery resize 后可能不刷新),
        // 无记录 (老主 App 兼容) 回落当前布局约束
        final tw = widget.targetW > 0 ? widget.targetW : constraints.maxWidth;
        final th = widget.targetH > 0 ? widget.targetH : constraints.maxHeight;
        // v6.5 双边扩展: 胶囊恒水平居中于窗口 (静止胶囊窗口 108 →
        // (108-100)/2 = 4 与原位一致; 面板窗口 tw → 居中)。变形盒绕胶囊
        // 中心左右对称生长, 面板卡片中心与胶囊中心重合 = "从两边扩展"
        // (灵动岛式)。主 App 展开时窗口水平中心对齐胶囊中心, 窗口落位后
        // 胶囊局部坐标随之更新 → 绝对位置不动 (LayoutBuilder 每帧取活
        // 约束, resize 传播前后自校正)。
        // v6.10.1 双边扩展 (用户指定): 胶囊恒水平居中于窗口, 变形盒绕
        // 胶囊中心左右对称生长; 展开窗口水平中心对齐胶囊中心, 收拢裁剪
        // 平移 (pillLocalX-4, 0) 保持胶囊绝对位置。裁剪后引擎约束滞后帧
        // (实测 ~2 帧) 由 [pinCollapsedGeometry] 钉死胶囊窗口常量位兜底 —
        // 属性由卡片在"原生裁剪落地后"置位; 动画结束帧就钉会把窗口未动
        // 的 1-2 帧也钉进去 = 胶囊先左跳再回 ("位置正确然后左抽", 真机
        // 反馈), 这是两版钉死时序之差的关键。
        final pillX = widget.pinCollapsedGeometry
            ? 4.0
            : (constraints.maxWidth - (pipCollapsedWidth - 8)) / 2;
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            // (整体节奏由分轴 wT/hT 承载, 见下)
            // 变形盒两端 = 真实视觉卡片盒 (胶囊内容 4dp 柔光边距, 水平
            // 居中; 面板卡片上 4dp 下 16dp 内距), 两端与静止态逐像素重合;
            // 两端顶边同在局部 y=4 → 变形全程顶边纹丝不动 (v6.5.2)。
            // easeOutCubic 快起缓收: 点按后立刻有位移反馈
            final t = Curves.easeOutCubic.transform(_c.value);
            final rect = Rect.lerp(
              Rect.fromLTWH(
                pillX,
                4,
                pipCollapsedWidth - 8,
                pipCollapsedHeight - 8,
              ),
              Rect.fromLTWH(0, 4, tw, th - 20),
              t,
            )!;
            const pillRadius = (pipCollapsedHeight - 8) / 2;
            final radius = lerpDouble(pillRadius, AppRadius.lg, t)!;
            return Stack(
              // 不裁剪: 底盒/面板层自管裁剪, 让窗口 surface 决定最终边界
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                // 变形形状 = 胶囊本体 (v6.8, 无独立底盒): 恒渲染。
                // 收拢态它就是胶囊 — 胶囊的底色/描边/状态柔光外晕全在它
                // 身上; 展开时它自己拉伸成面板卡片外观 (颜色/描边/圆角/
                // 光晕随进度插值, 光晕渐熄)。胶囊标签和面板内容只是趴在
                // 它上面交叉淡化 — 用户看到的是"胶囊在变形", 不是"一块
                // 板子垫在下面长大" (真机反馈)。
                Positioned.fromRect(
                  rect: rect,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.darkBg.withValues(
                        alpha: lerpDouble(0.92, 0.97, t)!,
                      ),
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(
                        color: Color.lerp(
                          Colors.white.withValues(alpha: 0.10),
                          AppColors.darkBorder,
                          t,
                        )!,
                      ),
                      boxShadow: t < 1
                          ? [
                              BoxShadow(
                                color: widget.glowColor.withValues(
                                  alpha: 0.30 * (1 - t),
                                ),
                                blurRadius: 8,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
                // 面板层 (温): 恒挂载 + OverflowBox 按目标尺寸布局; 收拢态
                // fade=0 → RenderAnimatedOpacity 跳过整个子树绘制 (布局
                // 保留 = 下次展开零冷成本)。ClipRRect 随底盒几何揭示;
                // IgnorePointer 挡住不可见时的误触 (标题栏按钮等)。
                Positioned.fromRect(
                  rect: rect,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: 0,
                      maxWidth: double.infinity,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: SizedBox(
                        width: tw,
                        height: th,
                        child: IgnorePointer(
                          ignoring: _c.value < 0.95,
                          child: FadeTransition(
                            key: const ValueKey('pip-panel-fade'),
                            opacity: _panelFade,
                            child: widget.panel,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 胶囊层 (温): 恒挂载, (pillX, 4) 与变形盒 fromRect 逐像素
                // 重合 (v6.8 标签无内边距)。展开态 fade=0 跳过绘制。
                // 手势 (tap=expand / pan=拖拽) 仅胶囊可见时生效。
                Positioned(
                  left: pillX,
                  top: 4,
                  child: IgnorePointer(
                    ignoring: _c.value > 0.05,
                    child: FadeTransition(
                      key: const ValueKey('pip-pill-fade'),
                      opacity: _pillFade,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onPillTap,
                        onPanStart: widget.onPillPanStart,
                        onPanEnd: widget.onPillPanEnd,
                        onPanCancel: widget.onPillPanCancel,
                        child: widget.pill,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 空态: 全部会话结束 / 无运行中会话 (悬浮窗保留, 用户手动关闭)
class _EmptyBody extends StatelessWidget {
  const _EmptyBody();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.monitor_heart_outlined,
            size: 22,
            color: AppColors.darkInkMuted,
          ),
          SizedBox(height: 6),
          Text(
            '暂无进行中会话',
            style: TextStyle(
              fontSize: AppTextSizes.bodySm,
              color: AppColors.darkInkSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 标题栏: 状态点 + 标题 + 最小化钮 + home 钮 + X; 同时是拖动手柄
/// (onPanUpdate 累积位移 → moveOverlay 经 in-flight 串行节流发送, 见 _dispatchMove)
class _Header extends StatelessWidget {
  /// null = 空态 (无会话): 中性灰点 + "ZCode" 标题, 手柄与关闭按钮照常可用
  final PipSessionSnapshot? session;
  final void Function(DragStartDetails) onPanStart;
  final void Function(DragEndDetails) onPanEnd;
  final VoidCallback onPanCancel;
  final VoidCallback onClose;

  /// home 钮 (X 左侧): 回 app — 有会话跳对应会话, 空态仅回前台
  final VoidCallback onHome;

  /// 最小化钮 (home 左): 收拢为顶部胶囊
  final VoidCallback onMinimize;

  const _Header({
    required this.session,
    required this.onPanStart,
    required this.onPanEnd,
    required this.onPanCancel,
    required this.onClose,
    required this.onHome,
    required this.onMinimize,
  });

  @override
  Widget build(BuildContext context) {
    // 紧凑标题栏: 高 44 → 36, 左右内距 10 → AppSpacing.sm, X 按钮收窄
    // (铬高预算同步 88 → 80, 见 pipWindowChromeHeight)
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.darkBorderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: onPanStart,
              onPanEnd: onPanEnd,
              onPanCancel: onPanCancel,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Row(
                  children: [
                    _StatusDot(session: session),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        session?.title ?? 'ZCode',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.darkInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 最小化钮 (home 左): 手动收拢为顶部胶囊 (切后台仍自动弹回展开)
          IconButton(
            icon: const Icon(
              Icons.remove_rounded,
              size: 16,
              color: AppColors.darkInkSecondary,
            ),
            tooltip: '最小化',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onMinimize,
          ),
          // home 钮 (X 左侧): 回 app — 替代原"点正文回跳"(正文单点易与
          // 滑动/滚动误触); constraints 同 X 保持紧凑标题栏节奏
          IconButton(
            icon: const Icon(
              Icons.home_rounded,
              size: 16,
              color: AppColors.darkInkSecondary,
            ),
            tooltip: '返回应用',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onHome,
          ),
          IconButton(
            icon: const Icon(
              Icons.close_rounded,
              size: 16,
              color: AppColors.darkInkSecondary,
            ),
            tooltip: '关闭悬浮窗',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// 运行状态点: 运行中呼吸点 (accent) / 完成绿点 / 出错红点
class _StatusDot extends StatelessWidget {
  /// null = 空态: 中性灰点 (无呼吸)
  final PipSessionSnapshot? session;
  const _StatusDot({required this.session});

  @override
  Widget build(BuildContext context) {
    if (session == null) {
      return Container(
        key: const ValueKey('pip-dot-empty'),
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: AppColors.darkInkMuted,
          shape: BoxShape.circle,
        ),
      );
    }
    final s = session!;
    final color = s.running
        ? AppColors.accent
        : s.error
        ? AppColors.danger
        : AppColors.success;
    final dot = Container(
      key: ValueKey('pip-dot-${s.key}'),
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (!s.running) return dot;
    return _Breathing(child: dot);
  }
}

/// 呼吸动画 (运行中): 透明度 0.35 ↔ 1.0 循环
class _Breathing extends StatefulWidget {
  final Widget child;
  const _Breathing({required this.child});

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.35,
        end: 1.0,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}

/// 单会话页: 正文 markdown 尾部缓冲, 可上下滚动 (初始停最底部; 底部自动跟随,
/// 翻历史中保持位置); 双击 → 回传 size 动作循环尺寸档位 (单点不再回 app,
/// 回 app 改由标题栏 home 钮, 避免滑动/滚动误触跳走)。
class _SessionBody extends StatefulWidget {
  final PipSessionSnapshot session;
  final VoidCallback onSize;

  const _SessionBody({super.key, required this.session, required this.onSize});

  @override
  State<_SessionBody> createState() => _SessionBodyState();
}

class _SessionBodyState extends State<_SessionBody> {
  final ScrollController _scrollController = ScrollController();

  /// 是否停在底部附近 (新内容到达时决定是否自动跟随)
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _jumpToBottomAfterFrame();
  }

  @override
  void didUpdateWidget(covariant _SessionBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // markdown 整体重建: 以 text 变化为准 (在底部 → 自动跟随; 翻历史中保持位置)
    final changed = oldWidget.session.text != widget.session.text;
    if (changed && _atBottom) {
      _jumpToBottomAfterFrame();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    _atBottom =
        _scrollController.offset >=
        _scrollController.position.maxScrollExtent - 2;
  }

  /// 初始停在最底部 / 底部跟随
  void _jumpToBottomAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          !_scrollController.position.hasContentDimensions) {
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      _atBottom = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.session.text;
    return GestureDetector(
      // 双击 (非拖动/滑动) → 回传 size, 由主 App 循环尺寸档位并重推快照
      onDoubleTap: widget.onSize,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: text.trim().isEmpty
            ? const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(
                  '暂无 AI 输出',
                  style: TextStyle(fontSize: 11, color: AppColors.darkInkMuted),
                ),
              )
            : AiMarkdown(
                // 复用主 App 统一 markdown 渲染 (同进程同包, 可跨引擎引用):
                // 固定深色墨/码底, 字号比主 App 档小一号 (bodySm), minimal 只
                // 接管正文/标题/行内代码, 其余交给包默认 (悬浮窗不要重能力)
                data: text,
                ink: AppColors.darkInk,
                codeBg: AppColors.darkSurfaceHigh,
                bodyStyle: const TextStyle(
                  color: AppColors.darkInk,
                  fontSize: AppTextSizes.bodySm,
                  height: 1.45,
                ),
                headingBase: const TextStyle(
                  color: AppColors.darkInk,
                  fontSize: AppTextSizes.bodySm,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
                minimal: true,
                // 流式期间传该会话 running 态
                isStreaming: widget.session.running,
              ),
      ),
    );
  }
}
