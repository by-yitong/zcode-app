/// 插件列表行 — 市场页 / 分组页 / 搜索页共用
///
/// 行尾: 已安装 = successContainer 圆形对勾 (纯展示);
/// 未安装 = accentContainer 圆形 + 号, 点击触发 [onInstall] 直装。
library;

import 'package:flutter/material.dart';

import '../../../shared/theme/app_design_tokens.dart';
import '../models/capability_models.dart';
import 'caps_page_chrome.dart';
import 'caps_widgets.dart';

class PluginListTile extends StatelessWidget {
  final PluginEntry plugin;

  /// 已装判定集合 (marketplace/name), 行外传入避免行内查 provider
  final Set<String> installedNames;

  final VoidCallback? onTap;

  /// 未安装时 + 号点击回调
  final ValueChanged<PluginEntry>? onInstall;

  const PluginListTile({
    super.key,
    required this.plugin,
    required this.installedNames,
    this.onTap,
    this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    final p = plugin;
    final installed =
        p.installed || installedNames.contains('${p.marketplace}/${p.name}');
    return CapsPlainTile(
      leading: PluginIconBox(icon: p.icon, name: p.label, size: 44),
      title: p.label,
      subtitle: p.description.isNotEmpty ? p.description : null,
      trailing: installed ? _installedBadge() : _installButton(),
      onTap: onTap,
    );
  }

  /// 已装: 28px successContainer 圆形对勾
  Widget _installedBadge() {
    return Container(
      width: 28,
      height: 28,
      decoration: const BoxDecoration(
        color: AppColors.successContainer,
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.check_rounded,
        size: 16,
        color: AppColors.success,
      ),
    );
  }

  /// 未装: 28px accentContainer 圆形 + 号直装
  Widget _installButton() {
    return GestureDetector(
      onTap: onInstall == null ? null : () => onInstall!(plugin),
      child: Container(
        width: 28,
        height: 28,
        decoration: const BoxDecoration(
          color: AppColors.accentContainer,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.add_rounded, size: 18, color: AppColors.accent),
      ),
    );
  }
}
