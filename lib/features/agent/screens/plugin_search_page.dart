/// 插件搜索页 — 实时过滤 available (label/description, 不区分大小写)
///
/// 底部固定搜索条 (对齐市场页 pill 样式); available 为空时 catalog 兜底。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../widgets/caps_page_chrome.dart';
import '../widgets/caps_widgets.dart';
import '../widgets/plugin_list_tile.dart';
import 'plugins_browser_page.dart';

class PluginSearchPage extends ConsumerStatefulWidget {
  const PluginSearchPage({super.key});

  @override
  ConsumerState<PluginSearchPage> createState() => _PluginSearchPageState();
}

class _PluginSearchPageState extends ConsumerState<PluginSearchPage> {
  String _query = '';
  bool _fallbackLoaded = false;
  List<PluginEntry>? _catalogFallback;

  /// available 为空时用 catalog 兜底 (与市场页同逻辑, provider 不动)
  Future<void> _ensureFallback() async {
    if (_fallbackLoaded) return;
    final st = ref.read(pluginsProvider).valueOrNull;
    if (st != null && st.available.isNotEmpty) return;
    _fallbackLoaded = true;
    try {
      final client = ref.read(relayClientProvider);
      final ws = ref.read(selectedWorkspaceProvider);
      if (client == null || ws == null) return;
      final resp = await client.getPluginReferenceCatalog(
        workspacePath: ws.workspacePath,
        workspaceIdentity: ws.workspaceIdentity,
      );
      final raw = resp['plugins'];
      if (raw is List && raw.isNotEmpty && mounted) {
        setState(() {
          _catalogFallback = raw
              .whereType<Map>()
              .map((m) => PluginEntry.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        });
      }
    } catch (e) {
      appLog.i('[PluginSearch] catalog 兜底失败(忽略): $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pluginsAsync = ref.watch(pluginsProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: CapsPageHeader.overlayStyle(context),
      child: Scaffold(
        appBar: const CapsPageHeader(title: '搜索插件'),
        body: Column(
          children: [
            Expanded(
              child: _query.trim().isEmpty
                  ? _idleHint(theme)
                  : _results(pluginsAsync, theme),
            ),
            // 底部固定搜索条 (胶囊 pill + 关闭)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        autofocus: true,
                        onChanged: (v) => setState(() => _query = v),
                        style: theme.textTheme.bodyMedium,
                        cursorColor: AppColors.accent,
                        decoration: InputDecoration(
                          hintText: '搜索插件…',
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: cs.onSurfaceVariant,
                          ),
                          isDense: true,
                          filled: true,
                          fillColor: cs.surfaceContainerHigh,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _closeButton(cs),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// query 为空的居中提示
  Widget _idleHint(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_rounded,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            '搜索插件',
            style: TextStyle(
              fontSize: AppTextSizes.titleSm,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: AppSpacing.xs + 2),
          Text(
            '输入名称或功能关键词',
            style: TextStyle(
              fontSize: AppTextSizes.bodySm,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 过滤结果 (available 为空走 catalog 兜底)
  Widget _results(AsyncValue<PluginsState> pluginsAsync, ThemeData theme) {
    return pluginsAsync.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      error: (e, _) => AppEmptyState(
        icon: Icons.cloud_off_rounded,
        title: '加载失败',
        subtitle: e.toString(),
        iconTint: AppColors.danger,
        actionLabel: '重试',
        onAction: () => ref.read(pluginsProvider.notifier).load(),
      ),
      data: (state) {
        var available = state.available;
        if (available.isEmpty && _catalogFallback != null) {
          available = _catalogFallback!;
        } else if (available.isEmpty && !_fallbackLoaded) {
          _ensureFallback();
        }
        final q = _query.trim().toLowerCase();
        final list = available
            .where(
              (p) =>
                  p.label.toLowerCase().contains(q) ||
                  p.description.toLowerCase().contains(q),
            )
            .toList();
        if (list.isEmpty) {
          return const Center(
            child: Text(
              '没有匹配的插件',
              style: TextStyle(fontSize: AppTextSizes.bodySm),
            ),
          );
        }
        final installedNames = state.installed
            .map((p) => '${p.marketplace}/${p.name}')
            .toSet();
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          children: [
            for (final p in list)
              PluginListTile(
                plugin: p,
                installedNames: installedNames,
                onTap: () => _openDetail(p),
                onInstall: _install,
              ),
          ],
        );
      },
    );
  }

  /// 胶囊关闭按钮 (高 44 圆角 22)
  Widget _closeButton(ColorScheme cs) {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.close_rounded, size: 18, color: cs.onSurface),
            const SizedBox(width: AppSpacing.xs),
            Text(
              '关闭',
              style: TextStyle(
                fontSize: AppTextSizes.bodyMd,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(PluginEntry p) {
    capsSheet(context, child: PluginDetailSheet(plugin: p));
  }

  Future<void> _install(PluginEntry p) async {
    try {
      await ref.read(pluginsProvider.notifier).install(p);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已安装 ${p.label}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      appLog.w('[PluginSearch] 安装失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('安装失败: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}
