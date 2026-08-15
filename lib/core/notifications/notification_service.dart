import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../logging/app_logger.dart';

/// 消息通知服务
///
/// 两部分:
/// 1. 前台服务常驻通知 (flutter_foreground_task): 登录后启动, 保持进程存活,
///    主 isolate 的 RelayClient 得以后台持续接收 WS 消息。
///    服务类型 remoteMessaging (Android 15 对 dataSync 有 6h 限制)。
/// 2. 事件通知 (flutter_local_notifications): 任务完成 / 需要确认 / 需要回答,
///    仅在 app 处于后台时弹出, 点击深链到对应会话。
///
/// vivo/OPPO 等厂商 ROM 还需用户在系统设置里允许「自启动」+「后台高耗电」,
/// 否则前台服务也可能被杀。
class NotificationService {
  NotificationService._();

  static final _local = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// 点击通知的路由回调 (main.dart 注入, 避免依赖 Riverpod 容器)
  static void Function(String route)? onNavigate;

  // 通知 ID 分段: 不同事件类型独立 ID, 新通知覆盖同类旧通知
  static const _idTurnComplete = 1001;
  static const _idPermissionBase = 2000;
  static const _idQuestion = 3000;

  static const _eventsChannel = AndroidNotificationDetails(
    'zcode_events',
    '任务事件',
    channelDescription: '任务完成、需要确认、需要回答',
    importance: Importance.high,
    priority: Priority.high,
    playSound: true,
  );

  // ================================================================
  // 初始化 (main 启动时调用一次)
  // ================================================================

  static Future<void> init() async {
    if (_initialized) return;
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: _onNotificationTap,
      );
      // Android 13+ 通知运行时权限
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();

      // 前台服务配置: 常驻通知走 LOW 级静音通道
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'zcode_keepalive',
          channelName: '后台连接',
          channelDescription: '保持与 ZCode 服务器的消息连接',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(), // 纯保活, 无周期任务
          allowWakeLock: true,
        ),      );
      _initialized = true;
      appLog.i('[Notify] 通知服务初始化完成');
    } catch (e) {
      appLog.w('[Notify] 通知服务初始化失败: $e');
    }
  }

  // ================================================================
  // 前台服务 (登录后启动 / 登出停止)
  // ================================================================

  static var _serviceStarted = false;

  static Future<void> startKeepAlive() async {
    if (!_initialized || _serviceStarted) return;
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: [ForegroundServiceTypes.remoteMessaging],
      notificationTitle: 'ZCode',
      notificationText: '正在后台保持连接 · 任务消息实时接收中',
    );
    if (result is ServiceRequestSuccess) {
      _serviceStarted = true;
      appLog.i('[Notify] 前台服务已启动 (常驻通知)');
    } else {
      final err = result is ServiceRequestFailure ? result.error : result;
      // 热重启后 statics 重置但系统层服务还活着 → AlreadyStarted 视为成功
      if (err is ServiceAlreadyStartedException) {
        _serviceStarted = true;
        appLog.i('[Notify] 前台服务已在运行 (热重启后复用)');
      } else {
        appLog.w('[Notify] 前台服务启动失败: $err');
      }
    }
  }

  static Future<void> stopKeepAlive() async {
    if (!_serviceStarted) return;
    await FlutterForegroundTask.stopService();
    _serviceStarted = false;
    appLog.i('[Notify] 前台服务已停止');
  }

  // ================================================================
  // 事件通知 (仅后台时弹)
  // ================================================================

  static bool get _isAppInBackground =>
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  /// 任务/本轮回复完成
  static void notifyTurnComplete({
    required String taskId,
    required String workspaceKey,
    String? sessionTitle,
  }) {
    _showEvent(
      id: _idTurnComplete,
      title: '任务完成',
      body: sessionTitle == null || sessionTitle.isEmpty
          ? 'AI 已完成回复, 点击查看'
          : '「$sessionTitle」AI 已完成回复',
      taskId: taskId,
      workspaceKey: workspaceKey,
    );
  }

  /// 工具权限确认请求
  static void notifyPermission({
    required String taskId,
    required String workspaceKey,
    required String permissionId,
    required String toolName,
    String? reason,
  }) {
    final id = _idPermissionBase + (permissionId.hashCode & 0x3FF);
    _showEvent(
      id: id,
      title: '需要确认: $toolName',
      body: reason == null || reason.isEmpty ? 'AI 请求执行操作, 点击处理' : reason,
      taskId: taskId,
      workspaceKey: workspaceKey,
    );
  }

  /// AI 提问等待回答
  static void notifyQuestion({
    required String taskId,
    required String workspaceKey,
    required String question,
  }) {
    _showEvent(
      id: _idQuestion,
      title: 'AI 有问题需要你回答',
      body: question,
      taskId: taskId,
      workspaceKey: workspaceKey,
    );
  }

  static void _showEvent({
    required int id,
    required String title,
    required String body,
    required String taskId,
    required String workspaceKey,
  }) {
    if (!_initialized) return;
    if (!_isAppInBackground) {
      appLog.d('[Notify] 前台中, 抑制通知: $title'); // 前台时 UI 已展示, 不打扰
      return;
    }
    final payload = jsonEncode({'taskId': taskId, 'workspaceKey': workspaceKey});
    _local.show(
      id: id,
      title: title,
      body: body.length > 120 ? '${body.substring(0, 120)}…' : body,
      notificationDetails: const NotificationDetails(android: _eventsChannel),
      payload: payload,
    );
    appLog.i('[Notify] 事件通知: $title');
  }

  /// 点击通知 → 深链到对应会话
  static void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final taskId = data['taskId'] as String?;
      final workspaceKey = data['workspaceKey'] as String?;
      if (taskId == null || workspaceKey == null) return;
      final route =
          '/chat?workspace=${Uri.encodeComponent(workspaceKey)}&task=${Uri.encodeComponent(taskId)}';
      appLog.i('[Notify] 通知点击 → $route');
      onNavigate?.call(route);
    } catch (e) {
      appLog.w('[Notify] 通知 payload 解析失败: $e');
    }
  }
}
