import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models/workspace.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/app_router.dart';

/// 打开搜索/命令面板
///
/// [onSlashCommand] — 用户选择斜杠命令时的回调 (传入命令文本如 "/compact")。
/// 调用方通常将其发送到当前对话。
void showSearchPalette(
  BuildContext context, {
  void Function(String command)? onSlashCommand,
}) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: '搜索',
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return _SearchPaletteDialog(
        parentContext: context,
        onSlashCommand: onSlashCommand,
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.05),
            end: Offset.zero,
          ).animate(CurvedAnimation(
              parent: animation, curve: Curves.easeOut)),
          child: child,
        ),
      );
    },
  );
}

// ── 斜杠命令定义 ──

class _SlashCommand {
  final String command;
  final String description;
  final IconData icon;

  const _SlashCommand(this.command, this.description, this.icon);
}

const _slashCommands = <_SlashCommand>[
  _SlashCommand('/compact', '压缩对话历史', Icons.compress_outlined),
  _SlashCommand('/model', '切换 AI 模型', Icons.swap_horiz),
  _SlashCommand('/agents', '查看可用 Agent', Icons.smart_toy_outlined),
  _SlashCommand('/help', '查看帮助信息', Icons.help_outline),
];

// ── 搜索面板 ──

class _SearchPaletteDialog extends ConsumerStatefulWidget {
  final BuildContext parentContext;
  final void Function(String command)? onSlashCommand;

  const _SearchPaletteDialog({
    required this.parentContext,
    this.onSlashCommand,
  });

  @override
  ConsumerState<_SearchPaletteDialog> createState() =>
      _SearchPaletteDialogState();
}

class _SearchPaletteDialogState extends ConsumerState<_SearchPaletteDialog> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // 自动聚焦
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

  void _close() {
    Navigator.of(context).pop();
  }

  void _selectTask(Task task) {
    _close();
    // 使用父 context 进行导航 (dialog context 在 pop 后不可用)
    GoRouter.of(widget.parentContext).push(
      '${AppRoutes.chat}?workspace=${Uri.encodeComponent(task.workspaceKey)}'
      '&task=${Uri.encodeComponent(task.id)}',
    );
  }

  void _selectSlashCommand(_SlashCommand cmd) {
    _close();
    widget.onSlashCommand?.call(cmd.command);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final allTasks = ref.watch(allTasksProvider);
    final workspacesAsync = ref.watch(workspaceListProvider);

    // 构建 workspaceKey → name 映射
    final workspaceNames = <String, String>{};
    workspacesAsync.whenData((workspaces) {
      for (final ws in workspaces) {
        workspaceNames[ws.workspaceKey] = ws.name;
      }
    });

    final query = _query.trim().toLowerCase();

    // 筛选任务 (标题大小写不敏感子串匹配; 排除归档)
    var tasks = allTasks.where((t) => !t.archived).toList();
    if (query.isNotEmpty) {
      tasks = tasks
          .where((t) => t.title.toLowerCase().contains(query))
          .toList();
    }
    // 按更新时间倒序
    tasks.sort((a, b) => (b.updatedAt?.millisecondsSinceEpoch ?? 0)
        .compareTo(a.updatedAt?.millisecondsSinceEpoch ?? 0));
    // 限制结果数
    if (tasks.length > 30) tasks = tasks.sublist(0, 30);

    // 筛选斜杠命令
    final commands = query.isEmpty
        ? _slashCommands
        : _slashCommands
            .where((c) => c.command.contains(query) ||
                c.description.toLowerCase().contains(query))
            .toList();

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _close,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: Colors.transparent,
          alignment: Alignment.topCenter,
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + AppSpacing.md,
            left: AppSpacing.lg,
            right: AppSpacing.lg,
          ),
          child: GestureDetector(
            onTap: () {}, // 阻止点击内容区域关闭
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.xl),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  // 实色背景 (不透明), 满足设计规范
                  color: isDark ? AppColors.darkBg : Colors.white,
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.75,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 搜索框
                      _buildSearchField(theme, isDark),
                      if (query.isEmpty)
                        Divider(
                            height: 1,
                            color: (isDark
                                    ? AppColors.darkBorder
                                    : AppColors.lightBorder)
                                .withValues(alpha: 0.5)),
                      // 结果列表
                      Flexible(
                        child: _buildResults(
                          theme,
                          isDark,
                          commands,
                          tasks,
                          workspaceNames,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(ThemeData theme, bool isDark) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: TextField(
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
          prefixIcon: Icon(Icons.search,
              size: 22, color: theme.colorScheme.onSurfaceVariant),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 44, minHeight: 44),
          suffixIcon: _query.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  color: theme.colorScheme.onSurfaceVariant,
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                    _focusNode.requestFocus();
                  },
                )
              : null,
          filled: true,
          fillColor: isDark
              ? AppColors.darkSurfaceHigh
              : AppColors.lightSurfaceHigh,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.md),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            borderSide: BorderSide(
                color: (isDark
                        ? AppColors.darkBorder
                        : AppColors.lightBorder)
                    .withValues(alpha: 0.5)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            borderSide:
                BorderSide(color: AppColors.accent.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }

  Widget _buildResults(
    ThemeData theme,
    bool isDark,
    List<_SlashCommand> commands,
    List<Task> tasks,
    Map<String, String> workspaceNames,
  ) {
    final hasResults = commands.isNotEmpty || tasks.isNotEmpty;

    if (!hasResults) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
        ),
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      children: [
        // 斜杠命令
        if (commands.isNotEmpty) ...[
          _sectionLabel(theme, '命令'),
          for (final cmd in commands)
            _buildCommandTile(theme, isDark, cmd),
          if (tasks.isNotEmpty)
            Divider(
                height: 1,
                indent: AppSpacing.lg,
                endIndent: AppSpacing.lg,
                color: (isDark ? AppColors.darkBorder : AppColors.lightBorder)
                    .withValues(alpha: 0.5)),
        ],
        // 任务结果
        if (tasks.isNotEmpty) ...[
          _sectionLabel(theme, '对话'),
          for (final task in tasks)
            _buildTaskTile(theme, isDark, task, workspaceNames),
        ],
      ],
    );
  }

  Widget _sectionLabel(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
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

  Widget _buildCommandTile(
      ThemeData theme, bool isDark, _SlashCommand cmd) {
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
    bool isDark,
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
