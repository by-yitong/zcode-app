import 'package:flutter/material.dart';

import '../../../providers/chat_provider.dart';
import 'chat_helpers.dart';
import '../../../shared/theme/app_design_tokens.dart';

class ErrorBanner extends StatelessWidget {
  final String message;
  final ThemeData theme;
  final VoidCallback? onRetry;

  const ErrorBanner({
    required this.message,
    required this.theme,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.errorContainer,
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: theme.colorScheme.onErrorContainer,
                fontSize: AppTextSizes.bodySm,
              ),
            ),
          ),
          if (onRetry != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: GestureDetector(
                onTap: onRetry,
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.refresh_rounded,
                      size: 14,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '重试',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: AppTextSizes.label,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Todo 计划列表 (来自 runtime.plan[])
///
/// AI 用 TodoWrite 工具产出的任务清单, 实时反映执行进度
/// (pending → in_progress → completed)。默认折叠只显示进度摘要,
/// 展开后列出每项 + 状态图标。
class PlanList extends StatefulWidget {
  final List<PlanItem> plan;
  final ThemeData theme;
  final bool isResponding;

  const PlanList({
    required this.plan,
    required this.theme,
    required this.isResponding,
  });

  @override
  State<PlanList> createState() => PlanListState();
}

class PlanListState extends State<PlanList>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  /// 当前进行的任务文字 (inProgress 优先, 否则最近 pending, 否则全部完成)
  String _currentTaskText(List<PlanItem> plan) {
    final inProgress = plan.firstWhere(
      (p) => p.status == TodoStatus.inProgress,
      orElse: () => plan.firstWhere(
        (p) => p.status == TodoStatus.pending,
        orElse: () => plan.last,
      ),
    );
    return inProgress.title;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final plan = widget.plan;
    if (plan.isEmpty) return const SizedBox.shrink();

    final completed = plan
        .where((p) => p.status == TodoStatus.completed)
        .length;
    final total = plan.length;
    final isDark = theme.brightness == Brightness.dark;
    // ★ 浮动面板必须完全不透明, 否会透出底层消息文字
    final cardBg = isDark ? AppColors.darkBg : AppColors.lightSurface;
    // 有进行中的项, 或 AI 正在工作 → 视为"活跃"
    final isActive =
        widget.isResponding ||
        plan.any((p) => p.status == TodoStatus.inProgress);

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        0,
      ),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: isActive
              ? AppColors.accent.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      constraints: const BoxConstraints(maxHeight: 240),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部: 小圆圈进度 + 当前任务 + 折叠箭头 (单行)
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: 5,
              ),
              child: Row(
                children: [
                  // 小圆圈进度条
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            value: total == 0 ? 0 : completed / total,
                            strokeWidth: 4,
                            backgroundColor: theme.colorScheme.outlineVariant
                                .withValues(alpha: 0.4),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isActive ? AppColors.accent : AppColors.success,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$completed/$total',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 收起时: 当前任务文字 (单行省略)
                  Expanded(
                    child: Text(
                      _currentTaskText(plan),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTextSizes.caption,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开后: 任务列表 (可滚动, 防止过长)
          Flexible(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: _expanded
                  ? ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(
                        bottom: AppSpacing.sm,
                        left: AppSpacing.sm,
                        right: AppSpacing.sm,
                      ),
                      itemCount: plan.length,
                      itemBuilder: (ctx, i) =>
                          PlanRow(item: plan[i], theme: theme),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 计划单行 (状态图标 + 标题)
class PlanRow extends StatelessWidget {
  final PlanItem item;
  final ThemeData theme;

  const PlanRow({required this.item, required this.theme});

  @override
  Widget build(BuildContext context) {
    final (icon, color, deco) = switch (item.status) {
      TodoStatus.completed => (
        Icons.check_circle_rounded,
        AppColors.success,
        TextDecoration.lineThrough,
      ),
      TodoStatus.inProgress => (
        Icons.radio_button_checked,
        AppColors.accent,
        TextDecoration.none,
      ),
      TodoStatus.pending => (
        Icons.radio_button_unchecked,
        theme.colorScheme.onSurfaceVariant,
        TextDecoration.none,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              item.title,
              style: TextStyle(
                fontSize: AppTextSizes.label,
                height: 1.35,
                color: item.status == TodoStatus.completed
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
                decoration: deco,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 内联审批卡 — permission.requested 时插在聊天列表尾部
///
/// ★ wire 实测 (host bundle 2026-06-19, 规格 §11.2):
/// permission.requested 事件含 options[], 每个 option 自带 optionId+name+decision。
/// 用户选哪个 option, 就回传那个 optionId + decision。
/// (ExitPlanMode/switch_mode 不走此卡 — 按钮内嵌在 plan 卡片里)

class ScrollToBottomButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool hasNewContent;

  const ScrollToBottomButton({
    required this.onPressed,
    this.hasNewContent = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onPressed,
      // opaque: 整个 40x40 圆钮都可命中 — deferToChild 下只有中间
      // 24x24 图标区能接住点击, 点边缘环会穿透到下面的消息列表
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: hasNewContent
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hasNewContent
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: hasNewContent ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 24,
              color: hasNewContent
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            if (hasNewContent)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.surfaceContainerHigh,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Token 用量徽章 (compact, 等宽, 状态行副标题用)。
/// 格式: ↑1.2k ↓3.4k — ↑=输入(prompt), ↓=输出(completion)。
/// 数字: <1000 原值; >=1000 用 1.2k (>=100k 去小数, >=1M 用 M)。

class CompactMarkerPill extends StatelessWidget {
  final String label;
  final bool running;

  const CompactMarkerPill({required this.label, this.running = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                Icon(
                  Icons.compress_outlined,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 日期分组标签 (居中药丸形)
class DateSeparator extends StatelessWidget {
  final DateTime date;
  const DateSeparator({required this.date});

  String _format(DateTime d) {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    if (isSameDay(d, now)) return '今天';
    if (isSameDay(d, yesterday)) return '昨天';
    return '${d.month}月${d.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            _format(date),
            style: TextStyle(
              fontSize: AppTextSizes.caption,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 消息头像 (AI: 渐变圆 + spark; 用户: 蓝色圆 + person)
class Avatar extends StatelessWidget {
  final String role; // 'user' | 'assistant'
  final ThemeData theme;

  const Avatar({required this.role, required this.theme});

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: isUser
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.accent, const Color(0xFF8B5CF6)],
              ),
        color: isUser ? AppColors.accent : null,
      ),
      child: Icon(
        isUser ? Icons.person_rounded : Icons.auto_awesome,
        size: 15,
        color: Colors.white,
      ),
    );
  }
}

/// 消息气泡
///
/// 用户: 强调色填充, 右对齐
/// AI: 透明面 + 左侧强调竖条 (开发者工具气质, 非圆胖聊天气泡)
/// 消息反馈类型 (赞/踩)
/// Markdown 文本按表格分段
