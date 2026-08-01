import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/theme/app_router.dart';
import '../../../providers/app_providers.dart';
import 'scanner_screen.dart';

/// 登录页 — 扫码或粘贴 zcode 连接地址
///
/// Cookie 无需手动输入: 登录时自动 HTTP GET 连接地址获取 (服务器 Set-Cookie 下发)。
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _urlController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final url = _urlController.text.trim();

    if (url.isEmpty) {
      setState(() => _error = '请输入或扫码获取 ZCode 连接地址');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final authRepo = ref.read(authRepositoryProvider);
      // loginFromUrl 自动 HTTP GET 获取 cookie, 无需用户输入
      final session = await authRepo.loginFromUrl(url);
      await authRepo.saveSession(session);
      await ref.read(sessionProvider.notifier).loginWithSession(session);

      if (mounted) {
        context.go(AppRoutes.home);
      }
    } on ArgumentError catch (e) {
      setState(() {
        _error = e.message.toString();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = '连接失败: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _pasteUrl() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) {
      setState(() {
        _urlController.text = data!.text!;
        _error = null;
      });
    }
  }

  Future<void> _scanQr() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() {
        _urlController.text = result;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.terminal,
                    size: 32, color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 20),
              Text('连接 ZCode',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('扫码或粘贴连接地址, Cookie 会自动获取',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),

              const SizedBox(height: 24),

              // 连接地址输入
              TextField(
                controller: _urlController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: '连接地址',
                  hintText: 'https://zcode.z.ai/remote/v3?sid=...',
                  prefixIcon: const Icon(Icons.link),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste),
                    onPressed: _pasteUrl,
                    tooltip: '粘贴',
                  ),
                  errorText: _error,
                ),
                autocorrect: false,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),

              const SizedBox(height: 20),

              // 扫码按钮 (主要入口, 显眼)
              OutlinedButton.icon(
                onPressed: _isLoading ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码连接'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),

              const SizedBox(height: 12),

              // 连接按钮
              FilledButton.icon(
                onPressed: _isLoading ? null : _login,
                icon: _isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.login),
                label: Text(_isLoading ? '连接中...' : '连接'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),

              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 12),

              // 帮助
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.help_outline,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('如何获取连接地址', style: theme.textTheme.titleSmall),
                    ]),
                    const SizedBox(height: 12),
                    _step('1', '在电脑上打开 ZCode 桌面端'),
                    _step('2', '点击「移动端」或「远程连接」显示二维码'),
                    _step('3', '用本 APP 扫码, 或复制连接地址粘贴'),
                    _step('4', '确保桌面端保持在线'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(String num, String text) {
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
              child: Text(num,
                  style: TextStyle(
                      fontSize: AppTextSizes.caption,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
