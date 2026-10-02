// lib/providers/git_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/relay/git_api.dart';
import 'app_providers.dart';

/// Git 面板引用 (workspacePath 必填)。
class GitRef {
  final String workspacePath;

  /// 工作区标识 (远程工作区形如 remote:ssh:host:22:user:path)。
  /// null 时服务端按 path 解析。写法对齐 [ChatRef]。
  final String? workspaceIdentity;

  const GitRef({required this.workspacePath, this.workspaceIdentity});

  @override
  bool operator ==(Object other) =>
      other is GitRef &&
      other.workspacePath == workspacePath &&
      other.workspaceIdentity == workspaceIdentity;

  @override
  int get hashCode => Object.hash(workspacePath, workspaceIdentity);
}

/// Git 面板阶段。
enum GitPhase {
  /// 首次加载中。
  loading,

  /// 正常展示 (含 detached HEAD)。
  ready,

  /// 非仓库 (branchName 与 headRefType 均空)。
  empty,
}

/// Git 面板不可变状态。
class GitState {
  final GitPhase phase;
  final GitSummary? summary;
  final List<GitChange> unstaged;
  final List<GitChange> staged;

  /// 分支列表; null = 尚未拉取 (惰性加载, 由 [GitController.loadBranches] 填充)。
  final List<GitBranchInfo>? branches;
  final List<GitCommitEntry> commits;
  final bool hasMoreCommits;

  /// 进行中的操作键 (如 'refresh' / 'stage:a.dart' / 'commit' / 'ai')。
  final Set<String> busyOps;
  final String? error;

  const GitState({
    required this.phase,
    required this.summary,
    required this.unstaged,
    required this.staged,
    required this.branches,
    required this.commits,
    required this.hasMoreCommits,
    required this.busyOps,
    required this.error,
  });

  const GitState.initial()
    : phase = GitPhase.loading,
      summary = null,
      unstaged = const [],
      staged = const [],
      branches = null,
      commits = const [],
      hasMoreCommits = false,
      busyOps = const {},
      error = null;

  GitState copyWith({
    GitPhase? phase,
    GitSummary? summary,
    List<GitChange>? unstaged,
    List<GitChange>? staged,
    List<GitBranchInfo>? branches,
    List<GitCommitEntry>? commits,
    bool? hasMoreCommits,
    Set<String>? busyOps,
    String? error,
  }) => GitState(
    phase: phase ?? this.phase,
    summary: summary ?? this.summary,
    unstaged: unstaged ?? this.unstaged,
    staged: staged ?? this.staged,
    branches: branches ?? this.branches,
    commits: commits ?? this.commits,
    hasMoreCommits: hasMoreCommits ?? this.hasMoreCommits,
    busyOps: busyOps ?? this.busyOps,
    error: error ?? this.error,
  );
}

/// Git 面板控制器 (Task 2: 状态管理)。
///
/// 语义约定:
/// - 构造即 [refresh] (provider 构造体内自动首拉);
/// - 所有操作通过 busyOps 占位防重入, finally 必清各自键;
/// - 错误统一写 state.error (原文 toString), 不抛给 UI。
class GitController extends StateNotifier<GitState> {
  final GitRef gitRef;
  final GitApi _api;

  GitController(this.gitRef, this._api) : super(const GitState.initial()) {
    // 构造末尾立即首拉 (fire-and-forget, 错误落在 state.error)。
    refresh();
  }

  String get _ws => gitRef.workspacePath;

  void _setBusy(String key) =>
      state = state.copyWith(busyOps: {...state.busyOps, key});

  void _clearBusy(String key) {
    if (!state.busyOps.contains(key)) return;
    state = state.copyWith(busyOps: {...state.busyOps}..remove(key));
  }

  /// 全量刷新: summary + 两段 changes + 提交图 并行拉取。
  /// branchName 与 headRefType 均空 → empty (非仓库);
  /// 异常 → error 带原文且 phase 落 ready (网络类失败不是"非仓库")。
  Future<void> refresh() async {
    _setBusy('refresh');
    try {
      final results = await Future.wait<Object?>([
        _api.getRepositorySummary(_ws),
        _api.getChanges(_ws, 'unstaged'),
        _api.getChanges(_ws, 'staged'),
        _api.getCommitGraph(_ws),
      ]);
      final summary = results[0] as GitSummary;
      final graph = results[3] as ({List<GitCommitEntry> commits, bool hasMore});
      final (unstaged, staged) = _splitChanges(results);
      state = GitState(
        phase: (summary.branchName == null && summary.headRefType == null)
            ? GitPhase.empty
            : GitPhase.ready,
        summary: summary,
        unstaged: unstaged,
        staged: staged,
        branches: state.branches,
        commits: graph.commits,
        hasMoreCommits: graph.hasMore,
        busyOps: {...state.busyOps}..remove('refresh'),
        error: null,
      );
    } catch (e) {
      state = state.copyWith(
        phase: GitPhase.ready,
        error: e.toString(),
        busyOps: {...state.busyOps}..remove('refresh'),
      );
    }
  }

  /// 按 isStaged 标志把两段 getChanges 结果归入未暂存/已暂存桶
  /// (服务端按 sourceId 返回, 但条目归属以 isStaged 字段为准)。
  (List<GitChange>, List<GitChange>) _splitChanges(List<Object?> results) => (
    [for (final c in results[1] as List<GitChange>) if (!c.isStaged) c],
    [for (final c in results[2] as List<GitChange>) if (c.isStaged) c],
  );

  /// 行级变更共用体: 逐路径占 busy 键 → RPC → 成功后重拉
  /// summary + 两段 getChanges (不动 commits/branches, 避免重置分页)。
  Future<void> _mutatePaths({
    required String opKey,
    required List<String> paths,
    required Future<void> Function() rpc,
  }) async {
    final keys = [for (final p in paths) '$opKey:$p'];
    for (final k in keys) {
      _setBusy(k);
    }
    try {
      await rpc();
      final results = await Future.wait<Object?>([
        _api.getRepositorySummary(_ws),
        _api.getChanges(_ws, 'unstaged'),
        _api.getChanges(_ws, 'staged'),
      ]);
      final (unstaged, staged) = _splitChanges(results);
      state = state.copyWith(
        summary: results[0] as GitSummary,
        unstaged: unstaged,
        staged: staged,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      for (final k in keys) {
        _clearBusy(k);
      }
    }
  }

  /// 暂存文件 (busy 键 'stage:<path>')。
  Future<void> stage(List<String> paths) => _mutatePaths(
    opKey: 'stage',
    paths: paths,
    rpc: () => _api.stagePaths(_ws, paths),
  );

  /// 取消暂存 (busy 键 'unstage:<path>')。
  Future<void> unstage(List<String> paths) => _mutatePaths(
    opKey: 'unstage',
    paths: paths,
    rpc: () => _api.unstagePaths(_ws, paths),
  );

  /// 丢弃变更 (busy 键 'discard:<path>')。
  Future<void> discard(List<String> paths, {required bool staged}) =>
      _mutatePaths(
        opKey: 'discard',
        paths: paths,
        rpc: () => _api.discardPaths(_ws, paths, staged: staged),
      );

  /// 分支切换/新建共用体: issues 非空 → error=首条 issue 文案且不动 summary;
  /// issues 空且 didChange → 全量 [refresh]。
  Future<void> _branchOp(
    String busyKey,
    Future<GitBranchOpResult> Function() rpc,
  ) async {
    _setBusy(busyKey);
    try {
      final r = await rpc();
      if (r.issues.isNotEmpty) {
        state = state.copyWith(error: r.issues.first.$2);
        return;
      }
      if (r.didChange) await refresh();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      _clearBusy(busyKey);
    }
  }

  /// 切换分支 (busy 键 'switch')。
  Future<void> switchTo(String branchName) => _branchOp(
    'switch',
    () => _api.switchBranch(_ws, branchName),
  );

  /// 新建分支并切换 (busy 键 'create')。
  Future<void> createAndSwitch(String branchName, String? startPoint) =>
      _branchOp(
        'create',
        () => _api.createBranchAndSwitch(_ws, branchName, startPoint),
      );

  /// 拉取本地分支列表 (惰性: state.branches 已有则跳过; busy 键 'branches')。
  Future<void> loadBranches() async {
    if (state.branches != null) return;
    _setBusy('branches');
    try {
      final b = await _api.getLocalBranches(_ws);
      state = state.copyWith(branches: b.branches);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      _clearBusy('branches');
    }
  }

  /// 提交图分页追加 (busy 键 'commits'): hasMoreCommits 才发,
  /// skip = commits.length; hasMore=false 后不再发。
  Future<void> loadMoreCommits() async {
    if (!state.hasMoreCommits || state.busyOps.contains('commits')) return;
    _setBusy('commits');
    try {
      final g = await _api.getCommitGraph(
        _ws,
        maxCount: 50,
        skip: state.commits.length,
      );
      state = state.copyWith(
        commits: [...state.commits, ...g.commits],
        hasMoreCommits: g.hasMore,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      _clearBusy('commits');
    }
  }

  /// AI 生成提交信息 (busy 键 'ai'): 只返回结果, 不写 state;
  /// 失败原样抛给调用方处理。
  Future<String> generateMessage() async {
    _setBusy('ai');
    try {
      return await _api.generateCommitMessage(_ws);
    } finally {
      _clearBusy('ai');
    }
  }

  /// 提交并可选 push (busy 键 'commit'): commit → 全量 [refresh] →
  /// pushAfter 时 push; push 失败只写 error, 不清已刷新的变更 (提交已成功)。
  Future<void> commitAndMaybePush({
    required String message,
    List<String>? paths,
    required bool stagedOnly,
    required bool pushAfter,
  }) async {
    _setBusy('commit');
    try {
      await _api.commit(_ws, message, paths: paths, stagedOnly: stagedOnly);
      await refresh();
      if (!pushAfter) return;
      try {
        await _api.push(_ws);
      } catch (e) {
        state = state.copyWith(error: e.toString());
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      _clearBusy('commit');
    }
  }
}

/// Git 面板 Provider (按 workspacePath+identity 区分, 离开页面自动销毁;
/// 构造体内立即首拉, 注册风格同 chatProvider)。
final gitProvider = StateNotifierProvider.autoDispose
    .family<GitController, GitState, GitRef>((ref, gitRef) {
      final relay = ref.watch(relayClientProvider);
      if (relay == null) throw StateError('RelayClient not available');
      return GitController(gitRef, GitApi(relay.rpcCallMap));
    });
