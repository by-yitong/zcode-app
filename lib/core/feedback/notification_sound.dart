import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 任务事件提示音 (对齐桌面端 task-notification-sound; 音源为系统 alert)。
/// 设置键 `notification_sound_enabled`, 默认开; 任何异常静默吞 (不响不崩)。
final notificationSound = NotificationSound();

/// SharedPreferences 中「提示音开关」的存储键 (service / 设置页 / provider 共用)。
const String kNotificationSoundPrefKey = 'notification_sound_enabled';

/// 任务事件提示音播放器: 任务完成 / AI 提问 / 权限请求三类事件各播一声。
///
/// 触发方 (chat_provider) 以 fire-and-forget 方式调用 [play], 不 await;
/// 开关关 / 偏好读取失败 / 播放失败 → 全部静默返回。
class NotificationSound {
  NotificationSound({this.playOverride, this.prefsOverride});

  /// 测试缝: 注入假播放函数 (默认绑 SystemSound.play(alert))。
  final Future<void> Function()? playOverride;

  /// 测试缝: 注入偏好来源 (默认 SharedPreferences.getInstance)。
  final Future<SharedPreferences?> Function()? prefsOverride;

  /// 读开关 → 开则播一声。全程 try/catch: 提示音永不崩 App。
  Future<void> play() async {
    try {
      final prefs = prefsOverride != null
          ? await prefsOverride!()
          : await SharedPreferences.getInstance();
      if (prefs == null) return; // 偏好不可用 → 无法确认开关, 静默返回
      if (prefs.getBool(kNotificationSoundPrefKey) == false) return;
      final play =
          playOverride ?? () => SystemSound.play(SystemSoundType.alert);
      await play();
    } catch (_) {}
  }
}
