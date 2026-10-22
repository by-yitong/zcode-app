import 'package:dio/dio.dart';

/// 账号认证过期 (JWT 失效 / HTTP 401)。
///
/// 上层捕获后应引导用户重新走 OAuth 登录, 而不是当作网络错误重试。
class AccountAuthExpiredException implements Exception {
  final String message;

  AccountAuthExpiredException([this.message = '账号认证已过期, 请重新登录']);

  @override
  String toString() => 'AccountAuthExpiredException: $message';
}

/// OAuth 换票结果 (design §1.1)
class ZcodeTokenSet {
  /// zcode 侧 JWT — 后续所有 /api/v1/remote/* 的 Bearer 凭据
  final String zcodeJwtToken;

  /// chat.z.ai 侧 access token (可能缺席)
  final String? zaiAccessToken;

  /// 用户信息 (宽松解析, 原样保留)
  final Map<String, dynamic> userInfo;

  const ZcodeTokenSet({
    required this.zcodeJwtToken,
    this.zaiAccessToken,
    this.userInfo = const {},
  });
}

/// 已配对的远程设备 (GET /api/v1/remote/device)
class RemoteDevice {
  final String deviceSid;
  final String? deviceMid;
  final bool online;
  final DateTime? createdAt;
  final Map<String, dynamic>? meta;

  const RemoteDevice({
    required this.deviceSid,
    this.deviceMid,
    this.online = false,
    this.createdAt,
    this.meta,
  });

  factory RemoteDevice.fromJson(Map<String, dynamic> json) {
    return RemoteDevice(
      deviceSid: json['device_sid'] as String? ?? '',
      deviceMid: json['device_mid'] as String?,
      online: json['online'] == true,
      createdAt: _parseDate(json['created_at']),
      meta: json['meta'] is Map
          ? Map<String, dynamic>.from(json['meta'] as Map)
          : null,
    );
  }

  /// 显示名: meta.name 优先, 缺席回退 deviceSid
  String get displayName {
    final name = meta?['name'];
    if (name is String && name.isNotEmpty) return name;
    return deviceSid;
  }

  /// 宽松时间解析: ISO 字符串 / epoch 秒 / epoch 毫秒
  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is String) return DateTime.tryParse(v);
    if (v is num) {
      final ms = v > 100000000000 ? v.toInt() : (v * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    return null;
  }
}

/// 短时 terminal token (POST /api/v1/remote/token)
class TerminalToken {
  /// 22 字符短时票, 形如 ^[A-Za-z0-9_-]{21}[AQgw]$
  final String token;

  /// 有效期 (秒)
  final int expiresIn;

  /// 绝对过期时间 (服务端给了才算)
  final DateTime? expiresAt;

  const TerminalToken({
    required this.token,
    required this.expiresIn,
    this.expiresAt,
  });

  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);
}

/// OAuth 供应商 (web 3.16.2 bundle: provider 字段二值)
enum OAuthProvider {
  zai,
  bigmodel;

  String get wireName => name;
}

/// ZCode 账号 API (3.16+ 协议, design §1.1/§1.2)
///
/// - OAuth 授权 URL 组装 + 授权码换票
/// - 设备列表 / 短时 terminal token (Bearer zcodeJwtToken)
///
/// 统一响应包装 `{code, msg, data}`: code==0 成功, 非 0 抛 [Exception](msg);
/// 裸对象 (无 code 键) 原样返回。401 抛 [AccountAuthExpiredException]。
class ZcodeAccountApi {
  /// REST 基址 (默认生产 origin; 测试可注入本地地址 + dio 拦截器打桩)
  static const defaultOrigin = 'https://zcode.z.ai';

  /// OAuth authorize 固定走 chat.z.ai (bundle 明文配置, 逆向证据 F2)
  static const authorizeOrigin = 'https://chat.z.ai';

  /// BigModel 授权页 (bundle: VITE_BIGMODEL_OAUTH_ORIGIN + /login)
  static const bigmodelAuthorizeOrigin = 'https://bigmodel.cn';

  /// BigModel 授权 appId (bundle 默认值)
  static const bigmodelAppId = 'zcode';

  /// OAuth client_id (3.16.2 web bundle 明文配置)
  static const oauthClientId = 'client_P8X5CMWmlaRO9gyO-KSqtg';

  /// OAuth 回调地址 (webview 拦截此 URL 提取 code, 不加载页面)
  static const redirectUri = 'https://zcode.z.ai/remote/v4';

  final String origin;

  /// 暴露 dio 供测试注入拦截器 (生产代码勿动)
  final Dio dio;

  ZcodeAccountApi({String? origin})
    : origin = origin ?? defaultOrigin,
      dio = Dio(
        BaseOptions(
          baseUrl: origin ?? defaultOrigin,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Content-Type': 'application/json'},
        ),
      );

  /// 组装 OAuth 授权 URL (state 由调用方生成, base64url(JSON{nonce}))
  ///
  /// - zai: chat.z.ai/api/oauth/authorize (授权码模式标准参数)
  /// - bigmodel: bigmodel.cn/login?redirect=&appId=zcode&state=
  ///   (bundle buildAuthorizeUrl 分支, 逆向证据: bigmodelAuthorizeUrl/bigmodelAppId)
  /// 两者回调 URL 与 code/state 参数形状一致, 由同一 WebView 拦截器处理。
  Uri buildAuthorizeUrl(
    String state, {
    OAuthProvider provider = OAuthProvider.zai,
  }) {
    if (provider == OAuthProvider.bigmodel) {
      return Uri.parse('$bigmodelAuthorizeOrigin/login').replace(
        queryParameters: {
          'redirect': redirectUri,
          'appId': bigmodelAppId,
          'state': state,
        },
      );
    }
    return Uri.parse('$authorizeOrigin/api/oauth/authorize').replace(
      queryParameters: {
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'client_id': oauthClientId,
        'state': state,
      },
    );
  }

  /// 授权码换票 (POST /api/v1/oauth/token)
  ///
  /// 响应形状宽松解析 (design §2.1): 顶层或 data 嵌套递归找
  /// zcodeJwtToken / zaiAccessToken|accessToken / userInfo|user_info。
  Future<ZcodeTokenSet> exchangeToken({
    required String code,
    required String state,
    OAuthProvider provider = OAuthProvider.zai,
  }) async {
    final resp = await _guard(
      () => dio.post(
        '/api/v1/oauth/token',
        data: {
          'provider': provider.wireName,
          'code': code,
          'redirect_uri': redirectUri,
          'state': state,
        },
      ),
    );
    return _parseTokenSet(_unwrap(resp));
  }

  /// 已配对设备列表 (GET /api/v1/remote/device)
  Future<List<RemoteDevice>> listDevices({String? jwtOverride}) async {
    final resp = await _guard(
      () => dio.get('/api/v1/remote/device', options: _auth(jwtOverride)),
    );
    final data = _unwrap(resp);
    final List<dynamic>? list;
    if (data is List) {
      list = data;
    } else if (data is Map && data['data'] is List) {
      // 双层包装兜底: {code:0, data:{data:[...]}}
      list = data['data'] as List;
    } else {
      list = null;
    }
    if (list == null) {
      throw Exception('listDevices 响应格式异常: ${data.runtimeType}');
    }
    return list
        .whereType<Map>()
        .map((m) => RemoteDevice.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// 换取短时 terminal token (POST /api/v1/remote/token, role=terminal)
  ///
  /// 宽松兼容两种 wire 键名: {token, expires_in, expires_at} 与
  /// 3.16.2 bundle zod 形状 {accessToken, expiresIn, expiresAt}。
  Future<TerminalToken> issueTerminalToken({String? jwtOverride}) async {
    final resp = await _guard(
      () => dio.post(
        '/api/v1/remote/token',
        data: {'role': 'terminal'},
        options: _auth(jwtOverride),
      ),
    );
    final data = _unwrap(resp);
    if (data is! Map) {
      throw Exception('issueTerminalToken 响应格式异常: ${data.runtimeType}');
    }
    final token =
        data['token'] as String? ?? data['accessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('issueTerminalToken 响应缺 token: $data');
    }
    final expiresInRaw = data['expires_in'] ?? data['expiresIn'];
    final expiresIn =
        expiresInRaw is num ? expiresInRaw.toInt() : int.tryParse('$expiresInRaw') ?? 0;
    return TerminalToken(
      token: token,
      expiresIn: expiresIn,
      expiresAt: RemoteDevice._parseDate(data['expires_at'] ?? data['expiresAt']),
    );
  }

  // ── 内部 ────────────────────────────────────────────────

  Options _auth(String? jwtOverride) {
    if (jwtOverride == null || jwtOverride.isEmpty) {
      throw StateError('缺少 JWT: 调用前需传入 jwtOverride (或先完成账号登录)');
    }
    return Options(headers: {'Authorization': 'Bearer $jwtOverride'});
  }

  /// 统一错误闸门: HTTP 401 (dio 抛 DioException) → [AccountAuthExpiredException]
  Future<Response<dynamic>> _guard(
    Future<Response<dynamic>> Function() fn,
  ) async {
    try {
      return await fn();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw AccountAuthExpiredException('HTTP 401: ${e.requestOptions.uri}');
      }
      rethrow;
    }
  }

  /// 解包 `{code, msg, data}` / 裸对象 (design §2.1)
  dynamic _unwrap(Response<dynamic> resp) {
    if (resp.statusCode == 401) {
      throw AccountAuthExpiredException('HTTP 401: ${resp.requestOptions.uri}');
    }
    final body = resp.data;
    if (body is Map && body.containsKey('code')) {
      final code = body['code'];
      if (code is num && code != 0) {
        throw Exception('${body['msg'] ?? '未知错误'} (code=$code)');
      }
      if (code is String && code != '0') {
        throw Exception('${body['msg'] ?? '未知错误'} (code=$code)');
      }
      return body['data'] ?? body;
    }
    return body;
  }

  ZcodeTokenSet _parseTokenSet(dynamic node) {
    // 标准结构 (bundle e7n 原文, 真机实测):
    //   {code:0, msg, data:{token:<JWT>, zai|bigmodel:{access_token}, user, expires_in}}
    //   ★ JWT 在 data.token; access_token 在 data.<provider>.access_token
    // 注意 _unwrap 在 code==0 时已剥壳返回 data 本体 — 两种输入都要兼容:
    //   node 可能是 data 本体 (token 在 node.token) 或完整 body (token 在 node.data.token)
    if (node is Map) {
      final root = Map<String, dynamic>.from(node);
      final d = root['data'] is Map
          ? Map<String, dynamic>.from(root['data'] as Map)
          : root;
      final jwt = d['token'];
      if (jwt is String && jwt.isNotEmpty) {
        final providerMap = d['zai'] is Map
            ? Map<String, dynamic>.from(d['zai'] as Map)
            : d['bigmodel'] is Map
            ? Map<String, dynamic>.from(d['bigmodel'] as Map)
            : null;
        final accessToken = providerMap?['access_token'];
        final user = d['user'] is Map
            ? Map<String, dynamic>.from(d['user'] as Map)
            : null;
        return ZcodeTokenSet(
          zcodeJwtToken: jwt,
          zaiAccessToken:
              accessToken is String && accessToken.isNotEmpty
                  ? accessToken
                  : null,
          userInfo: user ?? const {},
        );
      }
    }
    // 兜底宽松解析: 递归找 zcodeJwtToken 键 (兼容未知形状)
    final jwtHolder = _findFirstMap(node, (m) => m.containsKey('zcodeJwtToken'));
    if (jwtHolder == null) {
      throw Exception(
        'exchangeToken 响应缺 zcodeJwtToken (data.token): ${_brief(node)}',
      );
    }
    final jwt = jwtHolder['zcodeJwtToken'] as String?;
    if (jwt == null || jwt.isEmpty) {
      throw Exception('exchangeToken 响应 zcodeJwtToken 为空');
    }
    final zai = _findString(node, const ['zaiAccessToken', 'accessToken']);
    final userInfo = _findMapValue(node, const ['userInfo', 'user_info']);
    return ZcodeTokenSet(
      zcodeJwtToken: jwt,
      zaiAccessToken: zai,
      userInfo: userInfo ?? const {},
    );
  }

  /// 诊断摘要: JSON 序列化截断 (诊断响应形状用, 只在解析失败的异常里出现)
  static String _brief(dynamic node) {
    try {
      final s = node.toString();
      return s.length > 300 ? '${s.substring(0, 300)}...' : s;
    } catch (_) {
      return '<unprintable>';
    }
  }

  /// 递归找第一个满足 [test] 的 Map
  Map<String, dynamic>? _findFirstMap(
    dynamic node,
    bool Function(Map<String, dynamic>) test,
  ) {
    if (node is Map) {
      final map = Map<String, dynamic>.from(node);
      if (test(map)) return map;
      for (final v in map.values) {
        final r = _findFirstMap(v, test);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findFirstMap(v, test);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// 递归找 [keys] 中第一个命中的字符串值
  String? _findString(dynamic node, List<String> keys) {
    if (node is Map) {
      for (final k in keys) {
        final v = node[k];
        if (v is String && v.isNotEmpty) return v;
      }
      for (final v in node.values) {
        final r = _findString(v, keys);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findString(v, keys);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// 递归找 [keys] 中第一个命中的 Map 值
  Map<String, dynamic>? _findMapValue(dynamic node, List<String> keys) {
    if (node is Map) {
      for (final k in keys) {
        final v = node[k];
        if (v is Map) return Map<String, dynamic>.from(v);
      }
      for (final v in node.values) {
        final r = _findMapValue(v, keys);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findMapValue(v, keys);
        if (r != null) return r;
      }
    }
    return null;
  }
}
