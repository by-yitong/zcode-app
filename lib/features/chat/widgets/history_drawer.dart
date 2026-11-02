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
import '../../../shared/widgets/app_empty_state.dart';
import '../../agent/screens/plugins_browser_page.dart';
import 'thought_block.dart';
import '../../search/screens/search_screen.dart';

class HistoryDrawer extends ConsumerStatefulWidget {
  final String workspacePath;
  final String? currentTaskId;
  final ValueChanged<String> onSelected;
  final VoidCallback onNewChat;

  /// 切换工作区 (底部项目切换器)
  final ValueChanged<Workspace> onSwitchWorkspace;

  /// 任务列表视图下选中任务 (跨工作区: 草稿对话任务在各自 draft 工作区,
  /// 跳转必须带任务自身的 workspaceKey)。null 时回退 [onSelected]。
  final void Function(String taskId, String workspaceKey)?
  onSelectedInWorkspace;

  /// 打开搜索页 (跳转全屏搜索, 合并原顶栏搜索)
  final VoidCallback onOpenSearch;

  /// 关闭抽屉 (抽屉改为 RevealDrawer 推开式后不再是路由 overlay,
  /// 原先的 Navigator.pop(context) 关抽屉语义全部走此回调)
  final VoidCallback onClose;

  /// 抽屉背景色 (不传则按主题明暗取默认)。chat 页会把同一色传给
  /// RevealDrawer.backdropColor, 保证页面推开后露出的底与抽屉同色。
  final Color? backgroundColor;

  const HistoryDrawer({
    required this.workspacePath,
    required this.currentTaskId,
    required this.onSelected,
    required this.onNewChat,
    required this.onSwitchWorkspace,
    required this.onOpenSearch,
    required this.onClose,
    this.onSelectedInWorkspace,
    this.backgroundColor,
  });

  @override
  ConsumerState<HistoryDrawer> createState() => HistoryDrawerState();
}

class HistoryDrawerState extends ConsumerState<HistoryDrawer> {
  bool _showArchived = false;

  /// 「任务列表」聚合视图: 显示全部草稿对话任务 (projectId==null,
  /// 对应网页侧栏「对话」分区)。false = 普通模式 (当前工作区任务)。
  /// 切换真实项目时自动复位。
  bool _conversationView = false;

  /// 默认工作区 = 网页端的"不在项目中工作" (路径以 .zcode/workspace/default 结尾)
  static bool _isDefaultWorkspace(Workspace w) =>
      w.workspacePath.endsWith('.zcode/workspace/default');

  /// 真实项目 (切换弹窗只列这些): 排除 conversation 草稿工作区
  /// (purpose=='conversation')、旧协议下路径为 draft- 的工作区，
  /// 以及默认工作区 (已合并进「任务列表」)。
  static bool _isRealProject(Workspace w) {
    if (w.purpose == 'conversation') return false;
    if (_isDefaultWorkspace(w)) return false;
    if (w.purpose == null && w.workspacePath.contains('/workspace/draft-')) {
      return false;
    }
    return true;
  }

  /// 切换弹窗路径短显: 含 .zcode/workspace/default 显示"默认工作区",
  /// 其余只留后两段 (如 …/projects/GoStudio), 避免绝对路径截断在半个词上。
  static String _shortWorkspacePath(String path) {
    if (path.contains('.zcode/workspace/default')) return '默认工作区';
    final trimmed =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final parts = trimmed.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length <= 2) return trimmed;
    return '…/${parts[parts.length - 2]}/${parts.last}';
  }

  /// 该项目下是否存在"正在运行且未归档"的任务 (项目切换弹窗运行中标记用)
  static bool _hasRunningTask(List<Task> tasks, String workspaceKey) =>
      tasks.any(
        (t) =>
            t.workspaceKey == workspaceKey &&
            t.status == TaskStatus.running &&
            !t.archived,
      );

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

  /// 抽屉内部分组标题: 与 AppSectionHeader 同款式 (mono + 字间距 +
  /// onSurfaceVariant 次要色), 但字号再小 2 (caption-2), 让任务标题
  /// 视觉最突出。注: AppSectionHeader 不接受字号参数, 且任务要求
  /// 只改本文件, 故此处本地复刻一份, 不改共享组件。
  Widget _buildGroupHeader(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontFamily: kMonoFont,
                fontSize: AppTextSizes.caption - 2,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.06,
              ),
            ),
          ),
        ],
      ),
    );
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
          _buildGroupHeader(g),
          for (final task in groups[g]!)
            _buildHistoryItem(theme, task, g),
        ],
      ],
    );
  }

  /// 单个对话项 (圆角图标块 + 标题 + mono 时间/状态)
  Widget _buildHistoryItem(ThemeData theme, Task task, String groupLabel) {
    final isActive = task.id == widget.currentTaskId;
    final isRunning = task.status == TaskStatus.running;
    final isArchived = task.archived;
    // 昨天组: 第二行日期与分组标题完全重复, 隐藏 (运行中标记仍保留)。
    // 今天组 (14:32) / 本周组 (周二等) / 更早组 (7/20) 的第二行信息
    // 与分组标题不重复, 保留。
    final hideDate = groupLabel == '昨天';

    return Opacity(
      opacity: isArchived ? 0.5 : 1.0,
      child: InkWell(
        onTap: () {
          widget.onClose(); // 关抽屉
          if (_conversationView && widget.onSelectedInWorkspace != null) {
            // 任务列表视图: 任务在各自 draft 工作区, 跳转带任务自身工作区
            widget.onSelectedInWorkspace!(task.id, task.workspaceKey);
          } else {
            widget.onSelected(task.id);
          }
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
                    // 第二行: 昨天组隐藏日期 (运行中任务仍保留运行标记)
                    if (!hideDate || isRunning) ...[
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
                            if (!hideDate) ...[
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
                          ],
                          if (!hideDate)
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
    // 任务列表视图: 聚合全部草稿对话任务 (按任务自身 workspaceKey 连接)
    final tasks =
        _conversationView
            ? allTasks
                .where((t) => t.isConversation && t.archived == _showArchived)
                .toList()
            : allTasks
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

    // 推开式抽屉: 不再包 Material Drawer (宽度/滑入由 RevealDrawer 负责),
    // 只保留底色壳; 颜色与原 Drawer.backgroundColor 完全一致
    return Material(
      color: widget.backgroundColor ??
          (theme.brightness == Brightness.dark
              ? AppColors.darkSurfaceElevated
              : AppColors.lightSurface),
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
                      widget.onClose(); // 关抽屉
                      widget.onOpenSearch();
                    },
                  ),
                  // 设置按钮 (搜索右侧, 自底部栏上移)
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 20),
                    tooltip: '设置',
                    color: theme.colorScheme.onSurfaceVariant,
                    onPressed: () {
                      widget.onClose(); // 关抽屉
                      context.push('/settings');
                    },
                  ),
                ],
              ),
            ),
            // 快捷入口: 新建任务 / 搜索 / 插件市场
            _buildNavItem(
              theme,
              icon: Icons.add_rounded,
              label: '新建任务',
              accent: true,
              onTap: () {
                widget.onClose(); // 关抽屉
                widget.onNewChat();
              },
            ),
            _buildNavItem(
              theme,
              icon: Icons.search_rounded,
              label: '搜索',
              onTap: () {
                widget.onClose(); // 关抽屉
                widget.onOpenSearch();
              },
            ),
            _buildNavItem(
              theme,
              icon: Icons.storefront_outlined,
              label: '插件市场',
              onTap: () {
                widget.onClose(); // 关抽屉
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PluginsBrowserPage(),
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

  /// 抽屉底部: 项目切换卡片 (点击向上弹窗切换项目)
  Widget _buildDrawerBottomBar(ThemeData theme) {
    final workspaces =
        ref.watch(workspaceListProvider).valueOrNull ?? const <Workspace>[];
    final current = workspaces
        .where((w) => w.workspaceKey == widget.workspacePath)
        .firstOrNull;
    final isDefault = current != null && _isDefaultWorkspace(current);
    final label = (_conversationView || isDefault)
        ? '任务列表'
        : current == null
        ? '选择项目'
        : current.name;

    // 圆角卡片 (填充色区分, 无边框, 无分隔线)
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openProjectSwitcher(context, workspaces),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm + 2,
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
        ),
      ],
    );
  }

  /// 项目切换弹窗 (从抽屉底部向上延伸): 项目列表 + "不在项目中工作"
  void _openProjectSwitcher(BuildContext context, List<Workspace> workspaces) {
    final theme = Theme.of(context);
    // 先失焦再弹切换弹窗: 否则弹窗关闭时 Flutter 会把焦点还给打开前
    // 聚焦过的输入框 → 键盘自动弹起 (行点击里的 unfocus 拦不住关闭时
    // 的焦点恢复, 拖拽/点遮罩关闭时更无 unfocus)。
    FocusManager.instance.primaryFocus?.unfocus();
    // 打开时读一次任务快照, 用于标记"有任务正在运行"的项目
    // (弹窗展示期间不实时刷新, 不加定时器)
    final tasks = ref.read(allTasksProvider);
    // 切换弹窗只列真实项目 (草稿工作区与默认工作区不进列表):
    // 草稿只在任务列表聚合视图出现, 默认工作区已合并进任务列表。
    final projects = workspaces.where(_isRealProject).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    // 任务列表行选中态: 显式聚合视图, 或当前就在默认工作区
    // (网页端两者同为「任务列表」, 算一个)。
    final current = workspaces
        .where((w) => w.workspaceKey == widget.workspacePath)
        .firstOrNull;
    final taskListSelected = _conversationView ||
        (current != null && _isDefaultWorkspace(current));

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
              // 任务列表 (聚合草稿对话, 对应网页侧栏「对话」分区;
              // 默认工作区已合并进此行, 两者算一个)
              ListTile(
                dense: true,
                tileColor: taskListSelected ? AppColors.accentContainer : null,
                leading: Icon(
                  Icons.forum_outlined,
                  size: 20,
                  color: taskListSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  '任务列表',
                  style: TextStyle(
                    fontSize: AppTextSizes.bodyMd,
                    fontWeight: taskListSelected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                subtitle: Text(
                  '全部对话与后台任务',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTextSizes.caption,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: taskListSelected
                    ? Icon(
                        Icons.check_rounded,
                        size: 20,
                        color: theme.colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  FocusManager.instance.primaryFocus?.unfocus();
                  // 切到任务列表聚合视图 (不切工作区, 聊天连接仍归各任务自身)
                  setState(() => _conversationView = true);
                },
              ),
              for (final w in projects)
                ListTile(
                  dense: true,
                  // 当前项目行底色高亮 (对勾/主色图标/加粗标题已存在,
                  // 再加底色让当前项一眼可见)
                  tileColor: w.workspaceKey == widget.workspacePath
                      ? AppColors.accentContainer
                      : null,
                  leading: Icon(
                    Icons.folder_outlined,
                    size: 20,
                    color: w.workspaceKey == widget.workspacePath
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          w.name,
                          style: TextStyle(
                            fontSize: AppTextSizes.bodyMd,
                            fontWeight: w.workspaceKey == widget.workspacePath
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      // 有运行中任务的项目: 名字后加橙色脉动点
                      if (_hasRunningTask(tasks, w.workspaceKey)) ...[
                        const SizedBox(width: AppSpacing.xs),
                        const RunningDot(size: 6),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    _shortWorkspacePath(w.workspacePath),
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
                    // 弹窗关闭会触发 Flutter 焦点恢复 (把焦点还给切换前
                    // 聚焦过的输入框) → 键盘弹出; 切项目场景不需要, 主动清掉
                    FocusManager.instance.primaryFocus?.unfocus();
                    // 切项目不关抽屉: 列表随新工作区自动刷新,
                    // 用户留在抽屉里继续选会话 (产品要求)
                    if (w.workspaceKey != widget.workspacePath) {
                      setState(() => _conversationView = false);
                      widget.onSwitchWorkspace(w);
                    } else if (_conversationView) {
                      // 回到当前项目: 退出任务列表视图
                      setState(() => _conversationView = false);
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
