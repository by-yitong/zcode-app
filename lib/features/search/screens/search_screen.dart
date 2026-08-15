import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/workspace.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';

/// 斜杠命令条目
class SlashCommandItem {
  final String command;
  final String description;
  final IconData icon;

  const SlashCommandItem(this.command, this.description, this.icon);
}

const kSlashCommands = <SlashCommandItem>[
  SlashCommandItem('/compact', '压缩对话历史', Icons.compress_outlined),
  SlashCommandItem('/model', '切换 AI 模型', Icons.swap_horiz),
  SlashCommandItem('/agents', '查看可用 Agent', Icons.smart_toy_outlined),
  SlashCommandItem('/help', '查看帮助信息', Icons.help_outline),
];

/// 搜索页 — 顶部搜索框 + 结果列表
///
/// 合并了原顶栏搜索面板的全部能力:
///   - 全工作区会话搜索 (标题匹配, 显示所属项目)
///   - 斜杠命令 (/compact /model ...)
/// 选择结果后 pop 自身, 通过回调交给调用方导航。
class SearchScreen extends ConsumerStatefulWidget {
  /// 选择斜杠命令 (如 "/compact"), 由调用方在当前对话执行
  final void Function(String command)? onSlashCommand;

  /// 选择会话, 由调用方跳转 (需处理跨工作区 selectedWorkspace)
  final void Function(Task task)? onSelectTask;

  const SearchScreen({
    super.key,
    this.onSlashCommand,
    this.onSelectTask,
  });

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _selectSlashCommand(SlashCommandItem cmd) {
    Navigator.of(context).pop();
    widget.onSlashCommand?.call(cmd.command);
  }

  void _selectTask(Task task) {
    Navigator.of(context).pop();
    widget.onSelectTask?.call(task);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final allTasks = ref.watch(allTasksProvider);
    final workspacesAsync = ref.watch(workspaceListProvider);

    // workspaceKey → 项目名 映射
    final workspaceNames = <String, String>{};
    workspacesAsync.whenData((workspaces) {
      for (final ws in workspaces) {
        workspaceNames[ws.workspaceKey] = ws.name;
      }
    });

    final query = _query.trim().toLowerCase();

    // 会话: 标题大小写不敏感子串匹配, 排除归档, 按更新时间倒序
    var tasks = allTasks.where((t) => !t.archived).toList();
    if (query.isNotEmpty) {
      tasks = tasks
          .where((t) => t.title.toLowerCase().contains(query))
          .toList();
    }
    tasks.sort((a, b) => (b.updatedAt?.millisecondsSinceEpoch ?? 0)
        .compareTo(a.updatedAt?.millisecondsSinceEpoch ?? 0));
    if (tasks.length > 50) tasks = tasks.sublist(0, 50);

    // 斜杠命令: 空查询全展示, 有查询按命令/描述匹配
    final commands = query.isEmpty
        ? kSlashCommands
        : kSlashCommands
            .where((c) =>
                c.command.contains(query) ||
                c.description.toLowerCase().contains(query))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          onChanged: (value) => setState(() => _query = value),
          style: theme.textTheme.bodyLarge,
          cursorColor: AppColors.accent,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索对话或输入命令...',
            hintStyle: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: AppTextSizes.body,
            ),
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 36, minHeight: 36),
                    color: theme.colorScheme.onSurfaceVariant,
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                      _focusNode.requestFocus();
                    },
                  )
                : null,
          ),
          autocorrect: false,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
      body: _buildResults(theme, isDark, commands, tasks, workspaceNames),
    );
  }

  Widget _buildResults(
    ThemeData theme,
    bool isDark,
    List<SlashCommandItem> commands,
    List<Task> tasks,
    Map<String, String> workspaceNames,
  ) {
    if (commands.isEmpty && tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.5)),
            const SizedBox(height: AppSpacing.md),
            Text(
              _query.isEmpty ? '开始搜索' : '未找到匹配结果',
              style: TextStyle(
                fontSize: AppTextSizes.bodyMd,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        // 斜杠命令
        if (commands.isNotEmpty) ...[
          _sectionLabel(theme, '命令'),
          for (final cmd in commands)
            _buildCommandTile(theme, cmd),
          if (tasks.isNotEmpty) _divider(theme, isDark),
        ],
        // 会话结果
        if (tasks.isNotEmpty) ...[
          _sectionLabel(theme, _query.isEmpty ? '最近对话' : '对话'),
          for (final task in tasks)
            _buildTaskTile(theme, task, workspaceNames),
        ],
      ],
    );
  }

  Widget _divider(ThemeData theme, bool isDark) => Divider(
        height: 1,
        indent: AppSpacing.lg,
        endIndent: AppSpacing.lg,
        color:
            (isDark ? AppColors.darkBorder : AppColors.lightBorder)
                .withValues(alpha: 0.5),
      );

  Widget _sectionLabel(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppTextSizes.label,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildCommandTile(ThemeData theme, SlashCommandItem cmd) {
    return InkWell(
      onTap: () => _selectSlashCommand(cmd),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.accentContainer,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(cmd.icon, size: 18, color: AppColors.accent),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cmd.command,
                    style: TextStyle(
                      fontFamily: kMonoFont,
                      fontFamilyFallback: const ['monospace'],
                      fontSize: AppTextSizes.bodyMd,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    cmd.description,
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.north_west,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskTile(
    ThemeData theme,
    Task task,
    Map<String, String> workspaceNames,
  ) {
    final wsName = workspaceNames[task.workspaceKey] ??
        task.workspaceKey.split('/').where((s) => s.isNotEmpty).lastOrNull ??
        'Unknown';

    return InkWell(
      onTap: () => _selectTask(task),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(
              task.status == TaskStatus.running
                  ? Icons.autorenew
                  : Icons.chat_bubble_outline,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.folder_outlined,
                          size: 12,
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.7)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          wsName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTextSizes.label,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (task.updatedAt != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          _timeAgo(task.updatedAt),
                          style: TextStyle(
                            fontSize: AppTextSizes.caption,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.4)),
          ],
        ),
      ),
    );
  }
}

/// 相对时间格式化
String _timeAgo(DateTime? dt) {
  if (dt == null) return '';
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 7) return '${diff.inDays}天前';
  return '${dt.month}/${dt.day}';
}
