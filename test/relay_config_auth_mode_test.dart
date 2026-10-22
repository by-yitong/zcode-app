// RelayConfig 账号链路构造 + ZcodeSession/账号存储 单测 (桌面端 3.16+, design §2.2/§2.3):
// - RelayConfig.forAccount 工厂: ws2 URL + mid 携带 + 闭包透传
// - wsUrlWithToken: token/mid 查询参数追加
// - RelayClient.connect 前置校验: terminalTokenFetcher 必需 / 未登录 /
//   401 (AccountAuthExpiredException) 原样上抛 — 均在网络 IO 前抛出, 不触网
// - ZcodeSession: 字段 + JSON 往返 (旧存储多余键忽略) + isValid
// - SecureStorageService/AuthRepository 账号凭据 + lastDevice 读写 (fake FlutterSecureStorage)
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/network/zcode_account_api.dart';
import 'package:zcode_app/core/relay/relay_client.dart';
import 'package:zcode_app/core/storage/secure_storage.dart';
import 'package:zcode_app/data/models/zcode_account.dart';
import 'package:zcode_app/data/models/zcode_session.dart';
import 'package:zcode_app/data/repositories/repositories.dart';

/// 内存版 FlutterSecureStorage (只覆写 read/write/delete, 不触 platform channel)
class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }
}

void main() {
  group('RelayConfig.forAccount (3.16+ 账号链路)', () {
    test('工厂: ws2 URL + mid 携带 + 默认值', () {
      final c = RelayConfig.forAccount(deviceSid: 'd_9', mid: 'mid_9');
      expect(c.wsUrl, 'wss://zcode.z.ai/api/v1/remote/ws2');
      expect(c.mid, 'mid_9');
      expect(c.deviceSid, 'd_9');
      expect(c.deviceName, 'mobile-browser');
      expect(c.appVersion, '3.16.2');
      expect(c.jwtProvider, isNull);
      expect(c.terminalTokenFetcher, isNull);
    });

    test('工厂: jwtProvider / terminalTokenFetcher / appVersion 透传', () async {
      final c = RelayConfig.forAccount(
        deviceSid: 'd',
        mid: 'm',
        appVersion: '3.16.2-beta',
        jwtProvider: () async => 'jwt-from-storage',
        terminalTokenFetcher: (jwt) async => 'tt_$jwt',
      );
      expect(await c.jwtProvider!(), 'jwt-from-storage');
      expect(await c.terminalTokenFetcher!('x'), 'tt_x');
      expect(c.appVersion, '3.16.2-beta');
    });

    test('主构造: 账号字段直接构造 (等价 forAccount)', () {
      final c = RelayConfig(
        wsUrl: 'wss://zcode.z.ai/api/v1/remote/ws2',
        deviceSid: 'd_1',
        mid: 'm_1',
      );
      expect(c.wsUrl, 'wss://zcode.z.ai/api/v1/remote/ws2');
      expect(c.deviceSid, 'd_1');
      expect(c.mid, 'm_1');
      expect(c.appVersion, '3.16.2');
    });
  });

  group('RelayConfig.wsUrlWithToken', () {
    test('无既有查询参数: 追加 ?token=&mid=', () {
      expect(
        RelayConfig.wsUrlWithToken(
          'wss://zcode.z.ai/api/v1/remote/ws2',
          token: 'tk',
          mid: 'm1',
        ),
        'wss://zcode.z.ai/api/v1/remote/ws2?token=tk&mid=m1',
      );
    });

    test('已有查询参数: 续接不破坏', () {
      expect(
        RelayConfig.wsUrlWithToken(
          'wss://zcode.z.ai/api/v1/remote/ws2?x=1',
          token: 'tk',
          mid: 'm1',
        ),
        'wss://zcode.z.ai/api/v1/remote/ws2?x=1&token=tk&mid=m1',
      );
    });

    test('mid 为空时只追加 token', () {
      expect(
        RelayConfig.wsUrlWithToken(
          'wss://zcode.z.ai/api/v1/remote/ws2',
          token: 'tk',
        ),
        'wss://zcode.z.ai/api/v1/remote/ws2?token=tk',
      );
    });
  });

  group('RelayClient.connect 账号凭据前置校验 (网络 IO 前抛出)', () {
    test('terminalTokenFetcher 未配置 → StateError', () async {
      final relay = RelayClient(
        config: RelayConfig.forAccount(
          deviceSid: 'd',
          mid: 'm',
          jwtProvider: () async => 'jwt-ok',
        ),
      );
      try {
        await expectLater(relay.connect(), throwsStateError);
      } finally {
        relay.dispose();
      }
    });

    test('jwtProvider 返回 null (未登录) → AccountAuthExpiredException', () async {
      final relay = RelayClient(
        config: RelayConfig.forAccount(
          deviceSid: 'd',
          mid: 'm',
          jwtProvider: () async => null,
          terminalTokenFetcher: (jwt) async => 'tt',
        ),
      );
      try {
        await expectLater(
          relay.connect(),
          throwsA(isA<AccountAuthExpiredException>()),
        );
      } finally {
        relay.dispose();
      }
    });

    test('换票 401 → AccountAuthExpiredException 原样上抛', () async {
      final relay = RelayClient(
        config: RelayConfig.forAccount(
          deviceSid: 'd',
          mid: 'm',
          jwtProvider: () async => 'jwt-stale',
          terminalTokenFetcher: (jwt) async =>
              throw AccountAuthExpiredException('401'),
        ),
      );
      try {
        await expectLater(
          relay.connect(),
          throwsA(
            isA<AccountAuthExpiredException>().having(
              (e) => e.message,
              'message',
              '401',
            ),
          ),
        );
      } finally {
        relay.dispose();
      }
    });
  });

  group('ZcodeSession (账号链路形态)', () {
    test('isValid: deviceSid + mid 非空', () {
      expect(
        ZcodeSession(mid: 'm', deviceSid: 'd').isValid,
        isTrue,
      );
      expect(ZcodeSession(mid: '', deviceSid: 'd').isValid, isFalse); // 缺 mid
      expect(ZcodeSession(mid: 'm', deviceSid: '').isValid, isFalse); // 缺 sid
    });

    test('JSON 往返: 四字段保留', () {
      final session = ZcodeSession(
        mid: 'm',
        deviceSid: 'd',
        deviceName: 'my-phone',
        appVersion: '3.16.2',
      );
      final round = ZcodeSession.fromJson(session.toJson());
      expect(round.mid, 'm');
      expect(round.deviceSid, 'd');
      expect(round.deviceName, 'my-phone');
      expect(round.appVersion, '3.16.2');
      expect(round.isValid, isTrue);
    });

    test('fromJson 兼容旧存储: 忽略旧链路遗留的多余键', () {
      final restored = ZcodeSession.fromJson({
        'mid': 'm',
        'deviceSid': 'd',
        // 旧链路遗留字段 (已废弃) — 应被整体忽略
        'legacyCredential': 'x',
        'legacyCookie': 'y',
        'legacyAuthMode': 'z',
        'deviceName': 'phone',
        'appVersion': '3.16.2',
        'createdAt': '2026-01-01T00:00:00.000',
      });
      expect(restored.mid, 'm');
      expect(restored.deviceSid, 'd');
      expect(restored.deviceName, 'phone');
      expect(restored.appVersion, '3.16.2');
      expect(restored.isValid, isTrue);
      // 新序列化只含四字段
      expect(
        restored.toJson().keys.toSet(),
        {'mid', 'deviceSid', 'deviceName', 'appVersion'},
      );
    });
  });

  group('账号凭据 + 会话 + lastDevice 存储 (design §2.3)', () {
    late _FakeSecureStorage fake;
    late SecureStorageService storage;
    late AuthRepository repo;

    setUp(() {
      fake = _FakeSecureStorage();
      storage = SecureStorageService(fake);
      repo = AuthRepository(storage);
    });

    test('未登录 restoreAccount → null', () async {
      expect(await repo.restoreAccount(), isNull);
    });

    test('saveAccount → restoreAccount 往返 (jwt + userInfo)', () async {
      await repo.saveAccount(
        const ZcodeAccount(jwt: 'jwt_tok', userInfo: {'name': 'u', 'id': 1}),
      );
      // 落到约定的 key 上
      expect(fake.store.containsKey('zcode_account_jwt'), isTrue);
      expect(fake.store.containsKey('zcode_account_user'), isTrue);

      final restored = await repo.restoreAccount();
      expect(restored, isNotNull);
      expect(restored!.jwt, 'jwt_tok');
      expect(restored.userInfo, {'name': 'u', 'id': 1});
    });

    test('clearAccount 清空凭据', () async {
      await repo.saveAccount(const ZcodeAccount(jwt: 'j'));
      await repo.clearAccount();
      expect(await repo.restoreAccount(), isNull);
      expect(fake.store.containsKey('zcode_account_jwt'), isFalse);
    });

    test('userInfo 损坏不影响登录态', () async {
      await fake.write(key: 'zcode_account_jwt', value: 'jwt_ok');
      await fake.write(key: 'zcode_account_user', value: '{not-json');
      final account = await storage.getAccount();
      expect(account, isNotNull);
      expect(account!.jwt, 'jwt_ok');
      expect(account.userInfo, isEmpty);
    });

    test('saveSession → restoreSession → clearSession (新模型往返)', () async {
      expect(await repo.restoreSession(), isNull);

      await repo.saveSession(
        ZcodeSession(
          mid: 'm1',
          deviceSid: 'd_1',
          deviceName: 'dev-box',
          appVersion: '3.16.2',
        ),
      );
      final restored = await repo.restoreSession();
      expect(restored, isNotNull);
      expect(restored!.mid, 'm1');
      expect(restored.deviceSid, 'd_1');
      expect(restored.deviceName, 'dev-box');
      expect(restored.isValid, isTrue);

      await repo.clearSession();
      expect(await repo.restoreSession(), isNull);
    });

    test('lastDevice 读写清 (key zcode_last_device)', () async {
      expect(await storage.getLastDevice(), isNull);

      final device = {
        'deviceSid': 'd_9',
        'deviceMid': 'mid_9',
        'deviceName': 'MacBook',
        'appVersion': '3.16.2',
      };
      await storage.saveLastDevice(device);
      expect(fake.store.containsKey('zcode_last_device'), isTrue);
      expect(await storage.getLastDevice(), device);

      await storage.clearLastDevice();
      expect(await storage.getLastDevice(), isNull);
      expect(fake.store.containsKey('zcode_last_device'), isFalse);
    });

    test('lastDevice 数据损坏 → null (不抛)', () async {
      await fake.write(key: 'zcode_last_device', value: '{not-json');
      expect(await storage.getLastDevice(), isNull);
    });
  });
}
