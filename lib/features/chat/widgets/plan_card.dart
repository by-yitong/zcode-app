import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../core/relay/relay_events.dart';
import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/chat_markdown_style.dart';
import 'chat_helpers.dart';
import 'code_block.dart';

class PlanCard extends StatefulWidget {
  final ToolActivity activity;
  final ThemeData theme;
  final Color inkColor;

  /// ★ 权限确认按钮直接内嵌在卡片底部 (不再弹底部弹窗)
  final PendingPermission? permission;
  final void Function(
    String permissionId,
    String optionId,
    String decision,
    List<PermissionOption>? options,
    String? traceId,
  )?
  onRespondPermission;

  const PlanCard({
    required this.activity,
    required this.theme,
    required this.inkColor,
    this.permission,
    this.onRespondPermission,
  });

  @override
  State<PlanCard> createState() => PlanCardState();
}

class PlanCardState extends State<PlanCard>
    with SingleTickerProviderStateMixin {
  /// 历史计划默认折叠; 待确认(plan permission pending)时默认展开
  bool get _defaultExpanded => widget.permission != null;
  late bool _expanded = _defaultExpanded;

  // styleSheet 引用相等才不重解析 (见 _MessageBubbleState 同款注释)
  ThemeData? _styleTheme;
  MarkdownStyleSheet? _planStyle;
  Map<String, MarkdownElementBuilder>? _planBuilders;

  MarkdownStyleSheet _style(ThemeData theme) {
    if (_planStyle == null || !identical(_styleTheme, theme)) {
      _styleTheme = theme;
      _planStyle = MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: theme.textTheme.bodySmall,
        h1: theme.textTheme.titleSmall,
        h2: theme.textTheme.titleSmall,
        h3: theme.textTheme.titleSmall,
        listBullet: theme.textTheme.bodySmall,
        code: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceContainerLowest,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      );
    }
    return _planStyle!;
  }

  Map<String, MarkdownElementBuilder> _builders(ThemeData theme) {
    return _planBuilders ??= {'pre': CodeBlockBuilder(theme: theme)};
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    // plan 可能在 result (已完成的 ExitPlanMode output) 或 input.plan (待确认, wire 实测 state.input.plan)
    final planText =
        widget.activity.result ??
        widget.activity.input?['plan'] as String? ??
        '';
    if (planText.isEmpty) return const SizedBox.shrink();

    final perm = widget.permission;
    final isPending = perm != null;

    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerHigh;
    final accent = widget.inkColor;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: accent.withValues(alpha: 0.3), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行: 📋 计划 + 折叠按钮 + 待确认标签
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(Icons.checklist_rtl, size: 16, color: accent),
                  const SizedBox(width: 6),
                  Text(
                    '计划',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isPending) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '待确认',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // markdown 正文
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: _expanded
                ? Padding(
                    padding: EdgeInsets.only(
                      left: AppSpacing.sm + 2,
                      right: AppSpacing.sm + 2,
                      bottom: isPending ? 0 : AppSpacing.sm + 2,
                    ),
                    child: MarkdownBody(
                      data: planText,
                      selectable: true,
                      styleSheet: _style(theme),
                      builders: _builders(theme),
                    ),
                  )
                // 收起时显示前几行预览 (取纯文本, 最多7行)
                : Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.sm + 2,
                      right: AppSpacing.sm + 2,
                      bottom: AppSpacing.sm,
                    ),
                    child: Text(
                      planText
                          .split('\n')
                          .where((l) => l.trim().isNotEmpty)
                          .take(7)
                          .join('\n')
                          .replaceAll(mdLeadRe, ''),
                      maxLines: 7,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                  ),
          ),
          // ★ 内嵌权限按钮 (待确认时显示)
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: (isPending && _expanded)
                ? Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.sm + 2,
                      right: AppSpacing.sm + 2,
                      top: AppSpacing.sm,
                      bottom: AppSpacing.sm + 2,
                    ),
                    child: Row(
                      children: perm.options.map((opt) {
                        final cnLabel = switch (opt.normKind) {
                          'allowonce' => '允许',
                          'allowalways' => '始终允许',
                          'deny' => '拒绝',
                          'escalate' => '上报',
                          'modify' => '修改',
                          _ => opt.name,
                        };
                        final isDeny = opt.decision == 'deny';
                        return Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: opt != perm.options.last
                                  ? AppSpacing.xs
                                  : 0,
                            ),
                            child: isDeny
                                ? OutlinedButton.icon(
                                    onPressed: () =>
                                        widget.onRespondPermission?.call(
                                          perm.id,
                                          opt.optionId,
                                          opt.decision,
                                          perm.options,
                                          perm.traceId,
                                        ),
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                    ),
                                    label: Text(
                                      cnLabel,
                                      style: const TextStyle(
                                        fontSize: AppTextSizes.bodySm,
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.danger,
                                      minimumSize: const Size.fromHeight(38),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                    ),
                                  )
                                : FilledButton.icon(
                                    onPressed: () =>
                                        widget.onRespondPermission?.call(
                                          perm.id,
                                          opt.optionId,
                                          opt.decision,
                                          perm.options,
                                          perm.traceId,
                                        ),
                                    icon: const Icon(
                                      Icons.check_rounded,
                                      size: 16,
                                    ),
                                    label: Text(
                                      cnLabel,
                                      style: const TextStyle(
                                        fontSize: AppTextSizes.bodySm,
                                      ),
                                    ),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.success,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size.fromHeight(38),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      }).toList(),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 变更文件摘要 (折叠式 — 展示 N 个文件已更改 +N -M)
class ChangedFilesSummary extends StatefulWidget {
  final List<ToolActivity> activities;
  final ThemeData theme;
  final Color inkColor;

  /// turnHeader.fileChanges 权威统计 (additions/deletions/files);
  /// null 时回退到从工具活动刮取
  final V4TurnFileChanges? fileChanges;

  const ChangedFilesSummary({
    required this.activities,
    required this.theme,
    required this.inkColor,
    this.fileChanges,
  });

  @override
  State<ChangedFilesSummary> createState() => ChangedFilesSummaryState();
}

class ChangedFilesSummaryState extends State<ChangedFilesSummary>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = theme.brightness == Brightness.dark;
    final fileActivities = widget.activities
        .where((a) => isFileActivity(a) && !isTodoTool(a))
        .toList();

    // 提取唯一文件路径
    final fileMap = <String, ToolActivity>{};
    for (final a in fileActivities) {
      final path = extractFilePath(a);
      if (path != null && path.isNotEmpty) {
        fileMap[path] = a;
      }
    }
    final files = fileMap.keys.toList();

    // 增删行数: 优先 turnHeader.fileChanges 权威数据, 否则从 result 刮 +N -M
    final fc = widget.fileChanges;
    var totalAdded = 0;
    var totalRemoved = 0;
    if (fc != null) {
      totalAdded = fc.additions;
      totalRemoved = fc.deletions;
    } else {
      for (final a in fileActivities) {
        final (add, del) = extractDiffCounts(a.result ?? '');
        totalAdded += add;
        totalRemoved += del;
      }
    }
    final fileCount = fc != null && fc.files > 0 ? fc.files : files.length;

    final cardBg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerHigh;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部: "N 个文件已更改  +N -M"
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.difference_outlined,
                    size: 16,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$fileCount 个文件已更改',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w500,
                      color: widget.inkColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (totalAdded > 0)
                    Text(
                      '+$totalAdded',
                      style: const TextStyle(
                        fontSize: AppTextSizes.caption,
                        color: AppColors.success,
                      ),
                    ),
                  if (totalRemoved > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      '-$totalRemoved',
                      style: const TextStyle(
                        fontSize: AppTextSizes.caption,
                        color: AppColors.danger,
                      ),
                    ),
                  ],
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开详情: 文件列表
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: (_expanded && files.isNotEmpty)
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm + 2,
                      0,
                      AppSpacing.sm + 2,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(
                          height: 1,
                          color: widget.inkColor.withValues(alpha: 0.08),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        for (final path in files)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Icon(
                                  _fileIcon(path),
                                  size: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    path.split('/').last,
                                    style: TextStyle(
                                      fontSize: AppTextSizes.label,
                                      fontFamily: kMonoFont,
                                      color: widget.inkColor,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    path,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  IconData _fileIcon(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'dart' => Icons.flutter_dash,
      'py' => Icons.code,
      'js' || 'ts' || 'jsx' || 'tsx' => Icons.javascript,
      'json' || 'yaml' || 'yml' || 'toml' || 'xml' => Icons.settings,
      'md' => Icons.description,
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'svg' ||
      'webp' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

/// 工具调用统一折叠容器 (所有工具调用合并到一张卡, 节省空间)
///
/// 折叠态: 头部一行摘要 "🔧 N 个工具调用 · M 完成 / K 运行中"
/// 展开态: 内部按工具类型分组:
///   - 子代理 (Agent/Explore/Task): 整体折叠成 "🤖 调用了 N 个子任务"
///   - 普通工具: 精简行列表 (图标+名+状态), 点击单行展开详情
