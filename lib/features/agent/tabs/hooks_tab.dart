/// 钩子 Tab — 按来源分组 + 编辑器 (zcode 配置可写, 兼容/插件只读)
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

class HooksTab extends ConsumerStatefulWidget {
  const HooksTab({super.key});

  @override
  ConsumerState<HooksTab> createState() => HooksTabState();
}

class HooksTabState extends ConsumerState<HooksTab>
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
    final hooks = ref.watch(hooksProvider);

    return CapsAsyncView(
      value: hooks,
      onRetry: () => ref.read(hooksProvider.notifier).load(),
      emptyIcon: Icons.webhook_outlined,
      emptyTitle: '暂无钩子',
      emptySubtitle: '钩子可在工具调用等事件时执行自定义命令',
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
        child: TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
          style: theme.textTheme.bodyMedium,
          cursorColor: AppColors.accent,
          decoration: InputDecoration(
            hintText: '搜索事件/命令…',
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
                .where((h) =>
                    h.event.toLowerCase().contains(q) ||
                    h.command.toLowerCase().contains(q))
                .toList();
        final editable =
            filtered.where((h) => h.locationSource == 'zcode').toList();
        final compat = filtered
            .where((h) => h.locationSource != 'zcode' && h.locationSource != 'plugin')
            .toList();
        final plugins =
            filtered.where((h) => h.locationSource == 'plugin').toList();
        return RefreshIndicator(
          onRefresh: () => ref.read(hooksProvider.notifier).load(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
            children: [
              if (editable.isNotEmpty) ...[
                const AppSectionHeader(title: '已配置'),
                AppTileGroup(tiles: [for (final h in editable) _tile(theme, cs, h)]),
              ],
              if (compat.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                const AppSectionHeader(title: '兼容配置 (只读)'),
                AppTileGroup(tiles: [for (final h in compat) _tile(theme, cs, h)]),
              ],
              if (plugins.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                const AppSectionHeader(title: '插件提供 (只读)'),
                AppTileGroup(tiles: [for (final h in plugins) _tile(theme, cs, h)]),
              ],
            ],
          ),
        );
      },
    );
  }

  AppTile _tile(ThemeData theme, ColorScheme cs, HookEntry h) {
    return AppTile(
      icon: Icons.webhook_outlined,
      iconTint: h.enabled ? AppColors.accent : cs.onSurfaceVariant,
      title: h.event,
      subtitle: h.matcher != null && h.matcher!.isNotEmpty
          ? '${h.matcher} · ${h.command}'
          : h.command,
      subtitleMaxLines: 1,
      value: h.type == 'process' ? '进程' : '命令',
      showChevron: true,
      onTap: () => _openEditor(context, existing: h),
    );
  }

  void _openEditor(BuildContext context, {HookEntry? existing}) {
    capsSheet(
      context,
      child: _HookEditor(existing: existing),
    );
  }

  /// 新建钩子 (页面右上角入口)
  void openNewEditor() => _openEditor(context);
}

// ================================================================
// 编辑器
// ================================================================

class _HookEditor extends ConsumerStatefulWidget {
  final HookEntry? existing;
  const _HookEditor({this.existing});

  @override
  ConsumerState<_HookEditor> createState() => _HookEditorState();
}

class _HookEditorState extends ConsumerState<_HookEditor> {
  late final TextEditingController _matcher;
  late final TextEditingController _command;
  late final TextEditingController _args;
  late final TextEditingController _shell;
  late final TextEditingController _statusMessage;
  late final TextEditingController _timeout;

  late String _event;
  late String _type; // command | process
  late bool _async;
  late bool _enabled;
  bool _saving = false;

  bool get _isReadOnly =>
      widget.existing != null && widget.existing!.locationSource != 'zcode';

  @override
  void initState() {
    super.initState();
    final h = widget.existing;
    _matcher = TextEditingController(text: h?.matcher ?? '');
    _command = TextEditingController(text: h?.command ?? '');
    _args =
        TextEditingController(text: h?.args.join(' ') ?? '');
    _shell = TextEditingController(text: h?.shell ?? '');
    _statusMessage = TextEditingController(text: h?.statusMessage ?? '');
    _timeout = TextEditingController(
        text: h?.timeout != null ? '${h!.timeout}' : '');
    _event = h?.event ?? 'PreToolUse';
    _type = h?.type ?? 'command';
    _async = h?.runAsync ?? false;
    _enabled = h?.enabled ?? true;
  }

  @override
  void dispose() {
    for (final c in [
      _matcher, _command, _args, _shell, _statusMessage, _timeout
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_command.text.trim().isEmpty) {
      _snack('请填写命令');
      return;
    }
    setState(() => _saving = true);
    final h = HookEntry(
      id: widget.existing?.id ??
          'hook-zcode-user-${DateTime.now().millisecondsSinceEpoch}',
      event: _event,
      matcher: _matcher.text.trim().isEmpty ? null : _matcher.text.trim(),
      type: _type,
      command: _command.text.trim(),
      args: _type == 'process'
          ? _args.text
              .split(RegExp(r'[\s\n]+'))
              .where((s) => s.isNotEmpty)
              .toList()
          : const [],
      runAsync: _async,
      shell: _shell.text.trim().isEmpty ? null : _shell.text.trim(),
      statusMessage:
          _statusMessage.text.trim().isEmpty ? null : _statusMessage.text.trim(),
      timeout: int.tryParse(_timeout.text.trim()),
      enabled: _enabled,
      locationSource: 'zcode',
      locationScope: widget.existing?.locationScope ?? 'user',
    );
    try {
      await ref
          .read(hooksProvider.notifier)
          .upsert(h, oldId: widget.existing?.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('保存失败: $e');
      appLog.w('[HooksTab] 保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final h = widget.existing!;
    final ok = await capsConfirm(context,
        title: '删除钩子', message: '确定删除「${h.event}」上的这条钩子？');
    if (!ok) return;
    try {
      await ref.read(hooksProvider.notifier).delete(h);
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(isEdit ? '编辑钩子' : '新建钩子',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (_isReadOnly) const CapsBadge('只读'),
          ]),
          const SizedBox(height: AppSpacing.md),
          // 事件选择
          Text('事件',
              style: TextStyle(
                  fontSize: AppTextSizes.label,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.xs + 2),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              for (final e in kHookEvents)
                ChoiceChip(
                  label: Text(e, style: const TextStyle(fontSize: AppTextSizes.label)),
                  selected: _event == e,
                  onSelected: _isReadOnly
                      ? null
                      : (_) => setState(() => _event = e),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          CapsField(
              controller: _matcher,
              label: '匹配器 (可选)',
              hint: '如 Bash | 正则',
              mono: true),
          const SizedBox(height: AppSpacing.md),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('类型',
                  style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant)),
              const SizedBox(height: AppSpacing.xs + 2),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'command', label: Text('Shell 命令')),
                  ButtonSegment(value: 'process', label: Text('进程')),
                ],
                selected: {_type},
                onSelectionChanged: _isReadOnly
                    ? null
                    : (s) => setState(() => _type = s.first),
                showSelectedIcon: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          CapsField(
              controller: _command,
              label: _type == 'process' ? '可执行文件' : '命令',
              hint: _type == 'process' ? '如 /usr/bin/script.sh' : '如 ./check.sh',
              mono: true),
          if (_type == 'process') ...[
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _args,
                label: '参数 (空格分隔)',
                mono: true),
          ],
          const SizedBox(height: AppSpacing.md),
          CapsField(
              controller: _timeout,
              label: '超时秒 (可选)',
              hint: '如 60',
              keyboardType: TextInputType.number),
          const SizedBox(height: AppSpacing.md),
          CapsField(
              controller: _statusMessage,
              label: '运行提示 (可选)',
              hint: '执行中显示的文字'),
          const SizedBox(height: AppSpacing.sm),
          CapsSwitchListTile(
            title: '异步执行',
            subtitle: '不阻塞当前操作',
            value: _async,
            onChanged: _isReadOnly ? null : (v) => setState(() => _async = v),
          ),
          CapsSwitchListTile(
            title: '启用',
            value: _enabled,
            onChanged: _isReadOnly ? null : (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(children: [
            if (isEdit && !_isReadOnly)
              Expanded(
                child: OutlinedButton.icon(
                  style:
                      OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('删除'),
                ),
              ),
            if (isEdit && !_isReadOnly) const SizedBox(width: AppSpacing.md),
            if (!_isReadOnly)
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
