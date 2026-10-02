// lib/features/git/widgets/commit_sheet.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/git_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';

/// 提交底部弹窗 (Task 4): 变更文件勾选 (默认全选) + 仅提交已暂存开关 +
/// 提交信息 (AI 生成) + 提交后推送 + 「提交」。
///
/// 提交调 [GitController.commitAndMaybePush] 后关弹窗; 失败不抛出, error 由
/// controller 状态经 GitScreen 的 listener 弹 SnackBar。
Future<void> showCommitSheet(
  BuildContext context,
  WidgetRef ref,
  GitRef gitRef,
) {
  // ref 参数按任务卡签名保留 (冻结); 弹窗体为独立 Consumer, 自取 ref watch 状态。
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CommitSheetBody(gitRef: gitRef),
  );
}

class _CommitSheetBody extends ConsumerStatefulWidget {
  final GitRef gitRef;

  const _CommitSheetBody({required this.gitRef});

  @override
  ConsumerState<_CommitSheetBody> createState() => _CommitSheetBodyState();
}

class _CommitSheetBodyState extends ConsumerState<_CommitSheetBody> {
  final TextEditingController _msg = TextEditingController();
  Set<String> _selected = {};
  bool _selectionInitialized = false;
  bool _stagedOnly = false;
  bool _pushAfter = false;

  @override
  void initState() {
    super.initState();
    _msg.addListener(() {
      if (mounted) setState(() {}); // 驱动「提交」按钮可用态
    });
  }

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final controller = ref.read(gitProvider(widget.gitRef).notifier);
    try {
      final message = await controller.generateMessage();
      if (!mounted) return;
      _msg.text = message;
    } catch (e) {
      if (!mounted) return;
      // generateMessage 失败原样抛给调用方: 这里兜底弹提示。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI 生成提交信息失败: $e')),
      );
    }
  }

  Future<void> _submit() async {
    final controller = ref.read(gitProvider(widget.gitRef).notifier);
    final navigator = Navigator.of(context);
    await controller.commitAndMaybePush(
      message: _msg.text.trim(),
      paths: _stagedOnly ? null : _selected.toList(),
      stagedOnly: _stagedOnly,
      pushAfter: _pushAfter,
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(gitProvider(widget.gitRef));
    final changes = [...state.unstaged, ...state.staged];

    // 列表首次就绪时默认全选 (只初始化一次, 之后用户勾选状态不被重置)。
    if (!_selectionInitialized && changes.isNotEmpty) {
      _selected = {for (final c in changes) c.path};
      _selectionInitialized = true;
    }

    final aiBusy = state.busyOps.contains('ai');
    final commitBusy = state.busyOps.contains('commit');
    final canCommit = _msg.text.trim().isNotEmpty && !commitBusy;

    return Padding(
      // 键盘避让: viewInsets 本身就是 EdgeInsets, 直接作为 padding。
      padding: MediaQuery.viewInsetsOf(context),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '提交更改 (${changes.length})',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (changes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: Text(
                  '没有可提交的更改',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final c in changes)
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selected.contains(c.path),
                  onChanged: _stagedOnly
                      ? null
                      : (v) {
                          // v 在嵌套闭包里被赋值无法提升, 先在闭包外定死。
                          final checked = v ?? false;
                          setState(() {
                            if (checked) {
                              _selected.add(c.path);
                            } else {
                              _selected.remove(c.path);
                            }
                          });
                        },
                  title: Text(
                    c.workspaceRelativePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(context, size: AppTextSizes.bodySm),
                  ),
                ),
            SwitchListTile(
              dense: true,
              title: const Text('仅提交已暂存'),
              value: _stagedOnly,
              onChanged: (v) => setState(() => _stagedOnly = v),
            ),
            TextField(
              controller: _msg,
              minLines: 1,
              maxLines: 3,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: '提交信息',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'AI 生成',
                  onPressed: aiBusy ? null : _generate,
                  icon: aiBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 20),
                ),
              ),
            ),
            // detached HEAD 时服务端 push 必拒 (GitSummary.isDetached),
            // 隐藏推送入口 (非禁用, detached 下无意义);
            // summary 未就绪 (null) 时保持显示, 提交时由服务端兜底。
            if (state.summary?.isDetached != true)
              Row(
                children: [
                  Checkbox(
                    value: _pushAfter,
                    onChanged: (v) =>
                        setState(() => _pushAfter = v ?? false),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _pushAfter = !_pushAfter),
                    child: const Text('提交后推送'),
                  ),
                ],
              ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              onPressed: canCommit ? _submit : null,
              child: const Text('提交'),
            ),
          ],
        ),
      ),
    );
  }
}
