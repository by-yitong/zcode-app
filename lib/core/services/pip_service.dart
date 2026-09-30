import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../logging/app_logger.dart';

// ================================================================
// 悬浮窗进度监视器 (画中画) — flutter_overlay_window 封装 + IPC 契约模型
//
// 契约冻结 (docs/superpowers/specs/2026-10-01-pip-overlay-monitor-design.md):
//   主 App → 悬浮窗: {"v":1,"index":0,"sessions":[{key,title,running,error,lines[]}]}
//   悬浮窗 → 主 App: {"action":"refresh"} | {"action":"open","key":"..."}
// shareData 双向均传 JSON 字符串 (跨引擎 codec 兼容性最稳)。
// ================================================================

/// IPC 快照协议版本
const int kPipSnapshotVersion = 1;

/// 尾部缓冲常量: 每会话最多推送的 AI 输出行数
const int pipBufferLines = 60;

/// 单行截断长度 (超长截断, 避免悬浮窗内横向溢出)
const int pipMaxLineChars = 40;

/// 行数设置 SharedPreferences key (int, 范围 1–10, 默认 4)
const String kPipLinesPrefKey = 'pip.lines';
const int pipDefaultLines = 4;
const int pipMinLines = 1;
const int pipMaxLines = 10;

/// 悬浮窗正文单行行高 (逻辑 px)
const double pipLineExtent = 20.0;

/// 悬浮窗窗口高度公式: 88 + 行数*20 (铬高 88 = 上下 padding 10*2 + 标题栏 44 + 页码条 24)
const double pipWindowChromeHeight = 88.0;

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

  /// 该会话 AI 输出尾部缓冲 (至多 60 行, 最后一行最新; 单行已按 40 字符截断)
  final List<String> lines;

  const PipSessionSnapshot({
    required this.key,
    required this.title,
    required this.running,
    required this.error,
    required this.lines,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'title': title,
    'running': running,
    'error': error,
    'lines': lines,
  };
}

/// 整窗快照
class PipSnapshot {
  final int v;
  final int index;
  final List<PipSessionSnapshot> sessions;

  const PipSnapshot({
    required this.v,
    required this.index,
    required this.sessions,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': v,
    'index': index,
    'sessions': <Map<String, dynamic>>[for (final s in sessions) s.toJson()],
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
        final dynamic linesRaw = s['lines'];
        sessions.add(
          PipSessionSnapshot(
            key: key,
            title: s['title'] is String ? s['title'] as String : key,
            running: s['running'] == true,
            error: s['error'] == true,
            lines: <String>[
              if (linesRaw is List)
                for (final dynamic l in linesRaw)
                  if (l is String) l,
            ],
          ),
        );
      }
      return PipSnapshot(
        v: v,
        index: decoded['index'] is int ? decoded['index'] as int : 0,
        sessions: sessions,
      );
    } catch (_) {
      return null;
    }
  }
}

// ================================================================
// IPC 契约模型 (悬浮窗 → 主 App 动作)
// ================================================================

/// 悬浮窗动作
sealed class PipOverlayAction {
  const PipOverlayAction();
}

/// 悬浮窗启动时拉快照 (防白屏)
class PipRefreshAction extends PipOverlayAction {
  const PipRefreshAction();
}

/// 轻点某页 → 跳回对应会话
class PipOpenAction extends PipOverlayAction {
  final String key;
  const PipOpenAction(this.key);
}

/// 解码悬浮窗动作 (JSON 字符串或已解码 Map); 结构非法返回 null
PipOverlayAction? decodePipAction(dynamic raw) {
  try {
    final Object? decoded = raw is String && raw.isNotEmpty
        ? jsonDecode(raw)
        : raw;
    if (decoded is! Map) return null;
    switch (decoded['action']) {
      case 'refresh':
        return const PipRefreshAction();
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

  /// 弹出悬浮窗 (禁用原生拖动 — 会抢内容手势; 松手吸附左右边缘)
  Future<void> show({required int widthPx, required int heightPx}) async {
    await FlutterOverlayWindow.showOverlay(
      width: widthPx,
      height: heightPx,
      enableDrag: false,
      positionGravity: PositionGravity.auto,
      flag: OverlayFlag.defaultFlag,
      overlayTitle: 'ZCode 进度监视器',
      overlayContent: '轻点小窗返回对应会话',
      alignment: OverlayAlignment.center,
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

  /// 调整窗口尺寸 (行数设置变化时)
  Future<void> resize(int widthPx, int heightPx) async {
    try {
      await FlutterOverlayWindow.resizeOverlay(widthPx, heightPx, false);
    } catch (e) {
      appLog.w('[Pip] resize 失败: $e');
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

  /// 推送数据到对端引擎 (双向 JSON 字符串)
  Future<void> send(String json) async {
    try {
      await FlutterOverlayWindow.shareData(json);
    } catch (e) {
      appLog.w('[Pip] send 失败: $e');
    }
  }

  /// 对端推送的动作流 (主 App 侧只消费 PipOverlayAction; 单订阅, 只许绑定一次)
  Stream<PipOverlayAction> get actions async* {
    await for (final dynamic raw in FlutterOverlayWindow.overlayListener) {
      final action = decodePipAction(raw);
      if (action != null) yield action;
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
