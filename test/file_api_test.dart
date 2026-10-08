// file 通道 typed 封装测试 (假 RPC 缝, 不连真 relay)。
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/core/relay/file_api.dart';

void main() {
  Map<String, dynamic> ok(Object body) => body is Map
      ? Map<String, dynamic>.from(body as Map)
      : {'raw': body};

  test('readdir 解析裸数组 body, isSymbolicLink 缺省 false', () async {
    final calls = <String>[];
    final api = FileApi.direct((channel, method, args) async {
      calls.add('$channel.$method');
      return ok([
        {
          'name': 'lib', 'path': '/ws/lib', 'type': 'directory',
          'isSymbolicLink': false,
        },
        {'name': 'a.txt', 'path': '/ws/a.txt', 'type': 'file'},
        {
          'name': 'link', 'path': '/ws/link', 'type': 'directory',
          'isSymbolicLink': true,
        },
      ]);
    });
    final entries = await api.readdir('/ws');
    expect(calls, ['file.readdir']);
    expect(entries.length, 3);
    expect(entries[0].isSymbolicLink, false);
    expect(entries[2].isSymbolicLink, true);
    expect(entries[1].type, 'file');
  });

  test('readdir 兼容 {entries:[...]} 包裹', () async {
    final api = FileApi.direct((c, m, a) async => ok({
      'entries': [
        {'name': 'x', 'path': '/ws/x', 'type': 'file'},
      ],
    }));
    expect((await api.readdir('/ws')).single.name, 'x');
  });

  test('getIgnoredPaths 兼容裸数组与 {paths} 包裹, wire 参数数组上帧', () async {
    final seen = <dynamic>[];
    final api = FileApi.direct((c, m, args) async {
      seen.add(args);
      return ok(['.git', 'node_modules']);
    });
    expect(
      await api.getIgnoredPaths('/ws', ['/ws/.git']),
      ['.git', 'node_modules'],
    );
    final a2 = FileApi.direct((c, m, a) async => ok({
      'paths': ['dist'],
    }));
    expect(await a2.getIgnoredPaths('/ws', []), ['dist']);
    expect(seen.single, [
      {'workspacePath': '/ws', 'paths': ['/ws/.git']},
    ]);
  });

  test('probeWatcher: 第一候选(file-watcher)成功即命中, rootWatchId 取自 watch 响应', () async {
    final api = FileApi.direct((c, m, a) async => ok({'id': 'w1'}));
    final info = await api.probeWatcher(
      rootPath: '/ws',
      subscribeRaw: (channel, event, listenArgs) async {
        expect(channel, 'file-watcher');
        return const Stream.empty();
      },
    );
    expect(info, isNotNull);
    expect(info!.channel, 'file-watcher');
    expect(info.rootWatchId, 'w1');
    expect(info.listenEvent, 'onDidChange');
  });

  test('probeWatcher: 首候选抛异常降级到 file 通道; 全失败返回 null', () async {
    final api = FileApi.direct((c, m, a) async {
      if (c == 'file-watcher') throw StateError('unknown channel');
      return ok({'id': 'w2'});
    });
    final info = await api.probeWatcher(
      rootPath: '/ws',
      subscribeRaw: (c, e, l) async => const Stream.empty(),
    );
    expect(info?.channel, 'file');
    expect(info?.rootWatchId, 'w2');

    final apiAllFail = FileApi.direct((c, m, a) async => throw StateError('x'));
    expect(
      await apiAllFail.probeWatcher(
        rootPath: '/ws',
        subscribeRaw: (c, e, l) async => const Stream.empty(),
      ),
      isNull,
    );
  });

  test('watchDir 解析 {id}; 失败返回 null 不抛', () async {
    final api = FileApi.direct((c, m, a) async => ok({'id': 'w9'}));
    expect(await api.watchDir(channel: 'file-watcher', path: '/ws/lib'), 'w9');
    final bad = FileApi.direct((c, m, a) async => throw StateError('x'));
    expect(await bad.watchDir(channel: 'file-watcher', path: '/ws/lib'), isNull);
  });

  test('FileWatchEvent.fromBody 兼容 changedPath 直挂与 raw 包裹', () {
    expect(FileWatchEvent.fromBody({'changedPath': '/ws/a'}).changedPath, '/ws/a');
    expect(
      FileWatchEvent.fromBody({'raw': {'changedPath': '/ws/b'}}).changedPath,
      '/ws/b',
    );
    expect(FileWatchEvent.fromBody({}).changedPath, '');
    expect(FileWatchEvent.fromBody(null).changedPath, '');
  });
}
