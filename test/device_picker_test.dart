// 设备选择 → 会话组装纯逻辑单测 (design §3, 账号链路):
// - RemoteDevice → ZcodeSession 映射与回退值
// - isValid: 有 mid 才可连 (ws2 URL 参数)
// - 会话持久化 roundtrip (deviceName/appVersion 不丢)
// - mid 尾号展示
// 只测 DevicePickerScreen 上的静态纯函数, 不触网。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/network/zcode_account_api.dart';
import 'package:zcode_app/data/models/zcode_session.dart';
import 'package:zcode_app/features/auth/screens/device_picker_screen.dart';

RemoteDevice _device({String? mid, Map<String, dynamic>? meta}) {
  return RemoteDevice(
    deviceSid: 'd_sid_test',
    deviceMid: mid,
    online: true,
    meta: meta,
  );
}

void main() {
  group('sessionFromDevice (design §3 映射)', () {
    test('完整 meta → sid/mid/name/version 全映射', () {
      final session = DevicePickerScreen.sessionFromDevice(
        _device(
          mid: 'mid_abcdef123',
          meta: {
            'platform': 'darwin',
            'version': '3.17.0',
            'name': '我的 MacBook',
          },
        ),
      );
      expect(session.deviceSid, 'd_sid_test');
      expect(session.mid, 'mid_abcdef123');
      expect(session.deviceName, '我的 MacBook');
      expect(session.appVersion, '3.17.0');
      expect(session.isValid, isTrue);
    });

    test('meta 缺席 → deviceName=mobile-browser, appVersion=3.16.2', () {
      final session = DevicePickerScreen.sessionFromDevice(
        _device(mid: 'm1', meta: null),
      );
      expect(session.deviceName, 'mobile-browser');
      expect(session.appVersion, '3.16.2');
    });

    test('meta 缺 name/version → 同样回退', () {
      final session = DevicePickerScreen.sessionFromDevice(
        _device(mid: 'm1', meta: {'platform': 'win32'}),
      );
      expect(session.deviceName, 'mobile-browser');
      expect(session.appVersion, '3.16.2');
    });

    test('mid 缺席 → mid 空串且 isValid=false (UI 应禁点)', () {
      final session = DevicePickerScreen.sessionFromDevice(
        _device(mid: null, meta: {'name': 'X', 'version': '3.16.2'}),
      );
      expect(session.mid, '');
      expect(session.isValid, isFalse);
    });
  });

  group('会话持久化 roundtrip (账号链路字段不丢)', () {
    test('toJson → fromJson 保留 appVersion + 全部字段', () {
      final session = DevicePickerScreen.sessionFromDevice(
        _device(mid: 'mid_x', meta: {'name': 'Dev Box', 'version': '3.16.3'}),
      );
      final restored = ZcodeSession.fromJson(session.toJson());
      expect(restored.appVersion, '3.16.3');
      expect(restored.deviceSid, 'd_sid_test');
      expect(restored.mid, 'mid_x');
      expect(restored.deviceName, 'Dev Box');
      expect(restored.isValid, isTrue);
    });
  });

  group('midSuffix (尾号展示)', () {
    test('长 mid → 后 6 位', () {
      expect(DevicePickerScreen.midSuffix('m-abcdef123456'), '123456');
    });

    test('短 mid → 原样', () {
      expect(DevicePickerScreen.midSuffix('abc123'), 'abc123');
      expect(DevicePickerScreen.midSuffix('ab'), 'ab');
    });

    test('无 mid → 占位符', () {
      expect(DevicePickerScreen.midSuffix(null), '—');
      expect(DevicePickerScreen.midSuffix(''), '—');
    });
  });
}
