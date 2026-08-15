import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../shared/entry_workspace.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/theme/app_router.dart';
import '../../../providers/app_providers.dart';

/// 启动页 — 黑底 + Z logo,与原生 launch_background.xml 无缝衔接。
/// 检查 session → 连接 relay → 加载工作区 → 进入主页。
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  String _status = '正在连接...';

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    );
    _controller.forward();
    _checkSession();
  }

  Future<void> _checkSession() async {
    await Future.delayed(const Duration(milliseconds: 600));

    if (!mounted) return;

    final session = ref.read(sessionProvider);
    session.when(
      data: (s) {
        if (s != null && s.isValid) {
          _connectRelay();
        } else {
          context.go(AppRoutes.login);
        }
      },
      loading: () {
        Future.delayed(const Duration(milliseconds: 300), _checkSession);
      },
      error: (_, __) {
        context.go(AppRoutes.login);
      },
    );
  }

  /// 连接 relay + 开 bridge + 加载数据, 完成后直达聊天页
  Future<void> _connectRelay() async {
    if (!mounted) return;
    setState(() => _status = '正在连接服务器...');

    try {
      // 1) 连接 relay + 加载工作区
      await ref.read(workspaceListProvider.notifier).load();

      if (!mounted) return;
      setState(() => _status = '正在建立通道...');

      // 2) 选定入口工作区 (上次打开 / 默认) 并开它的 bridge → RPC ready
      //    模型/技能都依赖 _rpcCall, 必须先开 bridge
      final workspaces = ref.read(workspaceListProvider).valueOrNull;
      final repo = ref.read(workspaceRepositoryProvider);
      final entry = await pickEntryWorkspace(workspaces ?? const []);
      if (entry != null && repo != null) {
        // 更新选中工作区 (聊天页标题/identity 用)
        ref.read(selectedWorkspaceProvider.notifier).state = entry;
        try {
          // 远程工作区 bridge-open 必须传 identity (3.7.7 实测), 本地工作区两者相同
          await repo.openWorkspace(entry.workspaceIdentity);
        } catch (e) {
          // bridge 失败不阻塞进入
          appLog.w('[Splash] 入口工作区 bridge 打开失败 (不阻塞): $e');
        }
      }

      if (!mounted) return;
      setState(() => _status = '正在加载数据...');

      // 3) RPC ready 后, 模型/技能会通过 onRpcReadyChange 自动加载
      //    这里等一下让它们有机会完成
      try {
        await ref
            .read(modelListProvider.notifier)
            .refresh()
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        appLog.w('[Splash] 模型列表预加载失败/超时 (不阻塞): $e');
      }

      if (!mounted) return;
      // 直达聊天页 (对齐网页手机端); 无工作区时回退主页
      if (entry != null) {
        context.go(
          '${AppRoutes.chat}?workspace=${Uri.encodeComponent(entry.workspaceKey)}',
        );
      } else {
        context.go(AppRoutes.home);
      }
    } catch (e) {
      // 连接失败也进入主页 (主页有重试)
      appLog.w('[Splash] 启动连接失败, 直接进入主页 (主页可重试): $e');
      if (!mounted) return;
      context.go(AppRoutes.home);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBg,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Z logo
              Image.asset(
                'assets/images/app_icon.png',
                width: 112,
                height: 112,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 56),
              // 条状加载条 (圆角, 深色背景上克制的白色)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: const SizedBox(
                  width: 128,
                  height: 4,
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    backgroundColor: Color.fromRGBO(255, 255, 255, 0.10),
                    valueColor:
                        AlwaysStoppedAnimation(Color.fromRGBO(255, 255, 255, 0.5)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _status,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: AppTextSizes.bodySm,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
