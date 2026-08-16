/// Agent 设置六个独立详情页 (设置页菜单项 / 抽屉技能入口使用)
///
/// 统一布局: 右上角添加按钮 + 列表下拉刷新。
library;

import 'package:flutter/material.dart';

import '../tabs/commands_tab.dart';
import '../tabs/hooks_tab.dart';
import '../tabs/mcp_tab.dart';
import '../tabs/plugins_tab.dart';
import '../tabs/skills_tab.dart';
import '../tabs/subagents_tab.dart';

/// 技能页
class SkillsPage extends StatefulWidget {
  final VoidCallback? onNewSkill; // 新建技能 → 跳会话 (skill-creator 引导)
  const SkillsPage({super.key, this.onNewSkill});

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  final _tabKey = GlobalKey<SkillsTabState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('技能'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded, size: 20),
            tooltip: '从外部 Agent 导入',
            onPressed: () => _tabKey.currentState?.openImport(),
          ),
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 22),
            tooltip: '新建技能',
            onPressed: widget.onNewSkill,
          ),
        ],
      ),
      body: SkillsTab(key: _tabKey),
    );
  }
}

/// 子智能体页
class SubagentsPage extends StatefulWidget {
  const SubagentsPage({super.key});

  @override
  State<SubagentsPage> createState() => _SubagentsPageState();
}

class _SubagentsPageState extends State<SubagentsPage> {
  final _tabKey = GlobalKey<SubagentsTabState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('子智能体'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 22),
            tooltip: '新建子智能体',
            onPressed: () => _tabKey.currentState?.openNewEditor(),
          ),
        ],
      ),
      body: SubagentsTab(key: _tabKey),
    );
  }
}

/// MCP 服务器页
class McpPage extends StatefulWidget {
  const McpPage({super.key});

  @override
  State<McpPage> createState() => _McpPageState();
}

class _McpPageState extends State<McpPage> {
  final _tabKey = GlobalKey<McpTabState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP 服务器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 22),
            tooltip: '添加服务器',
            onPressed: () => _tabKey.currentState?.openNewEditor(),
          ),
        ],
      ),
      body: McpTab(key: _tabKey),
    );
  }
}

/// 命令页
class CommandsPage extends StatefulWidget {
  const CommandsPage({super.key});

  @override
  State<CommandsPage> createState() => _CommandsPageState();
}

class _CommandsPageState extends State<CommandsPage> {
  final _tabKey = GlobalKey<CommandsTabState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('命令'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 22),
            tooltip: '新建命令',
            onPressed: () => _tabKey.currentState?.openNewEditor(),
          ),
        ],
      ),
      body: CommandsTab(key: _tabKey),
    );
  }
}

/// 钩子页
class HooksPage extends StatefulWidget {
  const HooksPage({super.key});

  @override
  State<HooksPage> createState() => _HooksPageState();
}

class _HooksPageState extends State<HooksPage> {
  final _tabKey = GlobalKey<HooksTabState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('钩子'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 22),
            tooltip: '新建钩子',
            onPressed: () => _tabKey.currentState?.openNewEditor(),
          ),
        ],
      ),
      body: HooksTab(key: _tabKey),
    );
  }
}

/// 插件页 (右上角 = 浏览市场安装)
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  final _tabKey = GlobalKey<PluginsTabState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件'),
        actions: [
          IconButton(
            icon: const Icon(Icons.storefront_outlined, size: 20),
            tooltip: '浏览市场安装',
            onPressed: () => _tabKey.currentState?.openMarketplace(),
          ),
        ],
      ),
      body: PluginsTab(key: _tabKey),
    );
  }
}
