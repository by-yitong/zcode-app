import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/saved_connection.dart';
import '../../data/models/zcode_session.dart';
import '../logging/app_logger.dart';
import '../services/glm_quota_service.dart';

/// 安全存储 — 管理 session/token 的持久化
class SecureStorageService {
  final FlutterSecureStorage _secure;

  static const _keySession = 'zcode_session';
  static const _keyDeviceId = 'zcode_device_id';
  static const _keyGlmCredential = 'glm_credential';
  static const _keyConnections = 'zcode_connections';

  /// GLM 凭据默认 base URL (国内 bigmodel.cn)
  static const defaultGlmBaseUrl = 'https://open.bigmodel.cn/api/paas/v4';

  SecureStorageService([FlutterSecureStorage? storage])
      : _secure = storage ??
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

  // ── 多远程连接 ──────────────────────────────────────────

  /// 读取已保存的连接列表 (按 lastUsedAt 倒序)
  Future<List<SavedConnection>> getConnections() async {
    final json = await _secure.read(key: _keyConnections);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List;
      final conns = list
          .whereType<Map>()
          .map((m) => SavedConnection.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      conns.sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
      return conns;
    } catch (e) {
      appLog.w('[Storage] 连接列表解析失败: $e');
      return [];
    }
  }

  /// 保存连接列表
  Future<void> saveConnections(List<SavedConnection> connections) async {
    final json = jsonEncode([for (final c in connections) c.toJson()]);
    await _secure.write(key: _keyConnections, value: json);
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

  String get defaultModel => _prefs.getString('defaultModel') ?? 'GLM-X-PREVIEW';

  set defaultModel(String model) => _prefs.setString('defaultModel', model);

  String get defaultMode => _prefs.getString('defaultMode') ?? 'confirm';

  set defaultMode(String mode) => _prefs.setString('defaultMode', mode);

  bool get organizeByWorkspace =>
      _prefs.getBool('organizeByWorkspace') ?? true;

  set organizeByWorkspace(bool v) => _prefs.setBool('organizeByWorkspace', v);
}
