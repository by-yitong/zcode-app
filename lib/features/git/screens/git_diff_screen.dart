// lib/features/git/screens/git_diff_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/relay/git_api.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/git_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../widgets/git_diff_view.dart';

/// 丢弃确认弹窗 (GitScreen 行内菜单与 GitDiffScreen 操作条共用):
/// 文案必含 '不可恢复'; 确认后调 [GitController.discard]。
Future<void> confirmDiscard(
  BuildContext context, {
  required GitChange change,
  required GitController controller,
  required bool staged,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('丢弃更改'),
      content: Text(
        '将丢弃 ${change.workspaceRelativePath} 的'
        '${staged ? '已暂存' : '未暂存'}更改, 此操作不可恢复。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('丢弃'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await controller.discard([change.path], staged: staged);
  }
}

/// diff 详情页: 行级着色 patch + 底部 暂存/取消暂存/丢弃 操作条。
///
/// sourceId 取 [change.section] (unstaged/staged); untracked/conflicted 无
/// diff 内容, 由 GitScreen 侧 onTap 传 null 拦截, 不进本页。
class GitDiffScreen extends ConsumerStatefulWidget {
  final GitRef gitRef;
  final GitChange change;

  const GitDiffScreen({
    super.key,
    required this.gitRef,
    required this.change,
  });

  @override
  ConsumerState<GitDiffScreen> createState() => _GitDiffScreenState();
}

class _GitDiffScreenState extends ConsumerState<GitDiffScreen> {
  late Future<GitDiff> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<GitDiff> _load() {
    final relay = ref.read(relayClientProvider);
    if (relay == null) {
      return Future.error(StateError('RelayClient not available'));
    }
    return GitApi(relay.rpcCallMap).getDiff(
      widget.gitRef.workspacePath,
      widget.change.path,
      widget.change.section,
    );
  }

  @override
  Widget build(BuildContext context) {
    final change = widget.change;
    final state = ref.watch(gitProvider(widget.gitRef));
    final controller = ref.read(gitProvider(widget.gitRef).notifier);
    final busy = state.busyOps.any(
      (k) =>
          k == 'stage:${change.path}' ||
          k == 'unstage:${change.path}' ||
          k == 'discard:${change.path}',
    );
    final fileName = change.workspaceRelativePath.split('/').last;

    return Scaffold(
      appBar: AppBar(title: Text(fileName)),
      body: FutureBuilder<GitDiff>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('加载失败'),
                  TextButton(
                    onPressed: () => setState(() => _future = _load()),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          final patch = snap.data?.patch;
          if (patch == null || patch.isEmpty) {
            return const Center(child: Text('无差异'));
          }
          return buildDiffView(patch);
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              if (change.section != 'staged')
                FilledButton.tonal(
                  onPressed: busy ? null : () => controller.stage([change.path]),
                  child: const Text('暂存'),
                )
              else
                FilledButton.tonal(
                  onPressed:
                      busy ? null : () => controller.unstage([change.path]),
                  child: const Text('取消暂存'),
                ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                onPressed: busy
                    ? null
                    : () => confirmDiscard(
                          context,
                          change: change,
                          controller: controller,
                          staged: change.section == 'staged',
                        ),
                child: const Text('丢弃'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
