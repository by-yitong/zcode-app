import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/logging/app_logger.dart';
import 'core/notifications/notification_service.dart';
import 'core/services/pip_service.dart';
import 'providers/app_providers.dart';
import 'providers/pip_providers.dart';
import 'shared/theme/app_router.dart';
import 'shared/theme/app_theme.dart';
import 'shared/widgets/pip_overlay_card.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 启动时从 SharedPreferences 恢复主题选择, 避免首帧闪烁。
  final prefs = await SharedPreferences.getInstance();
  final initialThemeMode = themeModeFromString(
    prefs.getString(kThemeModePrefKey),
  );
  // 悬浮窗行数设置同步恢复 (空/损坏/越界在 pipLinesFromPref 内回落默认 4)
  final initialPipLines = pipLinesFromPref(prefs.get(kPipLinesPrefKey));
  appLog.i(
    '[App] 启动完成, 主题=${themeModeLabel(initialThemeMode)}, '
    '悬浮窗行数=$initialPipLines',
  );

  // 通知: 初始化 + 点击通知的深链路由 (goRouterProvider 是全局 GoRouter 实例)
  await NotificationService.init();
  NotificationService.onNavigate = goRouterProvider.go;

  runApp(
    ProviderScope(
      overrides: [
        themeModeProvider.overrideWith((ref) => initialThemeMode),
        pipLinesProvider.overrideWith((ref) => initialPipLines),
      ],
      child: const ZcodeApp(),
    ),
  );
}

/// 悬浮窗进度监视器: 独立 Flutter 引擎入口
/// (flutter_overlay_window 原生侧按 "overlayMain" 名字创建引擎, pragma 不可省略)
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: PipOverlayApp()));
}

class ZcodeApp extends ConsumerStatefulWidget {
  const ZcodeApp({super.key});

  @override
  ConsumerState<ZcodeApp> createState() => _ZcodeAppState();
}

class _ZcodeAppState extends ConsumerState<ZcodeApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 悬浮窗快照聚合变化 → 节流 500ms shareData 推送 (见 pipPushSchedulerProvider)
    ref.listenManual(pipMonitorProvider, (_, __) {
      ref.read(pipPushSchedulerProvider).schedule();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台挂起期间 WS 可能被系统静默掐断 (connect 无超时会永久卡住 /
    // 半开连接 onDone 不触发), 回前台必须主动探活并恢复
    if (state == AppLifecycleState.resumed) {
      appLog.d('[App] 前台恢复, 探活 relay 连接');
      ref.read(relayClientProvider)?.revive();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 激活前台服务启停 (登录常驻保活)
    ref.watch(keepAliveProvider);
    // 悬浮窗打开期间激活 X 关闭兜底轮询 (isActive 失败 → active 回滚)
    ref.watch(pipLivenessProvider);
    // 悬浮窗打开期间激活动作信箱轮询 (open → bringToForeground + 跳会话;
    // IPC v2: 反向不走 overlay_messenger, 主引擎槽位留给原生转发器)
    ref.watch(pipActionPollerProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'ZCode',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: goRouterProvider,
    );
  }
}
