/// 命令 Tab — 本地/插件分组 + 新建/编辑/删除 + 外部导入
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/widgets/app_section_header.dart';
import '../../../../shared/widgets/app_tile_group.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../widgets/caps_widgets.dart';
import '../widgets/import_sheet.dart';

class CommandsTab extends ConsumerStatefulWidget {
  const CommandsTab({super.key});

  @override
  ConsumerState<CommandsTab> createState() => CommandsTabState();
}

class CommandsTabState extends ConsumerState<CommandsTab>
    with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final commands = ref.watch(commandsProvider);

    return CapsAsyncView(
      value: commands,
      onRetry: () => ref.read(commandsProvider.notifier).load(),
      emptyIcon: Icons.terminal_rounded,
      emptyTitle: '暂无命令',
      emptySubtitle: '斜杠命令可在对话中快速调用',
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
        child: TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
          style: theme.textTheme.bodyMedium,
          cursorColor: AppColors.accent,
          decoration: InputDecoration(
            hintText: '搜索命令…',
            prefixIcon: Icon(Icons.search_rounded,
                size: 20, color: cs.onSurfaceVariant),
            isDense: true,
            filled: true,
            fillColor: cs.surfaceContainerHigh,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide.none),
          ),
        ),
      ),
      builder: (list) {
        final q = _query.trim().toLowerCase();
        var filtered = q.isEmpty
            ? list
            : list
                .where((c) =>
                    c.name.toLowerCase().contains(q) ||
                    c.description.toLowerCase().contains(q))
                .toList();
        final local = filtered.where((c) => !c.isPlugin).toList();
        final plugin = filtered.where((c) => c.isPlugin).toList();
        return RefreshIndicator(
          onRefresh: () => ref.read(commandsProvider.notifier).load(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
            children: [
                  if (local.isNotEmpty) ...[
                    AppSectionHeader(
                      title: '本地命令',
                      action: TextButton.icon(
                        onPressed: () => capsSheet(context,
                            child: ImportSheet(
                                category: 'commands',
                                onImported: () => ref
                                    .read(commandsProvider.notifier)
                                    .load())),
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: const Text('导入'),
                        style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact),
                      ),
                    ),
                    AppTileGroup(
                        tiles: [for (final c in local) _tile(theme, cs, c)]),
                  ],
                  if (plugin.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    const AppSectionHeader(title: '插件提供'),
                    AppTileGroup(
                        tiles: [for (final c in plugin) _tile(theme, cs, c)]),
                  ],
              ],
            ),
        );
      },
    );
  }

  AppTile _tile(ThemeData theme, ColorScheme cs, CommandEntry c) {
    return AppTile(
      icon: Icons.terminal_rounded,
      iconTint: AppColors.accent,
      title: c.name.startsWith('/') ? c.name : '/${c.name}',
      subtitle: c.description.isNotEmpty ? c.description : null,
      subtitleMaxLines: 2,
      value: c.isPlugin ? '插件' : '本地',
      showChevron: true,
      onTap: () => _openEditor(context, existing: c),
    );
  }

  /// 新建命令 (页面右上角入口)
  void openNewEditor() => _openEditor(context);

  void _openEditor(BuildContext context, {CommandEntry? existing}) {
    capsSheet(
      context,
      child: _CommandEditor(
        existing: existing,
        onSaved: () => ref.read(commandsProvider.notifier).load(),
      ),
    );
  }
}

class _CommandEditor extends ConsumerStatefulWidget {
  final CommandEntry? existing;
  final VoidCallback? onSaved;
  const _CommandEditor({this.existing, this.onSaved});

  @override
  ConsumerState<_CommandEditor> createState() => _CommandEditorState();
}

class _CommandEditorState extends ConsumerState<_CommandEditor> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _hint;
  late final TextEditingController _prompt;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    var name = c?.name ?? '';
    if (name.startsWith('/')) name = name.substring(1);
    _name = TextEditingController(text: name);
    _desc = TextEditingController(text: c?.description ?? '');
    _hint = TextEditingController(text: c?.argumentHint ?? '');
    _prompt = TextEditingController(text: c?.content ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _desc, _hint, _prompt]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim().replaceAll(RegExp(r'^/+'), '');
    if (name.isEmpty || !RegExp(r'^[a-zA-Z0-9/_-]+$').hasMatch(name)) {
      _snack('名称无效 (字母/数字/连字符/斜杠)');
      return;
    }
    if (_prompt.text.trim().isEmpty) {
      _snack('请填写命令内容 (Prompt 模板)');
      return;
    }
    setState(() => _saving = true);
    final config = <String, dynamic>{
      'name': name,
      if (_desc.text.trim().isNotEmpty) 'description': _desc.text.trim(),
      if (_hint.text.trim().isNotEmpty) 'argumentHint': _hint.text.trim(),
      'prompt': _prompt.text,
    };
    try {
      final n = ref.read(commandsProvider.notifier);
      if (widget.existing == null) {
        await n.create(config);
      } else {
        await n.update(widget.existing!, config);
      }
      widget.onSaved?.call();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      appLog.w('[CommandsTab] 保存失败: $e');
      _snack('保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await capsConfirm(context,
        title: '删除命令',
        message: '确定删除「/${widget.existing!.name}」？');
    if (!ok) return;
    try {
      await ref.read(commandsProvider.notifier).delete(widget.existing!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('删除失败: $e');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isEdit = widget.existing != null;
    final isPlugin = widget.existing?.isPlugin ?? false;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(isEdit ? '编辑命令' : '新建命令',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (isPlugin) const CapsBadge('插件 · 只读'),
          ]),
          const SizedBox(height: AppSpacing.md),
          CapsField(
              controller: _name,
              label: '名称',
              hint: '如 commit (输入 /commit 调用)'),
          const SizedBox(height: AppSpacing.md),
          CapsField(controller: _desc, label: '描述 (可选)'),
          const SizedBox(height: AppSpacing.md),
          CapsField(controller: _hint, label: '参数提示 (可选)', hint: '如 [消息]'),
          const SizedBox(height: AppSpacing.md),
          CapsField(
              controller: _prompt,
              label: '命令内容 (Prompt 模板)',
              hint: r'发送给 AI 的提示词, 可用 $1 $2 引用参数',
              maxLines: 8,
              mono: true),
          if (widget.existing?.filePath != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(widget.existing!.filePath!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono(context,
                    size: AppTextSizes.monoXs,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(children: [
            if (isEdit && !isPlugin)
              Expanded(
                child: OutlinedButton.icon(
                  style:
                      OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('删除'),
                ),
              ),
            if (isEdit && !isPlugin) const SizedBox(width: AppSpacing.md),
            if (!isPlugin)
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.accent),
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('保存'),
                ),
              ),
          ]),
        ],
      ),
    );
  }
}
