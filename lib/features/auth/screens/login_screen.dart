import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/theme/app_router.dart';

/// 登录页 — 「连接 ZCode」引导 (账号链路, 桌面端 3.16+)
///
/// 单一 CTA「账号登录」→ app 内 OAuth 授权 → 设备选择页 → 连接。
/// 旧「扫码/URL + hash」链路已删除。
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.xxl),
              // 品牌块
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Icon(
                  Icons.terminal,
                  size: 32,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '连接 ZCode',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '登录与桌面端相同的账号, 远程控制你的电脑',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),

              const SizedBox(height: AppSpacing.xl),

              // 主 CTA — 唯一入口
              FilledButton.icon(
                onPressed: () => context.go(AppRoutes.accountLogin),
                icon: const Icon(Icons.login_rounded),
                label: const Text('账号登录'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),

              const SizedBox(height: AppSpacing.xl),
              const Divider(),
              const SizedBox(height: AppSpacing.md),

              // 帮助卡 (仪表盘卡片风格: 圆角 + 浅底)
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.help_outline,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text('如何连接', style: theme.textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _step(context, '1', '桌面端登录 Z.ai 或 BigModel 账号, 并开启远程控制'),
                    _step(context, '2', '点「账号登录」, 在 app 内完成同一账号授权'),
                    _step(context, '3', '选择你的电脑设备即可连接'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 帮助步骤行: primary 色圆形序号 + 说明文字
  Widget _step(BuildContext context, String num, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                num,
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
