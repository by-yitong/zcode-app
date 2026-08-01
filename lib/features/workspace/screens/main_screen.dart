import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_providers.dart';
import 'workspace_list_screen.dart';
import '../../settings/screens/settings_screen.dart';

/// 主页 — 底部导航 (工作区 / 我的)
class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // relay 连接 + 工作区加载已在 SplashScreen 完成
    // 如果从登录页进来 (跳过了 splash), 兜底加载一次
    final wsState = ref.read(workspaceListProvider);
    if (wsState.isLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(workspaceListProvider.notifier).load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          const WorkspaceListScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.work_outline),
            selectedIcon: Icon(Icons.work),
            label: '工作区',
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
