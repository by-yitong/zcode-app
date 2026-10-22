import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/network/zcode_account_api.dart';
import '../../../../data/models/zcode_account.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/theme/app_router.dart';
import '../../../providers/app_providers.dart';

/// OAuth 回调 URL 解析结果 (design §1.1)
///
/// - 成功: code + state
/// - 失败: error (服务端拒绝/用户取消等)
class OAuthCallback {
  final String? code;
  final String? state;
  final String? error;

  const OAuthCallback({this.code, this.state, this.error});
}

/// 账号登录页 (桌面端 3.16+, design §1.1 / §3)
///
/// WebView 加载 chat.z.ai OAuth 授权页, 拦截 zcode.z.ai/remote/v4 回调
/// 提取授权码 (不加载回调页), 校验 state nonce 后换票存账号, 跳设备选择页。
/// OAuth 在第三方域, 页面全屏简化不套卡片。
class AccountLoginScreen extends ConsumerStatefulWidget {
  const AccountLoginScreen({super.key});

  @override
  ConsumerState<AccountLoginScreen> createState() =>
      _AccountLoginScreenState();

  // ── 纯逻辑 (静态, 供单测; 不触网不碰 WebView) ────────────

  /// 随机 nonce: uuid v4 去横线 (32 位 hex)
  static String generateNonce() => const Uuid().v4().replaceAll('-', '');

  /// state = base64url(JSON{nonce}), 无 padding (web 端形态)
  static String encodeState(String nonce) {
    final json = jsonEncode({'nonce': nonce});
    return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  }

  /// 从 state 解出 nonce; 非法 base64 / 非 JSON / 缺 nonce → null
  static String? extractNonce(String state) {
    try {
      var normalized = state;
      final rem = normalized.length % 4;
      if (rem == 1) return null; // 不可能是合法 base64 长度
      if (rem > 1) normalized += '=' * (4 - rem);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final json = jsonDecode(decoded);
      if (json is Map) {
        final nonce = json['nonce'];
        if (nonce is String && nonce.isNotEmpty) return nonce;
      }
      return null;
    } on FormatException {
      return null;
    } on Exception {
      return null;
    }
  }

  /// 回调 state 与本地 nonce 比对 (CSRF 防护, design §1.1)
  static bool verifyState(String state, String expectedNonce) {
    if (expectedNonce.isEmpty) return false;
    return extractNonce(state) == expectedNonce;
  }

  static final Uri _redirectUri = Uri.parse(ZcodeAccountApi.redirectUri);

  /// OAuth 回调判定: host==zcode.z.ai 且 query 带 code/authCode/error。
  ///
  /// - 不匹配 path — 授权服务器 302 回调时可能带 /cn 语言前缀,
  ///   且 SPA 也会改写路径; host + 参数已足够窄。
  /// - code 参数名两供应商不同 (web bundle 原文): zai 回调带 `code`,
  ///   bigmodel 回调带 `authCode`, 二者等价映射为 code。
  static bool isOAuthCallback(Uri uri) =>
      uri.host == _redirectUri.host &&
      (uri.queryParameters.containsKey('code') ||
          uri.queryParameters.containsKey('authCode') ||
          uri.queryParameters.containsKey('error'));

  /// 解析回调 query:
  /// - 含 error → 失败结果
  /// - 含 code/authCode → 成功结果 (state 缺席为空串)
  /// - 非回调 URL / 无 code 无 error → null (继续导航)
  static OAuthCallback? parseCallback(Uri uri) {
    if (!isOAuthCallback(uri)) return null;
    final q = uri.queryParameters;
    final error = q['error'];
    if (error != null && error.isNotEmpty) {
      return OAuthCallback(error: error);
    }
    final code = q['code'] ?? q['authCode'];
    if (code == null || code.isEmpty) return null;
    return OAuthCallback(code: code, state: q['state'] ?? '');
  }
}

enum _LoginPhase { choosing, loading, browsing, exchanging, failed }

class _AccountLoginScreenState extends ConsumerState<AccountLoginScreen> {
  static const _loadTimeout = Duration(seconds: 20);

  WebViewController? _controller;
  final ZcodeAccountApi _api = ZcodeAccountApi();

  /// CSRF 防护: 本次登录的 nonce, 回调 state 必须一致
  late String _nonce;
  late String _state;

  /// 用户选择的登录供应商 (choosing 阶段为 null)
  OAuthProvider? _provider;
  _LoginPhase _phase = _LoginPhase.choosing;
  String? _error;
  Timer? _loadTimer;
  Timer? _pollTimer;

  @override
  void dispose() {
    _loadTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  /// 生成新 nonce 并加载授权页 (选定供应商后/重试共用)
  String _startAuthorize() {
    _nonce = AccountLoginScreen.generateNonce();
    _state = AccountLoginScreen.encodeState(_nonce);
    return _api
        .buildAuthorizeUrl(_state, provider: _provider!)
        .toString();
  }

  /// 选定供应商 → 创建 WebView 开始授权
  void _choose(OAuthProvider provider) {
    appLog.i('[AccountLogin] 选定供应商: ${provider.name}');
    setState(() {
      _provider = provider;
      _phase = _LoginPhase.loading;
      _error = null;
    });
    _controller = _buildController(_startAuthorize());
    // 轮询兜底: 导航回调 (onUrlChange/onPageStarted) 个别机型不触发时,
    // 1s 轮询 currentUrl 仍能拿到带 code 的回调 URL
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted ||
          (_phase != _LoginPhase.browsing && _phase != _LoginPhase.loading)) {
        return;
      }
      final url = await _controller?.currentUrl();
      if (url != null) _maybeConsumeCallback(url);
    });
  }

  WebViewController _buildController(String authorizeUrl) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // 只拦截会离开 WebView 的导航; 返回值决定是否放行
            final cb = AccountLoginScreen.parseCallback(
              Uri.parse(request.url),
            );
            if (cb == null) return NavigationDecision.navigate;
            _consumeCallback(cb);
            return NavigationDecision.prevent;
          },
          // ★ 授权服务器用 302 重定向回回调页, onNavigationRequest 拦不到 302,
          // 回调页会正常加载 (其 JS 因缺 nonce 报「链接过期」, 但 code 未被消费)。
          // onUrlChange 对重定向也触发 — 兜底从这里提取 code。
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) {
              appLog.d('[AccountLogin] onUrlChange: $url');
              _maybeConsumeCallback(url);
            }
          },
          onPageStarted: (url) {
            appLog.d('[AccountLogin] onPageStarted: $url');
            _cancelLoadTimer();
            _maybeConsumeCallback(url);
          },
          onPageFinished: (url) async {
            appLog.d('[AccountLogin] onPageFinished: $url');
            _cancelLoadTimer();
            // 最后一道兜底: 某些实现 onUrlChange/onPageStarted 都没赶上时,
            // 回调页加载完成后 URL 仍带 code (页面 JS 因缺 nonce 不会消费它)
            _maybeConsumeCallback(url);
            final current = await _controller?.currentUrl();
            if (current != null) _maybeConsumeCallback(current);
            if (mounted && _phase == _LoginPhase.loading) {
              setState(() => _phase = _LoginPhase.browsing);
            }
          },
          onWebResourceError: (error) {
            // 子资源失败 (图片/CSS) 不当作页面失败, 只管主框架
            if (error.isForMainFrame != true) return;
            _fail('页面加载失败 (${error.errorCode}): ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(authorizeUrl));
    _startLoadTimer();
    return controller;
  }

  /// URL 变为带 code/error 的回调 → 提取消费 (exchanging 态自动去重)
  void _maybeConsumeCallback(String url) {
    if (_phase != _LoginPhase.browsing && _phase != _LoginPhase.loading) {
      return;
    }
    final cb = AccountLoginScreen.parseCallback(Uri.parse(url));
    if (cb == null) return;
    appLog.i('[AccountLogin] 命中回调 URL: $url');
    _consumeCallback(cb);
  }

  void _consumeCallback(OAuthCallback cb) {
    if (cb.error != null) {
      appLog.w('[AccountLogin] 回调带 error: ${cb.error}');
      _fail('授权被拒绝: ${cb.error}');
      return;
    }
    _exchange(cb.code!, cb.state ?? '');
  }

  /// 授权页加载超时看门狗 (onPageStarted/Finished 任一触发即解除)
  void _startLoadTimer() {
    _loadTimer?.cancel();
    _loadTimer = Timer(_loadTimeout, () {
      if (mounted && _phase == _LoginPhase.loading) {
        _fail('授权页加载超时, 请检查网络后重试');
      }
    });
  }

  void _cancelLoadTimer() {
    _loadTimer?.cancel();
    _loadTimer = null;
  }

  /// 授权码换票 → 存账号 → 设备选择页
  Future<void> _exchange(String code, String state) async {
    if (_phase == _LoginPhase.exchanging) return;
    if (!AccountLoginScreen.verifyState(state, _nonce)) {
      appLog.w('[AccountLogin] state nonce 不一致, 拒绝换票');
      _fail('登录状态校验失败, 请重试');
      return;
    }
    setState(() => _phase = _LoginPhase.exchanging);
    appLog.i(
      '[AccountLogin] 开始换票: provider=${_provider?.name} state=${state.substring(0, state.length > 16 ? 16 : state.length)}...',
    );
    try {
      final tokens = await _api.exchangeToken(
        code: code,
        state: state,
        provider: _provider ?? OAuthProvider.zai,
      );
      appLog.i('[AccountLogin] 换票成功: jwt=${tokens.zcodeJwtToken.length} 字符');
      await ref
          .read(authRepositoryProvider)
          .saveAccount(
            ZcodeAccount(
              jwt: tokens.zcodeJwtToken,
              provider: (_provider ?? OAuthProvider.zai).wireName,
              userInfo: tokens.userInfo,
            ),
          );
      appLog.i('[AccountLogin] OAuth 换票成功');
      if (!mounted) return;
      // 替换路由: 回退不再回到授权页
      context.go(AppRoutes.devicePicker);
    } catch (e) {
      appLog.w('[AccountLogin] OAuth 换票失败: $e');
      if (mounted) _fail('登录失败: $e');
    }
  }

  void _fail(String message) {
    appLog.w('[AccountLogin] 失败: $message');
    if (!mounted) return;
    _cancelLoadTimer();
    setState(() {
      _phase = _LoginPhase.failed;
      _error = message;
    });
  }

  /// 重试: 换新 nonce 重新加载授权页 (旧授权码/state 一并作废)
  void _retry() {
    setState(() {
      _phase = _LoginPhase.loading;
      _error = null;
    });
    _controller?.loadRequest(Uri.parse(_startAuthorize()));
    _startLoadTimer();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('账号登录'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '取消',
          onPressed: () => context.go(AppRoutes.login),
        ),
      ),
      // WebView 必须挂在树上才会真正加载 (平台视图随 WebViewWidget 懒创建),
      // 加载/换票/失败态用遮罩盖在其上而不是替换
      body: Stack(
        children: [
          if (_phase != _LoginPhase.choosing)
            Offstage(
              offstage: _phase != _LoginPhase.browsing &&
                  _phase != _LoginPhase.loading,
              child: WebViewWidget(controller: _controller!),
            ),
          if (_phase == _LoginPhase.choosing)
            _providerPicker(theme)
          else if (_phase != _LoginPhase.browsing)
            Positioned.fill(
              child: switch (_phase) {
                _LoginPhase.loading => _overlay(
                  icon: _spinner(theme),
                  title: '正在打开授权页...',
                  subtitle:
                      '将跳转到 ${_provider == OAuthProvider.bigmodel ? 'BigModel (bigmodel.cn)' : 'z.ai (chat.z.ai)'} 账号登录',
                ),
                _LoginPhase.exchanging => _overlay(
                  icon: _spinner(theme),
                  title: '正在完成登录...',
                  subtitle: '正在验证授权并获取凭据',
                ),
                _LoginPhase.failed => _overlay(
                  icon: Icon(
                    Icons.cloud_off_rounded,
                    size: 40,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  title: '无法完成登录',
                  subtitle: _error ?? '未知错误',
                  action: FilledButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重试'),
                  ),
                ),
                _ => const SizedBox.shrink(),
              },
            ),
        ],
      ),
    );
  }

  /// 供应商选择 (dashboard 卡片风格: 圆角 + 细描边)
  Widget _providerPicker(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选择账号体系',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '与桌面端登录的账号保持一致',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            _providerCard(
              theme: theme,
              provider: OAuthProvider.zai,
              icon: Icons.public_rounded,
              title: 'Z.ai',
              subtitle: 'chat.z.ai 账号 · 国际站',
            ),
            const SizedBox(height: AppSpacing.md),
            _providerCard(
              theme: theme,
              provider: OAuthProvider.bigmodel,
              icon: Icons.science_rounded,
              title: 'BigModel',
              subtitle: 'bigmodel.cn 账号 · 智谱开放平台',
            ),
          ],
        ),
      ),
    );
  }

  Widget _providerCard({
    required ThemeData theme,
    required OAuthProvider provider,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _choose(provider),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: theme.colorScheme.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _spinner(ThemeData theme) => SizedBox(
    width: 28,
    height: 28,
    child: CircularProgressIndicator(
      strokeWidth: 2.5,
      color: theme.colorScheme.primary,
    ),
  );

  /// 加载/换票/失败遮罩 (授权页本身全屏, 不套卡片)
  Widget _overlay({
    required Widget icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(height: AppSpacing.lg),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.xl),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
