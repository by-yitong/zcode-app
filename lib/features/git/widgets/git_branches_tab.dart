// lib/features/git/widgets/git_branches_tab.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/relay/git_api.dart';
import '../../../providers/git_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../agent/widgets/caps_widgets.dart';

/// 分支 Tab (Task 5): 首次可见懒加载 [GitController.loadBranches];
/// 行 = 名称 + upstreamName 副标题 + 当前行勾标/高亮 (accent);
/// 点非当前分支弹确认后 [GitController.switchTo]; 列表尾「新建分支」
/// add 行弹输入对话框 (名称必填 + 可选起点折叠展开) 走
/// [GitController.createAndSwitch]; detached 时顶部琥珀色提示条。
///
/// 当前行以 summary.branchName 推导 (refresh 刻意保留旧 branches 列表,
/// isCurrent 会过期; summary 是头部卡片同一事实源)。
class GitBranchesTab extends ConsumerStatefulWidget {
  final GitRef gitRef;

  const GitBranchesTab({super.key, required this.gitRef});

  @override
  ConsumerState<GitBranchesTab> createState() => _GitBranchesTabState();
}

class _GitBranchesTabState extends ConsumerState<GitBranchesTab> {
  @override
  void initState() {
    super.initState();
    // Tab 首次构建时懒加载; microtask 避免在 build 期间改 provider 状态。
    // loadBranches 幂等 (branches 非空即跳过), 重复构建无副作用。
    Future.microtask(() {
      if (mounted) {
        ref.read(gitProvider(widget.gitRef).notifier).loadBranches();
      }
    });
  }

  Future<void> _confirmSwitch(String name) {
    final controller = ref.read(gitProvider(widget.gitRef).notifier);
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('切换分支'),
        content: Text('切换到 $name?未提交的更改会保留在工作区。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              controller.switchTo(name);
            },
            child: const Text('切换'),
          ),
        ],
      ),
    );
  }

  Future<void> _newBranch() {
    final controller = ref.read(gitProvider(widget.gitRef).notifier);
    return showDialog<void>(
      context: context,
      builder: (_) => _NewBranchDialog(controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(gitProvider(widget.gitRef));
    final summary = state.summary;
    final branches = state.branches;
    // 当前行 = summary 指向的分支 (detached 时无当前分支, 仅提示条)。
    final currentName =
        (summary != null && !summary.isDetached) ? summary.branchName : null;

    return Column(
      children: [
        if (summary != null && summary.isDetached) const _DetachedBanner(),
        Expanded(child: _body(context, theme, branches, state, currentName)),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    ThemeData theme,
    List<GitBranchInfo>? branches,
    GitState state,
    String? currentName,
  ) {
    if (branches == null) {
      // 懒加载中; 失败 (busy 已清且仍为 null) 给重试入口。
      if (state.busyOps.contains('branches')) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '分支列表加载失败',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () =>
                  ref.read(gitProvider(widget.gitRef).notifier).loadBranches(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (branches.isEmpty) {
      // 空列表也保留 add 行 (包圆角卡; 替代原孤儿条与居中空态文案)。
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          0,
        ),
        child: CapsCard(
          child: _AddBranchTile(
            onTap: state.busyOps.contains('create') ? null : _newBranch,
          ),
        ),
      );
    }
    final busy = state.busyOps.contains('switch') ||
        state.busyOps.contains('create');
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xl,
      ),
      children: [
        CapsCard(
          child: Column(
            children: [
              for (final b in branches)
                _BranchTile(
                  info: b,
                  current: b.name == currentName,
                  busy: busy,
                  onSwitch: () => _confirmSwitch(b.name),
                ),
              _AddBranchTile(onTap: busy ? null : _newBranch),
            ],
          ),
        ),
      ],
    );
  }
}

/// 列表尾「新建分支」add 行 (accent 色; 替代原顶部右对齐孤儿按钮条)。
class _AddBranchTile extends StatelessWidget {
  final VoidCallback? onTap;

  const _AddBranchTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            const Icon(Icons.add_rounded, size: 18, color: AppColors.accent),
            const SizedBox(width: AppSpacing.sm),
            Text(
              '新建分支',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分支行: 名称 (mono) + upstreamName 副标题 + 当前行勾标与「当前」标签。
class _BranchTile extends StatelessWidget {
  final GitBranchInfo info;
  final bool current;
  final bool busy;
  final VoidCallback onSwitch;

  const _BranchTile({
    required this.info,
    required this.current,
    required this.busy,
    required this.onSwitch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: current ? AppColors.accentContainer : Colors.transparent,
      child: ListTile(
        dense: true,
        onTap: current || busy ? null : onSwitch,
        leading: SizedBox(
          width: 24,
          child: current
              ? const Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: AppColors.accent,
                )
              : null,
        ),
        title: Text(
          info.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.mono(
            context,
            size: AppTextSizes.bodySm,
            weight: current ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        subtitle: info.upstreamName == null
            ? null
            : Text(
                info.upstreamName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono(
                  context,
                  size: AppTextSizes.monoXs,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
        trailing: current ? const _CurrentPill() : null,
      ),
    );
  }
}

/// 「当前」小标签 (accent 底)。
class _CurrentPill extends StatelessWidget {
  const _CurrentPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.accentContainer,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        '当前',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// detached HEAD 琥珀提示条 (AppColors.warning = #F59E0B)。
class _DetachedBanner extends StatelessWidget {
  const _DetachedBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.warning,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: Colors.black87,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'HEAD 处于分离状态 (detached), 点击下方分支即可切换',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.black87,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 新建分支对话框: 名称必填; 「指定起点 (可选)」默认折叠, 点开输入。
/// 确认后 [GitController.createAndSwitch] (起点为空串按 null 发)。
class _NewBranchDialog extends StatefulWidget {
  final GitController controller;

  const _NewBranchDialog({required this.controller});

  @override
  State<_NewBranchDialog> createState() => _NewBranchDialogState();
}

class _NewBranchDialogState extends State<_NewBranchDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _start = TextEditingController();
  bool _showStart = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() {
      if (mounted) setState(() {}); // 驱动「创建」可用态
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _start.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final start = _start.text.trim();
    Navigator.of(context).pop();
    widget.controller.createAndSwitch(name, start.isEmpty ? null : start);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建分支'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CapsField(
            controller: _name,
            label: '分支名称',
            hint: '如 feat/new-thing',
            mono: true,
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
          if (!_showStart)
            TextButton.icon(
              onPressed: () => setState(() => _showStart = true),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('指定起点 (可选)'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: CapsField(
                controller: _start,
                label: '起点 (可选)',
                hint: '分支名 / tag / commit hash',
                mono: true,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty ? null : _submit,
          child: const Text('创建'),
        ),
      ],
    );
  }
}
