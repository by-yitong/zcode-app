import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

// ================================================================
// 悬浮窗进度监视器 (画中画) — flutter_overlay_window 封装 + IPC 契约模型
//
// 契约冻结 v5 (v3 快照结构不变, 动作信箱扩展; 交互 v5: 胶囊可拖拽/形态记忆):
//   主 App → 悬浮窗: shareData(json) 推快照 (走原生 Java 转发器)。
//     主 App 一律不得在 Dart 侧绑定 x-slayer/overlay_messenger 的 handler —
//     那会抢掉通道的原生槽位, 导致推送回声到主引擎自身。
//     session 载荷为 markdown 源文本 text (v2 行数组 lines 已废弃)。
//   悬浮窗 → 主 App: SharedPreferences 信箱, key pip.action, 取走即清空。
//     动作 (v5):
//       {"action":"open","key":"<taskId>"}  home 图标钮, 有会话 → 回 app 跳会话
//       {"action":"home"}                   home 图标钮, 空态 → 仅回前台
//       {"action":"size"}                   双击正文 → 循环尺寸档位 (仅展开态)
//       {"action":"collapse"}               窗口中心拖出屏外 → 收拢为胶囊
//       {"action":"minimize"}               最小化钮 → 收拢为胶囊 (v5 与 collapse 同语义)
//       {"action":"expand"}                 点胶囊 → 在胶囊位置原地展开
//       {"action":"pillMoved","x":..,"y":..} 胶囊拖拽松手 → 主 App 记忆胶囊位置 (逻辑 dp)
//     (无 refresh, 防白屏改由主 App 在 show/resize 成功后立即主动推一次快照)。
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

/// 尺寸档位 SharedPreferences key (int 0–3, 默认 0; 双击循环, 跨次打开生效)
const String kPipSizeStepPrefKey = 'pip.sizeStep';
const int pipDefaultSizeStep = 0;
const int pipSizeStepCount = 4;

/// 后台自动打开小窗 SharedPreferences key (bool, 默认 false)
const String kPipAutoOpenPrefKey = 'pip.autoOpen';

/// 胶囊位置记忆 SharedPreferences key (double, 逻辑 dp): 胶囊拖拽松手时
/// 经 pillMoved 动作写入主 App 侧; 收拢/隐藏恢复时胶囊放回记忆位。
/// 原生 resize/move 均传 dp, 记忆也按 dp 存 (跨 dpr 不失真)。
const String kPipPillXPrefKey = 'pip.pillX';
const String kPipPillYPrefKey = 'pip.pillY';

/// 收拢态胶囊窗口尺寸 (逻辑 dp): 108×36 横向胶囊, 顶部居中 (灵动岛式)。
/// 窗口高 44: 上下各留 4dp 给柔光外晕 (光晕画在窗口 surface 上, 贴边会被
/// 矩形窗口裁掉一圈)。原生 resize/move 均传 dp。
const double pipCollapsedWidth = 108.0;
const double pipCollapsedHeight = 44.0;

/// 各尺寸档位: 宽度 = 屏宽 fraction, 内容行数倍率。
/// 0 常规(默认) / 1 大 / 2 更大 / 3 超大 — 双击循环, 档位持久化跨次生效。
const List<({double widthFraction, int linesMultiplier})> kPipSizeSteps = [
  (widthFraction: 0.84, linesMultiplier: 1),
  (widthFraction: 0.92, linesMultiplier: 3),
  (widthFraction: 0.96, linesMultiplier: 6),
  (widthFraction: 1.00, linesMultiplier: 9),
];

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

/// 档位宽度 fraction (屏宽占比)
double pipWindowWidthFractionForStep(int step) =>
    kPipSizeSteps[step.clamp(0, pipSizeStepCount - 1)].widthFraction;

/// 档位窗口高度 (逻辑 dp): 80 + 行数*20*倍率, 钳到 [80+20, 屏高dp*0.9]。
/// 两步钳制 (先抬下限再压上限), 异常小的屏高不会造成 clamp 上下限倒挂。
double pipWindowHeightForStep(int lines, int step, double screenHDp) {
  final multiplier =
      kPipSizeSteps[step.clamp(0, pipSizeStepCount - 1)].linesMultiplier;
  final raw = pipWindowChromeHeight + lines * pipLineExtent * multiplier;
  const min = pipWindowChromeHeight + pipLineExtent;
  final raised = raw < min ? min : raw;
  final cappedMax = screenHDp * 0.9;
  return raised > cappedMax ? cappedMax : raised;
}

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

/// prefs 原始值 → 尺寸档位 (空/损坏/越界回落默认 0)
int pipSizeStepFromPref(Object? raw) {
  final value = switch (raw) {
    final int v => v,
    final String s => int.tryParse(s),
    _ => null,
  };
  if (value == null || value < 0 || value >= pipSizeStepCount) {
    return pipDefaultSizeStep;
  }
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

  /// 主 App 侧窗口处于收拢态 (v4.1; 真机实测 resize 后悬浮窗引擎的
  /// MediaQuery 可能不刷新, 窗口变小而内容仍渲染完整卡 → 被裁成一条缝;
  /// 收拢渲染改由本字段驱动, 窗口尺寸判定仅作兜底)。缺省 false 向后兼容。
  final bool collapsed;

  const PipSnapshot({
    required this.v,
    required this.index,
    required this.sessions,
    this.screenW,
    this.screenH,
    this.collapsed = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': v,
    'index': index,
    'sessions': <Map<String, dynamic>>[for (final s in sessions) s.toJson()],
    if (screenW != null) 'sw': screenW,
    if (screenH != null) 'sh': screenH,
    if (collapsed) 'co': true,
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
        collapsed: decoded['co'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

// ================================================================
// IPC 契约模型 (悬浮窗 → 主 App 动作, SharedPreferences 信箱承载)
// ================================================================

/// 悬浮窗动作 (契约 v5: open/home/size/collapse/minimize/expand/pillMoved)
sealed class PipOverlayAction {
  const PipOverlayAction();
}

/// home 图标钮 (有当前页会话) → 回 app 并跳对应会话
class PipOpenAction extends PipOverlayAction {
  final String key;
  const PipOpenAction(this.key);
}

/// home 图标钮 (空态) → 仅回 app 前台, 不跳路由
class PipHomeAction extends PipOverlayAction {
  const PipHomeAction();
}

/// 双击正文 → 主 App 循环尺寸档位 (0→1→2→3→0…; v5 仅展开态触发, 不改形态记忆)
class PipSizeAction extends PipOverlayAction {
  const PipSizeAction();
}

/// 窗口中心拖出屏外 → 收拢为胶囊 (v5: 胶囊放记忆位, 不再贴拖出侧;
/// 与最小化同语义, 形态记忆=collapsed)
class PipCollapseAction extends PipOverlayAction {
  const PipCollapseAction();
}

/// 最小化按钮 → 收拢为胶囊 (v5 与拖出屏 collapse 同语义: 形态记忆=collapsed,
/// 之后自动打开/后台恢复仍弹胶囊, 直到点胶囊展开)
class PipMinimizeAction extends PipOverlayAction {
  const PipMinimizeAction();
}

/// 点胶囊 → 在胶囊当前位置原地展开 (小窗顶部中点对齐胶囊中心)
class PipExpandAction extends PipOverlayAction {
  const PipExpandAction();
}

/// 胶囊拖拽松手 → 主 App 记忆胶囊位置并持久化。
/// x/y 为钳制回屏后的胶囊左上角 (逻辑 dp, 与原生 moveOverlay 同一坐标系)。
class PipPillMovedAction extends PipOverlayAction {
  final double x;
  final double y;
  const PipPillMovedAction(this.x, this.y);
}

/// 编码悬浮窗动作 → 信箱 JSON 字符串 (契约 v5, 见文件头)
String encodePipAction(PipOverlayAction action) {
  final map = switch (action) {
    PipOpenAction(:final key) => <String, dynamic>{
      'action': 'open',
      'key': key,
    },
    PipHomeAction() => <String, dynamic>{'action': 'home'},
    PipSizeAction() => <String, dynamic>{'action': 'size'},
    PipCollapseAction() => <String, dynamic>{'action': 'collapse'},
    PipMinimizeAction() => <String, dynamic>{'action': 'minimize'},
    PipExpandAction() => <String, dynamic>{'action': 'expand'},
    PipPillMovedAction(:final x, :final y) => <String, dynamic>{
      'action': 'pillMoved',
      'x': x,
      'y': y,
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
      case 'home':
        return const PipHomeAction();
      case 'size':
        return const PipSizeAction();
      case 'collapse':
        return const PipCollapseAction();
      case 'minimize':
        return const PipMinimizeAction();
      case 'expand':
        return const PipExpandAction();
      case 'pillMoved':
        // x/y 必须 num (int/double 皆可), 缺失/类型错 → 整条丢弃 (防半截坐标)
        final dynamic x = decoded['x'];
        final dynamic y = decoded['y'];
        if (x is! num || y is! num) return null;
        return PipPillMovedAction(x.toDouble(), y.toDouble());
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
  ///
  /// 悬浮窗引擎写信箱用的是它自己引擎的 SharedPreferences Dart 缓存,
  /// 本引擎的缓存不会自动失效 (getString 走内存) — 必须先 reload 从
  /// 原生层重拉, 否则跨引擎永远读不到新动作。
  Future<PipOverlayAction?> takeActionMailbox() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(kPipActionPrefKey);
      if (raw == null || raw.isEmpty) return null;
      await prefs.setString(kPipActionPrefKey, '');
      return decodePipAction(raw);
    } catch (e) {
      appLog.w('[Pip] 读动作信箱失败: $e');
      return null;
    }
  }

  /// app/pip 通道: 把主 App 提到前台 (悬浮窗 home 钮跳回会话, 原生侧已实现)
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

  /// app/pip 通道: 把主 App 退到后台 (聊天页开小窗后自动退 — 用户开小窗就是
  /// 为了在其他 app 上用; 原生侧 moveTaskToBack)
  Future<bool> moveToBackground() async {
    try {
      return await _pipChannel.invokeMethod<bool>('moveTaskToBack') ?? false;
    } on PlatformException catch (e) {
      appLog.w('[Pip] moveToBackground 失败: $e');
      return false;
    } catch (e) {
      appLog.w('[Pip] moveToBackground 失败: $e');
      return false;
    }
  }
}
