import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/logging/app_logger.dart';
import 'core/notifications/notification_service.dart';
import 'core/storage/message_cache.dart';
import 'providers/app_providers.dart';
import 'shared/theme/app_router.dart';
import 'shared/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地消息缓存 (离线可见优化)。
  final sw = Stopwatch()..start();
  await Hive.initFlutter();
  await MessageCache.init();
  appLog.i('[App] 本地缓存初始化完成 (${sw.elapsedMilliseconds}ms)');

  // 启动时从 SharedPreferences 恢复主题选择, 避免首帧闪烁。
  final prefs = await SharedPreferences.getInstance();
  final initialThemeMode =
      themeModeFromString(prefs.getString(kThemeModePrefKey));
  appLog.i('[App] 启动完成, 主题=${themeModeLabel(initialThemeMode)}');

  // 通知: 初始化 + 点击通知的深链路由 (goRouterProvider 是全局 GoRouter 实例)
  await NotificationService.init();
  NotificationService.onNavigate = goRouterProvider.go;

  runApp(
    ProviderScope(
      overrides: [
        themeModeProvider.overrideWith((ref) => initialThemeMode),
      ],
      child: const ZcodeApp(),
    ),
  );
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
