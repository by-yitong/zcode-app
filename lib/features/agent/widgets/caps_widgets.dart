/// Agent 能力页共享组件: 异步视图包装 / 搜索筛选栏 / 作用域徽章 / 危险确认
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/widgets/app_empty_state.dart';

/// loading / error / 空态 / 内容 四态包装
class CapsAsyncView<T> extends StatelessWidget {
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;
  final VoidCallback? onRetry;
  final Widget? header; // 列表上方的搜索/筛选栏 (仅数据态显示)

  const CapsAsyncView({
    super.key,
    required this.value,
    required this.builder,
    required this.emptyIcon,
    required this.emptyTitle,
    this.emptySubtitle,
    this.onRetry,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      error: (e, _) => AppEmptyState(
        icon: Icons.cloud_off_rounded,
        title: '加载失败',
        subtitle: _friendlyError(e),
        iconTint: AppColors.danger,
        actionLabel: onRetry != null ? '重试' : null,
        actionIcon: onRetry != null ? Icons.refresh_rounded : null,
        onAction: onRetry,
      ),
      data: (data) {
        final empty = _isEmpty(data);
        if (empty) {
          return ListView(
            children: [
              if (header != null) header!,
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: AppEmptyState(
                  icon: emptyIcon,
                  title: emptyTitle,
                  subtitle: emptySubtitle,
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            if (header != null) header!,
            Expanded(child: builder(data)),
          ],
        );
      },
    );
  }

  bool _isEmpty(T data) {
    if (data is List) return data.isEmpty;
    return false;
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('未连接') || s.contains('RelayClient')) return '未连接到 ZCode 桌面端';
    if (s.contains('未选择工作区')) return '未选择工作区';
    return s.replaceFirst(RegExp(r'^RpcException:\s*'), '');
  }
}

/// 搜索框 + 状态筛选 chips (启用/未启用)
class CapsFilterBar extends StatelessWidget {
  final TextEditingController searchController;
  final ValueChanged<String> onSearch;
  final String? filter; // null=全部 true=已启用 false=未启用
  final ValueChanged<String?> onFilter;

  const CapsFilterBar({
    super.key,
    required this.searchController,
    required this.onSearch,
    required this.filter,
    required this.onFilter,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        children: [
          TextField(
            controller: searchController,
            onChanged: onSearch,
            style: Theme.of(context).textTheme.bodyMedium,
            cursorColor: AppColors.accent,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '搜索…',
              hintStyle: TextStyle(
                  fontSize: AppTextSizes.bodySm, color: cs.onSurfaceVariant),
              prefixIcon: Icon(Icons.search_rounded,
                  size: 20, color: cs.onSurfaceVariant),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 40, minHeight: 40),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
              filled: true,
              fillColor: cs.surfaceContainerHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.5)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide:
                    BorderSide(color: AppColors.accent.withValues(alpha: 0.5)),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _chip(context, '全部', null),
                const SizedBox(width: AppSpacing.sm),
                _chip(context, '已启用', 'enabled'),
                const SizedBox(width: AppSpacing.sm),
                _chip(context, '未启用', 'disabled'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, String? value) {
    final selected = _normalize(filter) == value;
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onFilter(value == 'enabled'
          ? 'enabled'
          : value == 'disabled'
              ? 'disabled'
              : null),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: selected ? AppColors.accent : cs.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTextSizes.label,
            fontWeight: FontWeight.w500,
            color: selected ? Colors.white : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  static String? _normalize(String? f) => f;
}

/// 小徽章 (作用域/类型)
class CapsBadge extends StatelessWidget {
  final String text;
  final Color? color;

  const CapsBadge(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm + 1, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTextSizes.caption,
          fontWeight: FontWeight.w600,
          color: c,
        ),
      ),
    );
  }
}

/// 危险操作确认
Future<bool> capsConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '删除',
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// 底部弹窗外壳 (统一 dragHandle + 最大高度)
///
/// 不覆盖 backgroundColor — 主题 bottomSheetTheme 已配不透明提升面
/// (darkSurfaceElevated), 覆盖成半透明会透出页面文字。
Future<T?> capsSheet<T>(BuildContext context, {required Widget child}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85),
    builder: (_) => SafeArea(top: false, child: child),
  );
}

/// 统一开关 (M3: 强调色轨道 + 白色滑块; 旧 activeColor 会整体变纯色看不到滑块)
class CapsSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const CapsSwitch({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Switch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: AppColors.accent,
      activeThumbColor: Colors.white,
      inactiveTrackColor: cs.outlineVariant,
      inactiveThumbColor: cs.outline,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// 统一开关列表项 (同 CapsSwitch 配色)
class CapsSwitchListTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const CapsSwitchListTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title),
      subtitle: subtitle != null
          ? Text(subtitle!,
              style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  color: cs.onSurfaceVariant))
          : null,
      value: value,
      onChanged: onChanged,
      activeTrackColor: AppColors.accent,
      activeThumbColor: Colors.white,
      inactiveTrackColor: cs.outlineVariant,
      inactiveThumbColor: cs.outline,
    );
  }
}

/// 弹窗内文本字段 (统一样式)
class CapsField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final int maxLines;
  final bool mono;
  final TextInputType? keyboardType;

  const CapsField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.maxLines = 1,
    this.mono = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: AppTextSizes.label,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.xs + 2),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: mono
              ? AppText.mono(context,
                  size: AppTextSizes.monoSm, color: cs.onSurface)
              : Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: cs.onSurface),
          keyboardType: keyboardType,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
                fontSize: AppTextSizes.bodySm, color: cs.onSurfaceVariant),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
            filled: true,
            fillColor: cs.surfaceContainerHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide(color: cs.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.5)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide:
                  BorderSide(color: AppColors.accent.withValues(alpha: 0.6)),
            ),
          ),
        ),
      ],
    );
  }
}


/// 插件图标盒 — emoji / 网络图片 / 首字母兜底
class PluginIconBox extends StatelessWidget {
  final String? icon; // emoji 或 URL
  final String name;
  final double size;

  const PluginIconBox({super.key, required this.icon, required this.name, this.size = 36});

  bool get _isUrl =>
      icon != null &&
      (icon!.startsWith('http://') || icon!.startsWith('https://'));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.accentContainer,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      clipBehavior: Clip.antiAlias,
      child: Center(
        child: icon == null || icon!.isEmpty
            ? Text(
                name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
                style: TextStyle(
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                ),
              )
            : _isUrl
                ? Image.network(
                    icon!,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Text(
                      name.isNotEmpty
                          ? name.substring(0, 1).toUpperCase()
                          : '?',
                      style: TextStyle(
                        fontSize: size * 0.42,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accent,
                      ),
                    ),
                  )
                : Text(
                    icon!,
                    style: TextStyle(fontSize: size * 0.5),
                  ),
      ),
    );
  }
}
