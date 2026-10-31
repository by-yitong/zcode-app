// FileTreeController 测试: 假 FileApi + 假 GitApi (缝: fileApiProvider/gitApiProvider)。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/core/relay/file_api.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/providers/file_tree_provider.dart';
import 'package:zcode_app/providers/git_provider.dart';

class FakeFileApi implements FileApi {
  FakeFileApi({
    this.dirs = const {},
    Stream<FileWatchEvent>? rootEvents,
    this.watchOk = true,
  }) : _rootEvents = rootEvents;
  final Map<String, List<FileEntry>> dirs;
  final Stream<FileWatchEvent>? _rootEvents;
  final bool watchOk;
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

  // root 目录挂注入事件流; 子目录 watch 成功但无事件 (足够覆盖展开/收起)。
  @override
  Future<FileWatcherHandle?> watchAndListen(String path) async {
    if (!watchOk) return null;
    return (
      path: path,
      watchId: 'w-${path.hashCode}',
      events: path == '/ws'
          ? (_rootEvents ?? const Stream<FileWatchEvent>.empty())
          : const Stream<FileWatchEvent>.empty(),
      dispose: () {},
    );
  }

  @override
  Future<void> unwatch({required String watchId}) async {}
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

/// readdir 可用 Completer 挂起的 FakeFileApi (模拟慢速 IO, 制造异步恢复点)。
class GatedFileApi extends FakeFileApi {
  GatedFileApi({required this.gate, super.dirs});
  final Completer<void> gate;

  @override
  Future<List<FileEntry>> readdir(String path) =>
      gate.future.then((_) => super.readdir(path));
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
    final c = await makeContainer(
      FakeFileApi(dirs: {'/ws': const []}, watchOk: false),
      FakeGitApi(),
    );
    c.read(fileTreeProvider(ref1));
    await Future<void>.delayed(Duration.zero);
    final s = c.read(fileTreeProvider(ref1));
    expect(s.watcherAvailable, false);
    expect(s.phase, FileTreePhase.ready);
  });

  test('watcher 事件: dirPath 定位已展开目录 → 防抖后自动重载; changedPath 亦可兜底', () async {
    final events = StreamController<FileWatchEvent>();
    final api = FakeFileApi(
      dirs: {
        '/ws': [FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false)],
        '/ws/lib': [FileEntry(name: 'a.dart', path: '/ws/lib/a.dart', type: 'file', isSymbolicLink: false)],
      },
      rootEvents: events.stream,
    );
    final c = await makeContainer(api, FakeGitApi());
    final ctrl = c.read(fileTreeProvider(ref1).notifier);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(fileTreeProvider(ref1)).watcherAvailable, true);

    await ctrl.toggleDir('/ws/lib');
    var before = api.reloaded.length;
    events.add(const FileWatchEvent(dirPath: '/ws/lib', changedPath: '/ws/lib/a.dart'));
    await Future<void>.delayed(const Duration(milliseconds: 400)); // 越过 300ms 防抖
    expect(api.reloaded.length, greaterThan(before));

    // 老形状事件 (无 dirPath): 由 changedPath 父目录推导
    before = api.reloaded.length;
    events.add(const FileWatchEvent(dirPath: '', changedPath: '/ws/lib/b.dart'));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(api.reloaded.length, greaterThan(before));
    await events.close();
  });

  test('异步恢复点 disposed 守卫: 关保活 listen 回收后放行 readdir 不抛', () async {
    final gate = Completer<void>();
    final api = GatedFileApi(dirs: {'/ws': const []}, gate: gate);
    final c = ProviderContainer(overrides: [
      fileApiProvider.overrideWith((ref) => api),
      gitApiProvider.overrideWith((ref) => FakeGitApi()),
    ]);
    addTearDown(c.dispose);
    final keep = c.listen(fileTreeProvider(ref1), (_, _) {}); // 保活 + 创建
    await Future<void>.delayed(Duration.zero); // _init 停在 readdir 挂起点
    keep.close(); // 关监听触发 autoDispose 回收 (不动 ProviderContainer)
    await Future<void>.delayed(Duration.zero); // 先让回收落盘 (notifier.dispose)
    gate.complete(); // 放行 → _init 异步恢复; 有守卫则静默返回, 无守卫抛 StateError
    await Future<void>.delayed(Duration.zero);
  });

  test('showIgnored 开关: 默认隐藏忽略项, 切换后可见 (build 等)', () async {
    final api = FakeFileApi(dirs: {
      '/ws': [
        FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false),
        FileEntry(name: 'build', path: '/ws/build', type: 'directory', isSymbolicLink: false),
        FileEntry(name: 'a.dart', path: '/ws/a.dart', type: 'file', isSymbolicLink: false),
      ],
    });
    final git = FakeGitApi(ignored: ['/ws/build']);
    final c = await makeContainer(api, git);
    c.read(fileTreeProvider(ref1));
    await Future<void>.delayed(Duration.zero);
    var s = c.read(fileTreeProvider(ref1));
    expect(s.roots.keys.toList(), isNot(contains('/ws/build'))); // 默认隐藏
    expect(s.roots.keys.toSet(), containsAll(['/ws/lib', '/ws/a.dart']));

    await c.read(fileTreeProvider(ref1).notifier).toggleShowIgnored();
    await Future<void>.delayed(Duration.zero);
    s = c.read(fileTreeProvider(ref1));
    expect(s.roots.keys.toSet(), containsAll(['/ws/build', '/ws/lib', '/ws/a.dart']));
  });

  test('refresh 重拉根 + 已展开目录 + git 状态', () async {
    final api = FakeFileApi(dirs: {
      '/ws': [FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false)],
      '/ws/lib': [
        FileEntry(name: 'sub', path: '/ws/lib/sub', type: 'directory', isSymbolicLink: false),
      ],
      '/ws/lib/sub': [
        FileEntry(name: 'x.dart', path: '/ws/lib/sub/x.dart', type: 'file', isSymbolicLink: false),
      ],
    });
    final c = await makeContainer(api, FakeGitApi());
    final ctrl = c.read(fileTreeProvider(ref1).notifier);
    await Future<void>.delayed(Duration.zero);
    await ctrl.toggleDir('/ws/lib');
    await ctrl.toggleDir('/ws/lib/sub');
    api.reloaded.clear();
    await ctrl.refresh();
    expect(api.reloaded, containsAll(['/ws', '/ws/lib', '/ws/lib/sub']));
  });
}
