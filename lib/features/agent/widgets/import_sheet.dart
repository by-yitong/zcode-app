/// 从外部 Agent 导入 (settings-sync detect/importSelected 的移动端封装)
///
/// 复刻网页端 ExternalAgentImportDialog: 扫描 → 按来源分组勾选 →
/// 选目标(全局/项目) + 方式(复制/软链) → 导入结果。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';

class ImportSheet extends ConsumerStatefulWidget {
  final String category; // skills | commands | plugins | mcpServers
  final VoidCallback? onImported;

  const ImportSheet({super.key, required this.category, this.onImported});

  @override
  ConsumerState<ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<ImportSheet> {
  final _selected = <String>{};
  String _targetScope = 'global';
  String _importMode = 'copy';
  bool _importing = false;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(importProvider.notifier).detect([widget.category]);
    });
  }

  Future<void> _runImport() async {
    if (_selected.isEmpty) return;
    setState(() => _importing = true);
    try {
      final res = await ref.read(importProvider.notifier).importSelected(
            _selected,
            targetScope: _targetScope,
            importMode: _importMode,
          );
      setState(() => _result = res);
      widget.onImported?.call();
    } catch (e) {
      appLog.w('[Import] 导入失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final agents = ref.watch(importProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.download_rounded, size: 20, color: AppColors.accent),
              const SizedBox(width: AppSpacing.sm),
              Text('导入外部 ${importCategoryLabel(widget.category)}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: () =>
                    ref.read(importProvider.notifier).detect([widget.category]),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '扫描 Claude Code、Codex CLI 等外部 Agent 中可复用的资源；只导入缺失项，不覆盖现有内容。',
            style: TextStyle(
                fontSize: AppTextSizes.bodySm, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          Flexible(
            child: agents.when(
              loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(
                      child:
                          CircularProgressIndicator(strokeWidth: 2.5))),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Center(
                  child: Text('扫描失败: $e',
                      style: TextStyle(
                          fontSize: AppTextSizes.bodySm,
                          color: AppColors.danger)),
                ),
              ),
              data: (list) {
                if (_result != null) return _buildResult(theme, cs);
                if (list.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Center(
                      child: Text(
                        '暂无可导入内容。\n可检查外部 Agent 的目录后重新扫描。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: AppTextSizes.bodySm,
                            color: cs.onSurfaceVariant),
                      ),
                    ),
                  );
                }
                return ListView(
                  shrinkWrap: true,
                  children: [
                    for (final agent in list)
                      if (agent.candidates.isNotEmpty) ...[
                        _agentHeader(theme, cs, agent),
                        for (final c in agent.candidates)
                          _candidateTile(theme, cs, c),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                  ],
                );
              },
            ),
          ),
          if (_result == null) ...[
            const Divider(height: AppSpacing.lg),
            // 导入目标 + 方式
            Row(
              children: [
                Expanded(
                  child: _seg(cs, '导入到', const {'global': '全局', 'project': '项目'},
                      _targetScope, (v) => setState(() => _targetScope = v)),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _seg(cs, '方式', const {'copy': '复制', 'symlink': '软链'},
                      _importMode, (v) => setState(() => _importMode = v)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _importing || _selected.isEmpty ? null : _runImport,
                style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                child: _importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(_selected.isEmpty
                        ? '选择要导入的项目'
                        : '导入已选 (${_selected.length})'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResult(ThemeData theme, ColorScheme cs) {
    final success = (_result?['successCount'] as num?)?.toInt() ?? 0;
    final skipped = (_result?['skippedCount'] as num?)?.toInt() ?? 0;
    final failed = (_result?['failedCount'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Column(
        children: [
          Icon(success > 0 ? Icons.check_circle_rounded : Icons.info_rounded,
              size: 44, color: success > 0 ? AppColors.success : cs.onSurfaceVariant),
          const SizedBox(height: AppSpacing.md),
          Text('导入完成',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.sm),
          Text('成功 $success · 跳过 $skipped · 失败 $failed',
              style: TextStyle(
                  fontSize: AppTextSizes.bodySm, color: cs.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context),
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _agentHeader(ThemeData theme, ColorScheme cs, ImportAgent agent) {
    final count = agent.candidates.length;
    final allSelected = agent.candidates.every((c) => _selected.contains(c.jsonKey));
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${importAgentLabel(agent.agent)} · $count 项',
              style: TextStyle(
                  fontSize: AppTextSizes.label,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() {
              if (allSelected) {
                for (final c in agent.candidates) {
                  _selected.remove(c.jsonKey);
                }
              } else {
                for (final c in agent.candidates) {
                  _selected.add(c.jsonKey);
                }
              }
            }),
            child: Text(allSelected ? '取消全选' : '全选',
                style: TextStyle(
                    fontSize: AppTextSizes.label, color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  Widget _candidateTile(ThemeData theme, ColorScheme cs, ImportCandidate c) {
    final checked = _selected.contains(c.jsonKey);
    return InkWell(
      onTap: () => setState(() {
        checked ? _selected.remove(c.jsonKey) : _selected.add(c.jsonKey);
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs + 2),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: checked,
                onChanged: (v) => setState(() {
                  v == true ? _selected.add(c.jsonKey) : _selected.remove(c.jsonKey);
                }),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                activeColor: AppColors.accent,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500)),
                  if (c.sourceScope != null || c.version != null)
                    Text(
                      [
                        if (c.sourceScope == 'project') '项目' else '全局',
                        if (c.version != null) 'v${c.version}',
                      ].join(' · '),
                      style: TextStyle(
                          fontSize: AppTextSizes.caption,
                          color: cs.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _seg(ColorScheme cs, String label, Map<String, String> options,
      String value, ValueChanged<String> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: AppTextSizes.label,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.xs + 2),
        SegmentedButton<String>(
          segments: [
            for (final e in options.entries)
              ButtonSegment(value: e.key, label: Text(e.value)),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }
}
