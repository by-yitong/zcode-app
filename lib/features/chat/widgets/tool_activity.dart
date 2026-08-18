import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/chat_markdown_style.dart';
import 'chat_helpers.dart';
import 'thought_block.dart';
import 'code_block.dart';
import 'plan_card.dart';

class ToolActivityCards extends StatefulWidget {
  final List<ToolActivity> activities;
  final ThemeData theme;
  final Color inkColor;

  const ToolActivityCards({
    required this.activities,
    required this.theme,
    required this.inkColor,
  });

  @override
  State<ToolActivityCards> createState() => ToolActivityCardsState();
}

class ToolActivityCardsState extends State<ToolActivityCards>
    with SingleTickerProviderStateMixin {
  /// null = 跟随自动状态 (运行中展开, 完成后折叠); 手动点按后固定。
  /// 完成态重新变为运行态时重置 (对齐 ZCode 的 defaultOpen 同步)。
  bool? _manualExpanded;
  // 记录哪些工具行被单独展开 (按 toolCallId)
  final Set<String> _expandedRows = {};

  @override
  void didUpdateWidget(covariant ToolActivityCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasRunning = oldWidget.activities.any((a) => a.isRunning);
    final nowRunning = widget.activities.any((a) => a.isRunning);
    if (wasRunning != nowRunning) _manualExpanded = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final activities = widget.activities;
    if (activities.isEmpty) return const SizedBox.shrink();

    // plan/todo 工具已单独渲染 (PlanCard / plan 面板), 这里排除;
    // 子代理 (Agent/Explore/Task) 作为普通行渲染 (专属图标 + 摘要)
    final tools = activities
        .where((a) => !isPlanTool(a) && !isTodoTool(a))
        .toList();
    if (tools.isEmpty) return const SizedBox.shrink();

    final running = tools.where((a) => a.isRunning).length;
    final completed = tools
        .where(
          (a) =>
              a.status == 'result' ||
              a.status == 'done' ||
              a.status == 'complete' ||
              a.status == 'completed' ||
              a.status == 'success',
        )
        .length;
    final errors = tools
        .where((a) => a.status == 'error' || a.status == 'failed')
        .length;

    // ★ 自动隐藏: 运行中展开 (实时滚动), 全部完成后折叠成一行摘要
    final expanded = _manualExpanded ?? running > 0;

    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerHigh;

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.xs),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部: 摘要 + 折叠箭头
          InkWell(
            onTap: () => setState(() => _manualExpanded = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${tools.length} 个工具调用',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 状态摘要: M 完成 · K 运行中 · N 出错
                  Flexible(
                    child: Text(
                      [
                        if (completed > 0) '$completed 完成',
                        if (running > 0) '$running 运行中',
                        if (errors > 0) '$errors 出错',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: AppTextSizes.caption,
                        color: running > 0
                            ? AppColors.accent
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (running > 0)
                    const SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor: AlwaysStoppedAnimation(AppColors.accent),
                      ),
                    )
                  else if (errors > 0)
                    const Icon(
                      Icons.error_outline,
                      size: 13,
                      color: AppColors.danger,
                    ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: AppDur.fast,
                    curve: AppEase.inOut,
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
          // 展开后: 工具行 (含子代理行)
          AnimatedSize(
            duration: AppDur.base,
            curve: AppEase.inOut,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm + 2,
                      0,
                      AppSpacing.sm + 2,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      children: [
                        for (final a in tools) ...[
                          ToolActivityRow(
                            activity: a,
                            theme: theme,
                            inkColor: widget.inkColor,
                            expanded: _expandedRows.contains(a.toolCallId),
                            onToggle: () => setState(() {
                              if (_expandedRows.contains(a.toolCallId)) {
                                _expandedRows.remove(a.toolCallId);
                              } else {
                                _expandedRows.add(a.toolCallId);
                              }
                            }),
                          ),
                          const SizedBox(height: 2),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 格式化工具名显示: mcp__server__method → "server · method"
String formatToolName(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('mcp__')) {
    final parts = name.split('__');
    if (parts.length >= 3) {
      final server = parts[1];
      final method = parts.sublist(2).join('_');
      return '$server · $method';
    }
  }
  return name;
}

/// 工具名 → 图标 (按工具类型精确定位, 不用 emoji)
IconData iconForTool(String name) {
  final n = name.toLowerCase();
  if (n.startsWith('mcp__')) return Icons.extension;
  if (isSubagentToolName(n)) return Icons.account_tree_outlined;
  if (n.contains('bash') ||
      n.contains('shell') ||
      n.contains('terminal') ||
      n.contains('cmd') ||
      n.contains('exec')) {
    return Icons.terminal;
  }
  if (n.contains('grep') ||
      n.contains('glob') ||
      n.contains('search') ||
      n.contains('find')) {
    return Icons.search;
  }
  if (n.contains('edit') ||
      n.contains('write') ||
      n.contains('create') ||
      n.contains('str_replace')) {
    return Icons.edit_outlined;
  }
  if (n.contains('read') || n.contains('notebook'))
    return Icons.description_outlined;
  if (n.contains('web') ||
      n.contains('browser') ||
      n.contains('fetch') ||
      n.contains('curl') ||
      n.contains('url')) {
    return Icons.travel_explore;
  }
  if (n.contains('todo') || n.contains('plan')) return Icons.checklist;
  return Icons.build_outlined;
}

bool isSubagentToolName(String n) {
  return n == 'agent' ||
      n == 'task' ||
      n == 'explore' ||
      n.contains('subagent') ||
      n.startsWith('explore');
}

/// 工具调用的目标摘要 (行内灰色补充): 命令首行 / 文件名 / 搜索词 / URL
String? toolTarget(ToolActivity a) {
  final input = a.input;
  if (input == null) return null;
  String? firstNonEmpty(List<String> keys) {
    for (final k in keys) {
      final v = input[k];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  final n = a.toolName.toLowerCase();
  if (n.contains('bash') || n.contains('shell') || n.contains('terminal')) {
    final cmd = firstNonEmpty(['command', 'cmd', 'script']);
    if (cmd == null) return null;
    final line = cmd.split('\n').first.trim();
    return line.length > 60 ? '${line.substring(0, 60)}…' : line;
  }
  if (n.startsWith('mcp__')) {
    return firstNonEmpty(['query', 'url', 'path', 'name', 'text']);
  }
  if (isSubagentToolName(n)) {
    return firstNonEmpty(['description', 'prompt', 'query']);
  }
  if (n.contains('grep') || n.contains('glob') || n.contains('search')) {
    return firstNonEmpty(['pattern', 'query', 'q', 'search']);
  }
  if (n.contains('web') || n.contains('fetch') || n.contains('url')) {
    final url = firstNonEmpty(['url', 'link']);
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    return uri?.host ?? url;
  }
  // 文件类与其余: 显示文件名/路径
  final path = firstNonEmpty(['file_path', 'path', 'filename', 'file']);
  if (path != null) {
    final base = path.split('/').last;
    return base.length > 48 ? '…${base.substring(base.length - 47)}' : base;
  }
  return null;
}

/// 工具调用精简单行 (ZCode 风格: 图标 + mono 工具名 + 目标摘要 + 状态,
/// 无独立卡片背景, 点击展开详情)
class ToolActivityRow extends StatelessWidget {
  final ToolActivity activity;
  final ThemeData theme;
  final Color inkColor;
  final bool expanded;
  final VoidCallback onToggle;

  const ToolActivityRow({
    required this.activity,
    required this.theme,
    required this.inkColor,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final theme = this.theme;
    final running = a.isRunning;
    final isError = a.status == 'error' || a.status == 'failed';

    final toolLabel = formatToolName(a.toolName);
    final target = toolTarget(a);
    final elapsed = a.elapsedMs != null
        ? (a.elapsedMs! >= 60000
              ? formatWorkDuration(a.elapsedMs!)
              : '${(a.elapsedMs! / 1000).toStringAsFixed(1)}s')
        : null;

    final Widget statusIcon;
    if (a.status == 'pendingApproval') {
      statusIcon = const Icon(
        Icons.hourglass_top,
        size: 12,
        color: AppColors.warning,
      );
    } else if (running) {
      statusIcon = const SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(
          strokeWidth: 1.3,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    } else if (isError) {
      statusIcon = const Icon(Icons.close, size: 12, color: AppColors.danger);
    } else {
      statusIcon = const SizedBox.shrink();
    }

    final hasDetail =
        (a.input != null && a.input!.isNotEmpty) ||
        (a.result != null && a.result!.isNotEmpty);

    final detailBg = theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerLowest
        : theme.colorScheme.surfaceContainerHighest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: hasDetail ? onToggle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            child: Row(
              children: [
                Icon(
                  iconForTool(a.toolName),
                  size: 14,
                  color: running
                      ? AppColors.accent
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                // mono 工具名 + 目标摘要 (同行, 摘要灰色收缩)
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      text: toolLabel,
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        fontFamily: kMonoFont,
                        // 元信息降一档 (与执行轨迹节点一致)
                        color: isError
                            ? AppColors.danger
                            : inkColor.withValues(alpha: 0.65),
                      ),
                      children: [
                        if (target != null)
                          TextSpan(
                            text: '  $target',
                            style: TextStyle(
                              fontSize: AppTextSizes.caption,
                              fontFamily: kMonoFont,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const Spacer(),
                const SizedBox(width: 4),
                if (elapsed != null && !running)
                  Text(
                    elapsed,
                    style: TextStyle(
                      fontSize: AppTextSizes.monoXs,
                      fontFamily: kMonoFont,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 4),
                statusIcon,
                if (hasDetail) ...[
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: AppDur.fast,
                    curve: AppEase.inOut,
                    child: Icon(
                      Icons.chevron_right,
                      size: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // 展开详情 (输入参数 + 结果)
        if (expanded && hasDetail) ...[
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 300),
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: detailBg,
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _buildToolDetail(a, theme, inkColor),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 构建工具展开详情 — 根据工具类型智能渲染
  List<Widget> _buildToolDetail(
    ToolActivity a,
    ThemeData theme,
    Color inkColor,
  ) {
    final n = a.toolName.toLowerCase();
    final isBash =
        n.contains('bash') ||
        n.contains('shell') ||
        n.contains('terminal') ||
        n.contains('exec') ||
        n.contains('run');
    final isFileEdit =
        n.contains('edit') ||
        n.contains('write') ||
        n.contains('str_replace') ||
        n.contains('file');

    final children = <Widget>[];

    // MCP 工具 (mcp__server__tool): 专属分节 — Server 徽章 + Arguments/Result
    final isMcp = a.toolName.startsWith('mcp__');
    if (isMcp) {
      children.add(
        Row(
          children: [
            Icon(Icons.extension, size: 11, color: inkColor),
            const SizedBox(width: 4),
            Text(
              'MCP · ${formatToolName(a.toolName)}',
              style: TextStyle(
                fontSize: 10,
                fontFamily: kMonoFont,
                color: inkColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
      children.add(const SizedBox(height: AppSpacing.xs));
    }

    // 输入参数
    if (a.input != null && a.input!.isNotEmpty) {
      final label = isMcp
          ? 'Arguments'
          : isBash
              ? '命令'
              : (isFileEdit ? '文件' : '参数');
      children.add(
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
      children.add(const SizedBox(height: 3));

      // 对于文件类工具, 优先显示 file_path
      if (isFileEdit) {
        for (final key in ['file_path', 'path', 'filename', 'file']) {
          final v = a.input![key];
          if (v is String && v.isNotEmpty) {
            children.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  v.split('/').last,
                  style: TextStyle(
                    fontSize: AppTextSizes.caption,
                    fontFamily: kMonoFont,
                    color: inkColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
            break;
          }
        }
      }

      // 显示参数键值对 (截取重要部分)
      for (final e in a.input!.entries) {
        if (isFileEdit &&
            ['file_path', 'path', 'filename', 'file'].contains(e.key)) {
          continue;
        }
        final valStr = e.value is String
            ? e.value as String
            : e.value.toString();
        // 对长文本参数 (如 new_string/old_string/content), 用代码块显示
        if (valStr.length > 80) {
          children.add(
            Text(
              e.key,
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
          children.add(const SizedBox(height: 2));
          children.add(
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                valStr.length > 500 ? '${valStr.substring(0, 500)}...' : valStr,
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  fontFamily: kMonoFont,
                  color: inkColor,
                  height: 1.4,
                ),
              ),
            ),
          );
        } else {
          children.add(
            Text(
              '${e.key}: $valStr',
              style: TextStyle(
                fontSize: AppTextSizes.caption,
                fontFamily: kMonoFont,
                color: inkColor,
              ),
            ),
          );
        }
        children.add(const SizedBox(height: 2));
      }
    }

    // 结果
    if (a.result != null && a.result!.isNotEmpty) {
      if (a.input != null && a.input!.isNotEmpty) {
        children.add(const SizedBox(height: AppSpacing.xs));
      }
      children.add(
        Text(
          isMcp ? 'Result' : (isBash ? '输出' : '结果'),
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
      children.add(const SizedBox(height: 3));

      // 检测是否是 diff 格式 (含 +/- 开头的行)
      final resultText = a.result!.length > 800
          ? '${a.result!.substring(0, 800)}...'
          : a.result!;
      final lines = resultText.split('\n');

      children.add(
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lines.map((line) {
              final trimmed = line.trimLeft();
              Color? lineColor;
              if (trimmed.startsWith('+') && !trimmed.startsWith('+++')) {
                lineColor = AppColors.success;
              } else if (trimmed.startsWith('-') &&
                  !trimmed.startsWith('---')) {
                lineColor = AppColors.danger;
              }
              return Text(
                line,
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  fontFamily: kMonoFont,
                  color: lineColor ?? inkColor,
                  height: 1.4,
                ),
              );
            }).toList(),
          ),
        ),
      );
    }

    return children;
  }
}

/// 工作时长格式化 (对齐 ZCode 桌面端 Nvt):
/// 秒级取整 (最少 1s), 天/时/分/秒最多保留两个单位。
/// 62000ms → "1 分 2 秒"; 3900000ms → "1 时 5 分"; 45000 → "45 秒"。
/// 轮次工作状态行 (ZCode 同款, 桌面端 zvt 组件):
/// 运行中 = "工作中 X 分 Y 秒" (实时跳动); 完成 = "已工作 X 分 Y 秒";
/// 无时长数据 = "已处理"。底部发丝线, 可作为折叠历史的开关头。
