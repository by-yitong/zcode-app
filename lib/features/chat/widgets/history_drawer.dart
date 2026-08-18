import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/relay/relay_events.dart';
import '../../../data/models/workspace.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/app_router.dart';
import '../../../shared/theme/chat_markdown_style.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../agent/screens/cap_pages.dart';
import 'thought_block.dart';
import '../../search/screens/search_screen.dart';

class HistoryDrawer extends ConsumerStatefulWidget {
  final String workspacePath;
  final String? currentTaskId;
  final ValueChanged<String> onSelected;
  final VoidCallback onNewChat;

  /// 切换工作区 (底部项目切换器)
  final ValueChanged<Workspace> onSwitchWorkspace;

  /// 打开搜索页 (跳转全屏搜索, 合并原顶栏搜索)
  final VoidCallback onOpenSearch;

  /// 新建技能 (跳会话预填 skill-creator 引导)
  final VoidCallback? onNewSkill;

  const HistoryDrawer({
    required this.workspacePath,
    required this.currentTaskId,
    required this.onSelected,
    required this.onNewChat,
    required this.onSwitchWorkspace,
    required this.onOpenSearch,
    this.onNewSkill,
  });

  @override
  ConsumerState<HistoryDrawer> createState() => HistoryDrawerState();
}

class HistoryDrawerState extends ConsumerState<HistoryDrawer> {
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    // 抽屉打开 (菜单按钮/边缘右滑手势) → 输入框统一失焦:
    // Scaffold 抽屉是 overlay 不抢焦点, 边缘手势打开时聊天输入框
    // 保持聚焦 (键盘被抽屉盖住), 关闭抽屉时键盘"露出"像被弹起。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  /// 默认工作区 = 网页端的"不在项目中工作" (路径以 .zcode/workspace/default 结尾)
  static bool _isDefaultWorkspace(Workspace w) =>
      w.workspacePath.endsWith('.zcode/workspace/default');

  /// 长按会话弹出操作菜单 (归档 / 删除)
  ///
  /// 归档通过 zcode-task.archive/unarchive RPC 调用;
  /// 删除为纯客户端操作 (服务器端删除 RPC 尚不可用)。
  void _showTaskActions(BuildContext context, Task task) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      // surfaceContainerHigh 是半透明白叠加 (设计为叠在实色 bg 上),
      // 单独做弹窗背景会透出底层; 叠到 surfaceContainerLowest(=bg 实色) 上得到不透明等价色。
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 会话标题预览
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  task.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const Divider(
              height: 1,
              indent: AppSpacing.lg,
              endIndent: AppSpacing.lg,
            ),
            // 归档 / 取消归档
            ListTile(
              leading: Icon(
                task.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(task.archived ? '取消归档' : '归档'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleArchive(task);
              },
            ),
            // 删除会话 (危险操作, 红色文字)
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.danger,
              ),
              title: const Text(
                '删除会话',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(context, task);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  /// 切换归档状态 (调用 zcode-task.archive/unarchive RPC, 成功后更新 allTasksProvider)
  Future<void> _toggleArchive(Task task) async {
    try {
      await archiveTask(ref, task);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 删除前确认对话框, 确认后从 allTasksProvider 移除 (纯客户端)
  Future<void> _confirmDelete(BuildContext context, Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定要删除「${task.title}」吗?\n此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final tasks = List<Task>.from(ref.read(allTasksProvider));
      tasks.removeWhere((t) => t.id == task.id);
      ref.read(allTasksProvider.notifier).state = tasks;
    }
  }

  /// 时间分组标签: 今天 / 昨天 / 本周 / 更早
  String _timeGroupLabel(DateTime? time) {
    if (time == null) return '更早';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final t = DateTime(time.year, time.month, time.day);
    final diff = today.difference(t).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff < 7) return '本周';
    return '更早';
  }

  /// mono 相对时间 (14:32 / 昨天 / 周二 / 7/20)
  String _formatHistTime(DateTime? time) {
    if (time == null) return '—';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final t = DateTime(time.year, time.month, time.day);
    final diff = today.difference(t).inDays;
    String two(int n) => n.toString().padLeft(2, '0');
    if (diff <= 0) return '${two(time.hour)}:${two(time.minute)}';
    if (diff == 1) return '昨天';
    if (diff < 7) {
      const wd = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      return wd[time.weekday - 1];
    }
    return '${time.month}/${time.day}';
  }

  /// 分组渲染历史列表
  Widget _buildGroupedHistory(ThemeData theme, List<Task> tasks) {
    // 按时间分组 (保持已排序顺序, 分桶)
    final groups = <String, List<Task>>{};
    for (final t in tasks) {
      final label = _timeGroupLabel(t.updatedAt);
      (groups[label] ??= []).add(t);
    }
    // 固定分组顺序
    const order = ['今天', '昨天', '本周', '更早'];
    final ordered = order.where(groups.containsKey);

    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      children: [
        for (final g in ordered) ...[
          AppSectionHeader(title: g),
          for (final task in groups[g]!) _buildHistoryItem(theme, task),
        ],
      ],
    );
  }

  /// 单个对话项 (圆角图标块 + 标题 + mono 时间/状态)
  Widget _buildHistoryItem(ThemeData theme, Task task) {
    final isActive = task.id == widget.currentTaskId;
    final isRunning = task.status == TaskStatus.running;
    final isArchived = task.archived;

    return Opacity(
      opacity: isArchived ? 0.5 : 1.0,
      child: InkWell(
        onTap: () {
          Navigator.pop(context);
          widget.onSelected(task.id);
        },
        onLongPress: () => _showTaskActions(context, task),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 1,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: isActive ? AppColors.accentContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 图标块
              Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: isActive
                      ? AppColors.accent
                      : theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  isRunning
                      ? Icons.autorenew_rounded
                      : Icons.chat_bubble_outline_rounded,
                  size: 14,
                  color: isActive
                      ? Colors.white
                      : (isRunning
                            ? AppColors.warning
                            : theme.colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 标题 + 元信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: AppTextSizes.bodySm,
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (isRunning) ...[
                          RunningDot(),
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            '运行中',
                            style: AppText.mono(
                              context,
                              size: AppTextSizes.monoXs,
                              color: AppColors.warning,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            '·',
                            style: AppText.mono(
                              context,
                              size: AppTextSizes.monoXs,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.4),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                        ],
                        Text(
                          _formatHistTime(task.updatedAt),
                          style: AppText.mono(
                            context,
                            size: AppTextSizes.monoXs,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 抽屉快捷入口行 (新建任务 / 搜索 / 自动化 / 技能)
  Widget _buildNavItem(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 19,
              color: accent
                  ? AppColors.accent
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.md),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: accent ? AppColors.accent : theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allTasks = ref.watch(allTasksProvider);
    // 根据 _showArchived 过滤任务 (标题搜索已移至全屏搜索页)
    final tasks = allTasks
        .where(
          (t) =>
              t.workspaceKey == widget.workspacePath &&
              t.archived == _showArchived,
        )
        .toList();
    tasks.sort(
      (a, b) => (b.updatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
        a.updatedAt?.millisecondsSinceEpoch ?? 0,
      ),
    );

    return Drawer(
      backgroundColor: theme.brightness == Brightness.dark
          ? AppColors.darkSurfaceElevated
          : AppColors.lightSurface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部: ZCode + 搜索按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Text(
                    'ZCode',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const Spacer(),
                  // 搜索按钮 (跳转全屏搜索页)
                  IconButton(
                    icon: const Icon(Icons.search_rounded, size: 22),
                    tooltip: '搜索',
                    color: theme.colorScheme.onSurfaceVariant,
                    onPressed: () {
                      Navigator.pop(context); // 关抽屉
                      widget.onOpenSearch();
                    },
                  ),
                ],
              ),
            ),
            // 快捷入口: 新建任务 / 搜索 / 自动化 / 技能
            _buildNavItem(
              theme,
              icon: Icons.add_rounded,
              label: '新建任务',
              accent: true,
              onTap: () {
                Navigator.pop(context); // 关抽屉
                widget.onNewChat();
              },
            ),
            _buildNavItem(
              theme,
              icon: Icons.search_rounded,
              label: '搜索',
              onTap: () {
                Navigator.pop(context);
                widget.onOpenSearch();
              },
            ),
            _buildNavItem(
              theme,
              icon: Icons.auto_awesome_rounded,
              label: '技能',
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SkillsPage(onNewSkill: widget.onNewSkill),
                  ),
                );
              },
            ),
            // 对话历史区标题 + 归档切换
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  Text(
                    '对话历史',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _showArchived = !_showArchived),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _showArchived
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _showArchived
                                ? Icons.archive
                                : Icons.archive_outlined,
                            size: 13,
                            color: _showArchived
                                ? AppColors.accent
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _showArchived ? '已归档' : '归档',
                            style: TextStyle(
                              fontSize: AppTextSizes.label,
                              color: _showArchived
                                  ? AppColors.accent
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 历史列表 (时间分组, 可滚动)
            Expanded(
              child: tasks.isEmpty
                  ? AppEmptyState(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: _showArchived ? '暂无已归档对话' : '暂无历史对话',
                    )
                  : _buildGroupedHistory(theme, tasks),
            ),
            // 底部固定: 项目切换 + 设置 (对齐网页手机端)
            _buildDrawerBottomBar(theme),
          ],
        ),
      ),
    );
  }

  /// 抽屉底部栏: 左侧项目名 (点击向上弹窗切换项目) + 右侧设置按钮
  Widget _buildDrawerBottomBar(ThemeData theme) {
    final workspaces =
        ref.watch(workspaceListProvider).valueOrNull ?? const <Workspace>[];
    final current = workspaces
        .where((w) => w.workspaceKey == widget.workspacePath)
        .firstOrNull;
    final isDefault = current != null && _isDefaultWorkspace(current);
    final label = current == null
        ? '选择项目'
        : (isDefault ? '不在项目中工作' : current.name);

    return Container(
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? AppColors.darkSurfaceElevated
            : AppColors.lightSurface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          // 项目名 + 切换提示图标
          Expanded(
            child: InkWell(
              onTap: () => _openProjectSwitcher(context, workspaces),
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      isDefault
                          ? Icons.home_work_outlined
                          : Icons.folder_outlined,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: AppTextSizes.bodySm,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    // 向上延伸图标: 提示点击后弹窗向上展开
                    Icon(
                      Icons.keyboard_double_arrow_up_rounded,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 设置按钮
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: '设置',
            style: IconButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: () {
              Navigator.pop(context); // 关抽屉
              context.push('/settings');
            },
          ),
        ],
      ),
    );
  }

  /// 项目切换弹窗 (从抽屉底部向上延伸): 项目列表 + "不在项目中工作"
  void _openProjectSwitcher(BuildContext context, List<Workspace> workspaces) {
    final theme = Theme.of(context);
    // 默认工作区固定最上, 其余按名称排序
    final sorted = [...workspaces]
      ..sort((a, b) {
        final d = (_isDefaultWorkspace(b) ? 1 : 0).compareTo(
          _isDefaultWorkspace(a) ? 1 : 0,
        );
        if (d != 0) return d;
        return a.name.compareTo(b.name);
      });

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Text('切换项目', style: theme.textTheme.titleMedium),
              ),
              for (final w in sorted)
                ListTile(
                  dense: true,
                  leading: Icon(
                    _isDefaultWorkspace(w)
                        ? Icons.home_work_outlined
                        : Icons.folder_outlined,
                    size: 20,
                    color: w.workspaceKey == widget.workspacePath
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    _isDefaultWorkspace(w) ? '不在项目中工作' : w.name,
                    style: TextStyle(
                      fontSize: AppTextSizes.bodyMd,
                      fontWeight: w.workspaceKey == widget.workspacePath
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  subtitle: Text(
                    w.workspacePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTextSizes.caption,
                      fontFamily: kMonoFont,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: w.workspaceKey == widget.workspacePath
                      ? Icon(
                          Icons.check_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    Navigator.pop(ctx); // 关切换弹窗
                    Navigator.pop(context); // 关抽屉
                    if (w.workspaceKey != widget.workspacePath) {
                      widget.onSwitchWorkspace(w);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 运行中脉动小点 (历史列表元信息用)
