// lib/core/relay/file_api.dart
//
// file 通道 typed 封装 (只读: readdir/watch; 写操作网页端也没有, 见 spec §1)。

import 'git_api.dart';
import 'relay_client.dart';

/// git_api.RpcCallFn 复用 (rpcCallMap 同形)。
export 'git_api.dart' show RpcCallFn;

/// file 通道名 (桌面端共享协议枚举原文 File:"file", app 已实测)。
const String kFileChannel = 'file';

/// fileWatcher 通道候选 (spec §4.3 冻结探测顺序):
/// 1. file-watcher (外围域 kebab 规律推断, 同 mcp-sync/model-provider)
/// 2. file 通道上的 watch 方法 (兜底: FileWatcher 与 File 在桌面通道表相邻)
const List<({String channel, String listenEvent})> kWatcherCandidates = [
  (channel: 'file-watcher', listenEvent: 'onDidChange'),
  (channel: 'file', listenEvent: 'watch'),
];

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
              : Map<String, dynamic>.from(body))
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
  ///
  /// subscribeRawFrames 需具名 activate 参数, 与 RawSubscribeFn (3 位置参
  /// 测试缝) 不同形, 故包一层空 activate: subscribeRawFrames 返回前 LISTEN
  /// 已发出且路由表已注册 (controller 非广播, 先到的帧会缓冲), watch 由
  /// [probeWatcher] 在订阅返回后再发, 时序仍满足「先 LISTEN 后 watch」。
  FileApi(RelayClient relay)
    : _call = ((channel, method, args) =>
          relay.rpcCallMap(channel, method, args)),
      _subscribeRaw =
          ((channel, event, listenArgs) => relay.subscribeRawFrames(
                channel,
                event,
                listenArgs,
                activate: () async {},
              ));

  /// 测试构造: 直接注入 RPC / 订阅函数。
  FileApi.direct(this._call, {RawSubscribeFn? subscribeRaw})
    : _subscribeRaw =
          subscribeRaw ?? ((c, e, l) async => const Stream.empty());

  /// 列目录 (includeHidden 恒 true, 忽略项由 getIgnoredPaths 过滤, 对齐网页端)。
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

  /// 忽略路径过滤 (readdir 后用它过滤 git 忽略项, 对齐网页端)。走 git 通道,
  /// wire/解析复用 [GitApi.getIgnoredPaths] (裸数组 | {paths:[...]} 双兼容)。
  Future<List<String>> getIgnoredPaths(
    String workspacePath,
    List<String> paths,
  ) => GitApi(_call).getIgnoredPaths(workspacePath, paths);

  /// 探测 fileWatcher 通道 (spec §4.3): 依序试候选, 先挂 LISTEN 订阅再调
  /// watch, 全成功即命中并返回句柄; 全失败返回 null (= 本会话降级手动刷新,
  /// 不抛)。rootPath 的 watch 探针即根目录监听本体, 命中后不 unwatch
  /// (controller 复用)。候选失败时 LISTEN 暂无独立退订口 (RawSubscribeFn 缝
  /// 只出不进), 留待断线时 _indexFrameSubs 统一清理, 单次探测至多残留 1 条。
  /// [subscribeRaw] 为逐次注入缝 (测试用; 生产省略, 落到构造注入的实现)。
  Future<FileWatcherInfo?> probeWatcher({
    required String rootPath,
    RawSubscribeFn? subscribeRaw,
  }) async {
    final subscribe = subscribeRaw ?? _subscribeRaw;
    for (final c in kWatcherCandidates) {
      try {
        final raw = await subscribe(c.channel, c.listenEvent, const {});
        final b = await _call(c.channel, 'watch', [
          {'path': rootPath},
        ]);
        final watchId =
            (b['id'] ?? (b['raw'] is Map ? (b['raw'] as Map)['id'] : null))
                as String?;
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
