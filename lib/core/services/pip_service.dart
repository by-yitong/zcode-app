import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

// ================================================================
// 悬浮窗进度监视器 (画中画) — flutter_overlay_window 封装 + IPC 契约模型
//
// 契约冻结 v3 (docs/superpowers/specs/2026-10-01-pip-overlay-monitor-design.md
// 「IPC 契约（冻结，v3 — 悬浮窗 UI 修订）」):
//   主 App → 悬浮窗: shareData(json) 推快照 (走原生 Java 转发器)。
//     主 App 一律不得在 Dart 侧绑定 x-slayer/overlay_messenger 的 handler —
//     那会抢掉通道的原生槽位, 导致推送回声到主引擎自身。
//     session 载荷为 markdown 源文本 text (v2 行数组 lines 已废弃)。
//   悬浮窗 → 主 App: SharedPreferences 信箱, key pip.action, 取走即清空。
//     动作只有 {"action":"open","key":"<taskId>"} (无 refresh, 防白屏改由
//     主 App 在 show 成功后立即主动推一次快照)。
// ================================================================

/// IPC 快照协议版本
const int kPipSnapshotVersion = 1;

/// 尾部缓冲常量: 每会话最多推送的 AI 输出逻辑行数
const int pipBufferLines = 60;

/// 尾部缓冲常量: text 载荷最大字符数 (超出从头部截掉)
const int pipMaxTextChars = 4000;

/// 行数设置 SharedPreferences key (int, 范围 1–10, 默认 4)
const String kPipLinesPrefKey = 'pip.lines';
const int pipDefaultLines = 4;
const int pipMinLines = 1;
const int pipMaxLines = 10;

/// 悬浮窗 → 主 App 动作信箱 SharedPreferences key
/// (值为动作 JSON 字符串; 空串 = 无待处理动作)
const String kPipActionPrefKey = 'pip.action';

/// 悬浮窗正文视口单行高度系数 (仅用于窗口高度公式; 实际行高由 markdown
/// 自身布局决定, 13px 字号 * 1.45 行距 ≈ 19px, 取 20 留半档余量)
const double pipLineExtent = 20.0;

/// 悬浮窗窗口高度公式: 80 + 行数*20 (铬高 80 = 上下 padding 10*2 + 标题栏 36 + 页码条 24)
const double pipWindowChromeHeight = 80.0;

/// 悬浮窗宽度 = 主 App 屏宽的 84%
const double pipWindowWidthFraction = 0.84;

/// 悬浮窗窗口高度 (逻辑 px)
double pipWindowHeight(int lines) =>
    pipWindowChromeHeight + lines * pipLineExtent;

/// 悬浮窗窗口高度 (物理 px, showOverlay/resizeOverlay 用)
int pipWindowHeightPx(int lines, double devicePixelRatio) =>
    (pipWindowHeight(lines) * devicePixelRatio).round();

/// prefs 原始值 → 行数 (空/损坏/越界回落默认 4)
int pipLinesFromPref(Object? raw) {
  final value = switch (raw) {
    final int v => v,
    final String s => int.tryParse(s),
    _ => null,
  };
  if (value == null) return pipDefaultLines;
  if (value < pipMinLines || value > pipMaxLines) return pipDefaultLines;
  return value;
}

// ================================================================
// IPC 契约模型 (主 App → 悬浮窗 快照)
// ================================================================

/// 单会话快照页
class PipSessionSnapshot {
  /// 会话唯一键 (主 App 侧定义为 task id; 悬浮窗视为不透明串, open 时原样回传)
  final String key;
  final String title;
  final bool running;
  final bool error;

  /// 该会话 AI 输出尾部 markdown 源文本 (跨最多 3 条 assistant 消息拼接,
  /// 尾部 60 逻辑行 / 4000 字符截断, 末尾为最新流式内容; 悬浮窗侧渲染 markdown)
  final String text;

  const PipSessionSnapshot({
    required this.key,
    required this.title,
    required this.running,
    required this.error,
    required this.text,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'title': title,
    'running': running,
    'error': error,
    'text': text,
  };
}

/// 整窗快照
class PipSnapshot {
  final int v;
  final int index;
  final List<PipSessionSnapshot> sessions;

  /// 屏幕物理尺寸 px (v3.1; 悬浮窗松手钳制回屏用)。null = 主 App 未提供,
  /// 悬浮窗跳过钳制 (向后兼容)。
  final int? screenW;
  final int? screenH;

  const PipSnapshot({
    required this.v,
    required this.index,
    required this.sessions,
    this.screenW,
    this.screenH,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': v,
    'index': index,
    'sessions': <Map<String, dynamic>>[for (final s in sessions) s.toJson()],
    if (screenW != null) 'sw': screenW,
    if (screenH != null) 'sh': screenH,
  };

  /// 解码悬浮窗收到的快照 (JSON 字符串或已解码 Map); 结构非法返回 null
  static PipSnapshot? decode(dynamic raw) {
    try {
      final Object? decoded = raw is String && raw.isNotEmpty
          ? jsonDecode(raw)
          : raw;
      if (decoded is! Map) return null;
      final dynamic v = decoded['v'];
      if (v is! int || v != kPipSnapshotVersion) return null;
      final dynamic sessionsRaw = decoded['sessions'];
      if (sessionsRaw is! List) return null;
      final sessions = <PipSessionSnapshot>[];
      for (final dynamic s in sessionsRaw) {
        if (s is! Map) continue;
        final dynamic key = s['key'];
        if (key is! String || key.isEmpty) continue;
        final dynamic textRaw = s['text'];
        sessions.add(
          PipSessionSnapshot(
            key: key,
            title: s['title'] is String ? s['title'] as String : key,
            running: s['running'] == true,
            error: s['error'] == true,
            text: textRaw is String ? textRaw : '',
          ),
        );
      }
      return PipSnapshot(
        v: v,
        index: decoded['index'] is int ? decoded['index'] as int : 0,
        sessions: sessions,
        screenW: decoded['sw'] is int ? decoded['sw'] as int : null,
        screenH: decoded['sh'] is int ? decoded['sh'] as int : null,
      );
    } catch (_) {
      return null;
    }
  }
}

// ================================================================
// IPC 契约模型 (悬浮窗 → 主 App 动作, SharedPreferences 信箱承载)
// ================================================================

/// 悬浮窗动作
sealed class PipOverlayAction {
  const PipOverlayAction();
}

/// 轻点某页 → 跳回对应会话
class PipOpenAction extends PipOverlayAction {
  final String key;
  const PipOpenAction(this.key);
}

/// 编码悬浮窗动作 → 信箱 JSON 字符串 (契约: {"action":"open","key":"..."})
String encodePipAction(PipOverlayAction action) {
  final map = switch (action) {
    PipOpenAction(:final key) => <String, dynamic>{
      'action': 'open',
      'key': key,
    },
  };
  return json.encode(map);
}

/// 解码悬浮窗动作 (JSON 字符串或已解码 Map); 结构非法返回 null
PipOverlayAction? decodePipAction(dynamic raw) {
  try {
    final Object? decoded = raw is String && raw.isNotEmpty
        ? jsonDecode(raw)
        : raw;
    if (decoded is! Map) return null;
    switch (decoded['action']) {
      case 'open':
        final dynamic key = decoded['key'];
        if (key is! String || key.isEmpty) return null;
        return PipOpenAction(key);
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

// ================================================================
// 服务封装 (权限 / show / close / resize / move / shareData 收发)
// ================================================================

/// flutter_overlay_window 薄封装: 所有调用吞异常并落日志,
/// 保证非 Android / 测试环境 / 插件异常时不炸调用方。
class PipService {
  const PipService();

  static const MethodChannel _pipChannel = MethodChannel('app/pip');

  /// 悬浮窗权限是否已授予
  Future<bool> isPermissionGranted() async {
    try {
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (e) {
      appLog.w('[Pip] isPermissionGranted 失败: $e');
      return false;
    }
  }

  /// 跳系统设置申请"显示在其他应用上层"权限
  Future<void> requestPermission() async {
    try {
      await FlutterOverlayWindow.requestPermission();
    } catch (e) {
      appLog.w('[Pip] requestPermission 失败: $e');
    }
  }

  /// 悬浮窗是否已打开 (幂等保护用)
  Future<bool> isActive() async {
    try {
      return await FlutterOverlayWindow.isActive();
    } catch (e) {
      appLog.w('[Pip] isActive 失败: $e');
      return false;
    }
  }

  /// 弹出悬浮窗 (默认关原生拖动; 标题栏按下瞬时开关, 见 setNativeDrag)。
  /// - alignment topLeft: 参数 = 屏幕绝对坐标 (TOP|LEFT 锚点)。CENTER 偏移
  ///   语义在部分 ROM 上 relayout 时被重新解释, 真机表现为"一点就跳"。
  /// - startPosition 传逻辑 dp (原生侧 dpToPx 换算一次, 语义正确)。
  /// - positionGravity none: 关松手吸边动画 (与拖动开关并发互相干扰)。
  Future<void> show({
    required int widthPx,
    required int heightPx,
    int startX = 24,
    int startY = 120,
  }) async {
    await FlutterOverlayWindow.showOverlay(
      width: widthPx,
      height: heightPx,
      enableDrag: false,
      positionGravity: PositionGravity.none,
      flag: OverlayFlag.defaultFlag,
      overlayTitle: 'ZCode 进度监视器',
      overlayContent: '轻点小窗返回对应会话',
      alignment: OverlayAlignment.topLeft,
      startPosition: OverlayPosition(startX.toDouble(), startY.toDouble()),
    );
  }

  /// 关闭悬浮窗
  Future<void> close() async {
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (e) {
      appLog.w('[Pip] close 失败: $e');
    }
  }

  /// 调整窗口尺寸 (行数设置变化时; enableDrag 保持关, 正文手势不被原生拖动抢)
  Future<void> resize(int widthPx, int heightPx) async {
    try {
      await FlutterOverlayWindow.resizeOverlay(widthPx, heightPx, false);
    } catch (e) {
      appLog.w('[Pip] resize 失败: $e');
    }
  }

  /// 标题栏拖动开关: 按下开原生拖动 (插件 onTouch 在原生层直接搬窗口,
  /// 零通道往返 = 官方例子的丝滑路径), 松手关掉 (正文手势不被原生拖动抢)。
  /// 走本地补丁的 setDragEnabled 通道 — 只翻标志, 不 relayout。
  Future<void> setNativeDrag(bool enabled) async {
    try {
      await FlutterOverlayWindow.setDragEnabled(enabled);
    } catch (e) {
      appLog.w('[Pip] setNativeDrag($enabled) 失败: $e');
    }
  }

  /// 查询悬浮窗当前位置 (拖动手柄累积位移的基准)
  Future<OverlayPosition?> getOverlayPosition() async {
    try {
      return await FlutterOverlayWindow.getOverlayPosition();
    } catch (e) {
      appLog.w('[Pip] getOverlayPosition 失败: $e');
      return null;
    }
  }

  /// 移动悬浮窗到绝对位置 (标题栏拖动)
  Future<void> moveOverlay(OverlayPosition position) async {
    try {
      await FlutterOverlayWindow.moveOverlay(position);
    } catch (e) {
      appLog.w('[Pip] moveOverlay 失败: $e');
    }
  }

  /// 推送数据到对端引擎 (主 App → 悬浮窗, 走原生 Java 转发器; JSON 字符串)。
  /// 注意: 主 App 侧严禁绑定 messenger 通道 handler (会抢掉原生转发器槽位)。
  Future<void> send(String json) async {
    try {
      await FlutterOverlayWindow.shareData(json);
    } catch (e) {
      appLog.w('[Pip] send 失败: $e');
    }
  }

  /// 悬浮窗侧写动作信箱 (契约 v2: SharedPreferences, key pip.action)。
  /// 两引擎同进程共享同一 SharedPreferences 实例, 写后立即可见。
  Future<void> writeActionMailbox(String json) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kPipActionPrefKey, json);
    } catch (e) {
      appLog.w('[Pip] 写动作信箱失败: $e');
    }
  }

  /// 主 App 侧取动作信箱: 读到非空值即清空 key (写回空串) 并解码返回;
  /// 无动作 / 结构非法 / 异常返回 null。
  Future<PipOverlayAction?> takeActionMailbox() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kPipActionPrefKey);
      if (raw == null || raw.isEmpty) return null;
      await prefs.setString(kPipActionPrefKey, '');
      return decodePipAction(raw);
    } catch (e) {
      appLog.w('[Pip] 读动作信箱失败: $e');
      return null;
    }
  }

  /// app/pip 通道: 把主 App 提到前台 (悬浮窗轻点跳回会话, 原生侧已实现)
  Future<bool> bringToForeground() async {
    try {
      return await _pipChannel.invokeMethod<bool>('bringToForeground') ?? false;
    } on PlatformException catch (e) {
      appLog.w('[Pip] bringToForeground 失败: $e');
      return false;
    } catch (e) {
      appLog.w('[Pip] bringToForeground 失败: $e');
      return false;
    }
  }
}
