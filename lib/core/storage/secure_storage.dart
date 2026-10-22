import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/zcode_account.dart';
import '../../data/models/zcode_session.dart';
import '../logging/app_logger.dart';
import '../services/glm_quota_service.dart';

/// 安全存储 — 管理 session/token 的持久化
class SecureStorageService {
  final FlutterSecureStorage _secure;

  static const _keySession = 'zcode_session';
  static const _keyDeviceId = 'zcode_device_id';
  static const _keyGlmCredential = 'glm_credential';
  static const _keyAccountJwt = 'zcode_account_jwt';
  static const _keyAccountUser = 'zcode_account_user';
  static const _keyLastDevice = 'zcode_last_device';

  /// GLM 凭据默认 base URL (国内 bigmodel.cn)
  static const defaultGlmBaseUrl = 'https://open.bigmodel.cn/api/paas/v4';

  SecureStorageService([FlutterSecureStorage? storage])
    : _secure =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  /// 保存会话
  Future<void> saveSession(ZcodeSession session) async {
    final json = jsonEncode(session.toJson());
    await _secure.write(key: _keySession, value: json);
  }

  /// 读取会话
  Future<ZcodeSession?> getSession() async {
    final json = await _secure.read(key: _keySession);
    if (json == null) return null;
    try {
      return ZcodeSession.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      // 数据损坏按未登录处理; 留日志避免"莫名被登出"无迹可寻
      appLog.w('[Storage] session 数据解析失败, 视为未登录: $e');
      return null;
    }
  }

  /// 清除会话
  Future<void> clearSession() async {
    await _secure.delete(key: _keySession);
  }

  // ── 最近连接的设备 (账号链路, 设备选择页回填用) ──────────

  /// 读取最近连接的设备; 未存储或数据损坏返回 null
  ///
  /// 值形如 {deviceSid, deviceMid, deviceName, appVersion}
  Future<Map<String, dynamic>?> getLastDevice() async {
    final json = await _secure.read(key: _keyLastDevice);
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (e) {
      appLog.w('[Storage] lastDevice 数据解析失败, 视为未存储: $e');
      return null;
    }
  }

  /// 保存最近连接的设备 (键约定: deviceSid/deviceMid/deviceName/appVersion)
  Future<void> saveLastDevice(Map<String, dynamic> device) async {
    await _secure.write(key: _keyLastDevice, value: jsonEncode(device));
  }

  /// 清除最近连接的设备记录
  Future<void> clearLastDevice() async {
    await _secure.delete(key: _keyLastDevice);
  }

  // ── 账号登录 (3.16+ OAuth) ──────────────────────────────
  // JWT 与 session 同级保护 (不进 SharedPreferences)。

  /// 读取账号凭据; 未登录或数据损坏返回 null
  Future<ZcodeAccount?> getAccount() async {
    final jwt = await _secure.read(key: _keyAccountJwt);
    if (jwt == null || jwt.isEmpty) return null;
    var userInfo = const <String, dynamic>{};
    final userJson = await _secure.read(key: _keyAccountUser);
    if (userJson != null) {
      try {
        final decoded = jsonDecode(userJson);
        if (decoded is Map) {
          userInfo = Map<String, dynamic>.from(decoded);
        }
      } catch (e) {
        // userInfo 仅展示用, 损坏不清登录态
        appLog.w('[Storage] 账号 userInfo 解析失败, 忽略: $e');
      }
    }
    return ZcodeAccount(jwt: jwt, userInfo: userInfo);
  }

  /// 保存账号凭据
  Future<void> saveAccount(ZcodeAccount account) async {
    await _secure.write(key: _keyAccountJwt, value: account.jwt);
    await _secure.write(
      key: _keyAccountUser,
      value: jsonEncode(account.userInfo),
    );
  }

  /// 清除账号凭据 (退出账号登录)
  Future<void> clearAccount() async {
    await _secure.delete(key: _keyAccountJwt);
    await _secure.delete(key: _keyAccountUser);
  }

  /// 获取或生成设备 ID
  Future<String> getOrCreateDeviceId() async {
    var id = await _secure.read(key: _keyDeviceId);
    if (id == null || id.isEmpty) {
      // 生成简单设备 ID
      final ts = DateTime.now().millisecondsSinceEpoch;
      final rand = DateTime.now().microsecond;
      id = '${ts.toRadixString(36)}${rand.toRadixString(36)}';
      await _secure.write(key: _keyDeviceId, value: id);
    }
    return id;
  }

  // ── GLM Coding Plan 凭据 ────────────────────────────────
  // API key 是敏感数据, 与 session 同级保护 (不进 SharedPreferences)。
  // baseUrl 可配以支持 z.ai 国际站或第三方中转; 空时填默认 CN 入口。

  /// 保存 GLM 凭据
  ///
  /// baseUrl 留空时自动填 [defaultGlmBaseUrl]。apiKey 直接存, 不做 trim 以
  /// 便用户中转站可能需要前缀/后缀空格 (虽然罕见, 但 cc-switch 也未 trim)。
  Future<void> saveGlmCredential({
    required String baseUrl,
    required String apiKey,
  }) async {
    final json = jsonEncode({
      'baseUrl': baseUrl.trim().isEmpty ? defaultGlmBaseUrl : baseUrl.trim(),
      'apiKey': apiKey,
    });
    await _secure.write(key: _keyGlmCredential, value: json);
  }

  /// 读取 GLM 凭据; 未配置或解析失败返回 null
  Future<GlmCredential?> getGlmCredential() async {
    final json = await _secure.read(key: _keyGlmCredential);
    if (json == null) return null;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final baseUrl = (map['baseUrl'] as String?) ?? defaultGlmBaseUrl;
      final apiKey = (map['apiKey'] as String?) ?? '';
      return GlmCredential(baseUrl: baseUrl, apiKey: apiKey);
    } catch (e) {
      appLog.w('[Storage] GLM 凭据解析失败, 视为未配置: $e');
      return null;
    }
  }

  /// 清除 GLM 凭据
  Future<void> clearGlmCredential() async {
    await _secure.delete(key: _keyGlmCredential);
  }
}

/// 偏好设置存储
class PreferencesService {
  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String get themeMode => _prefs.getString('themeMode') ?? 'system';

  set themeMode(String mode) => _prefs.setString('themeMode', mode);

  String get defaultModel =>
      _prefs.getString('defaultModel') ?? 'GLM-X-PREVIEW';

  set defaultModel(String model) => _prefs.setString('defaultModel', model);

  String get defaultMode => _prefs.getString('defaultMode') ?? 'confirm';

  set defaultMode(String mode) => _prefs.setString('defaultMode', mode);

  bool get organizeByWorkspace => _prefs.getBool('organizeByWorkspace') ?? true;

  set organizeByWorkspace(bool v) => _prefs.setBool('organizeByWorkspace', v);
}
