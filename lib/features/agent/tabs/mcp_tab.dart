/// MCP Tab — 用户/工作区分组 + 运行状态 + 新建/编辑/删除/启停 + 外部导入
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../providers/app_providers.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/widgets/app_section_header.dart';
import '../../../../shared/widgets/app_tile_group.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../widgets/caps_widgets.dart';

class McpTab extends ConsumerStatefulWidget {
  const McpTab({super.key});

  @override
  ConsumerState<McpTab> createState() => McpTabState();
}

class McpTabState extends ConsumerState<McpTab>
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
    final state = ref.watch(mcpProvider);

    return CapsAsyncView(
      value: state,
      onRetry: () => ref.read(mcpProvider.notifier).load(),
      emptyIcon: Icons.dns_outlined,
      emptyTitle: '暂无 MCP 服务器',
      emptySubtitle: '点击下方添加，或从外部 Agent 导入',
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
        child: TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
          style: theme.textTheme.bodyMedium,
          cursorColor: AppColors.accent,
          decoration: InputDecoration(
            hintText: '搜索服务器…',
            prefixIcon:
                Icon(Icons.search_rounded, size: 20, color: cs.onSurfaceVariant),
            isDense: true,
            filled: true,
            fillColor: cs.surfaceContainerHigh,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide.none),
          ),
        ),
      ),
      builder: (data) {
        final q = _query.trim().toLowerCase();
        var servers = data.servers;
        if (q.isNotEmpty) {
          servers = servers
              .where((s) =>
                  s.name.toLowerCase().contains(q) ||
                  s.endpointLabel.toLowerCase().contains(q))
              .toList();
        }
        final user = servers.where((s) => s.scope != 'workspace').toList();
        final workspace = servers.where((s) => s.scope == 'workspace').toList();
        return RefreshIndicator(
          onRefresh: () => ref.read(mcpProvider.notifier).load(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
            children: [
                  if (user.isNotEmpty) ...[
                    const AppSectionHeader(title: '用户'),
                    AppTileGroup(tiles: [for (final s in user) _tile(theme, cs, s, data)]),
                  ],
                  if (workspace.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    const AppSectionHeader(title: '工作区'),
                    AppTileGroup(
                        tiles: [for (final s in workspace) _tile(theme, cs, s, data)]),
                  ],
              ],
            ),
        );
      },
    );
  }

  AppTile _tile(ThemeData theme, ColorScheme cs, McpServerEntry s, McpState data) {
    final status = data.statuses[s.name];
    String? statusLabel;
    Color? statusColor;
    if (status != null) {
      if (status.isConnected) {
        statusLabel = status.toolCount != null ? '${status.toolCount} 工具' : '已连接';
        statusColor = AppColors.success;
      } else if (status.status == 'connecting') {
        statusLabel = '连接中';
        statusColor = AppColors.warning;
      } else {
        statusLabel = '未连接';
        statusColor = cs.onSurfaceVariant;
      }
    }
    return AppTile(
      icon: s.type == McpServerType.stdio
          ? Icons.terminal_rounded
          : Icons.language_rounded,
      iconTint: s.enabled ? AppColors.accent : cs.onSurfaceVariant,
      title: s.name,
      subtitle: s.endpointLabel.isNotEmpty ? s.endpointLabel : null,
      subtitleMaxLines: 1,
      value: s.typeLabel,
      showChevron: true,
      onTap: () => _openDetail(context, s, status),
      trailing: statusLabel != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CapsBadge(statusLabel, color: statusColor),
                const SizedBox(width: AppSpacing.sm),
                CapsSwitch(value: s.enabled, onChanged: (v) => _toggle(s, v)),
              ],
            )
          : CapsSwitch(value: s.enabled, onChanged: (v) => _toggle(s, v)),
    );
  }

  Future<void> _toggle(McpServerEntry s, bool v) async {
    try {
      await ref.read(mcpProvider.notifier).setEnabled(s, v);
    } catch (e) {
      appLog.w('[McpTab] 启停失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('操作失败: $e'),
                behavior: SnackBarBehavior.floating));
      }
    }
  }

  void _openDetail(BuildContext context, McpServerEntry s, McpServerStatus? status) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    capsSheet(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(s.name,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              CapsBadge(s.scope == 'workspace' ? '工作区' : '用户'),
              const SizedBox(width: AppSpacing.sm),
              CapsBadge(s.typeLabel),
            ]),
            if (status != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(children: [
                Icon(
                  status.isConnected
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: 16,
                  color: status.isConnected
                      ? AppColors.success
                      : cs.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs + 2),
                Text(
                  status.isConnected
                      ? '已连接${status.toolCount != null ? ' · ${status.toolCount} 个工具' : ''}'
                      : '未连接',
                  style: TextStyle(
                      fontSize: AppTextSizes.bodySm, color: cs.onSurfaceVariant),
                ),
              ]),
              if (status.error != null && status.error!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(status.error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTextSizes.caption,
                          color: AppColors.danger)),
                ),
            ],
            const SizedBox(height: AppSpacing.md),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: SingleChildScrollView(
                child: Text(
                  const JsonEncoder.withIndent('  ').convert(s.rawConfig),
                  style: AppText.mono(context,
                      size: AppTextSizes.monoSm, color: cs.onSurface),
                ),
              ),
            ),
            if (s.filePath != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(s.filePath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono(context,
                      size: AppTextSizes.monoXs,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
            ],
            if (status?.authorizationUrl != null) ...[
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _openAuthorization(status!.authorizationUrl!),
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent),
                  icon: const Icon(Icons.key_rounded, size: 18),
                  label: const Text('打开授权'),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _openEditor(context, existing: s);
                  },
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('编辑'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger),
                  onPressed: () async {
                    Navigator.pop(context);
                    final ok = await capsConfirm(context,
                        title: '删除 MCP 服务器',
                        message: '确定删除「${s.name}」？');
                    if (!ok) return;
                    try {
                      await ref.read(mcpProvider.notifier).delete(s);
                    } catch (e) {
                      _snack('删除失败: $e');
                    }
                  },
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('删除'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  /// 新建服务器 (页面右上角入口)
  void openNewEditor() => _openEditor(context);

  void _openEditor(BuildContext context, {McpServerEntry? existing}) {
    capsSheet(
      context,
      child: _McpEditor(
        existing: existing,
        workspacePath: ref.read(selectedWorkspaceProvider)?.workspacePath,
        onSaved: () => ref.read(mcpProvider.notifier).load(),
      ),
    );
  }

  /// 打开 MCP OAuth 授权页 (外部浏览器); 返回 App 后下拉刷新看状态
  Future<void> _openAuthorization(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _snack('无法打开授权页: $e');
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
    }
  }
}

// ================================================================
// 编辑器
// ================================================================

class _McpEditor extends ConsumerStatefulWidget {
  final McpServerEntry? existing;
  final String? workspacePath;
  final VoidCallback? onSaved;

  const _McpEditor({this.existing, this.workspacePath, this.onSaved});

  @override
  ConsumerState<_McpEditor> createState() => _McpEditorState();
}

class _McpEditorState extends ConsumerState<_McpEditor> {
  late final TextEditingController _name;
  late final TextEditingController _command;
  late final TextEditingController _url;
  late final TextEditingController _args;
  late final TextEditingController _env;
  late final TextEditingController _headers;
  late final TextEditingController _timeout;
  final _jsonPaste = TextEditingController();

  McpServerType _type = McpServerType.stdio;
  String _scope = 'user'; // user | workspace
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _command = TextEditingController(text: e?.command ?? '');
    _url = TextEditingController(text: e?.url ?? '');
    _args = TextEditingController(text: e?.args.join('\n') ?? '');
    _env = TextEditingController(
        text: e?.env.entries.map((x) => '${x.key}=${x.value}').join('\n') ?? '');
    _headers = TextEditingController(
        text: e?.headers.entries.map((x) => '${x.key}=${x.value}').join('\n') ?? '');
    _timeout = TextEditingController(
        text: e?.timeoutMs != null ? '${e!.timeoutMs}' : '');
    if (e != null) {
      _type = e.type == McpServerType.unknown ? McpServerType.stdio : e.type;
      _scope = e.scope == 'workspace' ? 'workspace' : 'user';
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name, _command, _url, _args, _env, _headers, _timeout, _jsonPaste
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _parsePairs(String src) {
    final out = <String, String>{};
    for (final line in src.split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      final i = l.indexOf('=');
      if (i > 0) out[l.substring(0, i).trim()] = l.substring(i + 1).trim();
    }
    return out;
  }

  void _applyJson() {
    try {
      final m = jsonDecode(_jsonPaste.text.trim());
      if (m is! Map) throw '不是 JSON 对象';
      setState(() {
        final t = m['type']?.toString() ?? 'stdio';
        _type = t == 'http' || t == 'sse' || t == 'stdio'
            ? McpServerType.values.firstWhere((e) => e.name == t)
            : McpServerType.stdio;
        _command.text = m['command']?.toString() ?? '';
        _url.text = m['url']?.toString() ?? '';
        _args.text = m['args'] is List
            ? (m['args'] as List).map((e) => e.toString()).join('\n')
            : '';
        final env = m['env'];
        if (env is Map) {
          _env.text = env.entries
              .map((e) => '${e.key}=${e.value}')
              .join('\n');
        }
        final headers = m['headers'];
        if (headers is Map) {
          _headers.text = headers.entries
              .map((e) => '${e.key}=${e.value}')
              .join('\n');
        }
        if (m['timeoutMs'] != null) _timeout.text = '${m['timeoutMs']}';
      });
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('JSON 解析失败: $e'),
          behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('请填写服务器名称');
      return;
    }
    if (_type == McpServerType.stdio && _command.text.trim().isEmpty) {
      _snack('stdio 类型需要填写启动命令');
      return;
    }
    if (_type != McpServerType.stdio &&
        (_url.text.trim().isEmpty || !Uri.tryParse(_url.text.trim())!.hasScheme)) {
      _snack('请填写合法的 URL');
      return;
    }
    setState(() => _saving = true);
    final args = _args.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final entry = McpServerEntry(
      name: name,
      scope: _scope,
      type: _type,
      command: _type == McpServerType.stdio ? _command.text.trim() : null,
      url: _type != McpServerType.stdio ? _url.text.trim() : null,
      args: args,
      env: _parsePairs(_env.text),
      headers: _parsePairs(_headers.text),
      timeoutMs: int.tryParse(_timeout.text.trim()),
      enabled: widget.existing?.enabled ?? true,
      projectPath:
          _scope == 'workspace' ? widget.workspacePath : null,
    );
    try {
      await ref.read(mcpProvider.notifier).upsert(entry);
      widget.onSaved?.call();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
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
          Text(isEdit ? '编辑 MCP 服务器' : '添加 MCP 服务器',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.md),
          CapsField(controller: _name, label: '名称', hint: '如 context7'),
          const SizedBox(height: AppSpacing.md),
          // 类型 + 作用域
          Row(children: [
            Expanded(
              child: Column(
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
                      ButtonSegment(value: 'stdio', label: Text('stdio')),
                      ButtonSegment(value: 'sse', label: Text('SSE')),
                      ButtonSegment(value: 'http', label: Text('HTTP')),
                    ],
                    selected: {_type.name},
                    onSelectionChanged: (s) => setState(() => _type =
                        McpServerType.values
                            .firstWhere((e) => e.name == s.first)),
                    showSelectedIcon: false,
                  ),
                ],
              ),
            ),
          ]),
          if (!isEdit) ...[
            const SizedBox(height: AppSpacing.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('作用域',
                    style: TextStyle(
                        fontSize: AppTextSizes.label,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
                const SizedBox(height: AppSpacing.xs + 2),
                SegmentedButton<String>(
                  segments: [
                    const ButtonSegment(value: 'user', label: Text('用户')),
                    ButtonSegment(
                        value: 'workspace',
                        label: const Text('工作区'),
                        enabled: widget.workspacePath != null),
                  ],
                  selected: {_scope},
                  onSelectionChanged: (s) => setState(() => _scope = s.first),
                  showSelectedIcon: false,
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (_type == McpServerType.stdio) ...[
            CapsField(
                controller: _command,
                label: '启动命令',
                hint: '如 npx -y @upstash/context7-mcp',
                mono: true),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _args,
                label: '参数 (每行一个, 可选)',
                maxLines: 3,
                mono: true),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _env,
                label: '环境变量 KEY=value (每行一个, 可选)',
                maxLines: 3,
                mono: true),
          ] else ...[
            CapsField(controller: _url, label: 'URL', hint: 'https://…', mono: true),
            const SizedBox(height: AppSpacing.md),
            CapsField(
                controller: _headers,
                label: '请求头 KEY=value (每行一个, 可选)',
                maxLines: 3,
                mono: true),
          ],
          const SizedBox(height: AppSpacing.md),
          CapsField(
              controller: _timeout,
              label: '超时毫秒 (可选)',
              hint: '如 30000',
              keyboardType: TextInputType.number),
          const SizedBox(height: AppSpacing.md),
          // JSON 粘贴
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text('粘贴 JSON 配置 (可选)',
                style: TextStyle(
                    fontSize: AppTextSizes.bodySm,
                    color: cs.onSurfaceVariant)),
            children: [
              CapsField(
                  controller: _jsonPaste,
                  label: '配置 JSON',
                  hint: '{"type":"stdio","command":"…"}',
                  maxLines: 5,
                  mono: true),
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _applyJson,
                  child: const Text('解析并填充'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}
