import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/logging/app_logger.dart';
import 'core/notifications/notification_service.dart';
import 'core/services/display_service.dart';
import 'core/services/pip_service.dart';
import 'data/models/workspace.dart';
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
  // 悬浮窗尺寸档位同步恢复 (空/损坏/越界在 pipSizeStepFromPref 内回落默认 0)
  final initialPipSizeStep = pipSizeStepFromPref(
    prefs.get(kPipSizeStepPrefKey),
  );
  // 后台自动打开小窗设置同步恢复 (null → 默认关)
  final initialPipAutoOpen = prefs.getBool(kPipAutoOpenPrefKey) ?? false;
  // 悬浮窗形态记忆同步恢复 (用户上次收拢成胶囊后, 自动打开仍弹胶囊)
  final initialPipForm = pipFormFromPref(prefs.get(kPipFormPrefKey));
  // 胶囊位置记忆同步恢复 (拖拽松手时持久化; 缺任一轴 → null 走顶部居中默认)
  final pillX = prefs.getDouble(kPipPillXPrefKey);
  final pillY = prefs.getDouble(kPipPillYPrefKey);
  final initialPipPillPos = pillX == null || pillY == null
      ? null
      : OverlayPosition(pillX, pillY);
  // 屏幕常亮设置同步恢复 (null → 默认关)
  final initialKeepScreenOn = prefs.getBool(kKeepScreenOnPrefKey) ?? false;
  appLog.i(
    '[App] 启动完成, 主题=${themeModeLabel(initialThemeMode)}, '
    '悬浮窗行数=$initialPipLines, 尺寸档位=$initialPipSizeStep, '
    '后台自动小窗=$initialPipAutoOpen, 形态记忆=${initialPipForm.name}, '
    '胶囊位=${initialPipPillPos == null ? "默认" : "(${initialPipPillPos.x}, ${initialPipPillPos.y})"}, '
    '屏幕常亮=$initialKeepScreenOn',
  );

  // 通知: 初始化 + 点击通知的深链路由 (goRouterProvider 是全局 GoRouter 实例)
  await NotificationService.init();
  NotificationService.onNavigate = goRouterProvider.go;

  // 恢复原生屏幕常亮标志 (仿 pipLines 恢复模式; 仅 Android 生效)
  unawaited(DisplayService.setKeepScreenOn(initialKeepScreenOn));

  runApp(
    ProviderScope(
      overrides: [
        themeModeProvider.overrideWith((ref) => initialThemeMode),
        pipLinesProvider.overrideWith((ref) => initialPipLines),
        pipSizeStepProvider.overrideWith((ref) => initialPipSizeStep),
        pipAutoOpenProvider.overrideWith((ref) => initialPipAutoOpen),
        pipFormProvider.overrideWith((ref) => initialPipForm),
        pipPillPosProvider.overrideWith((ref) => initialPipPillPos),
        keepScreenOnProvider.overrideWith((ref) => initialKeepScreenOn),
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
    // 悬浮窗快照聚合变化 → 节流 500ms shareData 推送 (见 pipPushSchedulerProvider;
    // 前台快路径, 后台由 scheduler 内置轮询兜底)
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
      // 回前台: 小窗完全隐藏让位 (v5: 任何形态都不再以胶囊留在屏上,
      // 隐藏的窗口活着, 切后台按形态记忆恢复)
      unawaited(_onResumedPip());
    } else if (state == AppLifecycleState.paused) {
      // 进后台: 未开小窗按开关自动开 (打开形态由 openPipOverlay 按 form);
      // 隐藏态小窗按形态记忆恢复 (回 app 时让位隐藏了, 去别的 app 续上);
      // 胶囊/展开态本就可见 → 不动
      unawaited(_onPausedPip());
    }
  }

  /// 回前台的小窗处理 (仅 Android; 悬浮窗插件仅 Android 可用):
  /// v5 任何形态都完全隐藏 (展开大窗/胶囊都让位给 app 全屏, 不再收拢成
  /// 胶囊留在屏上)。窗口保持活着 (1×1 移出屏外), 切后台直接恢复,
  /// 免重走 show 的权限/首推时序 — 隐藏例程内部对 hidden 态幂等。
  Future<void> _onResumedPip() async {
    if (!Platform.isAndroid) return;
    if (!ref.read(pipOverlayActiveProvider)) return;
    await ref.read(pipHideOverlayProvider)();
  }

  /// 进后台的小窗处理 (仅 Android): 自动打开 / 隐藏态恢复。
  /// 自动打开需同时满足: 开关开 + 有进行中会话 + 有悬浮窗权限;
  /// 无权限静默跳过只落日志 (用户在别的 app 里, 不能弹系统设置页打扰)。
  /// 每个 return 都落日志 — 真机"没自动弹"时 logcat 一抓即知挂在哪个条件。
  Future<void> _onPausedPip() async {
    if (!Platform.isAndroid) return;
    if (!ref.read(pipOverlayActiveProvider)) {
      if (!ref.read(pipAutoOpenProvider)) return;
      final hasRunning = ref
          .read(allTasksProvider)
          .any((t) => t.status == TaskStatus.running);
      if (!hasRunning) {
        appLog.d('[Pip] 后台自动打开跳过: 无进行中会话');
        return;
      }
      final pip = ref.read(pipServiceProvider);
      if (!await pip.isPermissionGranted()) {
        appLog.d('[Pip] 后台自动打开跳过: 无悬浮窗权限');
        return;
      }
      final result = await ref.read(pipOpenOverlayProvider)();
      appLog.d('[Pip] 后台自动打开: $result');
      return;
    }
    if (ref.read(pipModeProvider) == PipMode.hidden) {
      await ref.read(pipRestoreFromHiddenProvider)();
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
      // 锁定中文: 文本选择菜单 (复制/粘贴/全选)、系统控件跟随中文化;
      // 不锁定会回落 en_US → 长按输入框弹出英文 Copy/Paste
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: goRouterProvider,
    );
  }
}
