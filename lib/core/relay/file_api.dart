// lib/core/relay/file_api.dart
//
// file 通道 typed 封装 (只读: readdir/watch; 写操作网页端也没有, 见 spec §1)。

import 'git_api.dart';
import 'relay_client.dart';

/// git_api.RpcCallFn 复用 (rpcCallMap 同形)。
export 'git_api.dart' show RpcCallFn;

/// file 通道名 (桌面端共享协议枚举原文 File:"file", app 已实测)。
const String kFileChannel = 'file';

/// fileWatcher wire (2026-10-27 3.16.3 抓包 + 网页 bundle 实证):
/// - channel: 'file-watcher'
/// - watch [{path}] (递归加 recursive:true) → OK {id}
/// - LISTEN 'onDynamicChange', 参数 = watchId 标量 (抓包 body:"115")
/// - 事件 body: {dirPath, changedPath} (网页树按 dirPath 局部刷新)
/// - unwatch [{id}]
const String kWatcherChannel = 'file-watcher';
const String kWatcherEvent = 'onDynamicChange';

/// LISTEN 订阅产物形 (relay_client.listenRawFrames 同形; 测试注入缝)。
typedef RawListen =
    ({
      Stream<Map<String, dynamic>> stream,
      void Function() dispose,
    }) Function(String channel, String event, dynamic listenArgs);

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

/// 目录变化事件 (fileWatcher onDynamicChange; 网页消费 dirPath+changedPath)。
class FileWatchEvent {
  /// 变化所属目录 (网页 WorkspaceFileTree 按 dirPath 定位刷新)。
  final String dirPath;

  /// 具体变化文件 (PptxFileWatch 等按文件路径消费)。
  final String changedPath;

  const FileWatchEvent({required this.dirPath, required this.changedPath});

  factory FileWatchEvent.fromBody(dynamic body) {
    final m = body is Map
        ? (body['raw'] is Map
              ? Map<String, dynamic>.from(body['raw'] as Map)
              : Map<String, dynamic>.from(body))
        : const <String, dynamic>{};
    return FileWatchEvent(
      dirPath: m['dirPath'] as String? ?? '',
      changedPath: (m['changedPath'] ?? m['path']) as String? ?? '',
    );
  }
}

/// watch + 订阅句柄: 一个目录一组 (watchId 专属 LISTEN, 对齐网页)。
typedef FileWatcherHandle =
    ({
      String path,
      String watchId,
      Stream<FileWatchEvent> events,
      void Function() dispose,
    });

class FileApi {
  final RpcCallFn _call;
  final RawListen _listenRaw;

  /// 生产构造: rpcCallMap + listenRawFrames。
  FileApi(RelayClient relay)
    : _call = ((channel, method, args) =>
          relay.rpcCallMap(channel, method, args)),
      _listenRaw = relay.listenRawFrames;

  /// 测试构造: 直接注入 RPC / LISTEN 函数。
  FileApi.direct(this._call, {RawListen? listenRaw})
    : _listenRaw =
          listenRaw ??
          ((c, e, l) => (
                stream: const Stream<Never>.empty(),
                dispose: () {},
              ));

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

  /// watch 一个目录并订阅其变更 (网页时序: 先 watch 拿 id, 再 LISTEN(id),
  /// 2026-10-27 抓包 frame 839/846/848 实证)。失败返回 null = 本会话降级
  /// 手动刷新, 不抛。
  Future<FileWatcherHandle?> watchAndListen(String path) async {
    String watchId;
    try {
      final b = await _call(kWatcherChannel, 'watch', [
        {'path': path},
      ]);
      watchId =
          (b['id'] ?? (b['raw'] is Map ? (b['raw'] as Map)['id'] : null))
              as String? ??
          '';
    } catch (_) {
      return null;
    }
    if (watchId.isEmpty) return null;
    final sub = _listenRaw(kWatcherChannel, kWatcherEvent, watchId);
    return (
      path: path,
      watchId: watchId,
      events: sub.stream.map(FileWatchEvent.fromBody),
      dispose: sub.dispose,
    );
  }

  /// 取消监听 (尽力而为, 吞错: 降级路径里 id 可能已失效)。
  Future<void> unwatch({required String watchId}) async {
    try {
      await _call(kWatcherChannel, 'unwatch', [
        {'id': watchId},
      ]);
    } catch (_) {}
  }
}
