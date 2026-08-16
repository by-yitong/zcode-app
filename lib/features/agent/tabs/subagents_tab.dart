/// 子智能体 Tab — 内置/个人/插件分组 + 编辑器 (模型/思考级别/提示词/工具)
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../providers/app_providers.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/widgets/app_section_header.dart';
import '../../../../shared/widgets/app_tile_group.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../widgets/caps_widgets.dart';

class SubagentsTab extends ConsumerStatefulWidget {
  const SubagentsTab({super.key});

  @override
  ConsumerState<SubagentsTab> createState() => SubagentsTabState();
}

class SubagentsTabState extends ConsumerState<SubagentsTab>
    with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  String _query = '';
  String? _filter;

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
    final agents = ref.watch(subagentsProvider);

    return CapsAsyncView(
      value: agents,
      onRetry: () => ref.read(subagentsProvider.notifier).load(),
      emptyIcon: Icons.smart_toy_outlined,
      emptyTitle: '暂无子智能体',
      emptySubtitle: '点击下方新建，或从外部 Agent 导入',
      header: CapsFilterBar(
        searchController: _search,
        onSearch: (v) => setState(() => _query = v),
        filter: _filter,
        onFilter: (v) => setState(() => _filter = v),
      ),
      builder: (list) {
        final q = _query.trim().toLowerCase();
        var filtered = list;
        if (q.isNotEmpty) {
          filtered = filtered
              .where((a) =>
                  a.name.toLowerCase().contains(q) ||
                  a.description.toLowerCase().contains(q))
              .toList();
        }
        if (_filter == 'enabled') {
          filtered = filtered.where((a) => a.enabled).toList();
        } else if (_filter == 'disabled') {
          filtered = filtered.where((a) => !a.enabled).toList();
        }
        final builtIn =
            filtered.where((a) => a.isBuiltIn && !a.isPlugin).toList();
        final user = filtered
            .where((a) => !a.isBuiltIn && !a.isPlugin)
            .toList();
        final plugin = filtered.where((a) => a.isPlugin).toList();
        return RefreshIndicator(
          onRefresh: () => ref.read(subagentsProvider.notifier).load(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
            children: [
                  if (user.isNotEmpty) ...[
                    const AppSectionHeader(title: '个人与工作区'),
                    AppTileGroup(tiles: [
                      for (final a in user) _agentTile(theme, cs, a),
                    ]),
                  ],
                  if (builtIn.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    const AppSectionHeader(title: '内置'),
                    AppTileGroup(tiles: [
                      for (final a in builtIn) _agentTile(theme, cs, a),
                    ]),
                  ],
                  if (plugin.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    const AppSectionHeader(title: '插件提供'),
                    AppTileGroup(tiles: [
                      for (final a in plugin) _agentTile(theme, cs, a),
                    ]),
                ],
              ],
            ),
        );
      },
    );
  }

  AppTile _agentTile(ThemeData theme, ColorScheme cs, SubagentEntry a) {
    return AppTile(
      icon: Icons.smart_toy_outlined,
      iconTint: _agentColor(a.color) ?? (a.enabled ? AppColors.accent : cs.onSurfaceVariant),
      title: a.name,
      subtitle: a.description.isNotEmpty
          ? a.description
          : (a.systemPrompt.isNotEmpty ? a.systemPrompt : null),
      subtitleMaxLines: 2,
      value: a.tools.contains('*') || a.tools.isEmpty
          ? a.modelLabel
          : '${a.modelLabel} · ${a.tools.length} 工具',
      showChevron: true,
      onTap: () => _openEditor(context, agent: a),
    );
  }

  void _openEditor(BuildContext context, {SubagentEntry? agent, bool isNew = false}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SubagentEditorPage(agent: agent, isNew: isNew),
    ));
  }

  /// 新建子智能体 (页面右上角入口)
  void openNewEditor() => _openEditor(context, isNew: true);
}

/// zcode agent 颜色名 → Material 色
Color? _agentColor(String? name) => switch (name) {
      'blue' => const Color(0xFF3B82F6),
      'green' => const Color(0xFF22C55E),
      'purple' => const Color(0xFF8B5CF6),
      'orange' => const Color(0xFFF97316),
      'red' => const Color(0xFFEF4444),
      'pink' => const Color(0xFFEC4899),
      'cyan' => const Color(0xFF06B6D4),
      'yellow' => const Color(0xFFEAB308),
      _ => null,
    };

const kAgentColors = <String>[
  'blue', 'green', 'purple', 'orange', 'red', 'pink', 'cyan', 'yellow',
];

// ================================================================
// 编辑器页
// ================================================================

class SubagentEditorPage extends ConsumerStatefulWidget {
  final SubagentEntry? agent; // null = 新建
  final bool isNew;
  const SubagentEditorPage({super.key, this.agent, this.isNew = false});

  @override
  ConsumerState<SubagentEditorPage> createState() =>
      _SubagentEditorPageState();
}

class _SubagentEditorPageState extends ConsumerState<SubagentEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _prompt;
  late final TextEditingController _tools;
  late final TextEditingController _disallowed;
  late final TextEditingController _mcp;
  late final TextEditingController _skillsList;
  late final TextEditingController _maxTurns;

  String? _modelOverride; // null=继承; custom:pid:mid
  String? _thoughtLevel; // null=继承
  String _color = 'blue';
  String? _permissionMode;
  bool _saving = false;

  bool get _isBuiltIn => widget.agent?.isBuiltIn ?? false;

  @override
  void initState() {
    super.initState();
    final a = widget.agent;
    _name = TextEditingController(text: a?.name ?? '');
    _desc = TextEditingController(text: a?.description ?? '');
    _prompt = TextEditingController(text: a?.systemPrompt ?? '');
    _tools = TextEditingController(
        text: a != null && a.tools.isNotEmpty && !a.tools.contains('*')
            ? a.tools.join(', ')
            : '');
    _disallowed =
        TextEditingController(text: a?.disallowedTools.join(', ') ?? '');
    _mcp = TextEditingController(text: a?.mcpServers.join(', ') ?? '');
    _skillsList = TextEditingController(text: a?.skills.join(', ') ?? '');
    _maxTurns = TextEditingController(
        text: a?.maxTurns != null ? '${a!.maxTurns}' : '');
    _modelOverride = a?.model;
    _thoughtLevel = a?.thoughtLevel;
    _color = a?.color ?? 'blue';
    _permissionMode = a?.permissionMode;
  }

  @override
  void dispose() {
    for (final c in [
      _name, _desc, _prompt, _tools, _disallowed, _mcp, _skillsList, _maxTurns
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_isBuiltIn) {
      // 内置: 只保存模型/思考级别覆盖
      setState(() => _saving = true);
      try {
        await ref.read(subagentsProvider.notifier).setBuiltInOverride(
              widget.agent!.name,
              _modelOverride,
              _thoughtLevel,
            );
        if (mounted) Navigator.pop(context);
      } catch (e) {
        _err('保存失败', e);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }

    final name = _name.text.trim();
    if (name.length < 3 || name.length > 50 ||
        !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(name)) {
      _err('名称无效', '名称需 3-50 个字符, 仅字母/数字/连字符');
      return;
    }
    if (_desc.text.trim().isEmpty) {
      _err('描述无效', '请填写描述 (会在 @ 提及列表中展示)');
      return;
    }
    setState(() => _saving = true);
    final config = <String, dynamic>{
      'name': name,
      'description': _desc.text.trim(),
      'systemPrompt': _prompt.text,
      'color': _color,
      if (_modelOverride != null && _modelOverride!.isNotEmpty)
        'model': _modelOverride,
      if (_thoughtLevel != null && _thoughtLevel!.isNotEmpty)
        'thoughtLevel': _thoughtLevel,
      'tools': _tools.text.trim().isEmpty ? ['*'] : _splitList(_tools.text),
      if (_disallowed.text.trim().isNotEmpty)
        'disallowedTools': _splitList(_disallowed.text),
      if (_skillsList.text.trim().isNotEmpty)
        'skills': _splitList(_skillsList.text),
      if (_permissionMode != null) 'permissionMode': _permissionMode,
      if (int.tryParse(_maxTurns.text.trim()) case final mt?)
        'maxTurns': mt,
      if (_mcp.text.trim().isNotEmpty) 'mcpServers': _splitList(_mcp.text),
    };
    try {
      final n = ref.read(subagentsProvider.notifier);
      if (widget.isNew) {
        await n.create(config);
      } else {
        await n.update(widget.agent!, config);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _err('保存失败', e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<String> _splitList(String src) => src
      .split(RegExp(r'[,，\n]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  void _err(String title, Object e) {
    appLog.w('[SubagentEditor] $title: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$title: $e'),
          behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final a = widget.agent;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew
            ? '新建子智能体'
            : (_isBuiltIn ? '内置子智能体' : '编辑子智能体')),
        actions: [
          if (!widget.isNew && !_isBuiltIn && a != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              onPressed: () => _delete(a),
            ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (_isBuiltIn) ...[
            _infoCard(theme, cs, a!),
            const SizedBox(height: AppSpacing.md),
          ] else ...[
            CapsField(controller: _name, label: '名称', hint: 'my-agent (3-50 字符, 字母/数字/连字符)'),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _desc,
                label: '描述',
                hint: '在 @ 提及列表中展示',
                maxLines: 2),
            const SizedBox(height: AppSpacing.md),
            _colorPicker(theme, cs),
            const SizedBox(height: AppSpacing.md),
          ],
          _modelPicker(theme, cs),
          const SizedBox(height: AppSpacing.md),
          _thoughtPicker(theme, cs),
          if (!_isBuiltIn) ...[
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _prompt,
                label: '系统提示词',
                hint: '定义该子智能体的行为…',
                maxLines: 6),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _tools,
                label: '可用工具 (留空 = 继承全部)',
                hint: 'Bash, Read, Grep…'),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                for (final t in [
                  'Bash', 'Read', 'Edit', 'Write', 'Glob', 'Grep',
                  'WebFetch', 'WebSearch', 'TodoWrite'
                ])
                  ActionChip(
                    label: Text(t, style: const TextStyle(fontSize: AppTextSizes.caption)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      final cur = _splitList(_tools.text);
                      if (!cur.contains(t)) {
                        cur.add(t);
                        _tools.text = cur.join(', ');
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _disallowed,
                label: '禁用工具 (可选)',
                hint: '逗号分隔'),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _mcp,
                label: 'MCP 服务器 (可选)',
                hint: '逗号分隔 server 名'),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _skillsList,
                label: '绑定技能 (可选)',
                hint: '逗号分隔技能名'),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _maxTurns,
                label: '最大轮次 (可选)',
                hint: '如 20',
                keyboardType: TextInputType.number),
            const SizedBox(height: AppSpacing.md),
            _permPicker(theme, cs),
          ],
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }

  Widget _infoCard(ThemeData theme, ColorScheme cs, SubagentEntry a) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            CapsBadge('内置 · 只读'),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
                child: Text(a.description,
                    style: TextStyle(
                        fontSize: AppTextSizes.bodySm,
                        color: cs.onSurfaceVariant))),
          ]),
          if (a.path != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(a.path!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono(context,
                    size: AppTextSizes.monoXs,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
          ],
        ],
      ),
    );
  }

  Widget _colorPicker(ThemeData theme, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('颜色',
            style: TextStyle(
                fontSize: AppTextSizes.label,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final c in kAgentColors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 36,
                    height: 36,
                    margin: const EdgeInsets.only(right: AppSpacing.sm),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _agentColor(c),
                      border: _color == c
                          ? Border.all(color: cs.onSurface, width: 2.5)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _modelPicker(ThemeData theme, ColorScheme cs) {
    final modelsAsync = ref.watch(modelListProvider);
    final models = modelsAsync.valueOrNull?.models ?? const <String>[];
    final providerNames =
        modelsAsync.valueOrNull?.providerNames ?? const <String, String>{};
    final current = _modelOverride;

    String labelOf(String id) {
      final short = id.contains('/') ? id.substring(id.indexOf('/') + 1) : id;
      final pid = id.contains('/') ? id.substring(0, id.indexOf('/')) : '';
      final pname = providerNames[pid];
      return pname != null && pname.isNotEmpty ? '$short · $pname' : short;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_isBuiltIn ? '模型覆盖' : '模型',
            style: TextStyle(
                fontSize: AppTextSizes.label,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.xs + 2),
        InkWell(
          onTap: () => _pickModelSheet(models, labelOf),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    current == null || current.isEmpty
                        ? '继承主会话模型'
                        : _overrideLabel(current),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (current != null && current.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() => _modelOverride = null),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: cs.onSurfaceVariant),
                  )
                else
                  Icon(Icons.chevron_right_rounded,
                      size: 20,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// custom:builtin:zai:GLM-5-Turbo → GLM-5-Turbo (用于显示)
  String _overrideLabel(String override) {
    var s = override;
    if (s.startsWith('custom:')) s = s.substring(7);
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {}
    final idx = s.lastIndexOf(':');
    return idx >= 0 && idx < s.length - 1 ? s.substring(idx + 1) : s;
  }

  bool _overrideMatches(String modelId) =>
      _modelOverride == 'custom:${modelId.replaceAll('/', ':')}';

  Future<void> _pickModelSheet(List<String> models, String Function(String) labelOf) {
    final cs = Theme.of(context).colorScheme;
    return capsSheet(
      context,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
        children: [
          Text('选择模型',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.sm),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('继承主会话模型'),
            trailing: _modelOverride == null
                ? Icon(Icons.check_rounded, size: 20, color: AppColors.accent)
                : null,
            onTap: () {
              setState(() => _modelOverride = null);
              Navigator.pop(context);
            },
          ),
          for (final id in models)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(labelOf(id)),
              subtitle: Text(id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono(context,
                      size: AppTextSizes.monoXs,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
              trailing: _overrideMatches(id)
                  ? Icon(Icons.check_rounded, size: 20, color: AppColors.accent)
                  : null,
              onTap: () {
                setState(() => _modelOverride = 'custom:${id.replaceAll('/', ':')}');
                Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }

  Widget _thoughtPicker(ThemeData theme, ColorScheme cs) {
    const options = {
      null: '继承',
      'max': '深度思考',
      'medium': '中等思考',
      'nothink': '不思考',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('思考级别',
            style: TextStyle(
                fontSize: AppTextSizes.label,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.xs + 2),
        SegmentedButton<String>(
          segments: [
            for (final e in options.entries)
              ButtonSegment(value: e.key ?? '', label: Text(e.value)),
          ],
          selected: {_thoughtLevel ?? ''},
          onSelectionChanged: (s) =>
              setState(() => _thoughtLevel = s.first.isEmpty ? null : s.first),
          showSelectedIcon: false,
        ),
      ],
    );
  }

  Widget _permPicker(ThemeData theme, ColorScheme cs) {
    const options = {
      null: '默认',
      'default': '标准',
      'acceptEdits': '接受编辑',
      'plan': '计划',
      'bypassPermissions': '全部权限',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('权限模式',
            style: TextStyle(
                fontSize: AppTextSizes.label,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.xs + 2),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            for (final e in options.entries)
              ChoiceChip(
                label: Text(e.value,
                    style: const TextStyle(fontSize: AppTextSizes.label)),
                selected: (_permissionMode ?? '') == (e.key ?? ''),
                onSelected: (_) =>
                    setState(() => _permissionMode = e.key),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _delete(SubagentEntry a) async {
    final ok = await capsConfirm(context,
        title: '删除子智能体',
        message: '确定删除「${a.name}」？将移除对应的 agent 文件，且无法撤销。');
    if (!ok) return;
    try {
      await ref.read(subagentsProvider.notifier).delete(a);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _err('删除失败', e);
    }
  }
}
