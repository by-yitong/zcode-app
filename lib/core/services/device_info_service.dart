/// 移动端设备信息 — mobile-view-state-update 上报用。
///
/// 桌面端靠这个信封识别"连接的设备" (名称/UA/平台/屏幕)。
/// 网页端发的是浏览器 UA; app 发真实机型 (vivo XXX + Android 版本)。
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../logging/app_logger.dart';

class DeviceInfoService {
  DeviceInfoService._();

  static Map<String, dynamic>? _cached;

  /// app 版本 (与 pubspec 保持同步; 桌面端可能展示)
  static const appVersion = '1.1.0';

  /// 设备信息只取一次 (型号/系统版本不变), updatedAt 每次刷新
  static Future<Map<String, dynamic>> build() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final base = _cached;
    if (base != null) {
      return {...base, 'updatedAt': now};
    }

    var model = 'Android';
    var brand = '';
    var osVersion = '';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      model = info.model; // 如 "V2404A"
      brand = info.brand; // 如 "vivo"
      osVersion = info.version.release; // 如 "15"
    } catch (_) {}

    final ua =
        'Mozilla/5.0 (Linux; Android ${osVersion.isEmpty ? '15' : osVersion}; $model) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

    // 视口/屏幕 (逻辑像素, 与网页端语义一致)
    var w = 1080, h = 2400;
    var dpr = 3.0;
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
      if (view != null) {
        dpr = view.devicePixelRatio;
        w = (view.physicalSize.width / dpr).round();
        h = (view.physicalSize.height / dpr).round();
      }
    } catch (_) {}

    _cached = {
      'platform': 'mobileApp',
      'version': appVersion,
      'name': model,
      'userAgent': ua,
      'language': 'zh-CN',
      'languages': const ['zh-CN', 'zh'],
      // 网页端此处是 navigator.platform (如 "Linux x86_64"), 桌面端把它当
      // 设备标识显示 — 放 "品牌 机型" 让桌面端直接认出手机型号
      'browserPlatform':
          brand.isEmpty ? model : '$brand $model',
      'viewport': {'width': w, 'height': h, 'devicePixelRatio': dpr},
      'screen': {'width': w, 'height': h},
      'timezone': _timezone(),
      'online': true,
      'updatedAt': now,
    };
    appLog.d('[DeviceInfo] model=$model brand=$brand os=$osVersion '
        'platform=${_cached!['browserPlatform']}');
    return _cached!;
  }

  static String _timezone() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    if (offset.inMinutes == 480) return 'Asia/Shanghai';
    final name = now.timeZoneName;
    if (name.isNotEmpty) return name;
    return 'UTC${offset.isNegative ? '+' : '-'}${offset.inHours.abs()}';
  }
}
