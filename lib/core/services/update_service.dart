/// 应用内版本检测更新 — 只依赖 GitHub Releases, 无自建服务器。
///
/// 检测: GET /repos/<repo>/releases/latest (匿名, 60 次/时/IP)
/// 更新: ① 应用内下载 APK (进度) → FileProvider → 系统安装器
///       ② 兜底 url_launcher 跳浏览器下载
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

class UpdateInfo {
  final String tag; // v1.2.0
  final String version; // 1.2.0
  final String notes; // release 说明
  final String apkUrl; // APK 直链
  final String htmlUrl; // release 页
  final int apkSize; // 字节

  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.htmlUrl,
    required this.apkSize,
  });
}

class UpdateService {
  UpdateService._();

  static const repo = 'by-yitong/zcode-app';
  static const _channel = MethodChannel('app/updater');

  static String? _localVersionCache;

  /// 本地版本 (如 "1.1.0")
  static Future<String> localVersion() async {
    if (_localVersionCache != null) return _localVersionCache!;
    final info = await PackageInfo.fromPlatform();
    _localVersionCache = info.version;
    return info.version;
  }

  /// 检查新版本; 无新版本/失败返回 null (静默, 不打扰)
  static Future<UpdateInfo?> check() async {
    try {
      final local = await localVersion();
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ));
      final resp = await dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repo/releases/latest',
        options: Options(headers: {'Accept': 'application/vnd.github+json'}),
      );
      final data = resp.data;
      if (data == null) return null;
      final tag = data['tag_name'] as String? ?? '';
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (version.isEmpty || !_isNewer(version, local)) return null;

      var apkUrl = '', apkSize = 0;
      final assets = data['assets'] as List? ?? [];
      for (final a in assets.whereType<Map>()) {
        if ((a['name'] as String?)?.endsWith('.apk') ?? false) {
          apkUrl = a['browser_download_url'] as String? ?? '';
          apkSize = (a['size'] as num?)?.toInt() ?? 0;
          break;
        }
      }
      if (apkUrl.isEmpty) return null;
      return UpdateInfo(
        tag: tag,
        version: version,
        notes: data['body'] as String? ?? '',
        apkUrl: apkUrl,
        htmlUrl: data['html_url'] as String? ?? 'https://github.com/$repo/releases',
        apkSize: apkSize,
      );
    } catch (e) {
      appLog.d('[Update] 检查失败 (网络/限流, 忽略): $e');
      return null;
    }
  }

  /// 下载 APK 到应用外部私有目录, [onProgress] 0..1
  static Future<String> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    DownloadCancel? onCancel,
  }) async {
    final dir = await getExternalStorageDirectory();
    final updateDir = Directory('${dir?.path ?? '/tmp'}/update');
    if (!updateDir.existsSync()) updateDir.createSync(recursive: true);
    // 清掉旧包, 只留最新
    for (final f in updateDir.listSync()) {
      if (f is File) f.deleteSync();
    }
    final file = File('${updateDir.path}/zcode-app-${info.version}.apk');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
    ));
    await dio.download(
      info.apkUrl,
      file.path,
      cancelToken: onCancel?.token,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );
    return file.path;
  }

  /// 调系统安装器安装 (需要用户已授予"安装未知应用"权限)
  static Future<void> install(String apkPath) async {
    try {
      await _channel.invokeMethod('install', {'path': apkPath});
    } on PlatformException catch (e) {
      appLog.w('[Update] 安装器调用失败: ${e.message}');
      rethrow;
    }
  }

  // ── 自动检查节流 + 忽略版本 ──

  static const _keyLastCheck = 'update_last_check';
  static const _keyDismissed = 'update_dismissed_tag';

  /// 距上次检查超过 [interval] 才需要再查
  static Future<bool> shouldAutoCheck({
    Duration interval = const Duration(hours: 24),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_keyLastCheck) ?? 0;
    return DateTime.now().millisecondsSinceEpoch - last >
        interval.inMilliseconds;
  }

  static Future<void> markChecked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _keyLastCheck, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<bool> isDismissed(String tag) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDismissed) == tag;
  }

  static Future<void> dismiss(String tag) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDismissed, tag);
  }

  /// semver 比较: [remote] 是否比 [local] 新 ("1.2.0" > "1.1.99")
  static bool _isNewer(String remote, String local) {
    List<int> parse(String v) =>
        v.split(RegExp(r'[+.]')).map((s) => int.tryParse(s) ?? 0).toList();
    final r = parse(remote);
    final l = parse(local);
    for (var i = 0; i < 3; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv != lv) return rv > lv;
    }
    return false;
  }
}

/// 下载取消句柄
class DownloadCancel {
  final CancelToken token = CancelToken();
  void cancel() => token.cancel();
}
