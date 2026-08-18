import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/glm_quota.dart' as glm;
import '../../../shared/theme/app_design_tokens.dart';

/// 用量详情底部弹窗 — 顶栏 UsagePill 点击进入
///
/// 三个区块:
/// 1. 本会话 Token: 上下文占用进度条 + 累计输出
/// 2. GLM Coding Plan: 5 小时 / 每周窗口配额 (进度条 + 重置时间)
/// 3. MCP 月度用量: 已用/总量 + 各 MCP 次数明细
///
/// 底部提供刷新入口 (回调到 glmQuotaProvider.refresh)。
class UsageDetailSheet extends StatelessWidget {
  final ({int input, int output, int max})? tokenUsage;
  final AsyncValue<glm.GlmQuota?> quotaAsync;
  final VoidCallback? onRefresh;

  const UsageDetailSheet({
    this.tokenUsage,
    required this.quotaAsync,
    this.onRefresh,
  });

  static Future<void> show(
    BuildContext context, {
    ({int input, int output, int max})? tokenUsage,
    required AsyncValue<glm.GlmQuota?> quotaAsync,
    VoidCallback? onRefresh,
  }) {
    final theme = Theme.of(context);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) => UsageDetailSheet(
        tokenUsage: tokenUsage,
        quotaAsync: quotaAsync,
        onRefresh: onRefresh,
      ),
    );
  }

  // ── 格式化 helpers ──────────────────────────────────────────

  /// 紧凑数字: 999 → 999, 1234 → 1.2k, 1234567 → 1.2M
  static String _fmt(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final k = n / 1000;
      return k >= 100 ? '${k.toStringAsFixed(0)}k' : '${k.toStringAsFixed(1)}k';
    }
    final m = n / 1000000;
    return m >= 100 ? '${m.toStringAsFixed(0)}M' : '${m.toStringAsFixed(1)}M';
  }

  /// 百分比 (整数优先, 一位小数兜底)
  static String _fmtPct(double v) {
    final rounded = (v * 10).roundToDouble() / 10;
    if (rounded == rounded.roundToDouble()) {
      return rounded.toInt().toString();
    }
    return rounded.toStringAsFixed(1);
  }

  static String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}';
  }

  static String _fmtRelative(String iso) {
    try {
      final diff = DateTime.parse(iso).difference(DateTime.now());
      if (diff.isNegative) return '已重置';
      final h = diff.inHours;
      if (h >= 24) return '${diff.inDays} 天后';
      if (h >= 1) return '$h 小时后';
      return '${diff.inMinutes} 分钟后';
    } catch (_) {
      return iso;
    }
  }

  static Color _utilColor(double utilization) {
    if (utilization >= 90) return AppColors.danger;
    if (utilization >= 70) return AppColors.warning;
    return AppColors.accent;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('用量详情', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            _buildTokenSection(context),
            Divider(
              height: 32,
              thickness: 1,
              color: theme.colorScheme.outlineVariant,
            ),
            _buildGlmSection(context),
          ],
        ),
      ),
    );
  }

  // ── 区块 1: 本会话 Token ────────────────────────────────────

  Widget _buildTokenSection(BuildContext context) {
    final theme = Theme.of(context);
    final u = tokenUsage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(icon: Icons.bolt_outlined, label: '本会话 Token'),
        const SizedBox(height: 8),
        if (u == null || u.input <= 0)
          Text(
            '暂无用量数据 (发送首条消息后统计)',
            style: TextStyle(
              fontSize: AppTextSizes.bodySm,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '上下文',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
              Text(
                '${_fmt(u.input)} / ${u.max > 0 ? _fmt(u.max) : '未知'}',
                style: AppText.mono(context,
                    size: 13, weight: FontWeight.w600, color: _utilColor(
                        u.max > 0 ? u.input / u.max * 100 : 0)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _Bar(value: u.max > 0 ? (u.input / u.max).clamp(0.0, 1.0) : 0.0),
          const SizedBox(height: 6),
          Text(
            '累计输出 ↓${_fmt(u.output)} · 接近容量时将自动压缩历史',
            style: TextStyle(
              fontSize: AppTextSizes.label,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  // ── 区块 2: GLM Coding Plan ─────────────────────────────────

  Widget _buildGlmSection(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          icon: Icons.local_fire_department_outlined,
          label: 'GLM Coding Plan',
        ),
        const SizedBox(height: 8),
        quotaAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          error: (e, _) => Text(
            'GLM 配额查询失败: $e',
            style: const TextStyle(
              fontSize: AppTextSizes.bodySm,
              color: AppColors.danger,
            ),
          ),
          data: (quota) {
            if (quota == null || !quota.hasData) {
              return Text(
                quota?.error ?? 'GLM 配额暂无数据',
                style: TextStyle(
                  fontSize: AppTextSizes.bodySm,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              );
            }
            final level = quota.credentialMessage;
            final mcp = quota.mcp;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (level != null && level.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '套餐: $level',
                      style: TextStyle(
                        fontSize: AppTextSizes.bodySm,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final tier in quota.tiers) ...[
                  _QuotaTierRow(tier: tier),
                  if (tier != quota.tiers.last) const SizedBox(height: 14),
                ],
                if (mcp != null) ...[
                  const Divider(height: 28, thickness: 1),
                  _McpUsageSection(mcp: mcp),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        // 更新时间 + 刷新
        Row(
          children: [
            if (quotaAsync.valueOrNull?.queriedAt != null)
              Expanded(
                child: Text(
                  '更新于 ${_fmtTime(quotaAsync.valueOrNull!.queriedAt!)}',
                  style: TextStyle(
                    fontSize: AppTextSizes.label,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              const Spacer(),
            if (onRefresh != null)
              TextButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('刷新'),
              ),
          ],
        ),
      ],
    );
  }
}

// ── 子组件 ─────────────────────────────────────────────────────

/// 区块标题 (小图标 + 灰色小字)
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: AppTextSizes.label,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 细进度条 (6px, 圆角, 阈值变色)
class _Bar extends StatelessWidget {
  final double value;
  final Color? color;

  const _Bar({required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: LinearProgressIndicator(
        value: value.clamp(0.0, 1.0),
        minHeight: 6,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        color: color ?? theme.colorScheme.primary,
      ),
    );
  }
}

/// 单窗口配额行: 标签 + 已用% + 进度条 + 重置时间
class _QuotaTierRow extends StatelessWidget {
  final glm.GlmQuotaTier tier;

  const _QuotaTierRow({required this.tier});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = tier.name == glm.GlmQuotaTier.fiveHour ? '5 小时窗口' : '每周窗口';
    final color = UsageDetailSheet._utilColor(tier.utilization);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            Text(
              '${UsageDetailSheet._fmtPct(tier.utilization)}%',
              style: AppText.mono(context,
                  size: 13, weight: FontWeight.w600, color: color),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _Bar(
          value: tier.utilization / 100,
          color: color,
        ),
        if (tier.resetsAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '重置: ${UsageDetailSheet._fmtRelative(tier.resetsAt!)}',
              style: TextStyle(
                fontSize: AppTextSizes.label,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// MCP 月度用量区块: 已用/总量 + 进度条 + 重置时间 + 各 MCP 次数明细
class _McpUsageSection extends StatelessWidget {
  final glm.GlmMcpQuota mcp;

  const _McpUsageSection({required this.mcp});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = UsageDetailSheet._utilColor(mcp.percentage);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          icon: Icons.extension_outlined,
          label: '本月 MCP 用量',
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${mcp.used} / ${mcp.total} 次',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
            Text(
              '${UsageDetailSheet._fmtPct(mcp.percentage)}%',
              style: AppText.mono(context,
                  size: 13, weight: FontWeight.w600, color: color),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _Bar(value: mcp.percentage / 100, color: color),
        if (mcp.resetsAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '重置: ${UsageDetailSheet._fmtRelative(mcp.resetsAt!)}',
              style: TextStyle(
                fontSize: AppTextSizes.label,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (mcp.details.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final d in mcp.details)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      glm.glmMcpDisplayName(d.modelCode),
                      style: const TextStyle(fontSize: AppTextSizes.bodySm),
                    ),
                  ),
                  Text(
                    '${d.usage} 次',
                    style: AppText.mono(
                      context,
                      size: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
