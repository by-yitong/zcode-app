// FileTreeController 测试: 假 FileApi + 假 GitApi (缝: fileApiProvider/gitApiProvider)。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/core/relay/file_api.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/providers/file_tree_provider.dart';
import 'package:zcode_app/providers/git_provider.dart';

class FakeFileApi implements FileApi {
  FakeFileApi({this.dirs = const {}, this.watcher});
  final Map<String, List<FileEntry>> dirs;
  final FileWatcherInfo? watcher;
  final reloaded = <String>[];

  @override
  Future<List<FileEntry>> readdir(String path) async {
    if (path.contains('boom')) throw StateError('readdir failed');
    reloaded.add(path);
    return dirs[path] ?? const [];
  }

  // controller 走 gitApiProvider 的 getIgnoredPaths; 此处仅满足接口。
  @override
  Future<List<String>> getIgnoredPaths(
    String workspacePath,
    List<String> paths,
  ) async =>
      const [];

  @override
  Future<FileWatcherInfo?> probeWatcher({
    required String rootPath,
    RawSubscribeFn? subscribeRaw,
  }) =>
      Future.value(watcher);

  @override
  Future<String?> watchDir({required String channel, required String path}) async => 'w-${path.hashCode}';

  @override
  Future<void> unwatch({required String channel, required String watchId}) async {}
}

class FakeGitApi implements GitApi {
  FakeGitApi({this.changes = const [], this.ignored = const []});
  final List<GitChange> changes;
  final List<String> ignored;

  @override
  Future<List<GitChange>> getChanges(String workspacePath, String sourceId) async =>
      sourceId == 'branch' ? const [] : changes;

  @override
  Future<List<String>> getIgnoredPaths(String ws, List<String> paths) async =>
      ignored.where(paths.contains).toList();

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName} 未在测试中使用');
}

const ref1 = FileTreeRef(workspacePath: '/ws');

Future<ProviderContainer> makeContainer(FakeFileApi api, FakeGitApi git) async {
  final c = ProviderContainer(overrides: [
    fileApiProvider.overrideWith((ref) => api),
    gitApiProvider.overrideWith((ref) => git),
  ]);
  addTearDown(c.dispose);
  // autoDispose provider 无监听者时 read 返回即被回收 (notifier 随后写入
  // state 会抛 dispose 后使用), 挂空监听保活; 生命周期由 tearDown 收口。
  c.listen(fileTreeProvider(ref1), (_, _) {});
  return c;
}

void main() {
  test('首拉: 根目录排序载入 + ignored 过滤 + git 状态并行就绪', () async {
    final api = FakeFileApi(dirs: {
      '/ws': [
        FileEntry(name: 'b.dart', path: '/ws/b.dart', type: 'file', isSymbolicLink: false),
        FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false),
      ],
    });
    final git = FakeGitApi(changes: [
      GitChange.fromJson({
        'path': '/ws/b.dart', 'repoRelativePath': 'b.dart',
        'workspaceRelativePath': 'b.dart', 'kind': 'modified',
      }),
    ], ignored: ['/ws/b.dart']);
    final c = await makeContainer(api, git);
    c.read(fileTreeProvider(ref1));
    await Future<void>.delayed(Duration.zero);
    final s = c.read(fileTreeProvider(ref1));
    expect(s.phase, FileTreePhase.ready);
    expect(s.roots.keys.toList(), ['/ws/lib']); // b.dart 被忽略过滤
    expect(s.statusByPath['b.dart'], 'M');
  });

  test('toggleDir 懒加载子目录; 子层过滤 ignored; 读目录失败落 node.error', () async {
    final api = FakeFileApi(dirs: {
      '/ws': [
        FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false),
        FileEntry(name: 'boom', path: '/ws/boom', type: 'directory', isSymbolicLink: false),
      ],
      '/ws/lib': [
        FileEntry(name: 'node_modules', path: '/ws/lib/node_modules', type: 'directory', isSymbolicLink: false),
        FileEntry(name: 'a.dart', path: '/ws/lib/a.dart', type: 'file', isSymbolicLink: false),
      ],
    });
    final git = FakeGitApi(ignored: ['/ws/lib/node_modules']);
    final c = await makeContainer(api, git);
    final ctrl = c.read(fileTreeProvider(ref1).notifier);
    await Future<void>.delayed(Duration.zero);

    await ctrl.toggleDir('/ws/lib');
    var s = c.read(fileTreeProvider(ref1));
    expect(s.roots['/ws/lib']!.expanded, true);
    expect(s.roots['/ws/lib']!.children.keys.toList(), ['/ws/lib/a.dart']);

    await ctrl.toggleDir('/ws/boom');
    s = c.read(fileTreeProvider(ref1));
    expect(s.roots['/ws/boom']!.error, isNotNull);
  });

  test('watcher 探测失败 → watcherAvailable=false, 其余功能不受损', () async {
    final c = await makeContainer(FakeFileApi(dirs: {'/ws': const []}), FakeGitApi());
    c.read(fileTreeProvider(ref1));
    await Future<void>.delayed(Duration.zero);
    final s = c.read(fileTreeProvider(ref1));
    expect(s.watcherAvailable, false);
    expect(s.phase, FileTreePhase.ready);
  });

  test('watcher 事件: changedPath 父目录已展开 → 防抖后自动重载该目录', () async {
    final events = StreamController<FileWatchEvent>();
    final info = (
      channel: 'file-watcher',
      listenEvent: 'onDidChange',
      events: events.stream,
      rootWatchId: 'w1',
    );
    final api = FakeFileApi(
      dirs: {
        '/ws': [FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false)],
        '/ws/lib': [FileEntry(name: 'a.dart', path: '/ws/lib/a.dart', type: 'file', isSymbolicLink: false)],
      },
      watcher: info,
    );
    final c = await makeContainer(api, FakeGitApi());
    final ctrl = c.read(fileTreeProvider(ref1).notifier);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(fileTreeProvider(ref1)).watcherAvailable, true);

    await ctrl.toggleDir('/ws/lib');
    final before = api.reloaded.length;
    events.add(const FileWatchEvent(changedPath: '/ws/lib/a.dart'));
    await Future<void>.delayed(const Duration(milliseconds: 400)); // 越过 300ms 防抖
    expect(api.reloaded.length, greaterThan(before));
    await events.close();
  });

  test('refresh 重拉根 + 已展开目录 + git 状态', () async {
    final api = FakeFileApi(dirs: {
      '/ws': [FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false)],
      '/ws/lib': const [],
    });
    final c = await makeContainer(api, FakeGitApi());
    final ctrl = c.read(fileTreeProvider(ref1).notifier);
    await Future<void>.delayed(Duration.zero);
    await ctrl.toggleDir('/ws/lib');
    api.reloaded.clear();
    await ctrl.refresh();
    expect(api.reloaded, containsAll(['/ws', '/ws/lib']));
  });
}
