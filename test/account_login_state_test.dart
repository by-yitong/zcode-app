// 账号登录 state/回调纯逻辑单测 (design §1.1, 任务卡 #2):
// - nonce 生成 (uuid v4 去横线) / state 编码 (base64url(JSON{nonce}))
// - state 解码与校验 (CSRF): roundtrip / 非法输入 / nonce 不一致
// - OAuth 回调判定与解析: code+state / error / 非回调 URL
// 只测 AccountLoginScreen 上的静态纯函数, 不触网不碰 WebView。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/features/auth/screens/account_login_screen.dart';

void main() {
  group('generateNonce', () {
    test('uuid v4 去横线: 32 位小写 hex', () {
      final n = AccountLoginScreen.generateNonce();
      expect(n.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(n), isTrue);
    });

    test('两次生成不重复', () {
      final a = AccountLoginScreen.generateNonce();
      final b = AccountLoginScreen.generateNonce();
      expect(a, isNot(b));
    });
  });

  group('encodeState / extractNonce', () {
    test('roundtrip: 解回原 nonce', () {
      final state = AccountLoginScreen.encodeState('nonce_abc123');
      expect(AccountLoginScreen.extractNonce(state), 'nonce_abc123');
    });

    test('state 是无 padding 的 base64url(JSON{nonce})', () {
      final state = AccountLoginScreen.encodeState('hello');
      // base64url 字母表, 不含 '=' padding
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(state), isTrue);
      // 补齐 padding 解码后应为 {"nonce":"hello"}
      final padded = state + '=' * ((4 - state.length % 4) % 4);
      final decoded = utf8.decode(base64Url.decode(padded));
      expect(jsonDecode(decoded), {'nonce': 'hello'});
    });

    test('非法输入 → null', () {
      expect(AccountLoginScreen.extractNonce(''), isNull); // 空串
      expect(AccountLoginScreen.extractNonce('!!!!'), isNull); // 非法字符
      // 合法 base64 但不是 JSON
      expect(
        AccountLoginScreen.extractNonce(
          base64Url.encode(utf8.encode('not json')).replaceAll('=', ''),
        ),
        isNull,
      );
      // JSON 显式无 nonce 键
      final noNonce = base64Url
          .encode(utf8.encode('{"foo":1}'))
          .replaceAll('=', '');
      expect(AccountLoginScreen.extractNonce(noNonce), isNull);
      // nonce 为空串
      final emptyNonce = base64Url
          .encode(utf8.encode('{"nonce":""}'))
          .replaceAll('=', '');
      expect(AccountLoginScreen.extractNonce(emptyNonce), isNull);
    });
  });

  group('verifyState (CSRF 校验)', () {
    test('state nonce 一致 → true', () {
      final state = AccountLoginScreen.encodeState('expected');
      expect(AccountLoginScreen.verifyState(state, 'expected'), isTrue);
    });

    test('nonce 不一致 → false', () {
      final state = AccountLoginScreen.encodeState('attacker');
      expect(AccountLoginScreen.verifyState(state, 'victim'), isFalse);
    });

    test('期望 nonce 为空 → false (拒绝空校验)', () {
      final state = AccountLoginScreen.encodeState('');
      expect(AccountLoginScreen.verifyState(state, ''), isFalse);
    });

    test('state 非法 → false', () {
      expect(AccountLoginScreen.verifyState('garbage!!', 'x'), isFalse);
    });
  });

  group('isOAuthCallback', () {
    test('zcode.z.ai/remote/v4 (含参) → true', () {
      expect(
        AccountLoginScreen.isOAuthCallback(
          Uri.parse('https://zcode.z.ai/remote/v4?code=c&state=s'),
        ),
        isTrue,
      );
    });

    test('带 /cn 语言前缀的回调 (服务器 302 实测形态) → true', () {
      expect(
        AccountLoginScreen.isOAuthCallback(
          Uri.parse('https://zcode.z.ai/cn/remote/v4?code=c&state=s'),
        ),
        isTrue,
      );
    });

    test('其他 host / 无 code 无 error → false', () {
      expect(
        AccountLoginScreen.isOAuthCallback(
          Uri.parse('https://chat.z.ai/remote/v4?code=c'),
        ),
        isFalse,
      );
      // host 对但没有 code/error 参数 (如 SPA 内部导航) → 不是回调
      expect(
        AccountLoginScreen.isOAuthCallback(
          Uri.parse('https://zcode.z.ai/remote/v4?sid=d_x&mid=m'),
        ),
        isFalse,
      );
      expect(
        AccountLoginScreen.isOAuthCallback(
          Uri.parse('https://zcode.z.ai/api/v1/remote/device'),
        ),
        isFalse,
      );
    });
  });

  group('parseCallback', () {
    test('code + state 提取', () {
      final cb = AccountLoginScreen.parseCallback(
        Uri.parse('https://zcode.z.ai/remote/v4?code=AUTHCODE&state=ST123'),
      );
      expect(cb, isNotNull);
      expect(cb!.code, 'AUTHCODE');
      expect(cb.state, 'ST123');
      expect(cb.error, isNull);
    });

    test('state 缺席 → 空串', () {
      final cb = AccountLoginScreen.parseCallback(
        Uri.parse('https://zcode.z.ai/remote/v4?code=AUTHCODE'),
      );
      expect(cb!.state, '');
    });

    test('bigmodel 回调参数名 authCode → 等价映射为 code (真机实测)', () {
      final cb = AccountLoginScreen.parseCallback(
        Uri.parse(
          'https://zcode.z.ai/remote/v4?authCode=BM_CODE_123&state=ST_BM',
        ),
      );
      expect(cb, isNotNull);
      expect(cb!.code, 'BM_CODE_123');
      expect(cb.state, 'ST_BM');
    });

    test('error 参数 → 失败结果', () {
      final cb = AccountLoginScreen.parseCallback(
        Uri.parse('https://zcode.z.ai/remote/v4?error=access_denied'),
      );
      expect(cb!.error, 'access_denied');
      expect(cb.code, isNull);
    });

    test('非回调 URL / 回调无 code 无 error → null', () {
      expect(
        AccountLoginScreen.parseCallback(
          Uri.parse('https://chat.z.ai/api/oauth/authorize?x=1'),
        ),
        isNull,
      );
      expect(
        AccountLoginScreen.parseCallback(
          Uri.parse('https://zcode.z.ai/remote/v4'),
        ),
        isNull,
      );
    });
  });
}
