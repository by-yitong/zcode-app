import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/chat_markdown_style.dart';

class ApprovalCard extends StatelessWidget {
  final PendingPermission perm;
  final ThemeData theme;
  final void Function(String optionId, String decision) onAnswer;

  const ApprovalCard({
    required this.perm,
    required this.theme,
    required this.onAnswer,
  });

  String _summarize() {
    final input = perm.input;
    final path =
        input['file_path'] ??
        input['filePath'] ??
        input['path'] ??
        input['file'];
    if (path is String && path.isNotEmpty) return path;
    final cmd = input['command'] ?? input['cmd'];
    if (cmd is String && cmd.isNotEmpty) return cmd;
    return '';
  }

  String _toolLabel(String toolName) {
    return switch (toolName) {
      'ExitPlanMode' => '计划确认',
      'EnterPlanMode' => '进入计划模式',
      'Edit' || 'Write' => '编辑文件',
      'Bash' => '执行命令',
      'MultiEdit' => '批量编辑',
      _ => '执行 $toolName',
    };
  }

  Color _riskColor() {
    return switch (perm.riskLevel) {
      'critical' => Colors.red.shade700,
      'high' => Colors.red,
      'medium' => Colors.orange,
      _ => Colors.blue,
    };
  }

  Widget _optionButton(PermissionOption opt) {
    // ★ 按钮中文标签 — 按 kind 映射 (网页端 option.name 是英文;
    //   kind 有 allowOnce/allow_once 两种拼写, 用 normKind 统一)
    final (label, icon) = switch (opt.normKind) {
      'allowonce' => ('允许', Icons.check_rounded),
      'allowalways' => ('始终允许', Icons.done_all_rounded),
      'deny' => ('拒绝', Icons.close_rounded),
      'escalate' => ('上报', Icons.north_rounded),
      'modify' => ('修改', Icons.edit_outlined),
      _ => (opt.name, Icons.check_rounded),
    };
    final isDeny = opt.decision == 'deny' || opt.kind == 'deny';
    const visualDensity = VisualDensity.compact;
    const minimumSize = Size(0, 38);
    const btnPadding = EdgeInsets.symmetric(horizontal: 14);
    void answer() => onAnswer(opt.optionId, opt.decision);

    if (isDeny) {
      return OutlinedButton.icon(
        onPressed: answer,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.danger,
          visualDensity: visualDensity,
          minimumSize: minimumSize,
          padding: btnPadding,
        ),
      );
    }
    if (opt.normKind == 'allowonce') {
      return FilledButton.icon(
        onPressed: answer,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.success,
          foregroundColor: Colors.white,
          visualDensity: visualDensity,
          minimumSize: minimumSize,
          padding: btnPadding,
        ),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: answer,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.successContainer,
        foregroundColor: AppColors.success,
        visualDensity: visualDensity,
        minimumSize: minimumSize,
        padding: btnPadding,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _summarize();
    final riskColor = _riskColor();

    // 入场: 淡入 + 轻微上移 (一次性, 提示有新请求且不突兀)
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.md),
          // 对齐 PlanCard 的细着色描边 (Border+圆角要求四边同色,
          // 风险语义由图标/徽章承担, 不再加粗色条)
          border: Border.all(color: riskColor.withValues(alpha: 0.3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm + 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行: 图标 + 工具名 + 风险徽章
              Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: riskColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '请求${_toolLabel(perm.toolName)}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (perm.riskLevel == 'high' || perm.riskLevel == 'critical')
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: riskColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        perm.riskLevel == 'critical' ? '严重' : '高风险',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: riskColor,
                        ),
                      ),
                    ),
                ],
              ),
              // 命令/路径摘要 (长按复制)
              if (detail.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs + 2),
                GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: detail));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('已复制'),
                          duration: Duration(milliseconds: 1200),
                        ),
                      );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        fontFamily: kMonoFont,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
              // 原因
              if (perm.reason.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs + 2),
                Text(
                  perm.reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTextSizes.bodySm,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              // 按钮行 (横排, 自动换行)
              if (perm.options.isNotEmpty)
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final opt in perm.options) _optionButton(opt),
                  ],
                )
              else
                Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    _optionButton(
                      const PermissionOption(
                        optionId: '',
                        kind: 'allow_once',
                        name: 'allow',
                      ),
                    ),
                    _optionButton(
                      const PermissionOption(
                        optionId: '',
                        kind: 'deny',
                        name: 'deny',
                        decision: 'deny',
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 待确认提示条 — 权限挂起时常驻输入栏上方, 滚丢审批卡时一键定位
class PendingApprovalBar extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const PendingApprovalBar({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppColors.warningContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm + 2,
          ),
          child: Row(
            children: [
              const Icon(
                Icons.gpp_maybe_outlined,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  count > 1 ? '$count 个操作等待确认' : '操作等待确认',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              Text(
                '定位',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: AppColors.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.keyboard_double_arrow_down_rounded,
                size: 16,
                color: AppColors.warning,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// AskUserQuestion 交互式问题卡片
///
/// AI 提交计划后后端暂停, 此卡片展示 plan 内容 (兜底用最近 assistant 消息文本,
/// 因 plan 原文 wire 上 inputOmitted) + 批准/拒绝按钮。
class PlanApprovalCard extends StatelessWidget {
  final String planText;
  final ThemeData theme;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const PlanApprovalCard({
    required this.planText,
    required this.theme,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final theme = this.theme;
    // 截断过长 plan 文本 (展示用, 避免卡片撑太高)
    final display = planText.length > 600
        ? '\${planText.substring(0, 600)}...'
        : planText;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.event_note_rounded, size: 18, color: AppColors.accent),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'AI 提议的计划',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 280),
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: SingleChildScrollView(
              child: MarkdownBody(
                data: display,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: AppTextSizes.bodySm,
                    height: 1.5,
                    color: theme.colorScheme.onSurface,
                  ),
                  h2: TextStyle(
                    fontSize: AppTextSizes.body,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  code: TextStyle(
                    backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    fontSize: AppTextSizes.label,
                    fontFamily: kMonoFont,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('批准并继续'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(40),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('拒绝'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    minimumSize: const Size.fromHeight(40),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// AskUserQuestion 交互式问题卡片
///
/// AI 调 AskUserQuestion 工具时, 此卡片渲染问题 + 选项,
/// 用户点选后通过 onAnswer 回调提交。
class QuestionCard extends StatefulWidget {
  final AskUserQuestion question;
  final void Function(List<String> selected) onAnswer;

  const QuestionCard({required this.question, required this.onAnswer});

  @override
  State<QuestionCard> createState() => QuestionCardState();
}

class QuestionCardState extends State<QuestionCard> {
  String? _singleSelect;
  final Set<String> _multiSelect = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = widget.question;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.accentContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行
          Row(
            children: [
              Icon(Icons.help_outline, size: 18, color: AppColors.accent),
              const SizedBox(width: AppSpacing.sm),
              Text(
                q.header.isNotEmpty ? q.header : 'AI 有个问题',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          // 问题文本
          Text(
            q.question,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: AppSpacing.md),
          // 选项列表
          ...q.options.map((opt) {
            final isSelected = q.multiSelect
                ? _multiSelect.contains(opt.label)
                : _singleSelect == opt.label;
            return QuestionOption(
              label: opt.label,
              description: opt.description,
              selected: isSelected,
              onTap: () {
                setState(() {
                  if (q.multiSelect) {
                    if (_multiSelect.contains(opt.label)) {
                      _multiSelect.remove(opt.label);
                    } else {
                      _multiSelect.add(opt.label);
                    }
                  } else {
                    _singleSelect = opt.label;
                  }
                });
              },
            );
          }),
          // 提交按钮
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: _canSubmit()
                ? () {
                    final selected = q.multiSelect
                        ? _multiSelect.toList()
                        : [_singleSelect!];
                    widget.onAnswer(selected);
                  }
                : null,
            icon: const Icon(Icons.check, size: 18),
            label: Text(q.multiSelect ? '提交选择' : '确认'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ],
      ),
    );
  }

  bool _canSubmit() {
    if (widget.question.multiSelect) return _multiSelect.isNotEmpty;
    return _singleSelect != null;
  }
}

/// 问题选项行
class QuestionOption extends StatelessWidget {
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const QuestionOption({
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.12)
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  ),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : theme.dividerColor.withValues(alpha: 0.2),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 选择指示器
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    key: ValueKey(selected),
                    size: 18,
                    color: selected
                        ? AppColors.accent
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm + 2),
              // 文本
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected
                            ? AppColors.accent
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: AppTextSizes.label,
                          height: 1.4,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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
}

/// slash 命令 (/命令面板)
///
/// 协议层命令多为客户端处理; 仅 /compact 接 session/compact RPC。
/// 命令表硬编码 (zcode 桌面端命令集, 见规格 §5.5)。
