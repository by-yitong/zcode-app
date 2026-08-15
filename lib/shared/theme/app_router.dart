import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/app_logger.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/splash_screen.dart';
import '../../features/chat/screens/chat_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../providers/app_providers.dart';
import '../../shared/theme/app_design_tokens.dart';
import '../../shared/entry_workspace.dart';

/// 路由名称
class AppRoutes {
  AppRoutes._();

  static const String splash = '/splash';
  static const String login = '/login';
  static const String home = '/';
  static const String chat = '/chat';
  static const String settings = '/settings';
}

/// GoRouter 配置
final goRouterProvider = GoRouter(
  initialLocation: AppRoutes.splash,
  routes: [
    GoRoute(
      path: AppRoutes.splash,
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: AppRoutes.login,
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const HomeRedirectScreen(),
    ),
    GoRoute(
      path: AppRoutes.settings,
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: AppRoutes.chat,
      builder: (context, state) {
        final workspaceKey = state.uri.queryParameters['workspace'] ?? '';
        final taskId = state.uri.queryParameters['task'];
        return ChatScreen(
          workspaceKey: workspaceKey,
          taskId: taskId,
        );
      },
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 64),
          const SizedBox(height: 16),
          Text('页面不存在: ${state.uri}'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => context.go(AppRoutes.home),
            child: const Text('返回首页'),
          ),
        ],
      ),
    ),
  ),
);

/// '/' 兜底入口 — 无底部导航, 自动选定入口工作区后直达聊天页
/// (正常流程 Splash 已直达聊天, 这里只处理兜底/回退)。
class HomeRedirectScreen extends ConsumerStatefulWidget {
  const HomeRedirectScreen({super.key});

  @override
  ConsumerState<HomeRedirectScreen> createState() =>
      _HomeRedirectScreenState();
}

class _HomeRedirectScreenState extends ConsumerState<HomeRedirectScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    if (!mounted) return;
    setState(() => _error = null);

    // 未登录 → 登录页
    final session = ref.read(sessionProvider).valueOrNull;
    if (session == null || !session.isValid) {
      context.go(AppRoutes.login);
      return;
    }

    try {
      var workspaces = ref.read(workspaceListProvider).valueOrNull;
      if (workspaces == null) {
        await ref.read(workspaceListProvider.notifier).load();
        workspaces = ref.read(workspaceListProvider).valueOrNull;
      }
      final entry = await pickEntryWorkspace(workspaces ?? const []);
      if (!mounted) return;
      if (entry != null) {
        ref.read(selectedWorkspaceProvider.notifier).state = entry;
        context.go(
          '${AppRoutes.chat}?workspace=${Uri.encodeComponent(entry.workspaceKey)}',
        );
      } else {
        setState(() => _error = '暂无可用工作区, 请确认桌面端在线后重试');
      }
    } catch (e) {
      appLog.w('[Home] 工作区加载失败: $e');
      if (!mounted) return;
      setState(() => _error = '连接失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppColors.darkBg,
      body: Center(
        child: _error == null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      color: Colors.white.withValues(alpha: 0.5),
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '正在进入对话...',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: AppTextSizes.bodySm,
                    ),
                  ),
                ],
              )
            : Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.cloud_off_rounded,
                        size: 48, color: Colors.white38),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: AppTextSizes.bodySm,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _resolve,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重试'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () async {
                        await ref.read(sessionProvider.notifier).logout();
                        if (context.mounted) context.go(AppRoutes.login);
                      },
                      child: const Text(
                        '切换账号',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
