# 项目文件树(WorkspaceFileTree 移动端对齐)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移动端只读项目文件树,全量对齐网页端 WorkspaceFileTree(浏览/变更过滤/搜索/git 角标/复制路径/加入对话/预览/watcher 自动刷新+降级)。

**Architecture:** 瘦客户端,一切文件访问走 relay RPC。数据层 `FileApi`(file 通道)仿 `GitApi` 测试缝模式;状态 `FileTreeController`(StateNotifierProvider.autoDispose.family)仿 `GitController`;UI 全屏页复用 `CapsPageHeader` + `AppEmptyState`;入口挂在 ChatFloatingHeader 更多菜单。规格:`docs/superpowers/specs/2026-10-08-project-file-tree-design.md`(契约冻结面以此为准)。

**Tech Stack:** Flutter + Riverpod 2.6(手写 provider,无 codegen)、go_router(仅预览页跳转)、既有 relay WebSocket RPC。

## Global Constraints

- 工作区有**他人未提交的 pip 相关改动**(pip_service/pip_providers/pip_overlay_card/test/pip_overlay_card_test/third_party/**)。`git add` 只允许 add 本计划列出的文件,严禁 `git add -A`/`git add .`/`git commit -a`。
- RPC wire 约定:**参数以数组上帧**(服务端展开为位置参数,zod strict 不多传)——见 git_api.dart:230 注释,所有新 RPC 照做:`_call(channel, method, [args])`。
- 中文 UI 文案固定:页面标题「文件树」;菜单项「新对话/文件树/悬浮窗监视/设置」;长按菜单「复制绝对路径/复制相对路径/加入对话/打开预览」;空态「空目录/读取失败/无匹配文件/重试」;过滤 tooltip「仅显示变更文件/显示全部文件」。
- 主题用既有 `AppColors`/`AppSpacing`/`AppRadius`/`AppTextSizes` 令牌;git 状态点为语义色,允许裸 hex(先例 composer.dart:316 `Color(0xFF34D399)`)。禁绿/紫主题色(语义状态色除外)。
- 不跑 golden 测试(仓库惯例);每个任务 `flutter analyze` 无新告警 + 相关 `flutter test` 全绿后才可 commit。
- watcher 通道名是**待确认面**:冻结的是探测顺序(`file-watcher` → `file`)与降级行为(任一步失败=本会话永久降级手动刷新,不报错)。

---

### Task 1: 数据层 — RelayClient 原始帧订阅 + FileApi + GitApi.getIgnoredPaths

**Files:**
- Modify: `lib/core/relay/relay_client.dart`(新增公开方法 `subscribeRawFrames`)
- Modify: `lib/core/relay/git_api.dart`(新增 `getIgnoredPaths`)
- Create: `lib/core/relay/file_api.dart`
- Test: `test/file_api_test.dart`

**Interfaces:**
- Consumes: `RelayClient.rpcCallMap(channel, method, args) → Future<Map<String,dynamic>>`(已存在);`RpcCallFn` typedef(git_api.dart:4,已导出);`_indexFrameSubs` 原始帧路由表(relay_client.dart:1977,type-204 事件按 LISTEN 请求 id 分发到原始 map 流,已存在);`RpcCodec.encodeListen/encodeUnlisten`、`unawaited`(该文件已有 import)。
- Produces(Task 2/3 依赖,签名冻结):
  - `class FileEntry { final String name; final String path; final String type; final bool isSymbolicLink; bool get isDirectory; }`(type: `directory`/`file`)
  - `class FileWatchEvent { final String changedPath; static FileWatchEvent fromBody(dynamic body); }`
  - `typedef FileWatcherInfo = ({String channel, String listenEvent, Stream<FileWatchEvent> events, String rootWatchId});`
  - `class FileApi { Future<List<FileEntry>> readdir(String path); Future<List<String>> getIgnoredPaths(String workspacePath, List<String> paths); Future<FileWatcherInfo?> probeWatcher({required String rootPath}); Future<String?> watchDir({required String channel, required String path}); Future<void> unwatch({required String channel, required String watchId}); FileApi(RelayClient relay); FileApi.direct(RpcCallFn call, {RawSubscribeFn? subscribeRaw}); }`
  - `typedef RawSubscribeFn = Future<Stream<Map<String, dynamic>>> Function(String channel, String event, Map<String, dynamic> listenArgs);`
  - `RelayClient.subscribeRawFrames(channel, event, listenArgs, {required Future<void> Function() activate}) → Future<Stream<Map<String,dynamic>>>`
  - `GitApi.getIgnoredPaths(workspacePath, paths) → Future<List<String>>`

- [ ] **Step 1: 写失败测试** `test/file_api_test.dart`

```dart
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /home/admins/projects/zocde-app && flutter test test/file_api_test.dart`
Expected: FAIL(`file_api.dart` 不存在,编译错误)。

- [ ] **Step 3: RelayClient 加公开原始帧订阅**(`lib/core/relay/relay_client.dart`,插在 `subscribeSessionsIndexV4`/`unsubscribeSessionsIndexV4` 之后、`rpcCall` 兜底方法之前)

```dart
  /// 通用原始帧订阅 (LISTEN + activate 激活动作; type-204 事件按 LISTEN
  /// 请求 id 路由到原始 map 表, body 原样转发)。供 file-watcher 等动态通道
  /// 复用。失败自动清理 LISTEN 并关闭流 (模式同 [subscribeSessionsIndexV4])。
  Future<Stream<Map<String, dynamic>>> subscribeRawFrames(
    String channel,
    String event,
    Map<String, dynamic> listenArgs, {
    required Future<void> Function() activate,
  }) async {
    _rpcReqId++;
    final id = _rpcReqId;
    final controller = StreamController<Map<String, dynamic>>();
    _indexFrameSubs[id] = controller;
    _sendRpcFrameData(RpcCodec.encodeListen(id, channel, event, listenArgs));
    try {
      await activate();
      return controller.stream;
    } catch (e) {
      _indexFrameSubs.remove(id);
      unawaited(controller.close());
      _sendRpcFrameData(RpcCodec.encodeUnlisten(id));
      rethrow;
    }
  }
```

- [ ] **Step 4: GitApi.getIgnoredPaths**(`lib/core/relay/git_api.dart`,加在 `discardPaths` 之后)

```dart
  /// 忽略路径过滤 (网页端文件树: readdir 后用它过滤 git 忽略项)。
  /// 传入待查 paths (绝对), 返回被忽略的子集。响应形状未动态坐实,
  /// 按 [裸数组 | {paths:[...]}] 双兼容解析 (与 getChanges 同策略)。
  Future<List<String>> getIgnoredPaths(
    String workspacePath,
    List<String> paths,
  ) async {
    final b = await _rpc('getIgnoredPaths', {
      'workspacePath': workspacePath,
      'paths': paths,
    });
    final list = (b['paths'] ?? b['raw']) as List<dynamic>? ?? const [];
    return [
      for (final p in list)
        p is Map ? (p['path'] as String? ?? '') : p as String,
    ].where((p) => p.isNotEmpty).toList();
  }
```

- [ ] **Step 5: 新建 `lib/core/relay/file_api.dart`**

```dart
// lib/core/relay/file_api.dart

/// file 通道 typed 封装 (只读: readdir/watch; 写操作网页端也没有, 见 spec §1)。

import 'relay_client.dart';

/// file 通道名 (桌面端共享协议枚举原文 File:"file", app 已实测)。
const String kFileChannel = 'file';

/// fileWatcher 通道候选 (spec §4.3 冻结探测顺序):
/// 1. file-watcher (外围域 kebab 规律推断, 同 mcp-sync/model-provider)
/// 2. file 通道上的 watch 方法 (兜底: FileWatcher 与 File 在桌面通道表相邻)
const List<({String channel, String listenEvent})> kWatcherCandidates = [
  (channel: 'file-watcher', listenEvent: 'onDidChange'),
  (channel: 'file', listenEvent: 'watch'),
];

/// git_api.RpcCallFn 复用 (rpcCallMap 同形)。
export 'git_api.dart' show RpcCallFn;

/// 原始帧订阅函数形 (测试注入缝; 生产 = RelayClient.subscribeRawFrames)。
typedef RawSubscribeFn =
    Future<Stream<Map<String, dynamic>>> Function(
      String channel,
      String event,
      Map<String, dynamic> listenArgs,
    );

/// 目录条目 (file.readdir; 网页端消费 name/path/type/isSymbolicLink)。
class FileEntry {
  final String name;
  final String path;

  /// 'directory' | 'file'
  final String type;
  final bool isSymbolicLink;

  const FileEntry({
    required this.name,
    required this.path,
    required this.type,
    required this.isSymbolicLink,
  });

  bool get isDirectory => type == 'directory';

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
    name: j['name'] as String? ?? '',
    path: j['path'] as String? ?? '',
    type: j['type'] as String? ?? 'file',
    isSymbolicLink: j['isSymbolicLink'] as bool? ?? false,
  );
}

/// 目录变化事件 (fileWatcher 动态帧; 网页端 UNt 消费 changedPath)。
class FileWatchEvent {
  final String changedPath;

  const FileWatchEvent({required this.changedPath});

  factory FileWatchEvent.fromBody(dynamic body) {
    final m = body is Map
        ? (body['raw'] is Map
              ? Map<String, dynamic>.from(body['raw'] as Map)
              : Map<String, dynamic>.from(body as Map))
        : const <String, dynamic>{};
    return FileWatchEvent(
      changedPath: (m['changedPath'] ?? m['path']) as String? ?? '',
    );
  }
}

/// probeWatcher 成功产物: 命中通道 + 事件流 + 根目录 watch 句柄 (探针复用)。
typedef FileWatcherInfo =
    ({
      String channel,
      String listenEvent,
      Stream<FileWatchEvent> events,
      String rootWatchId,
    });

class FileApi {
  final RpcCallFn _call;
  final RawSubscribeFn _subscribeRaw;

  /// 生产构造: rpcCallMap + subscribeRawFrames。
  FileApi(RelayClient relay)
    : _call = ((channel, method, args) => relay.rpcCallMap(channel, method, args)),
      _subscribeRaw = relay.subscribeRawFrames;

  /// 测试构造: 直接注入 RPC / 订阅函数。
  FileApi.direct(this._call, {RawSubscribeFn? subscribeRaw})
    : _subscribeRaw =
          subscribeRaw ?? ((c, e, l) async => const Stream.empty());

  /// 列目录 (includeHidden 恒 true, 忽略项由 git.getIgnoredPaths 过滤, 对齐网页端)。
  /// wire: 参数数组上帧; body 兼容 [裸数组 | {entries:[...]}]。
  Future<List<FileEntry>> readdir(String path) async {
    final b = await _call(kFileChannel, 'readdir', [
      {'path': path, 'includeHidden': true},
    ]);
    final list = (b['entries'] ?? b['raw']) as List<dynamic>? ?? const [];
    return [
      for (final e in list)
        FileEntry.fromJson(Map<String, dynamic>.from(e as Map)),
    ];
  }

  /// 探测 fileWatcher 通道 (spec §4.3): 依序试候选, 候选的 LISTEN + watch
  /// 全成功即命中并返回句柄; 全失败返回 null (= 本会话降级手动刷新, 不抛)。
  /// rootPath 的 watch 探针即根目录监听本体, 命中后不 unwatch (controller 复用)。
  Future<FileWatcherInfo?> probeWatcher({required String rootPath}) async {
    for (final c in kWatcherCandidates) {
      try {
        String? watchId;
        final raw = await _subscribeRaw(c.channel, c.listenEvent, const {}, ()
            async {
          final b = await _call(c.channel, 'watch', [
            {'path': rootPath},
          ]);
          watchId = (b['id'] ??
                  (b['raw'] is Map ? (b['raw'] as Map)['id'] : null))
              as String?;
        });
        if (watchId == null || watchId.isEmpty) continue;
        return (
          channel: c.channel,
          listenEvent: c.listenEvent,
          events: raw.map(FileWatchEvent.fromBody),
          rootWatchId: watchId,
        );
      } catch (_) {
        continue; // 该候选不可用, 试下一个
      }
    }
    return null;
  }

  /// 监听目录 (probeWatcher 命中后逐展开目录调; 失败返回 null 不抛)。
  Future<String?> watchDir({required String channel, required String path}) async {
    try {
      final b = await _call(channel, 'watch', [
        {'path': path},
      ]);
      return (b['id'] ?? (b['raw'] is Map ? (b['raw'] as Map)['id'] : null))
          as String?;
    } catch (_) {
      return null;
    }
  }

  /// 取消监听 (尽力而为, 吞错: 降级路径里 id 可能已失效)。
  Future<void> unwatch({
    required String channel,
    required String watchId,
  }) async {
    try {
      await _call(channel, 'unwatch', [
        {'id': watchId},
      ]);
    } catch (_) {}
  }
}
```

- [ ] **Step 6: 跑测试确认通过**

Run: `cd /home/admins/projects/zocde-app && flutter analyze lib/core/relay && flutter test test/file_api_test.dart`
Expected: PASS(7 个用例全绿,analyze 无新告警)。

- [ ] **Step 7: Commit**

```bash
cd /home/admins/projects/zocde-app
git add lib/core/relay/relay_client.dart lib/core/relay/git_api.dart lib/core/relay/file_api.dart test/file_api_test.dart
git commit -m "feat: file 通道 FileApi(readdir/watcher 探测降级) + getIgnoredPaths 封装 — 项目文件树数据层 (1/4)"
```

---

### Task 2: 状态层 — FileTreeController + 纯逻辑 + providers

**Files:**
- Create: `lib/providers/file_tree_provider.dart`
- Test: `test/file_tree_logic_test.dart`, `test/file_tree_provider_test.dart`

**Interfaces:**
- Consumes: Task 1 全部 Produces(`FileEntry/FileApi/FileWatcherInfo/FileWatchEvent/FileApi.direct/watchDir`);既有 `GitApi`(getChanges/getIgnoredPaths)、`gitApiProvider`(git_provider.dart:354)、`relayClientProvider`、`StateNotifier/flutter_riverpod`。
- Produces(Task 3/4 依赖,签名冻结):
  - `class FileTreeRef { const FileTreeRef({required this.workspacePath, this.workspaceIdentity}); }`(==/hashCode 同 GitRef)
  - `enum FileTreePhase { loading, ready }`
  - `class FileTreeNode { final FileEntry entry; final bool expanded; final bool loading; final Object? error; final Map<String, FileTreeNode> children; FileTreeNode copyWith({bool? expanded, bool? loading, Map<String, FileTreeNode>? children}); FileTreeNode withError(Object e); }`(children key = 绝对路径;copyWith 不带 error 参数——错误只经 withError 写入、成功路径以新节点替换清除)
  - `class FileTreeState { final FileTreePhase phase; final Map<String, FileTreeNode> roots; final Object? rootError; final bool filterChangedOnly; final String searchQuery; final Map<String, String> statusByPath; final Set<String> ignoredPaths; final bool watcherAvailable; }` + `const FileTreeState.initial()`(filterChangedOnly 默认 true)+ `copyWith`(rootError 为直传——传 null 即清除)
  - `class FileTreeController extends StateNotifier<FileTreeState>`: `Future<void> toggleDir(String path)` / `Future<void> refresh()` / `void setSearch(String q)` / `void toggleFilter()` / `void disposeWatcher()`
  - `final fileApiProvider = Provider.autoDispose<FileApi>`;`final fileTreeProvider = StateNotifierProvider.autoDispose.family<FileTreeController, FileTreeState, FileTreeRef>`
  - 纯函数(同文件顶层):`String relativePathOf(String absPath, String workspacePath)`;`int entrySortCompare(FileEntry a, FileEntry b)`;`String statusLetterFor(GitChange c)`;`Map<String, String> buildStatusByPath(List<GitChange> changes)`;`Map<String, String> dirBadges(Map<String, String> statusByPath)`;`Color statusColor(String s)`;`List<(FileTreeNode, int)> visibleRows({required Map<String, FileTreeNode> roots, required String workspacePath, required Map<String, String> statusByPath, required bool changedOnly, required String search})`

- [ ] **Step 1: 写纯函数失败测试** `test/file_tree_logic_test.dart`

```dart
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

  test('entrySortCompare: 目录(含符号链接目录)先, 名称 case-insensitive', () {
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
    expect(all.length, 3); // a + 两个文件 (未展开不深入)
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /home/admins/projects/zocde-app && flutter test test/file_tree_logic_test.dart`
Expected: FAIL(`file_tree_provider.dart` 不存在)。

- [ ] **Step 3: 写 controller 失败测试** `test/file_tree_provider_test.dart`

```dart
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

  @override
  Future<FileWatcherInfo?> probeWatcher({required String rootPath}) => Future.value(watcher);

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
```

- [ ] **Step 4: 跑测试确认失败**

Run: `cd /home/admins/projects/zocde-app && flutter test test/file_tree_provider_test.dart`
Expected: FAIL(同文件编译错)。

- [ ] **Step 5: 实现 `lib/providers/file_tree_provider.dart`**

```dart
// lib/providers/file_tree_provider.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/relay/file_api.dart';
import '../core/relay/git_api.dart';
import '../core/relay/relay_client.dart';
import 'git_provider.dart';

/// 文件树引用 (仿 GitRef; family key)。
class FileTreeRef {
  final String workspacePath;

  /// 远程工作区标识 (对齐 GitRef/ChatRef; null = 服务端按 path 解析)。
  final String? workspaceIdentity;

  const FileTreeRef({required this.workspacePath, this.workspaceIdentity});

  @override
  bool operator ==(Object other) =>
      other is FileTreeRef &&
      other.workspacePath == workspacePath &&
      other.workspaceIdentity == workspaceIdentity;

  @override
  int get hashCode => Object.hash(workspacePath, workspaceIdentity);
}

enum FileTreePhase { loading, ready }

/// 树节点 (不可变; children key = 绝对路径; 错误只经 withError 写入)。
class FileTreeNode {
  final FileEntry entry;
  final bool expanded;
  final bool loading;
  final Object? error;
  final Map<String, FileTreeNode> children;

  const FileTreeNode({
    required this.entry,
    this.expanded = false,
    this.loading = false,
    this.error = null,
    this.children = const {},
  });

  /// error 不进 copyWith: 错误态只经 [withError] 写, 成功替换节点即清除。
  FileTreeNode copyWith({
    bool? expanded,
    bool? loading,
    Map<String, FileTreeNode>? children,
  }) => FileTreeNode(
    entry: entry,
    expanded: expanded ?? this.expanded,
    loading: loading ?? this.loading,
    error: error,
    children: children ?? this.children,
  );

  FileTreeNode withError(Object e) => FileTreeNode(
    entry: entry,
    expanded: expanded,
    loading: false,
    error: e,
    children: children,
  );
}

/// 不可变树状态。
class FileTreeState {
  final FileTreePhase phase;
  final Map<String, FileTreeNode> roots;
  final Object? rootError;

  /// true = 仅变更文件 (对齐网页端默认); 非 git 项目 UI 直接隐藏切换。
  final bool filterChangedOnly;
  final String searchQuery;

  /// 相对路径 → 状态字母 (M/A/D/R/C/U)。
  final Map<String, String> statusByPath;

  /// 被忽略的绝对路径 (readdir 结果过滤用)。
  final Set<String> ignoredPaths;
  final bool watcherAvailable;

  const FileTreeState({
    required this.phase,
    required this.roots,
    required this.rootError,
    required this.filterChangedOnly,
    required this.searchQuery,
    required this.statusByPath,
    required this.ignoredPaths,
    required this.watcherAvailable,
  });

  const FileTreeState.initial()
    : phase = FileTreePhase.loading,
      roots = const {},
      rootError = null,
      filterChangedOnly = true,
      searchQuery = '',
      statusByPath = const {},
      ignoredPaths = const {},
      watcherAvailable = false;

  /// rootError 直传 (传 null 即清除)。
  FileTreeState copyWith({
    FileTreePhase? phase,
    Map<String, FileTreeNode>? roots,
    Object? rootError,
    bool? filterChangedOnly,
    String? searchQuery,
    Map<String, String>? statusByPath,
    Set<String>? ignoredPaths,
    bool? watcherAvailable,
  }) => FileTreeState(
    phase: phase ?? this.phase,
    roots: roots ?? this.roots,
    rootError: rootError,
    filterChangedOnly: filterChangedOnly ?? this.filterChangedOnly,
    searchQuery: searchQuery ?? this.searchQuery,
    statusByPath: statusByPath ?? this.statusByPath,
    ignoredPaths: ignoredPaths ?? this.ignoredPaths,
    watcherAvailable: watcherAvailable ?? this.watcherAvailable,
  );
}

// ---------------- 纯函数 ----------------

/// 绝对路径 → 工作区相对路径 (剥前缀与首斜杠; 非前缀内原样返回)。
String relativePathOf(String absPath, String workspacePath) {
  final ws = workspacePath.endsWith('/')
      ? workspacePath.substring(0, workspacePath.length - 1)
      : workspacePath;
  if (absPath == ws) return '';
  if (absPath.startsWith('$ws/')) return absPath.substring(ws.length + 1);
  return absPath;
}

/// 目录(含符号链接目录)先, 名称 case-insensitive。
int entrySortCompare(FileEntry a, FileEntry b) {
  final da = a.isDirectory ? 0 : 1;
  final db = b.isDirectory ? 0 : 1;
  if (da != db) return da - db;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// GitChange → 状态字母 (对齐网页端 git.kind.* / untracked 语义)。
String statusLetterFor(GitChange c) {
  if (c.isUntracked) return 'U';
  switch (c.kind) {
    case 'added':
      return 'A';
    case 'deleted':
      return 'D';
    case 'renamed':
      return 'R';
    case 'conflicted':
      return 'C';
    default:
      return 'M';
  }
}

Map<String, String> buildStatusByPath(List<GitChange> changes) => {
  for (final c in changes)
    (c.workspaceRelativePath.isNotEmpty
            ? c.workspaceRelativePath
            : c.repoRelativePath): statusLetterFor(c),
};

/// 状态严重度 (目录取子树最重): U(0) < A/M/R/C(1) < D(2)。
int _severity(String s) => switch (s) {
  'D' => 2,
  'U' => 0,
  _ => 1,
};

/// 目录角标: 目录相对路径 → 子树内最重状态字母 (按前缀聚合, 客户端算, 无额外 RPC)。
Map<String, String> dirBadges(Map<String, String> statusByPath) {
  final out = <String, String>{};
  for (final e in statusByPath.entries) {
    final parts = e.key.split('/');
    if (parts.length < 2) continue; // 根层文件无目录角标
    var dir = parts.sublist(0, parts.length - 1).join('/');
    while (dir.isNotEmpty) {
      final cur = out[dir];
      if (cur == null || _severity(e.value) > _severity(cur)) out[dir] = e.value;
      final i = dir.lastIndexOf('/');
      dir = i < 0 ? '' : dir.substring(0, i);
    }
  }
  return out;
}

/// git 状态字母 → 语义色 (非主题色)。
Color statusColor(String s) => switch (s) {
  'A' => const Color(0xFF34D399),
  'D' => const Color(0xFFEF4444),
  'R' => const Color(0xFF3B82F6),
  'C' => const Color(0xFFF97316),
  'U' => const Color(0xFF94A3B8),
  _ => const Color(0xFFF59E0B), // M 及未知
};

/// 可见行 (DFS 先序, 供 ListView 直接渲染):
/// - search 非空: 按名称 contains 过滤 (case-insensitive), 保留命中项的祖先目录链;
/// - changedOnly (search 为空时): 文件须命中 statusByPath; 目录在有命中后代
///   (已展开) 或按前缀命中 statusByPath (未展开也显示, 对齐网页端目录角标行为) 时保留;
/// - search 与 changedOnly 同时生效时 search 优先 (与网页端一致: 搜索即全量找)。
List<(FileTreeNode, int)> visibleRows({
  required Map<String, FileTreeNode> roots,
  required String workspacePath,
  required Map<String, String> statusByPath,
  required bool changedOnly,
  required String search,
}) {
  final out = <(FileTreeNode, int)>[];
  final q = search.toLowerCase();

  bool childHit(List<(FileTreeNode, int)> rows) => rows.isNotEmpty;

  List<(FileTreeNode, int)>? walkNode(FileTreeNode n, int depth) {
    if (n.entry.isDirectory) {
      final selfMatch =
          q.isNotEmpty && n.entry.name.toLowerCase().contains(q);
      final childRows = <(FileTreeNode, int)>[];
      if (n.expanded) {
        final kids = [...n.children.values]
          ..sort((a, b) => entrySortCompare(a.entry, b.entry));
        for (final k in kids) {
          final r = walkNode(k, depth + 1);
          if (r != null) childRows.addAll(r);
        }
      }
      final dirRel = relativePathOf(n.entry.path, workspacePath);
      final statusHit = q.isEmpty &&
          changedOnly &&
          statusByPath.keys.any((k) => k.startsWith('$dirRel/'));
      if (!selfMatch && !childHit(childRows) && !statusHit) return null;
      return [(n, depth), ...childRows];
    }
    final rel = relativePathOf(n.entry.path, workspacePath);
    final kept = q.isNotEmpty
        ? n.entry.name.toLowerCase().contains(q)
        : (!changedOnly || statusByPath.containsKey(rel));
    return kept ? [(n, depth)] : null;
  }

  final rootNodes = [...roots.values]
    ..sort((a, b) => entrySortCompare(a.entry, b.entry));
  for (final n in rootNodes) {
    final r = walkNode(n, 0);
    if (r != null) out.addAll(r);
  }
  return out;
}

// ---------------- Controller ----------------

/// 文件树控制器 (构造即首拉; watcher 探测失败静默降级, 语义见 spec §4.3)。
class FileTreeController extends StateNotifier<FileTreeState> {
  FileTreeController(this.treeRef, this._files, this._git)
    : super(const FileTreeState.initial()) {
    _init();
  }

  final FileTreeRef treeRef;
  final FileApi _files;
  final GitApi _git;

  String get _ws => treeRef.workspacePath;
  FileWatcherInfo? _watcher;
  final Map<String, String> _watchIds = {}; // dirPath → watchId
  Timer? _reloadDebounce;
  StreamSubscription<FileWatchEvent>? _eventSub;

  Future<void> _init() async {
    try {
      final results = await Future.wait<Object?>([
        _files.readdir(_ws),
        _git.getChanges(_ws, 'unstaged'),
        _git.getChanges(_ws, 'staged'),
      ]);
      final entries = results[0] as List<FileEntry>;
      final changes = [
        ...results[1] as List<GitChange>,
        ...results[2] as List<GitChange>,
      ];
      Set<String> ignoredSet = {};
      try {
        final ignored = await _git.getIgnoredPaths(_ws, [
          for (final e in entries) e.path,
        ]);
        ignoredSet = ignored.toSet();
      } catch (_) {// 过滤是增强, 失败不挡浏览
      }
      state = state.copyWith(
        phase: FileTreePhase.ready,
        roots: {
          for (final e in entries.where((e) => !ignoredSet.contains(e.path)))
            e.path: FileTreeNode(entry: e),
        },
        statusByPath: buildStatusByPath(changes),
        ignoredPaths: ignoredSet,
      );
    } catch (e) {
      state = state.copyWith(phase: FileTreePhase.ready, rootError: e);
      return;
    }
    await _probeWatcher();
  }

  Future<void> _probeWatcher() async {
    try {
      final w = await _files.probeWatcher(rootPath: _ws);
      if (w == null) return; // 全候选失败 = 本会话手动刷新
      _watcher = w;
      _watchIds[_ws] = w.rootWatchId;
      state = state.copyWith(watcherAvailable: true);
      _eventSub = w.events.listen(_onWatchEvent);
    } catch (_) {
      // 不报错 (spec §4.3)
    }
  }

  void _onWatchEvent(FileWatchEvent e) {
    if (e.changedPath.isEmpty) return;
    final i = e.changedPath.lastIndexOf('/');
    final dir = i > 0 ? e.changedPath.substring(0, i) : _ws;
    if (!_isLoaded(dir)) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 300), () {
      _reloadDir(dir);
    });
  }

  bool _isLoaded(String dir) =>
      state.roots.containsKey(dir) || _findNode(state.roots, dir) != null;

  static FileTreeNode? _findNode(Map<String, FileTreeNode> map, String path) {
    for (final n in map.values) {
      if (n.entry.path == path) return n;
      final r = _findNode(n.children, path);
      if (r != null) return r;
    }
    return null;
  }

  Future<void> _reloadDir(String dir) async {
    try {
      final entries = await _files.readdir(dir);
      _patchNode(dir, (n) => _nodeWithChildren(n, entries));
    } catch (_) {// 目录可能被删; 手动刷新兜底
    }
  }

  /// 已加载子节点重建: 保留既有子树展开态, 过滤 ignored, 移除已消失项。
  FileTreeNode _nodeWithChildren(FileTreeNode node, List<FileEntry> entries) {
    final ignored = state.ignoredPaths;
    return FileTreeNode(
      entry: node.entry,
      expanded: true,
      children: {
        for (final e in entries.where((e) => !ignored.contains(e.path)))
          e.path: node.children[e.path] ?? FileTreeNode(entry: e),
      },
    );
  }

  /// 展开/收起。收起只翻标志 (顺带退订监听); 展开且未加载 → readdir 懒加载。
  Future<void> toggleDir(String path) async {
    final node = _findNode(state.roots, path) ?? state.roots[path];
    if (node == null) return;
    if (node.expanded) {
      _patchNode(path, (n) => n.copyWith(expanded: false));
      _unwatchDir(path);
      return;
    }
    if (node.children.isNotEmpty) {
      _patchNode(path, (n) => n.copyWith(expanded: true));
      _watchDir(path);
      return;
    }
    _patchNode(path, (n) => n.copyWith(expanded: true, loading: true));
    try {
      final entries = await _files.readdir(path);
      _patchNode(path, (n) => _nodeWithChildren(n, entries));
      _watchDir(path);
    } catch (e) {
      _patchNode(path, (n) => n.withError(e));
    }
  }

  void _watchDir(String path) {
    final w = _watcher;
    if (w == null || _watchIds.containsKey(path)) return;
    () async {
      final id = await _files.watchDir(channel: w.channel, path: path);
      if (id != null && id.isNotEmpty) _watchIds[path] = id;
    }();
  }

  void _unwatchDir(String path) {
    final w = _watcher;
    final id = _watchIds.remove(path);
    if (w == null || id == null) return;
    _files.unwatch(channel: w.channel, watchId: id).ignore();
  }

  /// 手动刷新: 根 + 已展开目录逐个重载, git 状态重拉。
  Future<void> refresh() async {
    final expanded = [
      for (final r in state.roots.values)
        if (r.expanded) r.entry.path,
    ];
    try {
      final results = await Future.wait<Object?>([
        _files.readdir(_ws),
        _git.getChanges(_ws, 'unstaged'),
        _git.getChanges(_ws, 'staged'),
      ]);
      final entries = results[0] as List<FileEntry>;
      final ignoredSet = state.ignoredPaths;
      var roots = {
        for (final e in entries.where((e) => !ignoredSet.contains(e.path)))
          e.path: state.roots[e.path] ?? FileTreeNode(entry: e),
      };
      for (final dir in expanded) {
        try {
          final kids = await _files.readdir(dir);
          roots = _patchMap(roots, dir, (n) => _nodeWithChildren(n, kids));
        } catch (_) {
          roots = _patchMap(roots, dir, (n) => n.withError('目录读取失败'));
        }
      }
      state = state.copyWith(
        roots: roots,
        rootError: null,
        statusByPath: buildStatusByPath([
          ...results[1] as List<GitChange>,
          ...results[2] as List<GitChange>,
        ]),
      );
    } catch (e) {
      state = state.copyWith(rootError: e);
    }
  }

  void setSearch(String q) => state = state.copyWith(searchQuery: q);

  void toggleFilter() =>
      state = state.copyWith(filterChangedOnly: !state.filterChangedOnly);

  /// 整树按路径替换节点 (children 空的叶子不再深入)。
  static Map<String, FileTreeNode> _patchMap(
    Map<String, FileTreeNode> roots,
    String path,
    FileTreeNode Function(FileTreeNode) f,
  ) => {
    for (final e in roots.entries)
      e.key: e.value.entry.path == path
          ? f(e.value)
          : e.value.copyWith(
              children: e.value.children.isEmpty
                  ? null
                  : _patchMap(e.value.children, path, f),
            ),
  };

  void _patchNode(String path, FileTreeNode Function(FileTreeNode) f) =>
      state = state.copyWith(roots: _patchMap(state.roots, path, f));

  /// 释放 watcher (provider autoDispose 时经 ref.onDispose 调)。
  void disposeWatcher() {
    _reloadDebounce?.cancel();
    _eventSub?.cancel();
    final channel = _watcher?.channel;
    for (final id in _watchIds.values) {
      if (channel != null) {
        _files.unwatch(channel: channel, watchId: id).ignore();
      }
    }
    _watchIds.clear();
  }
}

/// FileApi 工厂 (测试缝, 仿 gitApiProvider)。
final fileApiProvider = Provider.autoDispose<FileApi>((ref) {
  final relay = ref.watch(relayClientProvider);
  if (relay == null) throw StateError('RelayClient not available');
  return FileApi(relay);
});

/// 文件树 provider (离开页面自动销毁并退订全部 watch)。
final fileTreeProvider = StateNotifierProvider.autoDispose
    .family<FileTreeController, FileTreeState, FileTreeRef>((ref, treeRef) {
      final files = ref.watch(fileApiProvider);
      final git = ref.watch(gitApiProvider);
      final ctrl = FileTreeController(treeRef, files, git);
      ref.onDispose(ctrl.disposeWatcher);
      return ctrl;
    });
```

- [ ] **Step 6: 跑测试确认通过**

Run: `cd /home/admins/projects/zocde-app && flutter analyze lib/providers lib/core/relay && flutter test test/file_tree_logic_test.dart test/file_tree_provider_test.dart test/file_api_test.dart`
Expected: PASS(6+5+7=18 个用例全绿)。

- [ ] **Step 7: Commit**

```bash
cd /home/admins/projects/zocde-app
git add lib/providers/file_tree_provider.dart test/file_tree_logic_test.dart test/file_tree_provider_test.dart
git commit -m "feat: FileTreeController(懒加载/变更过滤/搜索/角标聚合/watcher 自动重载降级) — 项目文件树状态层 (2/4)"
```

---

### Task 3: UI 层 — FileTreeScreen + 行组件 + 长按菜单

**Files:**
- Create: `lib/features/files/screens/file_tree_screen.dart`
- Create: `lib/features/files/widgets/file_tree_row.dart`
- Test: `test/file_tree_screen_test.dart`

**Interfaces:**
- Consumes: Task 2 全部 Produces(`fileTreeProvider`/`visibleRows`/`dirBadges`/`statusColor`/`relativePathOf`/`FileTreePhase`);`CapsPageHeader`/`CapsCircleIconButton`(caps_page_chrome.dart);`AppEmptyState({icon,title,subtitle,actionLabel,onAction,actionIcon,iconTint})`(app_empty_state.dart);`gitAvailabilityProvider(workspacePath)`(FutureProvider.family<bool,String>);`filePreviewRouteUrl(path, {workspace, line}) → String`(file_preview_screen.dart:63);`AppColors.dangerContainer`、`AppSpacing`/`AppRadius` 令牌。
- Produces(Task 4 依赖):
  - `class FileTreeScreen extends ConsumerStatefulWidget { const FileTreeScreen({super.key, required FileTreeRef treeRef, required void Function(String relativePath) onAddToChat}); }` — 加入对话回调传相对路径(不带 @);触发时页面已 pop 自身。

- [ ] **Step 1: 写 widget 失败测试** `test/file_tree_screen_test.dart`

```dart
// FileTreeScreen widget 测试 (不跑 golden): 三态/展开/长按菜单/过滤门控/加入对话。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/core/relay/file_api.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/features/files/screens/file_tree_screen.dart';
import 'package:zcode_app/providers/file_tree_provider.dart';
import 'package:zcode_app/providers/git_provider.dart';

class FakeFileApi implements FileApi {
  FakeFileApi(this.dirs);
  final Map<String, List<FileEntry>> dirs;

  @override
  Future<List<FileEntry>> readdir(String path) async => dirs[path] ?? const [];

  @override
  Future<FileWatcherInfo?> probeWatcher({required String rootPath}) async => null;

  @override
  Future<String?> watchDir({required String channel, required String path}) async => null;

  @override
  Future<void> unwatch({required String channel, required String watchId}) async {}
}

class FakeGitApi implements GitApi {
  FakeGitApi({this.changes = const [], this.ignored = const [], this.isRepo = true});
  final List<GitChange> changes;
  final List<String> ignored;
  final bool isRepo;

  @override
  Future<List<GitChange>> getChanges(String ws, String sourceId) async =>
      sourceId == 'branch' ? const [] : changes;

  @override
  Future<List<String>> getIgnoredPaths(String ws, List<String> paths) async =>
      ignored.where(paths.contains).toList();

  @override
  Future<GitSummary> getRepositorySummary(String ws) async => GitSummary(
    branchName: isRepo ? 'main' : null,
    trackingBranchName: null,
    headRefType: isRepo ? 'branch' : null,
    ahead: 0,
    behind: 0,
    isGitAvailable: isRepo,
    isRepository: isRepo,
  );

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName} 未在测试中使用');
}

const treeRef = FileTreeRef(workspacePath: '/ws');

final rootEntries = [
  FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false),
  FileEntry(name: 'README.md', path: '/ws/README.md', type: 'file', isSymbolicLink: false),
];

Widget wrap(Widget child, FakeFileApi api, FakeGitApi git) => ProviderScope(
  overrides: [
    fileApiProvider.overrideWith((ref) => api),
    gitApiProvider.overrideWith((ref) => git),
    gitAvailabilityProvider.overrideWith((ref) => Future.value(git.isRepo)),
  ],
  child: MaterialApp(home: child),
);

Future<void> pump(WidgetTester tester, FakeFileApi api, FakeGitApi git,
    {void Function(String)? onAddToChat}) async {
  await tester.pumpWidget(wrap(
    FileTreeScreen(treeRef: treeRef, onAddToChat: onAddToChat ?? (_) {}),
    api,
    git,
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('变更过滤默认开: 未命中文件剪枝; 切「全部」后可见', (tester) async {
    await pump(tester, FakeFileApi({'/ws': rootEntries}), FakeGitApi(changes: [
      GitChange.fromJson({
        'path': '/ws/lib/a.dart', 'repoRelativePath': 'lib/a.dart',
        'workspaceRelativePath': 'lib/a.dart', 'kind': 'modified',
      }),
    ]));
    expect(find.text('文件树'), findsOneWidget);
    // lib 目录按前缀命中保留; README.md 无变更被剪
    expect(find.text('lib'), findsOneWidget);
    expect(find.text('README.md'), findsNothing);

    await tester.tap(find.byTooltip('显示全部文件'));
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('点目录展开懒加载, 子层 ignored 过滤', (tester) async {
    await pump(
      tester,
      FakeFileApi({
        '/ws': rootEntries,
        '/ws/lib': [
          FileEntry(name: 'node_modules', path: '/ws/lib/node_modules', type: 'directory', isSymbolicLink: false),
          FileEntry(name: 'a.dart', path: '/ws/lib/a.dart', type: 'file', isSymbolicLink: false),
        ],
      }),
      FakeGitApi(ignored: ['/ws/lib/node_modules']),
    );
    // 先切全部, 让目录可见
    await tester.tap(find.byTooltip('显示全部文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('node_modules'), findsNothing);
  });

  testWidgets('长按文件弹 4 项菜单; 长按目录弹 2 项 (无加入对话/打开预览)', (tester) async {
    await pump(tester, FakeFileApi({'/ws': rootEntries}), FakeGitApi());
    await tester.tap(find.byTooltip('显示全部文件'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('README.md'));
    await tester.pumpAndSettle();
    expect(find.text('复制绝对路径'), findsOneWidget);
    expect(find.text('复制相对路径'), findsOneWidget);
    expect(find.text('加入对话'), findsOneWidget);
    expect(find.text('打开预览'), findsOneWidget);
    // 点 sheet 外关闭 (左上角空白)
    await tester.tapAt(const Offset(5, 60));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('lib'));
    await tester.pumpAndSettle();
    expect(find.text('复制绝对路径'), findsOneWidget);
    expect(find.text('加入对话'), findsNothing);
  });

  testWidgets('「加入对话」: pop 自身并回调相对路径 (不带 @)', (tester) async {
    String? added;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        fileApiProvider.overrideWith((ref) => FakeFileApi({'/ws': rootEntries})),
        gitApiProvider.overrideWith((ref) => FakeGitApi()),
        gitAvailabilityProvider.overrideWith((ref) => Future.value(true)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.push(
              ctx,
              MaterialPageRoute<void>(
                builder: (_) => FileTreeScreen(
                  treeRef: treeRef,
                  onAddToChat: (rel) => added = rel,
                ),
              ),
            ),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('显示全部文件'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('README.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入对话'));
    await tester.pumpAndSettle();
    expect(added, 'README.md');
    expect(find.byType(FileTreeScreen), findsNothing);
    expect(find.text('OPEN'), findsOneWidget); // 回到了宿主页
  });

  testWidgets('非 git 项目: 过滤切换隐藏, 行照常渲染', (tester) async {
    await pump(
      tester,
      FakeFileApi({'/ws': rootEntries}),
      FakeGitApi(isRepo: false),
    );
    expect(find.byTooltip('仅显示变更文件'), findsNothing);
    expect(find.byTooltip('显示全部文件'), findsNothing);
    expect(find.text('README.md'), findsOneWidget); // 无过滤 = 全部可见
  });

  testWidgets('空目录空态; 根读取失败显示重试', (tester) async {
    await pump(tester, FakeFileApi({'/ws': const []}), FakeGitApi());
    expect(find.text('空目录'), findsOneWidget);
  });

  testWidgets('根读取失败: 「读取失败 + 重试」空态', (tester) async {
    final failing = _FailingFileApi();
    await tester.pumpWidget(wrap(
      FileTreeScreen(treeRef: treeRef, onAddToChat: (_) {}),
      failing,
      FakeGitApi(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}

class _FailingFileApi implements FileApi {
  @override
  Future<List<FileEntry>> readdir(String path) async => throw StateError('x');

  @override
  Future<FileWatcherInfo?> probeWatcher({required String rootPath}) async => null;

  @override
  Future<String?> watchDir({required String channel, required String path}) async => null;

  @override
  Future<void> unwatch({required String channel, required String watchId}) async {}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /home/admins/projects/zocde-app && flutter test test/file_tree_screen_test.dart`
Expected: FAIL(`file_tree_screen.dart` 不存在)。

- [ ] **Step 3: 实现行组件 `lib/features/files/widgets/file_tree_row.dart`**

```dart
// lib/features/files/widgets/file_tree_row.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../providers/file_tree_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';

/// 长按操作菜单 (对齐网页端右键: 复制双路径 / 加入对话 / 打开预览)。
/// [onOpenPreview] 仅文件项出现; 页面侧注入 (负责 pop 页面 + push 预览路由)。
Future<void> showFileEntryActionsSheet(
  BuildContext context, {
  required FileTreeNode node,
  required String workspacePath,
  required void Function(String relativePath) onAddToChat,
  VoidCallback? onOpenPreview,
}) {
  final e = node.entry;
  final rel = relativePathOf(e.path, workspacePath);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                e.name,
                style: Theme.of(sheetCtx).textTheme.titleMedium,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('复制绝对路径'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: e.path));
              Navigator.pop(sheetCtx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: const Text('复制相对路径'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: rel));
              Navigator.pop(sheetCtx);
            },
          ),
          if (!e.isDirectory)
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded),
              title: const Text('加入对话'),
              onTap: () {
                Navigator.pop(sheetCtx); // 关 sheet
                Navigator.pop(context); // 关文件树页
                onAddToChat(rel);
              },
            ),
          if (!e.isDirectory)
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: const Text('打开预览'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onOpenPreview?.call();
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// 树行: 深度缩进 + 目录/文件图标 + 名称 + git 状态标记 + 目录 chevron。
class FileTreeRow extends StatelessWidget {
  final FileTreeNode node;
  final int depth;

  /// 文件: 自身状态字母; 目录: 子树聚合字母; null = 无。
  final String? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const FileTreeRow({
    super.key,
    required this.node,
    required this.depth,
    this.badge,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = node.entry;
    final icon = e.isDirectory
        ? (e.isSymbolicLink
              ? Icons.folder_symlink_rounded
              : Icons.folder_rounded)
        : Icons.description_outlined;
    final iconColor = e.isDirectory
        ? (e.isSymbolicLink
              ? const Color(0xFF94A3B8)
              : const Color(0xFFF59E0B))
        : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md + depth * 16.0,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            if (node.loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor(badge!).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: statusColor(badge!),
                    ),
                  ),
                ),
              if (e.isDirectory)
                Icon(
                  node.expanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 实现页面 `lib/features/files/screens/file_tree_screen.dart`**

```dart
// lib/features/files/screens/file_tree_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/file_tree_provider.dart';
import '../../../providers/git_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../agent/widgets/caps_page_chrome.dart';
import '../../chat/screens/file_preview_screen.dart';
import '../widgets/file_tree_row.dart';

/// 项目文件树 (对齐网页端 WorkspaceFileTree; 只读)。
class FileTreeScreen extends ConsumerStatefulWidget {
  final FileTreeRef treeRef;

  /// 加入对话 (相对路径, 不带 @); 触发时本页已 pop。
  final void Function(String relativePath) onAddToChat;

  const FileTreeScreen({
    super.key,
    required this.treeRef,
    required this.onAddToChat,
  });

  @override
  ConsumerState<FileTreeScreen> createState() => _FileTreeScreenState();
}

class _FileTreeScreenState extends ConsumerState<FileTreeScreen> {
  String get _ws => widget.treeRef.workspacePath;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileTreeProvider(widget.treeRef));
    final ctrl = ref.read(fileTreeProvider(widget.treeRef).notifier);
    final gitOk = ref.watch(gitAvailabilityProvider(_ws)).valueOrNull == true;
    final badges = dirBadges(state.statusByPath);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: CapsPageHeader.overlayStyle(context),
      child: Scaffold(
        appBar: const CapsPageHeader(title: '文件树'),
        body: Column(
          children: [
            _ToolRow(
              searchQuery: state.searchQuery,
              onSearch: ctrl.setSearch,
              showFilter: gitOk,
              filterChangedOnly: state.filterChangedOnly,
              onToggleFilter: ctrl.toggleFilter,
              onRefresh: ctrl.refresh,
            ),
            const Divider(height: 1),
            Expanded(child: _body(state)),
          ],
        ),
      ),
    );
  }

  Widget _body(FileTreeState state) {
    if (state.phase == FileTreePhase.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.rootError != null) {
      return AppEmptyState(
        icon: Icons.error_outline_rounded,
        title: '读取失败',
        subtitle: state.rootError.toString(),
        actionLabel: '重试',
        actionIcon: Icons.refresh_rounded,
        onAction: () =>
            ref.read(fileTreeProvider(widget.treeRef).notifier).refresh(),
        iconTint: AppColors.dangerContainer,
      );
    }
    if (state.roots.isEmpty) {
      return const AppEmptyState(
        icon: Icons.folder_off_outlined,
        title: '空目录',
        subtitle: '当前项目没有可见文件',
      );
    }
    final rows = visibleRows(
      roots: state.roots,
      workspacePath: _ws,
      statusByPath: state.statusByPath,
      changedOnly: state.filterChangedOnly,
      search: state.searchQuery,
    );
    if (rows.isEmpty) {
      return const AppEmptyState(
        icon: Icons.search_off_rounded,
        title: '无匹配文件',
        subtitle: '换个关键词试试',
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (node, depth) = rows[i];
        final rel = relativePathOf(node.entry.path, _ws);
        final badge = node.entry.isDirectory
            ? dirBadges(state.statusByPath)[rel]
            : state.statusByPath[rel];
        return FileTreeRow(
          node: node,
          depth: depth,
          badge: badge,
          onTap: () => _onTap(node),
          onLongPress: () => _onLongPress(node),
        );
      },
    );
  }

  void _onTap(FileTreeNode node) {
    if (node.entry.isDirectory) {
      ref.read(fileTreeProvider(widget.treeRef).notifier).toggleDir(node.entry.path);
      return;
    }
    context.push(filePreviewRouteUrl(node.entry.path, workspace: _ws));
  }

  void _onLongPress(FileTreeNode node) {
    showFileEntryActionsSheet(
      context,
      node: node,
      workspacePath: _ws,
      onAddToChat: widget.onAddToChat,
      onOpenPreview: () =>
          context.push(filePreviewRouteUrl(node.entry.path, workspace: _ws)),
    );
  }
}

/// 工具行: 搜索框 + (git 可用时) 变更/全部切换 + 刷新。
/// 搜索框自带 controller (State 持有), 外部清空 (clear 按钮) 走 onSearch('')。
class _ToolRow extends StatefulWidget {
  final String searchQuery;
  final ValueChanged<String> onSearch;
  final bool showFilter;
  final bool filterChangedOnly;
  final VoidCallback onToggleFilter;
  final VoidCallback onRefresh;

  const _ToolRow({
    required this.searchQuery,
    required this.onSearch,
    required this.showFilter,
    required this.filterChangedOnly,
    required this.onToggleFilter,
    required this.onRefresh,
  });

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.searchQuery,
  );

  @override
  void didUpdateWidget(covariant _ToolRow old) {
    super.didUpdateWidget(old);
    // 外部清空 (onSearch('') 后 state 回 0) 时同步输入框
    if (widget.searchQuery.isEmpty && _ctrl.text.isNotEmpty) {
      _ctrl.clear();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              onChanged: widget.onSearch,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索文件',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: widget.searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => widget.onSearch(''),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          if (widget.showFilter)
            IconButton(
              tooltip: widget.filterChangedOnly ? '显示全部文件' : '仅显示变更文件',
              onPressed: widget.onToggleFilter,
              icon: Icon(
                widget.filterChangedOnly
                    ? Icons.difference_rounded
                    : Icons.apps_rounded,
                size: 20,
              ),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd /home/admins/projects/zocde-app && flutter analyze lib/features/files && flutter test test/file_tree_screen_test.dart`
Expected: PASS(7 个用例全绿)。

- [ ] **Step 6: Commit**

```bash
cd /home/admins/projects/zocde-app
git add lib/features/files/screens/file_tree_screen.dart lib/features/files/widgets/file_tree_row.dart test/file_tree_screen_test.dart
git commit -m "feat: FileTreeScreen(树/搜索/变更过滤/长按菜单/三态) — 项目文件树 UI 层 (3/4)"
```

---

### Task 4: 接线 — 更多菜单入口 + chat_screen 组装

**Files:**
- Modify: `lib/features/chat/widgets/chat_floating_header.dart`(新增 `onOpenFileTree` 可空回调 + 菜单项)
- Modify: `lib/features/chat/screens/chat_screen.dart`(传回调:push FileTreeScreen + onAddToChat 插输入框)
- Test: `test/chat_floating_header_test.dart`(追加用例)

**Interfaces:**
- Consumes: Task 3 的 `FileTreeScreen(treeRef:, onAddToChat:)`、Task 2 的 `FileTreeRef`;chat_screen 既有 `_insertAtCursor(String)`(chat_screen.dart:1843)、`widget.chatRef.workspaceIdentity`、`widget.workspacePath`。
- Produces: 顶栏更多菜单「文件树」项 → 全屏文件树;「加入对话」→ 返回聊天页并在输入框光标处插入 `@<相对路径> `。

- [ ] **Step 1: 写失败测试**(在 `test/chat_floating_header_test.dart` 的 `main()` 里追加两个用例)

```dart
  testWidgets('更多菜单含「文件树」项且点击触发 onOpenFileTree', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: ChatFloatingHeader(
            title: 't',
            onMenuTap: () {},
            onNewChat: () {},
            onOpenFileTree: () => opened++,
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('文件树'), findsOneWidget);
    await tester.tap(find.text('文件树'));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('onOpenFileTree 为 null 时不渲染「文件树」项', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: ChatFloatingHeader(
            title: 't',
            onMenuTap: () {},
            onNewChat: () {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('文件树'), findsNothing);
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd /home/admins/projects/zocde-app && flutter test test/chat_floating_header_test.dart`
Expected: FAIL(无 `onOpenFileTree` 参数 → 编译错)。

- [ ] **Step 3: 修改 ChatFloatingHeader**(`lib/features/chat/widgets/chat_floating_header.dart`)

1. 字段区(`onOpenGit` 声明,约 :37 之后)加:

```dart
  /// 更多菜单 → 项目文件树 (null = 菜单项隐藏; chat_screen 恒传, 预留门控缝)。
  final VoidCallback? onOpenFileTree;
```

2. 构造函数参数列表(`this.onOpenGit,` 之后)加 `this.onOpenFileTree,`。
3. `_openMoreMenu` 的 sheet 里「新对话」ListTile 之后(「悬浮窗监视」之前)插入:

```dart
              if (onOpenFileTree != null)
                ListTile(
                  leading: const Icon(Icons.folder_open_rounded),
                  title: const Text('文件树'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onOpenFileTree!();
                  },
                ),
```

- [ ] **Step 4: chat_screen 接线**(`lib/features/chat/screens/chat_screen.dart`)

1. import 区(按文件现有相对路径风格)加:

```dart
import '../../files/screens/file_tree_screen.dart';
import '../../../providers/file_tree_provider.dart';
```

2. `ChatFloatingHeader(...)` 的参数里,`onOpenGit:` 之前插入:

```dart
        // 项目文件树 (对齐网页端 WorkspaceFileTree; 任何项目可用, 无门控)
        onOpenFileTree: () {
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => FileTreeScreen(
                treeRef: FileTreeRef(
                  workspacePath: widget.workspacePath,
                  workspaceIdentity: widget.chatRef.workspaceIdentity,
                ),
                onAddToChat: (rel) {
                  // 树页已 pop 自己; 此刻 chat 页在顶, 插入 @提及
                  _insertAtCursor('@$rel ');
                },
              ),
            ),
          );
        },
```

> 注意:闭包里的 `context` 是 `_FileTreeScreenState` 的 context,push 叠在 chat 页之上;`_insertAtCursor` 不主动取焦,符合既有焦点策略(chat_screen.dart:1858 注释)。

- [ ] **Step 5: 跑测试确认通过 + 全量回归**

Run: `cd /home/admins/projects/zocde-app && flutter analyze && flutter test`
Expected: analyze 无新告警;全量测试全绿(含既有 33 个测试文件,其中 worktree 中 pip 相关既有测试若本来就红,记录基线不修——先跑一次 `flutter test test/pip_overlay_card_test.dart` 确认其基线状态并在交付报告中注明)。

- [ ] **Step 6: Commit**

```bash
cd /home/admins/projects/zocde-app
git add lib/features/chat/widgets/chat_floating_header.dart lib/features/chat/screens/chat_screen.dart test/chat_floating_header_test.dart
git commit -m "feat: 顶栏更多菜单接入项目文件树 + 加入对话回填 @提及 — 项目文件树接线 (4/4)"
```

---

## 手测验收清单(全部任务后,主 agent 执行)

1. 打开聊天 → 更多 → 文件树:标题「文件树」,根列表目录先排序;
2. 展开目录懒加载,再点收起;
3. git 项目:默认「仅变更」,切「全部」可见全部;文件角标字母与 Git 页变更一致;
4. 非 git 项目:无过滤按钮,其余功能正常;
5. 搜索框输入过滤、清空恢复;
6. 点文件 → FilePreviewScreen 正常打开;
7. 长按文件:复制绝对/相对路径落剪贴板;「加入对话」回聊天页输入框出现 `@路径 `;
8. watcher:桌面端往已展开目录新增文件 → 手机侧 ~1s 自动出现;若通道未接通则手动刷新兜底、全程不报错;
9. 断网/桌面端关闭后打开树:「读取失败 + 重试」。
