import 'package:flutter/material.dart';

// hide QuestionOption (chat_provider 的数据类): 本文件的 QuestionOption
// 指 approval_cards 里的选项行 widget, 同名模型类经推断使用不受影响
import '../../../providers/chat_provider.dart' hide QuestionOption;
import '../../../shared/theme/app_design_tokens.dart';
import 'approval_cards.dart' show QuestionOption;

/// AI 提问答题底部弹窗 (AskUserQuestion)
///
/// 对齐网页端交互: 全部题在弹窗内逐题作答 (单选/多选 + 自定义文本),
/// 最后一次性提交 (resolveInteraction), 或整体忽略 (decline)。
/// 返回 sheet 的关闭 Future (调用方据此复位"弹窗已开"标志)。
Future<void> showQuestionSheet(
  BuildContext context, {
  required AskUserQuestion question,
  required ThemeData theme,
  required void Function({
    bool decline,
    Map<int, List<String>> selectedValues,
    Map<int, String> customAnswers,
  }) onAnswer,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _QuestionSheet(
      question: question,
      theme: theme,
      onAnswer: onAnswer,
    ),
  );
}

class _QuestionSheet extends StatefulWidget {
  final AskUserQuestion question;
  final ThemeData theme;
  final void Function({
    bool decline,
    Map<int, List<String>> selectedValues,
    Map<int, String> customAnswers,
  }) onAnswer;

  const _QuestionSheet({
    required this.question,
    required this.theme,
    required this.onAnswer,
  });

  @override
  State<_QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends State<_QuestionSheet> {
  /// 每题选中的选项 value 集合 (按题下标; 提交时按选项顺序重排)
  final Map<int, Set<String>> _selected = {};
  /// 每题自定义回答输入框
  late final List<TextEditingController> _customControllers;

  @override
  void initState() {
    super.initState();
    _customControllers = List.generate(
      widget.question.questions.length,
      (_) => TextEditingController(),
    );
  }

  @override
  void dispose() {
    for (final c in _customControllers) {
      c.dispose();
    }
    super.dispose();
  }

  bool _canSubmit() {
    for (var i = 0; i < widget.question.questions.length; i++) {
      if ((_selected[i]?.isNotEmpty ?? false) ||
          _customControllers[i].text.trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  void _submit() {
    final questions = widget.question.questions;
    final selectedValues = <int, List<String>>{};
    for (var i = 0; i < questions.length; i++) {
      final sel = _selected[i];
      if (sel == null || sel.isEmpty) continue;
      // 按选项在题内的原始顺序输出 (与网页端遍历选项一致)
      final ordered = questions[i].options
          .where((o) => sel.contains(o.value))
          .map((o) => o.value)
          .toList();
      if (ordered.isNotEmpty) selectedValues[i] = ordered;
    }
    final customAnswers = <int, String>{};
    for (var i = 0; i < _customControllers.length; i++) {
      final text = _customControllers[i].text;
      if (text.trim().isNotEmpty) customAnswers[i] = text;
    }
    widget.onAnswer(
      decline: false,
      selectedValues: selectedValues,
      customAnswers: customAnswers,
    );
    Navigator.of(context).pop();
  }

  void _decline() {
    widget.onAnswer(
      decline: true,
      selectedValues: const {},
      customAnswers: const {},
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final questions = widget.question.questions;
    final header = questions.first.header;

    return Container(
      // 内容超高时封顶, 内部滚动 (普通固定高度 sheet)
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
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
            // 标题行
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  const Icon(
                    Icons.help_outline,
                    size: 18,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      header.isNotEmpty ? header : 'AI 有个问题',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 题目列表 (超高内部滚动)
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < questions.length; i++)
                      _buildQuestion(i, questions[i], theme),
                  ],
                ),
              ),
            ),
            // 底部按钮行
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _decline,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: const Text('忽略'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _canSubmit() ? _submit : null,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('提交回答'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(44),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestion(int index, QuestionItem q, ThemeData theme) {
    final sel = _selected.putIfAbsent(index, () => <String>{});
    return Padding(
      padding: EdgeInsets.only(
        bottom: index == widget.question.questions.length - 1
            ? 0
            : AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第 x / N 题小标签
          Text(
            '第 ${index + 1} / ${widget.question.questions.length} 题',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          // 问题文本
          Text(
            q.question,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: AppSpacing.md),
          // 选项列表 (单选 radio / multiSelect 多选)
          for (final opt in q.options)
            QuestionOption(
              label: opt.label,
              description: opt.description,
              selected: sel.contains(opt.value),
              onTap: () {
                setState(() {
                  if (q.multiSelect) {
                    if (sel.contains(opt.value)) {
                      sel.remove(opt.value);
                    } else {
                      sel.add(opt.value);
                    }
                  } else {
                    sel
                      ..clear()
                      ..add(opt.value);
                  }
                });
              },
            ),
          const SizedBox(height: AppSpacing.sm),
          // 自定义回答
          TextField(
            controller: _customControllers[index],
            maxLines: 1,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '输入你的回答…',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm + 2,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.3),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.3),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: const BorderSide(
                  color: AppColors.accent,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
