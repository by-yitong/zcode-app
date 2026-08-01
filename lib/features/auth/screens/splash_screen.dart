import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

  /// 连接 relay + 开 bridge + 加载数据, 完成后进入主页
  Future<void> _connectRelay() async {
    if (!mounted) return;
    setState(() => _status = '正在连接服务器...');

    try {
      // 1) 连接 relay + 加载工作区
      await ref.read(workspaceListProvider.notifier).load();

      if (!mounted) return;
      setState(() => _status = '正在建立通道...');

      // 2) 开第一个工作区的 bridge → RPC ready
      //    模型/技能都依赖 _rpcCall, 必须先开 bridge
      final workspaces = ref.read(workspaceListProvider).valueOrNull;
      final repo = ref.read(workspaceRepositoryProvider);
      if (workspaces != null && workspaces.isNotEmpty && repo != null) {
        try {
          await repo.openWorkspace(workspaces.first.workspaceKey);
        } catch (_) {
          // bridge 失败不阻塞进主页
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
      } catch (_) {}

      if (!mounted) return;
      context.go(AppRoutes.home);
    } catch (e) {
      // 连接失败也进入主页 (主页有重试)
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
