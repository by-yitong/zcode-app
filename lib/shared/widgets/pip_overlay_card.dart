import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../../core/services/pip_service.dart';
import '../theme/app_design_tokens.dart';
import '../theme/app_theme.dart';

// ================================================================
// 悬浮窗进度监视器 UI (overlay 独立引擎侧)
//
// 由 main.dart 的 overlayMain() 挂载 (flutter_overlay_window 原生侧按
// "overlayMain" 名字创建独立引擎)。固定深色卡, 不依赖跨引擎主题同步。
//
// 布局预算 (与 pipWindowHeight 公式 88 + N*20 严格对齐):
//   上下 padding 10*2 + 标题栏 44 + 正文 N*20 + 页码条 24 = 88 + N*20
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

/// 悬浮窗卡片: 左右滑切会话 (PageView) / 上下滑看尾部缓冲 / 轻点回跳会话
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

  // 拖动手柄: 以 getOverlayPosition 为基准累积位移 (enableDrag:false 原生
  // 拖动会抢内容手势, 故由标题栏手柄自行驱动)
  OverlayPosition _dragBase = const OverlayPosition(0, 0);
  bool _dragBaseReady = false;

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
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }

  void _onMessage(dynamic raw) {
    final snap = PipSnapshot.decode(raw);
    if (snap == null || !mounted) return;
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
    });
  }

  void _onPanStart(DragStartDetails details) {
    _dragBaseReady = false;
    unawaited(() async {
      final pos = await _pip.getOverlayPosition();
      if (pos != null) {
        _dragBase = pos;
        _dragBaseReady = true;
      }
    }());
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_dragBaseReady) return;
    _dragBase = OverlayPosition(
      _dragBase.x + details.delta.dx,
      _dragBase.y + details.delta.dy,
    );
    unawaited(_pip.moveOverlay(_dragBase));
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _snapshot?.sessions ?? const <PipSessionSnapshot>[];
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
            child: sessions.isEmpty
                ? const _EmptyBody()
                : Column(
                    children: [
                      _Header(
                        session: sessions[_index.clamp(0, sessions.length - 1)],
                        onPanStart: _onPanStart,
                        onPanUpdate: _onPanUpdate,
                        onClose: () => unawaited(_close()),
                      ),
                      Expanded(
                        child: PageView.builder(
                          itemCount: sessions.length,
                          onPageChanged: (value) =>
                              setState(() => _index = value),
                          itemBuilder: (context, index) {
                            final session = sessions[index];
                            return _SessionBody(
                              key: ValueKey('pip-page-${session.key}'),
                              session: session,
                              onOpen: (key) =>
                                  _send(encodePipAction(PipOpenAction(key))),
                            );
                          },
                        ),
                      ),
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

/// 标题栏: 状态点 + 标题 + X; 同时是拖动手柄 (onPanUpdate 累积位移 → moveOverlay)
class _Header extends StatelessWidget {
  final PipSessionSnapshot session;
  final void Function(DragStartDetails) onPanStart;
  final void Function(DragUpdateDetails) onPanUpdate;
  final VoidCallback onClose;

  const _Header({
    required this.session,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.darkBorderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: onPanStart,
              onPanUpdate: onPanUpdate,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    _StatusDot(session: session),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        session.title,
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
          IconButton(
            icon: const Icon(
              Icons.close_rounded,
              size: 16,
              color: AppColors.darkInkSecondary,
            ),
            tooltip: '关闭悬浮窗',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// 运行状态点: 运行中呼吸点 (accent) / 完成绿点 / 出错红点
class _StatusDot extends StatelessWidget {
  final PipSessionSnapshot session;
  const _StatusDot({required this.session});

  @override
  Widget build(BuildContext context) {
    final color = session.running
        ? AppColors.accent
        : session.error
        ? AppColors.danger
        : AppColors.success;
    final dot = Container(
      key: ValueKey('pip-dot-${session.key}'),
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (!session.running) return dot;
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

/// 单会话页: 正文可上下滚动的尾部缓冲 (初始停最底部; 底部自动跟随,
/// 翻历史中保持位置); 单页轻点 → 回传 open 动作。
class _SessionBody extends StatefulWidget {
  final PipSessionSnapshot session;
  final void Function(String key) onOpen;

  const _SessionBody({super.key, required this.session, required this.onOpen});

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
    final changed = !listEquals(oldWidget.session.lines, widget.session.lines);
    if (changed && _atBottom) {
      _jumpToBottomAfterFrame(); // 在底部 → 自动跟随; 翻历史中保持位置
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
    final lines = widget.session.lines;
    return GestureDetector(
      // 轻点 (非拖动/滑动) → 回传 open, 由主 App 关悬浮窗 + 跳会话
      onTap: () => widget.onOpen(widget.session.key),
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lines.isEmpty)
              const SizedBox(
                height: pipLineExtent,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '暂无 AI 输出',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.darkInkMuted,
                    ),
                  ),
                ),
              ),
            for (final line in lines)
              SizedBox(
                height: pipLineExtent,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kMonoFont,
                      fontFamilyFallback: ['monospace'],
                      fontSize: 11,
                      height: 1.0,
                      color: AppColors.darkInkSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
