import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// V4 附件上传 checksum wire 契约回归。
///
/// 服务端 (桌面端 3.14.4 共享协议层) 对 attachmentBeginV4.checksum 的
/// zod 校验为严格正则 `^sha256:[0-9a-f]{64}$` — 必须带 `sha256:` 前缀,
/// 且为小写 hex。曾因发裸 hex 导致上传 100% 被拒 (「图片上传失败」)。
void main() {
  // 桌面端 zod: checksum: z.string().regex(/^sha256:[0-9a-f]{64}$/)
  final serverPattern = RegExp(r'^sha256:[0-9a-f]{64}$');

  bool serverAccepts(String checksum) => serverPattern.hasMatch(checksum);

  test('裸 hex checksum (旧实现) 被服务端拒绝', () {
    final bare = sha256.convert(utf8.encode('hello')).toString();
    expect(serverAccepts(bare), isFalse);
  });

  test('sha256: 前缀 checksum (网页端同款) 被服务端接受', () {
    final bare = sha256.convert(utf8.encode('hello')).toString();
    expect(serverAccepts('sha256:$bare'), isTrue);
  });

  test('大写 hex 被拒 (正则限定小写)', () {
    final bare = sha256.convert(utf8.encode('hello')).toString();
    expect(serverAccepts('sha256:${bare.toUpperCase()}'), isFalse);
  });
}
