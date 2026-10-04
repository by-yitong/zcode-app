import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/core/services/pip_service.dart';

// ================================================================
// IPC 契约 v6 编解码测试: 快照可选变形字段 (mo/fx/fy/tw/th)。
// - 纯可选字段, 不 bump kPipSnapshotVersion (保持 1);
// - 老载荷 (无新字段) 解码兼容 (缺省 null = 无变形, v5 瞬时切换);
// - 非法 mo / 残缺坐标对 / 非 num 坐标防御解析回落 null。
// ================================================================

void main() {
  test('契约版本不 bump: kPipSnapshotVersion 保持 1 (v6 纯可选字段)', () {
    expect(kPipSnapshotVersion, 1);
  });

  group('变形字段 round-trip', () {
    test('expand: mo/tw/th 序列化 (仅非空发) 与解码', () {
      final json = jsonEncode(
        const PipSnapshot(
          v: kPipSnapshotVersion,
          index: 0,
          sessions: [
            PipSessionSnapshot(
              key: 'k',
              title: 't',
              running: true,
              error: false,
              text: 'x',
            ),
          ],
          collapsed: false,
          morph: 'expand',
          targetW: 268.8,
          targetH: 160.0,
        ).toJson(),
      );
      // 键名契约: mo/tw/th; collapse 侧键 (fx/fy) 不出现
      final map = jsonDecode(json) as Map<String, dynamic>;
      expect(map['mo'], 'expand');
      expect(map['tw'], 268.8);
      expect(map['th'], 160.0);
      expect(map.containsKey('fx'), isFalse);
      expect(map.containsKey('fy'), isFalse);
      expect(map.containsKey('co'), isFalse, reason: 'collapsed=false 不输出');

      final decoded = PipSnapshot.decode(json)!;
      expect(decoded.morph, 'expand');
      expect(decoded.targetW, 268.8);
      expect(decoded.targetH, 160.0);
      expect(decoded.morphX, isNull);
      expect(decoded.morphY, isNull);
      expect(decoded.collapsed, isFalse);
      expect(decoded.sessions.single.key, 'k');
    });

    test('collapse: mo/fx/fy 序列化与解码 (int 坐标 → double)', () {
      final json = jsonEncode(
        const PipSnapshot(
          v: kPipSnapshotVersion,
          index: 1,
          sessions: [],
          collapsed: true,
          morph: 'collapse',
          morphX: 106,
          morphY: 0,
        ).toJson(),
      );
      final map = jsonDecode(json) as Map<String, dynamic>;
      expect(map['mo'], 'collapse');
      expect(map['fx'], 106);
      expect(map['fy'], 0);
      expect(map['co'], true);
      expect(map.containsKey('tw'), isFalse, reason: 'tw/th 仅 expand 用');

      final decoded = PipSnapshot.decode(json)!;
      expect(decoded.morph, 'collapse');
      expect(decoded.morphX, 106.0);
      expect(decoded.morphY, 0.0);
      expect(decoded.targetW, isNull);
      expect(decoded.targetH, isNull);
      expect(decoded.collapsed, isTrue);
    });

    test('缺省字段不序列化: 无变形时 JSON 不含任何 v6 键', () {
      final json = jsonEncode(
        const PipSnapshot(
          v: kPipSnapshotVersion,
          index: 0,
          sessions: [],
        ).toJson(),
      );
      for (final key in const ['mo', 'fx', 'fy', 'tw', 'th']) {
        expect(json.contains('"$key"'), isFalse, reason: '键 $key 不应出现');
      }
    });
  });

  group('向后兼容与防御解析', () {
    test('老载荷 (v5, 无新字段) 解码: 全部 null = 无变形瞬时切换', () {
      final decoded = PipSnapshot.decode(
        '{"v":1,"index":0,"sessions":[{"key":"k","title":"t","text":"x"}],'
        '"sw":320,"sh":600,"co":true}',
      )!;
      expect(decoded.morph, isNull);
      expect(decoded.morphX, isNull);
      expect(decoded.morphY, isNull);
      expect(decoded.targetW, isNull);
      expect(decoded.targetH, isNull);
      // v5 字段照旧工作
      expect(decoded.collapsed, isTrue);
      expect(decoded.screenW, 320);
      expect(decoded.screenH, 600);
    });

    test('非法 mo 值 → null (仅认 expand/collapse)', () {
      expect(
        PipSnapshot
            .decode('{"v":1,"index":0,"sessions":[],"mo":"bogus"}')
            ?.morph,
        isNull,
      );
      expect(
        PipSnapshot.decode('{"v":1,"index":0,"sessions":[],"mo":123}')?.morph,
        isNull,
      );
    });

    test('坐标对残缺 → 整体视为无变形 (不得拿残缺目标播动画)', () {
      // expand 缺 th
      expect(
        PipSnapshot
            .decode('{"v":1,"index":0,"sessions":[],"mo":"expand","tw":268}')
            ?.morph,
        isNull,
      );
      // expand 缺 tw
      expect(
        PipSnapshot
            .decode('{"v":1,"index":0,"sessions":[],"mo":"expand","th":160}')
            ?.morph,
        isNull,
      );
      // collapse 缺 fy
      expect(
        PipSnapshot
            .decode('{"v":1,"index":0,"sessions":[],"mo":"collapse","fx":80}')
            ?.morph,
        isNull,
      );
      // collapse 缺 fx
      expect(
        PipSnapshot
            .decode('{"v":1,"index":0,"sessions":[],"mo":"collapse","fy":0}')
            ?.morph,
        isNull,
      );
    });

    test('非 num 坐标 → 防御解析回落 null', () {
      // fx 为字符串: morph 配对失败 + 字段本身也是 null
      final decoded = PipSnapshot.decode(
        '{"v":1,"index":0,"sessions":[],"mo":"collapse","fx":"abc","fy":0}',
      )!;
      expect(decoded.morph, isNull);
      expect(decoded.morphX, isNull);
      expect(decoded.morphY, 0.0);
      // tw 为 bool / null 等非 num
      expect(
        PipSnapshot
            .decode('{"v":1,"index":0,"sessions":[],"mo":"expand","tw":true,'
                '"th":160}')
            ?.morph,
        isNull,
      );
      expect(
        PipSnapshot.decode('{"v":1,"index":0,"sessions":[],"fx":true}')
            ?.morphX,
        isNull,
      );
    });
  });
}
