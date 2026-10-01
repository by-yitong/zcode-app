import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/features/chat/screens/file_preview_screen.dart';

/// 文件预览页路径解析纯函数单测 (任务卡: AI 消息文件链接 → 可点击预览)
void main() {
  group('parseFileLinkTarget', () {
    test('file:// URI → 去掉 scheme 得本地路径', () {
      final t = parseFileLinkTarget('file:///a/b.dart');
      expect(t.path, '/a/b.dart');
      expect(t.line, isNull);
    });

    test('file:// URI 带行号尾缀 → 剥离并解析行号', () {
      final t = parseFileLinkTarget('file:///a/b.dart:7');
      expect(t.path, '/a/b.dart');
      expect(t.line, 7);
    });

    test('绝对路径 + 尾缀 :42 → path 剥离行号', () {
      final t = parseFileLinkTarget('/a/b.dart:42');
      expect(t.path, '/a/b.dart');
      expect(t.line, 42);
    });

    test('相对路径 + workspace 拼接', () {
      final t = parseFileLinkTarget('lib/x.dart', workspace: '/home/w');
      expect(t.path, '/home/w/lib/x.dart');
      expect(t.line, isNull);
    });

    test('相对路径 ./ 前缀剥离后拼接', () {
      final t = parseFileLinkTarget('./lib/x.dart', workspace: '/home/w');
      expect(t.path, '/home/w/lib/x.dart');
    });

    test('无扩展名路径原样保留', () {
      final t = parseFileLinkTarget('/a/b');
      expect(t.path, '/a/b');
      expect(t.line, isNull);
    });

    test('无扩展名路径 + 行号尾缀', () {
      final t = parseFileLinkTarget('/a/b:3');
      expect(t.path, '/a/b');
      expect(t.line, 3);
    });

    test('非数字尾缀不算行号 (保留在路径中)', () {
      final t = parseFileLinkTarget('/a/b.dart:x');
      expect(t.path, '/a/b.dart:x');
      expect(t.line, isNull);
    });

    test('无 workspace 时相对路径原样返回', () {
      final t = parseFileLinkTarget('lib/x.dart');
      expect(t.path, 'lib/x.dart');
      expect(t.line, isNull);
    });

    test('前后空白与首尾 trim', () {
      final t = parseFileLinkTarget('  /a/b.dart  ');
      expect(t.path, '/a/b.dart');
    });
  });

  group('filePreviewRouteUrl', () {
    test('query 参数正确 encode, line 仅在有值时输出', () {
      expect(
        filePreviewRouteUrl('/a/b.dart'),
        '/file-preview?path=%2Fa%2Fb.dart',
      );
      expect(
        filePreviewRouteUrl('/a/b.dart', workspace: '/home/w', line: 42),
        '/file-preview?path=%2Fa%2Fb.dart&workspace=%2Fhome%2Fw&line=42',
      );
    });
  });
}
