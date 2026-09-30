import 'package:flutter/material.dart';

import '../../../core/relay/relay_events.dart';
import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import 'thought_block.dart';

/// 输入框顶部"后台运行"胶囊 — 运行中子智能体 + 后台终端计数。
/// 悬浮居中不占满宽, 点击弹清单面板 (showRunningWorksSheet);
/// 呼吸点示意"正在跑", 入场淡入+上浮。调用方保证 totalCount > 0。
class RunningWorkBar extends StatelessWidget {
  final int subagentCount;
  final int bashCount;
  final VoidCallback onTap;

  const RunningWorkBar({
    super.key,
    required this.subagentCount,
    required this.bashCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = theme.colorScheme.onSurfaceVariant;
    final textStyle = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurface,
    );
    final both = subagentCount > 0 && bashCount > 0;

    // 入场: 轻微缩放 + 上浮淡入 (一次性, 出现即提示"后台有活动")
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - t)),
          child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
        ),
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: Semantics(
          button: true,
          label: '查看后台运行任务',
          child: Material(
            color: Color.alphaBlend(
              theme.colorScheme.surfaceContainerHigh,
              theme.colorScheme.surfaceContainerLowest,
            ),
            elevation: 3,
            shadowColor: Colors.black.withValues(alpha: 0.25),
            shape: const StadiumBorder(),
            child: InkWell(
              onTap: onTap,
              customBorder: const StadiumBorder(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _BreathDot(),
                    const SizedBox(width: AppSpacing.sm),
                    if (subagentCount > 0) ...[
                      Icon(Icons.account_tree_outlined,
                          size: 15, color: iconColor),
                      const SizedBox(width: 4),
                      Text('$subagentCount 个智能体', style: textStyle),
                    ],
                    if (both)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm - 2,
                        ),
                        child: Text(
                          '·',
                          style: textStyle?.copyWith(color: iconColor),
                        ),
                      ),
                    if (bashCount > 0) ...[
                      Icon(Icons.terminal_outlined, size: 15, color: iconColor),
                      const SizedBox(width: 4),
                      Text('$bashCount 个终端', style: textStyle),
                    ],
                    const SizedBox(width: 2),
                    Icon(
                      Icons.keyboard_double_arrow_down_rounded,
                      size: 16,
                      color: iconColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 呼吸点 — 胶囊左侧 6px 圆点, 缩放+透明度循环呼吸, 示意"正在进行"。
/// 用 warning 琥珀色 (与清单面板 RunningDot 同族, 区别于静态状态点)。
class _BreathDot extends StatefulWidget {
  const _BreathDot();

  @override
  State<_BreathDot> createState() => _BreathDotState();
}

class _BreathDotState extends State<_BreathDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // 呼吸曲线: 0→1→0 平滑往返
        final t = (Curves.easeInOut.transform(_controller.value) * 2 - 1).abs();
        return Opacity(
          opacity: 0.45 + 0.55 * (1 - t),
          child: Transform.scale(scale: 0.75 + 0.45 * (1 - t), child: child),
        );
      },
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: AppColors.warning,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 后台运行清单底部面板 — 运行中的子智能体 (点击进详情弹窗)
/// + 后台终端 (取消按钮)。
/// 打开时传入当时的快照即可 (面板短生命周期, 不订阅后续更新)。
Future<void> showRunningWorksSheet(
  BuildContext context, {
  required List<SubagentPart> subagents,
  required List<V4BackgroundWork> bashWorks,
  required ThemeData theme,
  required void Function(SubagentPart part) onOpenSubagent,
  required void Function(V4BackgroundWork work) onCancelBash,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _RunningWorksSheet(
      subagents: subagents,
      bashWorks: bashWorks,
      theme: theme,
      onOpenSubagent: onOpenSubagent,
      onCancelBash: onCancelBash,
    ),
  );
}

class _RunningWorksSheet extends StatelessWidget {
  final List<SubagentPart> subagents;
  final List<V4BackgroundWork> bashWorks;
  final ThemeData theme;
  final void Function(SubagentPart part) onOpenSubagent;
  final void Function(V4BackgroundWork work) onCancelBash;

  const _RunningWorksSheet({
    required this.subagents,
    required this.bashWorks,
    required this.theme,
    required this.onOpenSubagent,
    required this.onCancelBash,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // 内容超高时封顶 0.7, 内部滚动 (question_sheet 同款)
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      decoration: BoxDecoration(
        // 与全 app 底部弹层一致的不透明提升面 (execution_trace 同款)
        color: Color.alphaBlend(
          theme.colorScheme.surfaceContainerHigh,
          theme.colorScheme.surfaceContainerLowest,
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // drag handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题行: 后台运行 + 关闭
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '后台运行',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            // 清单 (超高内部滚动)
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: subagents.isEmpty && bashWorks.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xl,
                        ),
                        child: Center(
                          child: Text(
                            '没有正在运行的后台任务',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (subagents.isNotEmpty) ...[
                            _sectionLabel('运行中的子智能体'),
                            for (final s in subagents) _subagentRow(context, s),
                          ],
                          if (bashWorks.isNotEmpty) ...[
                            if (subagents.isNotEmpty)
                              const SizedBox(height: AppSpacing.md),
                            _sectionLabel('后台终端'),
                            for (final w in bashWorks) _bashRow(w),
                          ],
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String s) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text(
          s,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  /// 子代理行: 类型 + 摘要一行截断 + 运行点, 点击进详情弹窗
  Widget _subagentRow(BuildContext context, SubagentPart s) {
    return InkWell(
      onTap: () => onOpenSubagent(s),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: AppSpacing.sm + 2,
        ),
        child: Row(
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: s.subagentType.isEmpty ? '子智能体' : s.subagentType,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (s.summaryText.isNotEmpty) ...[
                      TextSpan(
                        text: '  ',
                        style: theme.textTheme.bodyMedium,
                      ),
                      TextSpan(
                        text: s.summaryText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            const RunningDot(size: 6),
          ],
        ),
      ),
    );
  }

  /// 后台终端行: 命令 (mono 一行截断, 空 title 回退 workId 前 8 位) + 取消
  Widget _bashRow(V4BackgroundWork w) {
    final title =
        w.title.isNotEmpty ? w.title : w.workId.length > 8 ? w.workId.substring(0, 8) : w.workId;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          Icon(
            Icons.terminal_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTextSizes.label,
                fontFamily: kMonoFont,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          OutlinedButton(
            onPressed: () => onCancelBash(w),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.danger,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
