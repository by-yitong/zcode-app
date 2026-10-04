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

  /// 进行中的变形规格 (v6): 带 mo 快照的翻转沿写入, 动画完成回调清空。
  /// 非空期间 build 返回 _MorphTransition (优先于收拢判定); 动画期间到达
  /// 的流式快照 (无 mo) 只更新 _snapshot 数据, 不中断不重启动画。
  _MorphSpec? _morph;

  /// 变形序号: 每次启动 +1, 拼进 _MorphTransition 的 key — 新变形必然
  /// 换 State (全新 controller), 不会复用已完成动画的旧 State。
  int _morphSeq = 0;

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
    // 拖动中冻结快照重建: 流式推送每 500ms 触发整卡 rebuild (markdown 重新
    // 解析+布局), 撞上拖动帧预算就会掉帧抖动; 挂起待松手后一次性应用。
    if (_dragging) {
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
      // v6 变形触发: 仅翻转沿启动一次 (带 mo 且当前无进行中的变形)。
      // 解码已保证坐标对完整 (expand→tw/th, collapse→fx/fy), 这里直接取。
      final mo = snap.morph;
      if (mo != null && _morph == null) {
        _morph = _MorphSpec.fromSnapshot(snap, id: ++_morphSeq);
      }
    });
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
      _send(encodePipAction(const PipCollapseAction()));
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
    // v6 变形过渡优先于收拢判定: 翻转沿启动的 ~260ms 内渲染过渡组件
    // (胶囊↔面板几何插值 + 内容交叉淡入淡出), 完成后按最新快照渲染最终
    // 形态。变形期间用户拖动手柄照 _dragging 冻结快照逻辑, 不特殊处理;
    // 窗口透明区域会吞点击 (~300ms, 接受 — 变形是瞬时反馈, 拦截比误触安全)。
    final morph = _morph;
    if (morph != null) {
      return KeyedSubtree(
        // 外层恒定 key 供测试/调试定位; 内层 key 带序号, 新变形换新 State
        key: const ValueKey('pip-morph'),
        child: _MorphTransition(
          key: ValueKey('pip-morph-${morph.id}'),
          spec: morph,
          buildPanel: () => _buildPanel(sessions: sessions, current: current),
          buildPillContent: () => _buildCollapsedPillContent(current),
          onCompleted: () {
            if (mounted) setState(() => _morph = null);
          },
        ),
      );
    }
    // 收拢态 (v4.1 双保险, v5 语义不变): 主 App 快照 collapsed 字段为主
    // (真机实测 resize 后 MediaQuery 可能不刷新 — 窗口变小而内容仍渲染
    // 完整卡, 被裁成一条缝; 状态驱动渲染不赌窗口尺寸), 窗口尺寸判定
    // (108×44 命中, 展开态最小档 0.84 屏宽远大于 160dp 不误判) 兜底快照
    // 未达的间隙。隐藏态窗口 1×1 同样命中胶囊渲染 — 窗口在屏外不可见,
    // 渲染什么都不上屏, 无所谓。
    // 点胶囊 → 回传 expand 由主 App 在胶囊位原地展开; 拖胶囊 → 松手回传
    // pillMoved 由主 App 记忆位置。
    final winSize = MediaQuery.of(context).size;
    final collapsed = _snapshot?.collapsed == true ||
        (winSize.width < 160 && winSize.height < 56);
    if (collapsed != _lastCollapsedReported) {
      _lastCollapsedReported = collapsed;
      appLog.d(
        '[Pip] collapsed=$collapsed win=${winSize.width}x${winSize.height} '
        'flag=${_snapshot?.collapsed}',
      );
    }
    if (collapsed) {
      return _buildCollapsedPill(current);
    }
    return _buildPanel(sessions: sessions, current: current);
  }

  /// 展开态面板子树 (v6 从 build 抽出, 正常态与变形过渡共用):
  /// 铺满父盒 (正常态=整窗; 变形期间由 _MorphTransition 包进显式尺寸盒)。
  Widget _buildPanel({
    required List<PipSessionSnapshot> sessions,
    PipSessionSnapshot? current,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        // 与 pipWindowHeight 公式的铬高 (88) 对齐
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Container(
            color: AppColors.darkBg.withValues(alpha: 0.97),
            // 边框画在前景: 不内缩 child, 保证正文视口高度 = N*pipLineExtent
            foregroundDecoration: BoxDecoration(
              border: Border.all(color: AppColors.darkBorder),
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            // 空态也保留标题栏: 拖动手柄与 X 关闭不能因无会话而失效
            // (曾因整树替换成 _EmptyBody 导致空态既不能拖也不能关)。
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
                  onMinimize: () =>
                      _send(encodePipAction(const PipMinimizeAction())),
                ),
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
  Widget _buildCollapsedPill(PipSessionSnapshot? session) {
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 轻点 → 主 App 在胶囊当前位置原地展开 (窗口左上锚定胶囊左上)
        onTap: () => _send(encodePipAction(const PipExpandAction())),
        // 拖拽 → 原生层直接搬窗口 (零延迟), 松手钳回屏 + 回传 pillMoved
        onPanStart: _onPillPanStart,
        onPanEnd: (_) => unawaited(_onPillDragFinished()),
        onPanCancel: () => unawaited(_onPillDragFinished()),
        child: _buildCollapsedPillContent(session),
      ),
    );
  }

  /// 胶囊视觉内容 (v6 从 _buildCollapsedPill 抽出, 正常收拢态与变形过渡
  /// 共用): 固定 100×36 (108×44 窗口减四周 4dp 柔光边距), 不含手势壳 —
  /// 变形期间 (~300ms) 手势无意义, 交叉淡入淡出只搬视觉。
  Widget _buildCollapsedPillContent(PipSessionSnapshot? session) {
    final s = session;
    final color = s == null
        ? AppColors.darkInkMuted
        : s.running
        ? AppColors.accent
        : s.error
        ? AppColors.danger
        : AppColors.success;
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
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Container(
        key: const ValueKey('pip-collapsed-pill'),
        width: pipCollapsedWidth - 8,
        height: pipCollapsedHeight - 8,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2),
        decoration: BoxDecoration(
          color: AppColors.darkBg.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular((pipCollapsedHeight - 8) / 2),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          // 状态色柔光: 任何桌面背景 (含浅色) 上都能浮出来, 状态一眼可见
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.30),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
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
    );
  }
}

/// v6 变形规格: 带 mo 快照翻转沿的解析结果 (PipSnapshot.decode 已保证
/// 坐标对完整 — expand 携 tw/th, collapse 携 fx/fy)。
class _MorphSpec {
  /// 启动序号 (拼进过渡组件 key, 保证每次变形拿到全新 controller)
  final int id;

  /// true = 胶囊→面板 (expand); false = 面板→胶囊 (collapse)
  final bool expand;

  /// collapse 用: 胶囊目标左上角在窗口内的局部坐标 (逻辑 dp)
  final double fx;

  /// collapse 用: 胶囊目标 Y (局部 dp, 主 App 固定传 0 = 面板顶)
  final double fy;

  /// expand 用: 目标面板宽 (逻辑 dp, 显式传 — resize 后悬浮窗引擎
  /// MediaQuery 可能不刷新, 不得读窗口尺寸做动画目标, v4.1 真机教训)
  final double tw;

  /// expand 用: 目标面板高 (逻辑 dp)
  final double th;

  const _MorphSpec({
    required this.id,
    required this.expand,
    this.fx = 0,
    this.fy = 0,
    this.tw = 0,
    this.th = 0,
  });

  factory _MorphSpec.fromSnapshot(PipSnapshot snap, {required int id}) =>
      _MorphSpec(
        id: id,
        expand: snap.morph == 'expand',
        fx: snap.morphX ?? 0,
        fy: snap.morphY ?? 0,
        tw: snap.targetW ?? 0,
        th: snap.targetH ?? 0,
      );
}

/// 胶囊↔面板变形过渡 (灵动岛式, v6): ~260ms 几何插值 + 内容交叉淡入淡出。
/// - expand: 内容盒 (0,0,108,44) → (0,0,tw,th), 圆角 18 → AppRadius.lg,
///   胶囊内容淡出 / 面板内容淡入 (交叠 ~150ms)。
/// - collapse: 面板盒全窗 → (fx,fy,108,44), 圆角反向插值, 反向交叉淡化。
/// 面板子树始终包在显式尺寸盒里布局 (expand=tw×th; collapse=当前布局
/// 尺寸 — 后者仅动画起点, 起点取 LayoutBuilder 约束即面板真实视觉尺寸,
/// 目标一律来自快照字段)。完成后回调 onCompleted → 正常形态渲染。
class _MorphTransition extends StatefulWidget {
  final _MorphSpec spec;

  /// 面板子树构建器 (变形开始时构建一次缓存, 逐帧只重绘不重排 markdown;
  /// 动画期间流式快照更新的数据在完成后按最新快照渲染)
  final Widget Function() buildPanel;

  /// 胶囊视觉内容构建器 (同上, 构建一次缓存)
  final Widget Function() buildPillContent;

  final VoidCallback onCompleted;

  const _MorphTransition({
    super.key,
    required this.spec,
    required this.buildPanel,
    required this.buildPillContent,
    required this.onCompleted,
  });

  @override
  State<_MorphTransition> createState() => _MorphTransitionState();
}

class _MorphTransitionState extends State<_MorphTransition>
    with SingleTickerProviderStateMixin {
  /// 变形时长: 主 App 收拢例程按 260ms + 余量 (340ms) 才裁剪窗口,
  /// 改这里必须同步改 pip_providers 的等待时长。
  static const Duration _duration = Duration(milliseconds: 260);

  /// 旧内容 (expand=胶囊 / collapse=面板) 淡出区间
  static const Interval _oldFade = Interval(0.2, 0.8, curve: Curves.easeInCubic);

  /// 新内容淡入区间 (与 _oldFade 交叠 ~150ms)
  static const Interval _newFade = Interval(
    0.25,
    0.85,
    curve: Curves.easeOutCubic,
  );

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  );

  /// 子树缓存: 动画逐帧 rebuild 复用同一 Widget 实例 → Flutter 跳过子树
  /// 重建, markdown 不逐帧重排 (掉帧防线)
  late final Widget _panel = widget.buildPanel();
  late final Widget _pill = widget.buildPillContent();

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onCompleted();
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // collapse 的动画起点 = 当前窗口布局尺寸 (此刻窗口尚未 resize,
        // 布局尺寸即面板真实视觉尺寸; 仅作起点 — 目标来自快照字段)。
        final winW = constraints.maxWidth;
        final winH = constraints.maxHeight;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final spec = widget.spec;
            final t = Curves.easeInOutCubicEmphasized.transform(
              _controller.value,
            );
            const pillRadius = (pipCollapsedHeight - 8) / 2;
            final Rect box;
            final double radius;
            if (spec.expand) {
              box = Rect.fromLTWH(
                0,
                0,
                lerpDouble(pipCollapsedWidth, spec.tw, t)!,
                lerpDouble(pipCollapsedHeight, spec.th, t)!,
              );
              radius = lerpDouble(pillRadius, AppRadius.lg, t)!;
            } else {
              box = Rect.fromLTWH(
                lerpDouble(0, spec.fx, t)!,
                lerpDouble(0, spec.fy, t)!,
                lerpDouble(winW, pipCollapsedWidth, t)!,
                lerpDouble(winH, pipCollapsedHeight, t)!,
              );
              radius = lerpDouble(AppRadius.lg, pillRadius, t)!;
            }
            final oldT = _oldFade.transform(_controller.value);
            final newT = _newFade.transform(_controller.value);
            final pillOpacity = spec.expand ? 1 - oldT : newT;
            final panelOpacity = spec.expand ? newT : 1 - oldT;
            // 变形底盒 (深色玻璃 + 动画圆角) = "黑色岛"轮廓; 面板/胶囊内容
            // 各自携带底色, 底盒只在尺寸差与圆角过渡期露出
            final rr = RRect.fromRectAndRadius(
              box,
              Radius.circular(radius),
            );
            return Stack(
              // 不裁剪: 底盒可能短暂超出布局盒 (MediaQuery 滞后的过渡帧),
              // 让窗口 surface 自己决定裁剪边界
              clipBehavior: Clip.none,
              children: [
                Positioned.fromRect(
                  rect: box,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.darkBg.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(color: AppColors.darkBorder),
                    ),
                  ),
                ),
                // 面板子树: 显式尺寸盒 + 动画圆角裁剪 (裁剪沿随底盒几何走)
                Positioned.fill(
                  child: Opacity(
                    opacity: panelOpacity,
                    child: ClipPath(
                      clipper: _MorphRRectClipper(rr),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: spec.expand ? spec.tw : winW,
                          height: spec.expand ? spec.th : winH,
                          child: _panel,
                        ),
                      ),
                    ),
                  ),
                ),
                // 胶囊子树: 固定 100×36 (108×44 减四周 4dp 柔光边距)。
                // expand 停在 (4,4) 原位淡出; collapse 直接淡入在目标位
                // (fx+4, fy+4), 面板缩过去与之合流。
                Positioned(
                  left: spec.expand ? 4 : spec.fx + 4,
                  top: spec.expand ? 4 : spec.fy + 4,
                  child: Opacity(opacity: pillOpacity, child: _pill),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 动画圆角矩形裁剪器 (面板子树的裁剪沿随变形底盒几何走)
class _MorphRRectClipper extends CustomClipper<Path> {
  final RRect rrect;
  const _MorphRRectClipper(this.rrect);

  @override
  Path getClip(Size size) => Path()..addRRect(rrect);

  @override
  bool shouldReclip(_MorphRRectClipper oldClipper) =>
      oldClipper.rrect != rrect;
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
