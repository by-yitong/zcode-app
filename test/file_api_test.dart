// file 通道 typed 封装测试 (假 RPC 缝, 不连真 relay)。
import 'dart:async';

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

  test('watchAndListen: 先 watch 拿 id 再 LISTEN(id 标量), 事件名实证 onDynamicChange', () async {
    final order = <String>[];
    String? listenArgs;
    final api = FileApi.direct(
      (c, m, a) async {
        order.add('$c.$m');
        return ok({'id': 'w1'});
      },
      listenRaw: (channel, event, args) {
        order.add('LISTEN $channel.$event');
        listenArgs = args;
        return (stream: const Stream.empty(), dispose: () {});
      },
    );
    final h = await api.watchAndListen('/ws');
    expect(order, ['file-watcher.watch', 'LISTEN file-watcher.onDynamicChange']);
    expect(h, isNotNull);
    expect(h!.path, '/ws');
    expect(h.watchId, 'w1');
    expect(listenArgs, 'w1'); // 抓包实证: LISTEN 参数是 watchId 标量
  });

  test('watchAndListen: watch 抛异常或无 id 返回 null 不抛', () async {
    final api = FileApi.direct((c, m, a) async => throw StateError('x'));
    expect(await api.watchAndListen('/ws'), isNull);
    final noId = FileApi.direct((c, m, a) async => ok({'foo': 1}));
    expect(await noId.watchAndListen('/ws'), isNull);
  });

  test('watchAndListen: 事件流经 FileWatchEvent.fromBody (dirPath+changedPath)', () async {
    late StreamController<Map<String, dynamic>> ctrl;
    final api = FileApi.direct(
      (c, m, a) async => ok({'id': 'w5'}),
      listenRaw: (c, e, l) {
        ctrl = StreamController<Map<String, dynamic>>();
        return (stream: ctrl.stream, dispose: () {});
      },
    );
    final h = await api.watchAndListen('/ws/lib');
    final events = <FileWatchEvent>[];
    h!.events.listen(events.add);
    ctrl.add({'dirPath': '/ws/lib', 'changedPath': '/ws/lib/a.dart'});
    await pumpEventQueue();
    expect(events.single.dirPath, '/ws/lib');
    expect(events.single.changedPath, '/ws/lib/a.dart');
    await ctrl.close();
  });

  test('unwatch: 参数 [{id}] 上帧; 失败吞错', () async {
    final seen = <dynamic>[];
    final api = FileApi.direct((c, m, a) async {
      seen.add('$c.$m $a');
      return ok({});
    });
    await api.unwatch(watchId: 'w9');
    expect(seen.single, 'file-watcher.unwatch [{id: w9}]');
    final bad = FileApi.direct((c, m, a) async => throw StateError('x'));
    await bad.unwatch(watchId: 'w9'); // 不抛
  });

  test('FileWatchEvent.fromBody 兼容 dirPath/changedPath 直挂与 raw 包裹', () {
    expect(FileWatchEvent.fromBody({'changedPath': '/ws/a'}).changedPath, '/ws/a');
    expect(FileWatchEvent.fromBody({'dirPath': '/ws/lib'}).dirPath, '/ws/lib');
    expect(
      FileWatchEvent.fromBody({'raw': {'changedPath': '/ws/b'}}).changedPath,
      '/ws/b',
    );
    expect(FileWatchEvent.fromBody({}).changedPath, '');
    expect(FileWatchEvent.fromBody(null).changedPath, '');
  });
}
