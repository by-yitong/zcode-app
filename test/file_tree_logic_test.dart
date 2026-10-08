// 文件树纯逻辑: 排序/相对路径/状态映射/角标聚合/可见行过滤。
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/core/relay/file_api.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/providers/file_tree_provider.dart';

FileEntry dir(String p) => FileEntry(
  name: p.split('/').last, path: p, type: 'directory', isSymbolicLink: false,
);
FileEntry file(String p) => FileEntry(
  name: p.split('/').last, path: p, type: 'file', isSymbolicLink: false,
);

void main() {
  test('relativePathOf 剥工作区前缀与首斜杠', () {
    expect(relativePathOf('/ws/lib/a.dart', '/ws'), 'lib/a.dart');
    expect(relativePathOf('/ws', '/ws'), '');
    expect(relativePathOf('/other/x', '/ws'), '/other/x');
  });

  test('entrySortCompare: 目录(含符号链接目录)先 + ASCII 序(大写在前)', () {
    final link = FileEntry(
      name: 'zz', path: '/ws/zz', type: 'directory', isSymbolicLink: true,
    );
    final entries = [
      file('b.dart'), file('A.txt'), dir('m'), link, file('a.dart'),
    ];
    final sorted = [...entries]..sort(entrySortCompare);
    expect(sorted.map((e) => e.name).toList(),
        ['m', 'zz', 'A.txt', 'a.dart', 'b.dart']);
  });

  test('buildStatusByPath: workspaceRelativePath 优先, 字母映射与 untracked', () {
    GitChange ch(String rel, String kind, {bool untracked = false}) =>
        GitChange.fromJson({
          'path': '/repo/$rel',
          'repoRelativePath': rel,
          'workspaceRelativePath': rel,
          'kind': kind,
          'isUntracked': untracked,
        });
    final s = buildStatusByPath([
      ch('lib/a.dart', 'modified'),
      ch('new.txt', 'added', untracked: true),
      ch('gone.txt', 'deleted'),
      ch('r.txt', 'renamed'),
    ]);
    expect(s, {'lib/a.dart': 'M', 'new.txt': 'U', 'gone.txt': 'D', 'r.txt': 'R'});
  });

  test('dirBadges: 祖先目录聚合并取最重状态 (U<M<D), 根层文件不产生角标', () {
    final badges = dirBadges({
      'lib/a.dart': 'M',
      'lib/sub/b.txt': 'D',
      'new.txt': 'U',
    });
    expect(badges['lib'], 'D');
    expect(badges['lib/sub'], 'D');
    expect(badges.containsKey('new.txt'), false);
  });

  test('visibleRows: changedOnly 只留命中文件 + 命中祖先目录 (未展开目录按前缀命中)', () {
    final roots = {
      '/ws/a': FileTreeNode(entry: dir('/ws/a'), children: {
        '/ws/a/b.dart': FileTreeNode(entry: file('/ws/a/b.dart')),
      }),
      '/ws/top.md': FileTreeNode(entry: file('/ws/top.md')),
    };
    final rows = visibleRows(
      roots: roots,
      workspacePath: '/ws',
      statusByPath: {'a/b.dart': 'M'},
      changedOnly: true,
      search: '',
    );
    // a 目录: 未展开但子树有变更 → 前缀命中保留; top.md 无变更 → 剪枝
    expect(rows.map((r) => r.$1.entry.name), ['a']);
    expect(rows.single.$2, 0);
  });

  test('visibleRows: search 过滤按名称且保祖先链; 关闭 changedOnly 后全部可见', () {
    final roots = {
      '/ws/a': FileTreeNode(entry: dir('/ws/a'), children: {
        '/ws/a/needle.dart': FileTreeNode(entry: file('/ws/a/needle.dart')),
        '/ws/a/other.dart': FileTreeNode(entry: file('/ws/a/other.dart')),
      }),
    };
    final rows = visibleRows(
      roots: roots,
      workspacePath: '/ws',
      statusByPath: const {},
      changedOnly: false,
      search: 'needle',
    );
    expect(rows.map((r) => r.$1.entry.name), ['a', 'needle.dart']);
    expect(rows[1].$2, 1);

    final all = visibleRows(
      roots: roots,
      workspacePath: '/ws',
      statusByPath: const {},
      changedOnly: false,
      search: '',
    );
    expect(all.length, 1); // 只有 'a': 未展开不深入(all 模式)
  });
}
