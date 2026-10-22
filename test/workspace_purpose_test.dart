import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/data/models/workspace.dart';

/// 3.16 workspacePurpose 解析 + 项目列表过滤 (对齐网页「对话」分区)
void main() {
  group('Workspace.workspacePurpose', () {
    test("purpose=conversation → isConversation=true, 不进项目列表", () {
      final resp = {
        'result': {
          'workspaces': [
            {
              'workspacePath': '/home/u/proj-a',
              'kind': 'local',
              'workspacePurpose': 'project',
            },
            {
              'workspacePath': '/home/u/.zcode/workspace/draft-abc123',
              'kind': 'local',
              'workspacePurpose': 'conversation',
            },
          ],
        },
      };
      final list = Workspace.parseList(resp);
      expect(list.length, 1);
      expect(list.first.workspacePath, '/home/u/proj-a');
      expect(list.first.isConversation, isFalse);
    });

    test('旧协议无 purpose 键 → 全部保留 (兼容 <3.16)', () {
      final resp = {
        'result': {
          'workspaces': [
            {'workspacePath': '/a', 'kind': 'local'},
            {'workspacePath': '/b', 'kind': 'remote'},
          ],
        },
      };
      expect(Workspace.parseList(resp).length, 2);
    });

    test('非法 purpose 值 → 当 null 处理 (不误过滤)', () {
      final w = Workspace.fromJson({
        'workspacePath': '/x',
        'workspacePurpose': 'weird-value',
      });
      expect(w.purpose, isNull);
      expect(w.isConversation, isFalse);
    });

    test('purpose 缺省但路径是 draft- 形态 → 仍保留 (以服务端字段为准)', () {
      // 3.16 一定带 purpose; 只按字段过滤, 不按路径猜 — 避免误伤
      // 用户真实名为 draft-xxx 的项目
      final w = Workspace.fromJson({
        'workspacePath': '/home/u/draft-looks-like',
      });
      expect(w.isConversation, isFalse);
    });
  });
}
