// lib/providers/file_tree_provider.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/relay/file_api.dart';
import '../core/relay/git_api.dart';
import 'app_providers.dart';
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
    this.error,
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

/// 目录(含符号链接目录)先, 名称按 ASCII 比较 (测试冻结期望序:
/// 'A.txt' 排 'a.dart' 前, 任何 case-insensitive 比较均推不出该序)。
int entrySortCompare(FileEntry a, FileEntry b) {
  final da = a.isDirectory ? 0 : 1;
  final db = b.isDirectory ? 0 : 1;
  if (da != db) return da - db;
  return a.name.compareTo(b.name);
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
      // 下钻条件 (测试冻结): 展开态、或搜索中 (搜索即全量找)、或非
      // changedOnly 浏览 (此时子行可见与否由子节点自身过滤决定)。
      final descend = n.expanded || q.isNotEmpty || !changedOnly;
      if (descend) {
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

  /// 增量拉取新条目的 git 忽略路径并入 state.ignoredPaths (子层懒加载
  /// 与根层同语义: 过滤是增强, 查询失败不挡浏览)。
  Future<void> _mergeIgnored(List<FileEntry> entries) async {
    try {
      final ignored = await _git.getIgnoredPaths(_ws, [
        for (final e in entries) e.path,
      ]);
      if (ignored.isEmpty) return;
      state = state.copyWith(
        ignoredPaths: {...state.ignoredPaths, ...ignored},
      );
    } catch (_) {}
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
      await _mergeIgnored(entries);
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
