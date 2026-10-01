import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/logging/app_logger.dart';
import '../core/services/pip_service.dart';
import '../data/models/workspace.dart';
import '../shared/theme/app_router.dart';
import 'app_providers.dart';
import 'chat_provider.dart';

// ================================================================
// 悬浮窗进度监视器 (画中画) providers
//
// 职责:
//   - pipServiceProvider: flutter_overlay_window 封装
//   - pipLinesProvider:   正文视口行数设置 (SharedPreferences 持久化,
//                         key pip.lines, 默认 4, 范围 1–10; main() 启动 override)
//   - pipSizeStepProvider: 尺寸档位 0–3 (key pip.sizeStep, 默认 0; 双击循环,
//                         档位动作内持久化; main() 启动恢复)
//   - pipAutoOpenProvider: 后台自动打开小窗开关 (key pip.autoOpen, 默认 false)
//   - pipModeProvider:    窗口模式状态机 v5 (expanded 展开 / collapsed 胶囊 /
//                         hidden 完全隐藏 — 窗口 1×1 移出屏, 活着恢复快)
//   - pipFormProvider:    形态记忆 (用户最后主动选择的形态, key pip.form)。
//                         自动打开 / 后台恢复 / alreadyActive 恢复都按它:
//                         用户最小化成胶囊后, 下次弹窗仍是胶囊, 点胶囊展开
//                         才恢复展开形态
//   - pipExpandedPosProvider: 最近展开位置记忆 (dp), 隐藏/收拢前记录、恢复时 move 回
//   - pipPillPosProvider: 胶囊位置记忆 (dp, key pip.pillX/pip.pillY),
//                         胶囊拖拽松手经 pillMoved 动作更新
//   - pipOverlayActiveProvider / pipPinnedTaskProvider: 悬浮窗开关 + 钉住的会话
//   - pipMonitorProvider: 打开期间存活 (非 autoDispose)。对页面集合内每个
//                         会话 ref.watch(chatProvider(chatRef)) 保活并聚合
//                         尾部缓冲, 输出 IPC 快照
//   - pipPushSchedulerProvider: 节流 500ms shareData 推快照 + 行数变化 resize
//   - pipLivenessProvider: 悬浮窗被 X 关闭后主引擎收不到通知, 轮询兜底回收
//   - pipActionPollerProvider: 悬浮窗打开期间 300ms 轮询 SharedPreferences
//                         动作信箱 (pip.action), 取走即清空 (IPC 契约 v5)
//   - pipActionHandlerProvider: 处理悬浮窗七类动作 (open/home/size/collapse/
//                         minimize/expand/pillMoved, 信箱轮询喂入)
//   - openPipOverlay / hidePipOverlay / restorePipFromHidden /
//     collapsePipToPill / expandPipFromPill: 顶层例程, 供动作处理器与
//                         main.dart 生命周期复用; Widget 侧 (WidgetRef 无公共
//                         接口) 经 pipOpenOverlayProvider 等函数 provider 间接调用
//
// 保活链: ZcodeApp.listenManual(pipMonitorProvider) → 激活聚合;
// 关闭时 pipOverlayActiveProvider=false → 页面集合清空 → 各 chatProvider
// 随 watch 撤销自动销毁。
// ================================================================

final pipServiceProvider = Provider<PipService>((ref) => const PipService());

/// 悬浮窗正文视口行数 (悬浮窗开着时改动会 resizeOverlay + 立即重推, 即时生效)
final pipLinesProvider = StateProvider<int>((ref) => pipDefaultLines);

/// 悬浮窗尺寸档位 0–3 (双击循环; 双击动作内持久化, main() 启动恢复)
final pipSizeStepProvider = StateProvider<int>((ref) => pipDefaultSizeStep);

/// 后台自动打开小窗 (切到其他应用时自动弹出悬浮窗, 需有进行中会话)
final pipAutoOpenProvider = StateProvider<bool>((ref) => false);

/// 悬浮窗窗口模式 (状态机 v5):
/// - expanded  展开态
/// - collapsed 胶囊态 (108×44, 可拖拽)
/// - hidden    完全隐藏 (app 在前台: 窗口 resize 1×1 移出屏外左上角,
///             不走 closeOverlay — 窗口活着, 切后台 restorePipFromHidden
///             直接 resize/move 回来, 免重走 show 的权限/首推时序)
enum PipMode { expanded, collapsed, hidden }

final pipModeProvider = StateProvider<PipMode>((ref) => PipMode.expanded);

/// 形态记忆 (v5): 用户最后主动选择的形态 (最小化/拖出屏 → collapsed,
/// 点胶囊展开 → expanded)。区别于 PipMode (描述窗口"现在"的物理形态):
/// 自动打开 / 后台恢复 / alreadyActive 恢复都按 form — 用户最小化成胶囊后,
/// 下次自动弹出的仍是胶囊, 直到点胶囊展开才恢复展开形态。
enum PipForm { expanded, collapsed }

/// 形态记忆持久化 key (String: "expanded" | "collapsed"; main() 启动恢复)
const String kPipFormPrefKey = 'pip.form';

final pipFormProvider = StateProvider<PipForm>((ref) => PipForm.expanded);

/// prefs 原始值 → 形态记忆 (空/损坏/未知值回落 expanded)
PipForm pipFormFromPref(Object? raw) =>
    raw == PipForm.collapsed.name ? PipForm.collapsed : PipForm.expanded;

/// 形态记忆持久化 (最小化/展开/拖出屏收拢时写入; 失败仅落日志不阻断状态机 —
/// 内存 provider 已先行更新, 最坏退化为本次进程内记忆)
Future<void> persistPipForm(PipForm form) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPipFormPrefKey, form.name);
  } catch (e) {
    appLog.w('[Pip] 持久化形态记忆失败: $e');
  }
}

/// 最近展开位置记忆 (逻辑 dp): 隐藏/收拢前 getOverlayPosition 记录,
/// 恢复展开时 moveOverlay 回去 (钳回屏内)
final pipExpandedPosProvider = StateProvider<OverlayPosition?>((ref) => null);

/// 胶囊位置记忆 (逻辑 dp): 胶囊拖拽松手经 pillMoved 动作更新并持久化
/// (kPipPillXPrefKey/kPipPillYPrefKey); 收拢/隐藏恢复时胶囊放回记忆位,
/// 无记忆则顶部居中 (灵动岛式)。
final pipPillPosProvider = StateProvider<OverlayPosition?>((ref) => null);

/// 悬浮窗是否处于打开状态 (show 失败 / 被 X 关闭时回滚为 false)
final pipOverlayActiveProvider = StateProvider<bool>((ref) => false);

/// 进入悬浮窗时钉住的当前会话 (即使已完成也保留为页)
final pipPinnedTaskProvider = StateProvider<String?>((ref) => null);

/// 页面集合 = 运行中会话 (allTasksProvider status==running, updatedAt 倒序)
///          ∪ 进入悬浮窗时的当前会话 (钉住, 完成后也保留)
List<Task> _pipPages(Ref ref) {
  final active = ref.watch(pipOverlayActiveProvider);
  if (!active) return const <Task>[];
  // relay 未连接时 chatProvider 会抛错, 直接空页
  if (ref.watch(relayClientProvider) == null) return const <Task>[];
  final all = ref.watch(allTasksProvider);
  final pinnedId = ref.watch(pipPinnedTaskProvider);
  final running = all.where((t) => t.status == TaskStatus.running).toList()
    ..sort(
      (a, b) => (b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
    );
  final pinned = pinnedId == null
      ? null
      : all.where((t) => t.id == pinnedId).firstOrNull;
  final pages = <Task>[...running];
  if (pinned != null && !pages.any((t) => t.id == pinned.id)) {
    pages.add(pinned); // 用户主动钉的当前会话
  }
  return pages;
}

/// workspaceIdentity 从工作区列表对齐 (ChatScreen 同款)
List<Workspace> _pipWorkspaces(Ref ref) =>
    ref.watch(workspaceListProvider).valueOrNull ?? const <Workspace>[];

/// ChatRef 构造
ChatRef _pipChatRef(Ref ref, Task task) {
  final ws = _pipWorkspaces(
    ref,
  ).where((w) => w.workspaceKey == task.workspaceKey).firstOrNull;
  return ChatRef(
    taskId: task.id,
    workspacePath: task.workspaceKey,
    workspaceIdentity: ws?.workspaceIdentity,
  );
}

// ================================================================
// 监视器: 页面集合聚合 → IPC 快照 (非 autoDispose)
// ================================================================

/// 聚合页面集合内各会话尾部缓冲, 输出契约快照。
/// watch(chatProvider) 即保活: 悬浮窗打开期间页面集合内会话的
/// chatProvider 不会被 autoDispose 回收, 流式更新触发快照重建。
final pipMonitorProvider = Provider<PipSnapshot>((ref) {
  final pages = _pipPages(ref);
  final sessions = <PipSessionSnapshot>[];
  for (final task in pages) {
    final chatState = ref.watch(chatProvider(_pipChatRef(ref, task)));
    sessions.add(
      PipSessionSnapshot(
        key: task.id,
        title: task.title,
        running: task.status == TaskStatus.running,
        error: task.status == TaskStatus.error || chatState.error != null,
        text: extractPipTailText(
          chatState,
          running: task.status == TaskStatus.running,
        ),
      ),
    );
  }
  // 主 App 侧 index: 初始页 = 钉住的当前会话位置 (夹紧); 用户滑动只发生在
  // 悬浮窗引擎侧, 集合变化时悬浮窗按此 index 重新对齐
  final pinnedIdx = pages.indexWhere(
    (t) => t.id == ref.watch(pipPinnedTaskProvider),
  );
  // 屏幕物理尺寸 (打开悬浮窗时由 ChatScreen 记录, 悬浮窗松手钳制回屏用)
  final screen = ref.watch(pipScreenPxProvider);
  // 收拢态标志 (v4.1): resize 后悬浮窗引擎 MediaQuery 可能不刷新, 收拢
  // 渲染由快照字段驱动, 不赌窗口尺寸
  final collapsed = ref.watch(pipCollapsedProvider);
  return PipSnapshot(
    v: kPipSnapshotVersion,
    index: pinnedIdx > 0 ? pinnedIdx : 0,
    sessions: sessions,
    screenW: screen?.w,
    screenH: screen?.h,
    collapsed: collapsed,
  );
});

/// 窗口收拢态 (与 pipModeProvider 联动但独立成 bool: 快照聚合直接 watch,
/// true 时悬浮窗渲染顶部胶囊)
final pipCollapsedProvider = StateProvider<bool>((ref) => false);

/// 屏幕物理尺寸 px (主 App 侧打开悬浮窗时写入; 悬浮窗引擎拿不到真实屏幕
/// 大小 — 它的 MediaQuery 是悬浮窗自身窗口 — 经快照带给它做松手钳制)
final pipScreenPxProvider = StateProvider<({int w, int h})?>((ref) => null);

/// 屏幕逻辑尺寸 dp + dpr (与 pipScreenPxProvider 同源, 打开悬浮窗时一并写入)。
/// 收拢/恢复展开走原生 resizeOverlay/moveOverlay, 必须传逻辑 dp (原生侧
/// dpToPx 换算一次), 故单独记录 dp 维度。
final pipScreenDpProvider =
    StateProvider<({double w, double h, double dpr})?>((ref) => null);

// ================================================================
// 推送调度: 节流 500ms + 行数变化 resize
// ================================================================

final pipPushSchedulerProvider = Provider<PipPushScheduler>((ref) {
  final scheduler = PipPushScheduler(ref);
  // 行数设置变化: 悬浮窗开着 → resizeOverlay + 立即重推 (设置即时生效)。
  // (ref.listen 在 provider build 期注册, 合法)
  ref.listen(pipLinesProvider, (prev, next) {
    if (prev == next) return;
    unawaited(scheduler.onLinesChanged(next));
  });
  // 悬浮窗开/关 → 启停后台轮询推送。真机实测: app 后台化后 Riverpod 懒加载
  // Provider 不再重算 (listenManual 收不到通知), 事件驱动推送在后台失效;
  // 轮询 read() 强制重算快照, 有变化才推, 保证后台持续刷新。
  ref.listen(pipOverlayActiveProvider, (prev, next) {
    scheduler.setPolling(next);
    if (next) unawaited(scheduler.pushNow());
  });
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

class PipPushScheduler {
  PipPushScheduler(this._ref);

  /// 节流窗口 (trailing): 窗口内多次快照更新合并为一次推送
  static const Duration _throttle = Duration(milliseconds: 500);

  /// 后台兜底轮询间隔 (与节流同频, 事件驱动失效时由它接管)
  static const Duration _pollInterval = Duration(milliseconds: 500);

  final Ref _ref;
  Timer? _timer;
  Timer? _pollTimer;
  String? _lastPushedJson;
  int _windowWidthPx = 0;
  double _devicePixelRatio = 1;

  /// 打开悬浮窗时记录窗口物理尺寸 (行数变化 resize 用)
  void configure({
    required int windowWidthPx,
    required double devicePixelRatio,
  }) {
    _windowWidthPx = windowWidthPx;
    _devicePixelRatio = devicePixelRatio;
  }

  /// 悬浮窗开/关 → 启停兜底轮询 (打开时立即首推防白屏)
  void setPolling(bool active) {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!active) return;
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  void _pollOnce() {
    if (!_ref.read(pipOverlayActiveProvider)) return;
    unawaited(pushNow(ifChangedSince: _lastPushedJson));
  }

  /// 节流推送 (快照变化时由 ZcodeApp 的 listenManual 触发)
  void schedule() {
    if (_timer != null) return;
    _timer = Timer(_throttle, () {
      _timer = null;
      unawaited(pushNow());
    });
  }

  /// 立即推送当前快照 (showOverlay 成功后首推防白屏 / resize 后)。
  /// [ifChangedSince] 非空时内容一致则跳过 (轮询去重, 避免无变化空推)。
  Future<void> pushNow({String? ifChangedSince}) async {
    try {
      final snapshot = _ref.read(pipMonitorProvider);
      final json = jsonEncode(snapshot.toJson());
      if (ifChangedSince != null && json == ifChangedSince) return;
      final totalChars = snapshot.sessions.fold<int>(
        0,
        (n, s) => n + s.text.length,
      );
      appLog.d(
        '[Pip] push sessions=${snapshot.sessions.length} chars=$totalChars',
      );
      await _ref.read(pipServiceProvider).send(json);
      _lastPushedJson = json;
    } catch (e) {
      appLog.w('[Pip] 推送快照失败: $e');
    }
  }

  /// 行数设置变化: resize 窗口 + 立即重推。
  /// 注意: 插件 resizeOverlay 原生侧对入参做 dp→px 换算 (与 showOverlay 的
  /// 原始 px 语义不一致), 必须传逻辑 dp, 否则窗口被放大 devicePixelRatio 倍。
  /// 高度按当前尺寸档位的倍率计算 (无屏幕 dp 记录时退回无档位公式兜底)。
  /// 隐藏/胶囊态跳过 resize: 隐藏窗口被 resize 会撕开 1×1 伪装重新上屏
  /// (用户正在 app 里), 胶囊会被撑成大窗; 新行数在恢复/展开时按当前
  /// lines 重算尺寸自然生效, 这里只重推内容。
  Future<void> onLinesChanged(int lines) async {
    if (!_ref.read(pipOverlayActiveProvider)) return;
    if (_ref.read(pipModeProvider) != PipMode.expanded) {
      appLog.d('[Pip] 行数变化跳过 resize: 当前非展开态');
      await pushNow();
      return;
    }
    final widthDp = (_windowWidthPx / _devicePixelRatio).round();
    final screen = _ref.read(pipScreenDpProvider);
    final heightDp = screen == null
        ? pipWindowHeight(lines)
        : pipWindowHeightForStep(lines, _ref.read(pipSizeStepProvider), screen.h);
    await _ref
        .read(pipServiceProvider)
        .resize(widthDp, heightDp.round());
    await pushNow();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}

// ================================================================
// 兜底回收: X 关闭悬浮窗后主引擎收不到通知 → 打开期间轮询 isActive
// ================================================================

/// 由 ZcodeApp build watch 激活。active 置位后延迟 4s 开始轮询
/// (覆盖 showOverlay 启动窗口, 避免弹窗过程中误判已关闭)。
final pipLivenessProvider = Provider<void>((ref) {
  final active = ref.watch(pipOverlayActiveProvider);
  if (!active) return;
  Timer? periodic;
  final grace = Timer(const Duration(seconds: 4), () {
    periodic = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!ref.read(pipOverlayActiveProvider)) return;
      if (await ref.read(pipServiceProvider).isActive()) return;
      appLog.d('[Pip] 悬浮窗已关闭, 回收监视状态');
      ref.read(pipOverlayActiveProvider.notifier).state = false;
    });
  });
  ref.onDispose(() {
    grace.cancel();
    periodic?.cancel();
  });
});

// ================================================================
// 悬浮窗 → 主 App 动作: SharedPreferences 信箱轮询 (IPC 契约 v4)
// (overlay_messenger 通道主引擎槽位必须留给原生转发器, 故反向不走 shareData)
// ================================================================

/// 动作信箱轮询周期
const Duration _pipActionPollInterval = Duration(milliseconds: 300);

/// 悬浮窗打开期间 300ms 轮询动作信箱, 读到动作交给
/// pipActionHandlerProvider。由 ZcodeApp build watch 激活;
/// active 变 false / provider dispose 时取消 Timer (不留 pending Timer)。
final pipActionPollerProvider = Provider<void>((ref) {
  final active = ref.watch(pipOverlayActiveProvider);
  if (!active) return;
  final pip = ref.read(pipServiceProvider);
  final timer = Timer.periodic(_pipActionPollInterval, (_) async {
    if (!ref.read(pipOverlayActiveProvider)) return;
    try {
      final action = await pip.takeActionMailbox();
      if (action != null) {
        ref.read(pipActionHandlerProvider)(action);
      }
    } catch (e) {
      appLog.w('[Pip] 动作信箱轮询失败: $e');
    }
  });
  ref.onDispose(timer.cancel);
});

/// 悬浮窗动作处理 (pipActionPollerProvider 读到信箱动作后调用; 契约 v5)
final pipActionHandlerProvider =
    Provider<void Function(PipOverlayAction)>((ref) {
  final pip = ref.read(pipServiceProvider);
  return (PipOverlayAction action) {
    switch (action) {
      case PipOpenAction(:final key):
        unawaited(_openPipSession(ref, pip, key));
      case PipHomeAction():
        // 空态 home 钮: 仅回前台, 不跳路由 (无可跳会话)
        unawaited(pip.bringToForeground());
      case PipSizeAction():
        unawaited(_cyclePipSizeStep(ref));
      case PipCollapseAction():
        // 拖出屏: v5 与最小化同语义 — 收拢成胶囊放记忆位, form=collapsed
        unawaited(collapsePipToPill(ref));
      case PipMinimizeAction():
        // 最小化钮: 同上 (form 记忆统一后不再区分"普通收拢/用户隐藏")
        unawaited(collapsePipToPill(ref));
      case PipExpandAction():
        unawaited(expandPipFromPill(ref));
      case PipPillMovedAction(:final x, :final y):
        unawaited(_persistPipPillPos(ref, x, y));
    }
  };
});

/// 胶囊拖拽松手: 记忆 + 持久化胶囊位置 (悬浮窗引擎已钳回屏内传最终坐标),
/// 并确保 mode=collapsed (拖拽只可能发生在胶囊态, 兜底对齐状态机)。
Future<void> _persistPipPillPos(Ref ref, double x, double y) async {
  ref.read(pipPillPosProvider.notifier).state = OverlayPosition(x, y);
  ref.read(pipModeProvider.notifier).state = PipMode.collapsed;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kPipPillXPrefKey, x);
    await prefs.setDouble(kPipPillYPrefKey, y);
    appLog.d('[Pip] 胶囊位置记忆 → ($x, $y)');
  } catch (e) {
    appLog.w('[Pip] 持久化胶囊位置失败: $e');
  }
}

/// 悬浮窗 home 钮 (有会话) → bringToForeground + 路由跳转对应会话
/// (与 history_drawer 跳会话同款: /chat?workspace=...&task=...)
Future<void> _openPipSession(Ref ref, PipService pip, String key) async {
  // 先把主 App 提到前台 (悬浮窗引擎无法启动 Activity, 必须经主引擎转调原生)
  await pip.bringToForeground();
  final tasks = ref.read(allTasksProvider);
  final index = tasks.indexWhere((t) => t.id == key);
  // 悬浮窗早于任务列表加载等场景反查不到 → 放弃跳转 (不可达页面, 别跳空路由)
  if (index < 0) return;
  final task = tasks[index];
  final wsKey = task.workspaceKey;
  final workspaces =
      ref.read(workspaceListProvider).valueOrNull ?? const <Workspace>[];
  Workspace? ws = workspaces.where((w) => w.workspaceKey == wsKey).firstOrNull;
  ws ??= Workspace(
    workspaceKey: wsKey,
    workspaceIdentity: wsKey,
    workspacePath: wsKey,
    name: wsKey,
  );
  ref.read(selectedWorkspaceProvider.notifier).state = ws;
  goRouterProvider.go(
    '${AppRoutes.chat}?workspace=${Uri.encodeComponent(wsKey)}'
    '&task=${Uri.encodeComponent(key)}',
  );
}

// ================================================================
// 窗口例程: 打开 / 完全隐藏 / 隐藏恢复 / 收拢为胶囊 / 原地展开 / 双击循环档位
// (主 App 侧统一入口, 供动作处理器与 main.dart 生命周期复用)
// ================================================================

/// 打开结果 (调用方按结果决定 UI 引导: 聊天页弹 snackbar, 自动打开只落日志)
enum PipOpenResult { opened, alreadyActive, permissionDenied, failed }

/// 状态栏高度 (主引擎 MediaQuery 取 — 悬浮窗引擎拿不到系统栏 inset;
/// TYPE_APPLICATION_OVERLAY 可与状态栏重叠, 胶囊停在状态栏下沿更稳)
double _pipStatusBarPadding() => MediaQueryData.fromView(
  WidgetsBinding.instance.platformDispatcher.views.first,
).padding.top;

/// 胶囊默认位置: 顶部居中、状态栏下沿 +6dp (灵动岛式; 无用户记忆位时用)。
/// TOP|LEFT 锚点下 x/y = 窗口左上角绝对 dp (原生侧 dpToPx 换算)。
OverlayPosition _pipDefaultPillPos(double screenWDp) =>
    OverlayPosition((screenWDp - pipCollapsedWidth) / 2, _pipStatusBarPadding() + 6);

/// 胶囊放置位 (收拢/恢复/按胶囊形态打开共用): 用户拖拽记忆位优先,
/// 无记忆则顶部居中默认。
OverlayPosition _pipPillPlacement(Ref ref, double screenWDp) =>
    ref.read(pipPillPosProvider) ?? _pipDefaultPillPos(screenWDp);

/// 打开悬浮窗 (顶层函数, 聊天页手动开 / 进后台自动开复用), 按形态记忆打开:
/// 权限检查 (无权限返回 permissionDenied, 不弹系统设置 — 引导方式由调用方
/// 决定) → 幂等 isActive → configure scheduler → 记录屏幕尺寸 (px 快照钳制
/// 用 + dp 原生 resize/move 用) → 钉住会话 ([pinTaskId] 非空才写) →
/// 按 form 设初始 mode/collapsed → show → 首推快照。失败回滚 active=false。
///
/// 屏幕尺寸用 MediaQueryData.fromView 取 (不依赖 BuildContext — 生命周期
/// 回调没有 context)。
Future<PipOpenResult> openPipOverlay(Ref ref, {String? pinTaskId}) async {
  final pip = ref.read(pipServiceProvider);
  appLog.d('[Pip] 打开流程开始');
  // 幂等: 已打开时仅隐藏态需要恢复 (按形态记忆) — 回 app 时窗口被完全隐藏
  // 了, 点小窗按钮的意图就是"要小窗", 必须先放出来; 胶囊态保持 (用户自己
  // 收的胶囊, 打扰等于替用户做主)
  if (await pip.isActive()) {
    appLog.d('[Pip] 已打开');
    if (ref.read(pipModeProvider) == PipMode.hidden) {
      await restorePipFromHidden(ref);
    }
    return PipOpenResult.alreadyActive;
  }
  if (!await pip.isPermissionGranted()) {
    appLog.d('[Pip] 无悬浮窗权限');
    return PipOpenResult.permissionDenied;
  }
  final mq = MediaQueryData.fromView(
    WidgetsBinding.instance.platformDispatcher.views.first,
  );
  final form = ref.read(pipFormProvider);
  // 初始尺寸/位置按形态记忆: 胶囊记忆 → 108×44 放胶囊记忆位 (无记忆顶部
  // 居中); 展开记忆 → 档位尺寸, 水平居中、垂直约 0.3 屏高 (逻辑 dp)
  final int widthPx;
  final int heightPx;
  final double startXdp;
  final double startYdp;
  if (form == PipForm.collapsed) {
    widthPx = (pipCollapsedWidth * mq.devicePixelRatio).round();
    heightPx = (pipCollapsedHeight * mq.devicePixelRatio).round();
    final pill = ref.read(pipPillPosProvider) ??
        _pipDefaultPillPos(mq.size.width);
    startXdp = pill.x;
    startYdp = pill.y;
  } else {
    final step = ref.read(pipSizeStepProvider);
    final widthDp = mq.size.width * pipWindowWidthFractionForStep(step);
    widthPx = (widthDp * mq.devicePixelRatio).round();
    final heightDp = pipWindowHeightForStep(
      ref.read(pipLinesProvider),
      step,
      mq.size.height,
    );
    heightPx = (heightDp * mq.devicePixelRatio).round();
    startXdp = (mq.size.width - widthDp) / 2;
    startYdp = mq.size.height * 0.3;
  }
  try {
    ref
        .read(pipPushSchedulerProvider)
        .configure(windowWidthPx: widthPx, devicePixelRatio: mq.devicePixelRatio);
    ref.read(pipScreenPxProvider.notifier).state = (
      w: (mq.size.width * mq.devicePixelRatio).round(),
      h: (mq.size.height * mq.devicePixelRatio).round(),
    );
    ref.read(pipScreenDpProvider.notifier).state = (
      w: mq.size.width,
      h: mq.size.height,
      dpr: mq.devicePixelRatio,
    );
    if (pinTaskId != null) {
      ref.read(pipPinnedTaskProvider.notifier).state = pinTaskId;
    }
    ref.read(pipModeProvider.notifier).state =
        form == PipForm.collapsed ? PipMode.collapsed : PipMode.expanded;
    ref.read(pipCollapsedProvider.notifier).state = form == PipForm.collapsed;
    ref.read(pipOverlayActiveProvider.notifier).state = true;
    await pip.show(
      widthPx: widthPx,
      heightPx: heightPx,
      startX: startXdp.round(),
      startY: startYdp.round(),
    );
    // 防白屏 (IPC v2: 悬浮窗不再回传 refresh, 由主 App 主动首推快照)
    appLog.d('[Pip] show 成功 (form=${form.name}) → 首推快照');
    await ref.read(pipPushSchedulerProvider).pushNow();
    // 展开形态记录展开位置 (后续收拢/隐藏 → 恢复展开以此为基准)
    if (form == PipForm.expanded) {
      ref.read(pipExpandedPosProvider.notifier).state = OverlayPosition(
        startXdp.round().toDouble(),
        startYdp.round().toDouble(),
      );
    }
    return PipOpenResult.opened;
  } catch (e) {
    appLog.w('[Pip] showOverlay 失败: $e');
    ref.read(pipOverlayActiveProvider.notifier).state = false;
    return PipOpenResult.failed;
  }
}

/// 完全隐藏悬浮窗 (app 回前台时任何形态都让位):
/// 窗口 resize 成 1×1 dp 并移到屏外左上角 (-2,-2) — 不走 closeOverlay,
/// 窗口活着恢复快 (切后台 restorePipFromHidden 直接 resize/move 回来,
/// 免重走 show 的权限/首推时序; close 后重开会有白屏启动窗口)。
/// mode 已是 hidden 则幂等直接返回; collapsedProvider 不动 (1×1 窗口在屏外
/// 不可见, 渲染什么都不上屏, 恢复时按形态重写该标志)。
Future<void> hidePipOverlay(Ref ref) async {
  if (!ref.read(pipOverlayActiveProvider)) return;
  if (ref.read(pipModeProvider) == PipMode.hidden) return;
  final pip = ref.read(pipServiceProvider);
  // 展开态先记忆位置 (恢复展开时 move 回去); 胶囊位有独立记忆 (pillMoved),
  // 这里不动
  if (ref.read(pipModeProvider) == PipMode.expanded) {
    final pos = await pip.getOverlayPosition();
    if (pos != null) ref.read(pipExpandedPosProvider.notifier).state = pos;
  }
  // resize/move 均传逻辑 dp (原生侧 dpToPx 换算一次); -2 连 1dp 边框也不入屏
  await pip.resize(1, 1);
  await pip.moveOverlay(const OverlayPosition(-2, -2));
  ref.read(pipModeProvider.notifier).state = PipMode.hidden;
  appLog.d('[Pip] 完全隐藏 (1×1 移出屏外)');
}

/// 从隐藏态恢复 (app 进后台): 按形态记忆恢复 —
/// collapsed → 胶囊回记忆位 (无记忆顶部居中); expanded → 档位尺寸 +
/// 展开位置记忆 (钳回屏内, 无记忆用打开默认位)。末尾重推快照
/// (resize 后悬浮窗引擎 MediaQuery 可能不刷新, 由快照 collapsed 字段驱动
/// 渲染切换, 重推保证胶囊/展开卡立即正确)。
Future<void> restorePipFromHidden(Ref ref) async {
  if (ref.read(pipModeProvider) != PipMode.hidden) return;
  final screen = ref.read(pipScreenDpProvider);
  if (screen == null) {
    appLog.w('[Pip] 恢复跳过: 无屏幕尺寸记录');
    return;
  }
  final pip = ref.read(pipServiceProvider);
  final form = ref.read(pipFormProvider);
  if (form == PipForm.collapsed) {
    final pill = _pipPillPlacement(ref, screen.w);
    await pip.resize(pipCollapsedWidth.round(), pipCollapsedHeight.round());
    await pip.moveOverlay(pill);
    ref.read(pipCollapsedProvider.notifier).state = true;
    ref.read(pipModeProvider.notifier).state = PipMode.collapsed;
    appLog.d('[Pip] 隐藏恢复为胶囊 (${pill.x}, ${pill.y})');
  } else {
    final step = ref.read(pipSizeStepProvider);
    final widthDp = screen.w * pipWindowWidthFractionForStep(step);
    final heightDp = pipWindowHeightForStep(
      ref.read(pipLinesProvider),
      step,
      screen.h,
    );
    await pip.resize(widthDp.round(), heightDp.round());
    // 无记忆位置用打开默认位 (水平居中、0.3 屏高); 有记忆钳回屏内
    // (隐藏期间旋转屏幕等可能让旧位置出屏)
    final pos = ref.read(pipExpandedPosProvider) ??
        OverlayPosition((screen.w - widthDp) / 2, screen.h * 0.3);
    final maxX = (screen.w - widthDp).clamp(0.0, screen.w);
    final maxY = (screen.h - heightDp).clamp(0.0, screen.h);
    await pip.moveOverlay(
      OverlayPosition(
        pos.x.clamp(0.0, maxX).toDouble(),
        pos.y.clamp(0.0, maxY).toDouble(),
      ),
    );
    ref.read(pipCollapsedProvider.notifier).state = false;
    ref.read(pipModeProvider.notifier).state = PipMode.expanded;
    // 同步 scheduler 宽度记录 (后续行数变化 resize 用)
    ref.read(pipPushSchedulerProvider).configure(
      windowWidthPx: (widthDp * screen.dpr).round(),
      devicePixelRatio: screen.dpr,
    );
    appLog.d('[Pip] 隐藏恢复为展开 step=$step w=${widthDp.round()} h=${heightDp.round()}');
  }
  await ref.read(pipPushSchedulerProvider).pushNow();
}

/// 收拢悬浮窗为胶囊 (v5 统一语义: 最小化钮 / 拖出屏收拢两个动作都走这里):
/// 展开态先记忆展开位置 → resize 108×44 → 胶囊放记忆位 (无记忆顶部居中;
/// 拖出屏不再贴拖出侧, 位置语义统一由用户拖拽记忆承载) →
/// form=collapsed 持久化 + mode=collapsed + 重推快照。
/// 原生 resizeOverlay/moveOverlay 均传逻辑 dp (原生侧 dpToPx 换算一次)。
Future<void> collapsePipToPill(Ref ref) async {
  if (!ref.read(pipOverlayActiveProvider)) return;
  final screen = ref.read(pipScreenDpProvider);
  if (screen == null) {
    appLog.w('[Pip] 收拢跳过: 无屏幕尺寸记录');
    return;
  }
  final pip = ref.read(pipServiceProvider);
  // 展开态先记忆位置 (恢复展开时 move 回去); 已是胶囊则位置没变无需重记
  if (ref.read(pipModeProvider) == PipMode.expanded) {
    final pos = await pip.getOverlayPosition();
    if (pos != null) ref.read(pipExpandedPosProvider.notifier).state = pos;
  }
  final pill = _pipPillPlacement(ref, screen.w);
  await pip.resize(pipCollapsedWidth.round(), pipCollapsedHeight.round());
  await pip.moveOverlay(pill);
  // form 记忆 = 用户最后主动选择的形态: 收拢后自动打开/后台恢复仍弹胶囊,
  // 直到点胶囊展开才翻回 expanded (持久化跨进程生效)
  ref.read(pipFormProvider.notifier).state = PipForm.collapsed;
  unawaited(persistPipForm(PipForm.collapsed));
  ref.read(pipModeProvider.notifier).state = PipMode.collapsed;
  // 收拢标志随快照推送驱动悬浮窗切换胶囊渲染 (MediaQuery 不刷新也可靠)
  ref.read(pipCollapsedProvider.notifier).state = true;
  await ref.read(pipPushSchedulerProvider).pushNow();
  appLog.d('[Pip] 收拢为胶囊 x=${pill.x} y=${pill.y}');
}

/// 在胶囊当前位置原地展开 (点胶囊):
/// 胶囊中心 = 当前窗口位置 (getOverlayPosition — 用户可能刚拖过, 拿不到用
/// 胶囊记忆位/默认位兜底) + (54, 22); 小窗顶部中点对齐胶囊中心, 顶部与胶囊
/// 齐平: x = 中心x - W/2, y = 胶囊 y; 钳回屏内后 resize + move。
/// form=expanded 持久化 (点胶囊 = 用户主动选展开形态)。
/// 展开不做 move 动画 — 原生窗口无过渡, 多步插值逐帧 resize/move 反而抖。
Future<void> expandPipFromPill(Ref ref) async {
  if (!ref.read(pipOverlayActiveProvider)) return;
  final screen = ref.read(pipScreenDpProvider);
  if (screen == null) {
    appLog.w('[Pip] 恢复展开跳过: 无屏幕尺寸记录');
    return;
  }
  final pip = ref.read(pipServiceProvider);
  final step = ref.read(pipSizeStepProvider);
  final lines = ref.read(pipLinesProvider);
  final widthDp = screen.w * pipWindowWidthFractionForStep(step);
  final heightDp = pipWindowHeightForStep(lines, step, screen.h);
  // 胶囊左上角: 窗口实际位置优先 (点胶囊时窗口就在胶囊位), 记忆位/默认位兜底
  final pill = await pip.getOverlayPosition() ??
      _pipPillPlacement(ref, screen.w);
  // 小窗顶部中点对齐胶囊中心; 变大后钳回屏内 (胶囊贴边时窗口必须整体可见)
  final centerX = pill.x + pipCollapsedWidth / 2;
  final maxX = (screen.w - widthDp).clamp(0.0, screen.w);
  final maxY = (screen.h - heightDp).clamp(0.0, screen.h);
  final x = (centerX - widthDp / 2).clamp(0.0, maxX).toDouble();
  final y = pill.y.clamp(0.0, maxY).toDouble();
  await pip.resize(widthDp.round(), heightDp.round());
  await pip.moveOverlay(OverlayPosition(x, y));
  // 新展开位置记忆 = 本次实际落位 (下次收拢→展开回到视觉连续的位置)
  ref.read(pipExpandedPosProvider.notifier).state = OverlayPosition(x, y);
  ref.read(pipFormProvider.notifier).state = PipForm.expanded;
  unawaited(persistPipForm(PipForm.expanded));
  ref.read(pipModeProvider.notifier).state = PipMode.expanded;
  ref.read(pipCollapsedProvider.notifier).state = false;
  // 同步 scheduler 的窗口宽度记录 (后续行数变化 resize 用) + 重推防白屏
  ref.read(pipPushSchedulerProvider).configure(
    windowWidthPx: (widthDp * screen.dpr).round(),
    devicePixelRatio: screen.dpr,
  );
  await ref.read(pipPushSchedulerProvider).pushNow();
  appLog.d('[Pip] 胶囊位原地展开 step=$step x=$x y=$y w=${widthDp.round()} h=${heightDp.round()}');
}

/// 双击循环尺寸档位: step=(step+1)%4 → 持久化 → resize 新宽高 (逻辑 dp) →
/// 更新 scheduler 宽度记录 → 重推快照。档位跨次打开生效。
/// v5 约束: 仅展开态触发 (双击手势本就挂在展开卡正文上, 此守卫兜底防
/// 动作信箱时序错位), 且不改 form (尺寸档位与形态记忆是两件事)。
Future<void> _cyclePipSizeStep(Ref ref) async {
  if (!ref.read(pipOverlayActiveProvider)) return;
  if (ref.read(pipModeProvider) != PipMode.expanded) {
    appLog.d('[Pip] 尺寸切换跳过: 非展开态');
    return;
  }
  final screen = ref.read(pipScreenDpProvider);
  if (screen == null) {
    appLog.w('[Pip] 尺寸切换跳过: 无屏幕尺寸记录');
    return;
  }
  final step = (ref.read(pipSizeStepProvider) + 1) % pipSizeStepCount;
  ref.read(pipSizeStepProvider.notifier).state = step;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPipSizeStepPrefKey, step);
  } catch (e) {
    appLog.w('[Pip] 持久化尺寸档位失败: $e');
  }
  final pip = ref.read(pipServiceProvider);
  final widthDp = screen.w * pipWindowWidthFractionForStep(step);
  final heightDp = pipWindowHeightForStep(
    ref.read(pipLinesProvider),
    step,
    screen.h,
  );
  await pip.resize(widthDp.round(), heightDp.round());
  // 变大后左上角不动会把右/下缘推出屏 (超大档全宽尤甚), 钳回屏内
  final pos = await pip.getOverlayPosition();
  if (pos != null) {
    final maxX = (screen.w - widthDp).clamp(0.0, screen.w);
    final maxY = (screen.h - heightDp).clamp(0.0, screen.h);
    final cx = pos.x.clamp(0.0, maxX);
    final cy = pos.y.clamp(0.0, maxY);
    if (cx != pos.x || cy != pos.y) {
      await pip.moveOverlay(OverlayPosition(cx.toDouble(), cy.toDouble()));
    }
  }
  ref.read(pipPushSchedulerProvider).configure(
    windowWidthPx: (widthDp * screen.dpr).round(),
    devicePixelRatio: screen.dpr,
  );
  await ref.read(pipPushSchedulerProvider).pushNow();
  appLog.d('[Pip] 尺寸档位 → $step w=${widthDp.round()} h=${heightDp.round()}');
}

// ================================================================
// Widget 侧调用桥: Riverpod 2 的 Ref / WidgetRef 无公共接口, 顶层例程
// (参数 Ref) 无法被 Widget 持有的 WidgetRef 直接调用, 经函数 provider
// 转发 (closure 捕获 provider 自身的 Ref; 非 autoDispose, 存活期等同 App)
// ================================================================

/// 聊天页 / 生命周期打开悬浮窗入口
final pipOpenOverlayProvider =
    Provider<Future<PipOpenResult> Function({String? pinTaskId})>((ref) {
  return ({String? pinTaskId}) => openPipOverlay(ref, pinTaskId: pinTaskId);
});

/// 生命周期: 收拢为胶囊 (动作处理器外部的调用入口)
final pipCollapseToPillProvider = Provider<Future<void> Function()>((ref) {
  return () => collapsePipToPill(ref);
});

/// 生命周期: 原地展开 (动作处理器外部的调用入口)
final pipExpandFromPillProvider = Provider<Future<void> Function()>((ref) {
  return () => expandPipFromPill(ref);
});

/// 生命周期: 完全隐藏 (main.dart 回前台时用 — 任何形态都让位给 app 全屏)
final pipHideOverlayProvider = Provider<Future<void> Function()>((ref) {
  return () => hidePipOverlay(ref);
});

/// 生命周期: 从隐藏态恢复 (main.dart 进后台时用, 按形态记忆恢复胶囊/展开)
final pipRestoreFromHiddenProvider = Provider<Future<void> Function()>((ref) {
  return () => restorePipFromHidden(ref);
});

// ================================================================
// 尾部文本提取 (设计文档"尾部行提取规则", 契约 v3: markdown 源文本)
// ================================================================

/// 从 ChatState 提取最新 AI 输出尾部 markdown 源文本:
/// 最新 assistant 消息按行切分取尾部至多 60 行; 不足时向前一条 assistant
/// 消息补足, 最多跨 3 条消息, 行间用 \n 连接; 超过 4000 字符从头部截掉。
/// 无任何 AI 文本且运行中 → 状态占位 ("思考中…"/"运行中…")。
String extractPipTailText(ChatState state, {required bool running}) {
  final buffer = <String>[];
  var scanned = 0;
  for (final message in state.messages.reversed) {
    if (message.role != 'assistant') continue;
    if (scanned >= 3) break;
    scanned++;
    final text = _assistantText(message);
    if (text.trim().isEmpty) continue;
    final messageLines = text.split('\n');
    final need = pipBufferLines - buffer.length;
    buffer.insertAll(
      0,
      messageLines.length > need
          ? messageLines.sublist(messageLines.length - need)
          : messageLines,
    );
    if (buffer.length >= pipBufferLines) break;
  }
  var joined = buffer.join('\n');
  if (joined.length > pipMaxTextChars) {
    joined = joined.substring(joined.length - pipMaxTextChars);
  }
  if (joined.trim().isEmpty) {
    return running ? (state.isResponding ? '思考中…' : '运行中…') : '';
  }
  return joined;
}

/// assistant 消息文本: parts 路径拼接 TextPart / 旧路径 content
String _assistantText(DisplayMessage message) {
  if (message.parts.isNotEmpty) {
    final buffer = StringBuffer();
    for (final part in message.parts) {
      if (part is TextPart) buffer.write(part.text);
    }
    final text = buffer.toString();
    if (text.trim().isNotEmpty) return text;
  }
  return message.content;
}
