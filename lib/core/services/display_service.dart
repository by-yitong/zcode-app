import 'dart:io';

import 'package:flutter/services.dart';

/// 屏幕常亮控制 (Android FLAG_KEEP_SCREEN_ON, 经 "app/display" MethodChannel)
///
/// 仅 Android 生效; 通道不可用 (旧原生端/热重启窗口期) 时静默忽略,
/// 不影响 UI 流程。
class DisplayService {
  static const _channel = MethodChannel('app/display');

  /// 开/关屏幕常亮
  static Future<void> setKeepScreenOn(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('keepScreenOn', {'enabled': enabled});
    } catch (_) {}
  }
}
