// ZcodeAccountApi 单测 (design §2.1 / §1.1-§1.2):
// - {code,msg,data} 解包: 成功 / code≠0 / 裸对象 / HTTP 401
// - exchangeToken 宽松解析: 顶层 / data 嵌套 / 深层递归 / 缺 zcodeJwtToken
// - issueTerminalToken: 请求形状 (path/body/Bearer) + 两种键名形状
// - listDevices 解析 (displayName 回退 / created_at / online)
// 全部用 dio 拦截器打桩, 不触网。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/network/zcode_account_api.dart';

/// 拦截器打桩响应: 显式状态码 + data (默认 200)
class _Res {
  final int status;
  final Object? data;
  const _Res(this.status, [this.data]);
}

class _ApiStub {
  final requests = <RequestOptions>[];
  Object? Function(RequestOptions)? responder;
  late final ZcodeAccountApi api;

  _ApiStub([this.responder]) {
    api = ZcodeAccountApi(origin: 'http://localhost:9');
    api.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final result = responder?.call(options) ?? const <String, dynamic>{};
          final status = result is _Res ? result.status : 200;
          final data = result is _Res ? result.data : result;
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: status,
              data: data,
            ),
          );
        },
      ),
    );
  }
}

void main() {
  group('buildAuthorizeUrl', () {
    test('chat.z.ai 授权端点 + 固定 client_id/redirect_uri + state', () {
      final api = ZcodeAccountApi();
      final uri = api.buildAuthorizeUrl('st_abc123');
      expect(uri.scheme, 'https');
      expect(uri.host, 'chat.z.ai');
      expect(uri.path, '/api/oauth/authorize');
      expect(uri.queryParameters['redirect_uri'], 'https://zcode.z.ai/remote/v4');
      expect(uri.queryParameters['response_type'], 'code');
      expect(
        uri.queryParameters['client_id'],
        'client_P8X5CMWmlaRO9gyO-KSqtg',
      );
      expect(uri.queryParameters['state'], 'st_abc123');
    });

    test('bigmodel: bigmodel.cn/login + redirect/appId=zcode/state', () {
      final api = ZcodeAccountApi();
      final uri = api.buildAuthorizeUrl(
        'st_bm456',
        provider: OAuthProvider.bigmodel,
      );
      expect(uri.scheme, 'https');
      expect(uri.host, 'bigmodel.cn');
      expect(uri.path, '/login');
      expect(uri.queryParameters['redirect'], 'https://zcode.z.ai/remote/v4');
      expect(uri.queryParameters['appId'], 'zcode');
      expect(uri.queryParameters['state'], 'st_bm456');
      // 不应带 zai 专属参数
      expect(uri.queryParameters.containsKey('client_id'), isFalse);
      expect(uri.queryParameters.containsKey('response_type'), isFalse);
    });

    test('exchangeToken body 带 provider 字段 (bigmodel)', () async {
      final stub = _ApiStub(
        (req) => const {
          'code': 0,
          'data': {
            'zcodeJwtToken': 'jwt_bm',
            'accessToken': 'bm_at',
            'userInfo': {'name': 'bm-user'},
          },
        },
      );
      final set = await stub.api.exchangeToken(
        code: 'c',
        state: 's',
        provider: OAuthProvider.bigmodel,
      );
      expect(set.zcodeJwtToken, 'jwt_bm');
      expect(set.zaiAccessToken, 'bm_at');
      expect(stub.requests.single.data['provider'], 'bigmodel');
    });
  });

  group('issueTerminalToken', () {
    test('请求形状: POST /api/v1/remote/token, body role=terminal, Bearer JWT', () async {
      final stub = _ApiStub(
        (req) => const {
          'code': 0,
          'msg': 'ok',
          'data': {'token': 't_22chars_terminal_tick', 'expires_in': 600},
        },
      );
      final t = await stub.api.issueTerminalToken(jwtOverride: 'jwt-x');

      expect(t.token, 't_22chars_terminal_tick');
      expect(t.expiresIn, 600);
      expect(t.expiresAt, isNull); // 响应未给 expires_at
      expect(t.isExpired, isFalse);

      final req = stub.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.path, '/api/v1/remote/token');
      expect(req.data, {'role': 'terminal'});
      expect(req.headers['Authorization'], 'Bearer jwt-x');
    });

    test('服务端给了 expires_at 时解析为绝对时间', () async {
      final stub = _ApiStub(
        (req) => {
          'code': 0,
          'data': {
            'token': 'tk',
            'expires_in': 30,
            'expires_at': '2020-01-01T00:00:00Z', // 早已过期
          },
        },
      );
      final t = await stub.api.issueTerminalToken(jwtOverride: 'j');
      expect(t.expiresAt, DateTime.parse('2020-01-01T00:00:00Z'));
      expect(t.isExpired, isTrue);
    });

    test('裸对象 + 3.16.2 bundle 键名 (accessToken/expiresIn) 兼容', () async {
      final stub = _ApiStub(
        (req) => const {
          'accessToken': 'bare_token',
          'tokenType': 'Bearer',
          'expiresIn': 300,
        },
      );
      final t = await stub.api.issueTerminalToken(jwtOverride: 'j');
      expect(t.token, 'bare_token');
      expect(t.expiresIn, 300);
      // 裸对象 (无 code 包装) 不应被当作失败
      expect(stub.requests.single.uri.path, '/api/v1/remote/token');
    });

    test('code≠0 抛 Exception(msg)', () async {
      final stub = _ApiStub(
        (req) => const {'code': 1003, 'msg': '登录已过期'},
      );
      await expectLater(
        stub.api.issueTerminalToken(jwtOverride: 'j'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'msg',
            contains('登录已过期'),
          ),
        ),
      );
    });

    test('HTTP 401 → AccountAuthExpiredException', () async {
      final stub = _ApiStub((req) => const _Res(401));
      await expectLater(
        stub.api.issueTerminalToken(jwtOverride: 'j'),
        throwsA(isA<AccountAuthExpiredException>()),
      );
    });

    test('缺 jwtOverride → StateError (编程错误, 不发请求)', () async {
      final stub = _ApiStub();
      await expectLater(
        stub.api.issueTerminalToken(),
        throwsA(isA<StateError>()),
      );
      expect(stub.requests, isEmpty);
    });
  });

  group('listDevices', () {
    test('解析设备列表 + displayName 回退 + epoch 秒解析', () async {
      final stub = _ApiStub(
        (req) => {
          'code': 0,
          'msg': 'ok',
          'data': [
            {
              'device_sid': 'd_mac',
              'device_mid': 'mid_1',
              'online': true,
              'created_at': 1770000000,
              'meta': {
                'platform': 'darwin',
                'version': '3.16.2',
                'name': 'MacBook Pro',
              },
            },
            {'device_sid': 'd_other', 'meta': {'name': ''}},
          ],
        },
      );
      final devices = await stub.api.listDevices(jwtOverride: 'j');

      expect(stub.requests.single.method, 'GET');
      expect(stub.requests.single.uri.path, '/api/v1/remote/device');

      expect(devices.length, 2);
      final d = devices[0];
      expect(d.deviceSid, 'd_mac');
      expect(d.deviceMid, 'mid_1');
      expect(d.online, isTrue);
      expect(d.createdAt, isNotNull);
      expect(d.meta?['version'], '3.16.2');
      expect(d.displayName, 'MacBook Pro');
      // meta.name 空 → 回退 deviceSid; 缺省字段容错
      expect(devices[1].displayName, 'd_other');
      expect(devices[1].deviceMid, isNull);
      expect(devices[1].online, isFalse);
    });
  });

  group('exchangeToken', () {
    test('标准结构 (bundle e7n / 真机实测): JWT=data.token, access_token=data.<provider>', () async {
      final stub = _ApiStub(
        (req) => const {
          'code': 0,
          'msg': 'ok',
          'data': {
            'token': 'jwt_std',
            'bigmodel': {'access_token': 'bm_std'},
            'user': {'id': '1', 'displayName': 'BM用户'},
            'expires_in': 86400,
          },
        },
      );
      final set = await stub.api.exchangeToken(
        code: 'c',
        state: 's',
        provider: OAuthProvider.bigmodel,
      );
      expect(set.zcodeJwtToken, 'jwt_std');
      expect(set.zaiAccessToken, 'bm_std');
      expect(set.userInfo['displayName'], 'BM用户');
    });

    test('请求形状: POST /api/v1/oauth/token, provider=zai + code/state', () async {
      final stub = _ApiStub(
        (req) => const {
          'zcodeJwtToken': 'jwt1',
          'zaiAccessToken': 'zai1',
          'userInfo': {'name': 'u'},
        },
      );
      final set = await stub.api.exchangeToken(code: 'c1', state: 's1');

      final req = stub.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.path, '/api/v1/oauth/token');
      expect(req.data['provider'], 'zai');
      expect(req.data['code'], 'c1');
      expect(req.data['state'], 's1');
      expect(req.data['redirect_uri'], 'https://zcode.z.ai/remote/v4');

      expect(set.zcodeJwtToken, 'jwt1');
      expect(set.zaiAccessToken, 'zai1');
      expect(set.userInfo, {'name': 'u'});
    });

    test('data 嵌套 + 别名键 (accessToken/user_info)', () async {
      final stub = _ApiStub(
        (req) => const {
          'code': 0,
          'msg': 'ok',
          'data': {
            'zcodeJwtToken': 'jwt2',
            'accessToken': 'a2',
            'user_info': {'id': 7},
          },
        },
      );
      final set = await stub.api.exchangeToken(code: 'c', state: 's');
      expect(set.zcodeJwtToken, 'jwt2');
      expect(set.zaiAccessToken, 'a2');
      expect(set.userInfo, {'id': 7});
    });

    test('更深层嵌套递归查找', () async {
      final stub = _ApiStub(
        (req) => const {
          'code': 0,
          'data': {
            'result': {'zcodeJwtToken': 'jwt3'},
          },
        },
      );
      final set = await stub.api.exchangeToken(code: 'c', state: 's');
      expect(set.zcodeJwtToken, 'jwt3');
      expect(set.zaiAccessToken, isNull);
      expect(set.userInfo, isEmpty);
    });

    test('缺 zcodeJwtToken → Exception', () async {
      final stub = _ApiStub((req) => const {'foo': 1});
      await expectLater(
        stub.api.exchangeToken(code: 'c', state: 's'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'msg',
            contains('zcodeJwtToken'),
          ),
        ),
      );
    });

    test('HTTP 401 → AccountAuthExpiredException', () async {
      final stub = _ApiStub((req) => const _Res(401, {'code': 401}));
      await expectLater(
        stub.api.exchangeToken(code: 'c', state: 's'),
        throwsA(isA<AccountAuthExpiredException>()),
      );
    });
  });
}
