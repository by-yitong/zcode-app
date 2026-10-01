/// 插件分组全量列表页 — 市场页分组标题 (组内 > 3 个) 点入
///
/// 复用市场页同款行 (PluginListTile) 与详情 sheet (PluginDetailSheet)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../models/capability_models.dart';
import '../providers/agent_caps_providers.dart';
import '../widgets/caps_page_chrome.dart';
import '../widgets/caps_widgets.dart';
import '../widgets/plugin_list_tile.dart';
import 'plugins_browser_page.dart';

class PluginGroupPage extends ConsumerWidget {
  final String title;
  final List<PluginEntry> plugins;
  final Set<String> installedNames;

  const PluginGroupPage({
    super.key,
    required this.title,
    required this.plugins,
    required this.installedNames,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: CapsPageHeader.overlayStyle(context),
      child: Scaffold(
        appBar: CapsPageHeader(title: title),
        body: plugins.isEmpty
            ? const AppEmptyState(icon: Icons.extension_outlined, title: '暂无插件')
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.xxl,
                ),
                itemCount: plugins.length,
                itemBuilder: (context, i) {
                  final p = plugins[i];
                  return PluginListTile(
                    plugin: p,
                    installedNames: installedNames,
                    onTap: () => _openDetail(context, p),
                    onInstall: (p) => _install(context, ref, p),
                  );
                },
              ),
      ),
    );
  }

  void _openDetail(BuildContext context, PluginEntry p) {
    capsSheet(context, child: PluginDetailSheet(plugin: p));
  }

  Future<void> _install(
    BuildContext context,
    WidgetRef ref,
    PluginEntry p,
  ) async {
    try {
      await ref.read(pluginsProvider.notifier).install(p);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已安装 ${p.label}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      appLog.w('[PluginGroup] 安装失败: $e');
      if (context.mounted) {
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
