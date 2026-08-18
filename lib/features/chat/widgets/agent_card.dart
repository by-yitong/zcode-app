import 'dart:async';

import 'package:flutter/material.dart';

import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import 'thought_block.dart';
import 'tool_activity.dart';

/// 子代理卡 (V4 `subagent` 行) — 独立折叠区域, 不混入工具合并卡。
///
/// 折叠头: 类型 + 状态 (运行中跳动 / ✓ / ✗ / 已取消)。
/// 展开: 摘要 + 子会话内容 (懒加载: 首次展开拉 childSessionId 行,
/// 失败降级为仅摘要); 子会话内再有 subagent 行 → 递归嵌套 AgentCard。
class AgentCard extends StatefulWidget {
  final SubagentPart part;
  final ThemeData theme;

  /// 子会话懒加载器 (chat_screen 从 chatProvider 注入; null = 无下钻能力)
  final Future<List<MessagePart>> Function(String childSessionId)?
      onLoadChildren;
  final int depth; // 嵌套深度 (0 = 顶层)

  const AgentCard({
    super.key,
    required this.part,
    required this.theme,
    this.onLoadChildren,
    this.depth = 0,
  });

  @override
  State<AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends State<AgentCard> {
  bool _expanded = false;
  List<MessagePart>? _children;
  bool _loading = false;
  String? _error;

  Future<void> _ensureChildren() async {
    final loader = widget.onLoadChildren;
    final sid = widget.part.childSessionId;
    if (loader == null || sid == null || _children != null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final children = await loader(sid);
      if (!mounted) return;
      setState(() => _children = children);
    } catch (_) {
      if (!mounted) return;
      // 子会话拉取失败不阻断主流程 — 降级为仅摘要展示
      setState(() => _error = '子任务详情加载失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final part = widget.part;
    final statusColor = switch (part.status) {
      'running' => AppColors.accent,
      'success' => AppColors.success,
      'failed' => AppColors.danger,
      _ => theme.colorScheme.onSurfaceVariant, // cancelled / 未知
    };

    return Container(
      margin: EdgeInsets.only(
        left: widget.depth > 0 ? AppSpacing.md : 0,
        bottom: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.md),
        // 对齐 PlanCard 的细着色描边 (Border+圆角要求四边同色,
        // 状态语义由图标/耗时承担, 不再加粗色条)
        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 折叠头
          InkWell(
            onTap: () {
              setState(() => _expanded = !_expanded);
              if (_expanded) unawaited(_ensureChildren());
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 16,
                    color: statusColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      part.subagentType.isEmpty ? '子代理' : part.subagentType,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (part.isRunning) ...[
                    const RunningDot(size: 6),
                    const SizedBox(width: 4),
                    Text(
                      '运行中',
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        color: statusColor,
                      ),
                    ),
                  ] else
                    Icon(_statusIcon(), size: 14, color: statusColor),
                  const SizedBox(width: 4),
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
          // 展开区
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: _expanded
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
                        if (part.summaryText.isNotEmpty)
                          Text(
                            part.summaryText,
                            style: TextStyle(
                              fontSize: AppTextSizes.bodySm,
                              height: 1.5,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        if (part.childSessionId != null &&
                            widget.onLoadChildren != null) ...[
                          if (part.summaryText.isNotEmpty)
                            const SizedBox(height: AppSpacing.sm),
                          if (_loading)
                            Row(
                              children: [
                                const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '加载子任务详情…',
                                  style: TextStyle(
                                    fontSize: AppTextSizes.label,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            )
                          else if (_error != null)
                            Text(
                              _error!,
                              style: TextStyle(
                                fontSize: AppTextSizes.label,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          else if (_children != null)
                            _ChildPartsView(
                              parts: _children!,
                              theme: theme,
                              loader: widget.onLoadChildren,
                              depth: widget.depth + 1,
                            ),
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

  IconData _statusIcon() => switch (widget.part.status) {
        'success' => Icons.check_circle_outline,
        'failed' => Icons.cancel_outlined,
        'cancelled' => Icons.block_outlined,
        _ => Icons.check_circle_outline,
      };
}

/// 子代理 children 的轻量投影渲染 (不复用主列表的合并卡, 保持克制)
class _ChildPartsView extends StatelessWidget {
  final List<MessagePart> parts;
  final ThemeData theme;
  final Future<List<MessagePart>> Function(String childSessionId)? loader;
  final int depth;

  const _ChildPartsView({
    required this.parts,
    required this.theme,
    this.loader,
    required this.depth,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in parts) _buildPart(p),
      ],
    );
  }

  Widget _buildPart(MessagePart p) {
    final theme = this.theme;
    return switch (p) {
      SubagentPart() => AgentCard(
          part: p,
          theme: theme,
          onLoadChildren: loader,
          depth: depth,
        ),
      ToolPart() => _ChildToolRow(activity: p.activity, theme: theme),
      ThoughtPart() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(
                Icons.psychology_outlined,
                size: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                p.durationMs != null
                    ? '思考 ${formatWorkDuration(p.durationMs!)}'
                    : '思考过程',
                style: TextStyle(
                  fontSize: AppTextSizes.label,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      TextPart() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            p.text,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTextSizes.bodySm,
              height: 1.5,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      StepPart() => const SizedBox.shrink(),
    };
  }
}

/// 子会话内单个工具调用行 (紧凑: 图标 + 名 + 摘要 + 状态)
class _ChildToolRow extends StatelessWidget {
  final ToolActivity activity;
  final ThemeData theme;

  const _ChildToolRow({required this.activity, required this.theme});

  @override
  Widget build(BuildContext context) {
    final theme = this.theme;
    final running = activity.isRunning;
    final failed = activity.status == 'error' || activity.status == 'failed';
    final color = failed
        ? AppColors.danger
        : running
            ? AppColors.accent
            : AppColors.success;
    final target = toolTarget(activity);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(iconForTool(activity.toolName), size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            formatToolName(activity.toolName),
            style: TextStyle(
              fontSize: AppTextSizes.label,
              fontFamily: kMonoFont,
              color: theme.colorScheme.onSurface,
            ),
          ),
          if (target != null && target.isNotEmpty) ...[
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                target,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTextSizes.label,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ] else
            const Spacer(),
          const SizedBox(width: 6),
          if (running)
            const RunningDot(size: 5)
          else
            Icon(
              failed ? Icons.close_rounded : Icons.check_rounded,
              size: 13,
              color: color,
            ),
        ],
      ),
    );
  }
}
