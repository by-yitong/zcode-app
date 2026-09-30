import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
//   - pipOverlayActiveProvider / pipPinnedTaskProvider: 悬浮窗开关 + 钉住的会话
//   - pipMonitorProvider: 打开期间存活 (非 autoDispose)。对页面集合内每个
//                         会话 ref.watch(chatProvider(chatRef)) 保活并聚合
//                         尾部缓冲, 输出 IPC 快照
//   - pipPushSchedulerProvider: 节流 500ms shareData 推快照 + 行数变化 resize
//   - pipLivenessProvider: 悬浮窗被 X 关闭后主引擎收不到通知, 轮询兜底回收
//   - pipActionHandlerProvider: 处理悬浮窗回传动作 (refresh / open)
//
// 保活链: ZcodeApp.listenManual(pipMonitorProvider) → 激活聚合;
// 关闭时 pipOverlayActiveProvider=false → 页面集合清空 → 各 chatProvider
// 随 watch 撤销自动销毁。
// ================================================================

final pipServiceProvider = Provider<PipService>((ref) => const PipService());

/// 悬浮窗正文视口行数 (悬浮窗开着时改动会 resizeOverlay + 立即重推, 即时生效)
final pipLinesProvider = StateProvider<int>((ref) => pipDefaultLines);

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
        lines: extractPipTailLines(
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
  return PipSnapshot(
    v: kPipSnapshotVersion,
    index: pinnedIdx > 0 ? pinnedIdx : 0,
    sessions: sessions,
  );
});

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
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

class PipPushScheduler {
  PipPushScheduler(this._ref);

  /// 节流窗口 (trailing): 窗口内多次快照更新合并为一次推送
  static const Duration _throttle = Duration(milliseconds: 500);

  final Ref _ref;
  Timer? _timer;
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

  /// 节流推送 (快照变化时由 ZcodeApp 的 listenManual 触发)
  void schedule() {
    if (_timer != null) return;
    _timer = Timer(_throttle, () {
      _timer = null;
      unawaited(pushNow());
    });
  }

  /// 立即推送当前快照 (悬浮窗 refresh 动作 / resize 后)
  Future<void> pushNow() async {
    try {
      final snapshot = _ref.read(pipMonitorProvider);
      await _ref.read(pipServiceProvider).send(jsonEncode(snapshot.toJson()));
    } catch (e) {
      appLog.w('[Pip] 推送快照失败: $e');
    }
  }

  /// 行数设置变化: resize 窗口 + 立即重推
  Future<void> onLinesChanged(int lines) async {
    if (!_ref.read(pipOverlayActiveProvider)) return;
    await _ref
        .read(pipServiceProvider)
        .resize(_windowWidthPx, pipWindowHeightPx(lines, _devicePixelRatio));
    await pushNow();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
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
// 悬浮窗回传动作处理
// ================================================================

/// 悬浮窗回传动作处理 (main.dart 的 ZcodeApp 订阅 PipService.actions 后调用)
final pipActionHandlerProvider = Provider<void Function(PipOverlayAction)>((
  ref,
) {
  final pip = ref.read(pipServiceProvider);
  return (PipOverlayAction action) {
    switch (action) {
      case PipRefreshAction():
        // 悬浮窗启动拉快照 (防白屏): 立即推一次
        unawaited(ref.read(pipPushSchedulerProvider).pushNow());
      case PipOpenAction(:final key):
        unawaited(_openPipSession(ref, pip, key));
    }
  };
});

/// 轻点悬浮窗某页 → bringToForeground + 路由跳转对应会话
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
// 尾部行提取 (设计文档"尾部行提取规则")
// ================================================================

/// 从 ChatState 提取最新 AI 输出尾部缓冲:
/// 最新 assistant 消息按行切分取尾部至多 60 行; 不足时向前一条 assistant
/// 消息补足, 最多跨 3 条消息。无任何 AI 文本且运行中 → 状态行。
List<String> extractPipTailLines(ChatState state, {required bool running}) {
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
  final lines =
      (buffer.length > pipBufferLines
              ? buffer.sublist(buffer.length - pipBufferLines)
              : buffer)
          .map(
            (l) => l.length > pipMaxLineChars
                ? l.substring(0, pipMaxLineChars)
                : l,
          )
          .toList();
  if (lines.isEmpty && running) {
    return <String>[state.isResponding ? '思考中…' : '运行中…'];
  }
  return lines;
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
