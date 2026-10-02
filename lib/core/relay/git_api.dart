// lib/core/relay/git_api.dart

/// git 通道 RPC 返回的 Map (已由 RelayClient.rpcCallMap 归一)。
typedef RpcCallFn = Future<Map<String, dynamic>> Function(
  String channel,
  String method,
  dynamic args,
);

/// git 通道名 (桌面端共享协议枚举原文 Git:"git")。
const String kGitChannel = 'git';

/// 仓库状态摘要 (getStatus().summary)。
class GitSummary {
  final String? branchName;
  final String? trackingBranchName;

  /// "branch" = 正常分支; 其他值 (含 null) 视为 detached/异常。
  final String? headRefType;
  final int ahead;
  final int behind;

  const GitSummary({
    required this.branchName,
    required this.trackingBranchName,
    required this.headRefType,
    required this.ahead,
    required this.behind,
  });

  bool get isDetached => headRefType != 'branch';

  factory GitSummary.fromJson(Map<String, dynamic> j) => GitSummary(
    branchName: j['branchName'] as String?,
    trackingBranchName: j['trackingBranchName'] as String?,
    headRefType: j['headRefType'] as String?,
    ahead: (j['ahead'] as num?)?.toInt() ?? 0,
    behind: (j['behind'] as num?)?.toInt() ?? 0,
  );
}

/// 单个文件变更 (getChanges 条目)。
class GitChange {
  final String path;
  final String repoRelativePath;
  final String workspaceRelativePath;
  final String kind; // modified/added/deleted/renamed…
  final String section; // unstaged/staged/untracked/conflicted
  final int added;
  final int removed;
  final bool isStaged;
  final bool isUntracked;
  final bool isConflicted;

  const GitChange({
    required this.path,
    required this.repoRelativePath,
    required this.workspaceRelativePath,
    required this.kind,
    required this.section,
    required this.added,
    required this.removed,
    required this.isStaged,
    required this.isUntracked,
    required this.isConflicted,
  });

  factory GitChange.fromJson(Map<String, dynamic> j) => GitChange(
    path: j['path'] as String? ?? '',
    repoRelativePath: j['repoRelativePath'] as String? ?? '',
    workspaceRelativePath: j['workspaceRelativePath'] as String? ?? '',
    kind: j['kind'] as String? ?? 'modified',
    section: j['section'] as String? ?? 'unstaged',
    added: (j['added'] as num?)?.toInt() ?? 0,
    removed: (j['removed'] as num?)?.toInt() ?? 0,
    isStaged: j['isStaged'] as bool? ?? false,
    isUntracked: j['isUntracked'] as bool? ?? false,
    isConflicted: j['isConflicted'] as bool? ?? false,
  );
}

/// 本地分支 (getLocalBranches 条目; 服务端已按当前在前/时间倒序排好)。
class GitBranchInfo {
  final String name;
  final bool isCurrent;
  final String? upstreamName;
  final String? commitHash;
  final int? commitTimestampMs;

  const GitBranchInfo({
    required this.name,
    required this.isCurrent,
    required this.upstreamName,
    required this.commitHash,
    required this.commitTimestampMs,
  });

  factory GitBranchInfo.fromJson(Map<String, dynamic> j) => GitBranchInfo(
    name: j['name'] as String? ?? '',
    isCurrent: j['isCurrent'] as bool? ?? false,
    upstreamName: j['upstreamName'] as String?,
    commitHash: j['commitHash'] as String?,
    commitTimestampMs: (j['commitTimestampMs'] as num?)?.toInt(),
  );
}

/// 提交条目 (getCommitGraph; git log %H %P %an %at %s %D)。
class GitCommitEntry {
  final String hash;
  final List<String> parents;
  final List<String> refs;
  final String subject;
  final String? authorName;
  final int? authoredAtMs;

  const GitCommitEntry({
    required this.hash,
    required this.parents,
    required this.refs,
    required this.subject,
    required this.authorName,
    required this.authoredAtMs,
  });

  factory GitCommitEntry.fromJson(Map<String, dynamic> j) => GitCommitEntry(
    hash: j['hash'] as String? ?? '',
    parents: [
      for (final p in (j['parents'] as List<dynamic>? ?? const [])) p as String,
    ],
    refs: [
      for (final r in (j['refs'] as List<dynamic>? ?? const [])) r as String,
    ],
    subject: j['subject'] as String? ?? '',
    authorName: j['authorName'] as String?,
    authoredAtMs: (j['authoredAtMs'] as num?)?.toInt(),
  );
}

/// 切换/新建分支结果: issues 非空 = 未成功 (含原因), 此时 didChange=false。
class GitBranchOpResult {
  final String action;
  final String? branchName;
  final bool didChange;
  final bool created;
  final GitSummary? summary;
  final List<(String, String)> issues; // (code, message)

  const GitBranchOpResult({
    required this.action,
    required this.branchName,
    required this.didChange,
    required this.created,
    required this.summary,
    required this.issues,
  });

  factory GitBranchOpResult.fromJson(Map<String, dynamic> j) =>
      GitBranchOpResult(
        action: j['action'] as String? ?? '',
        branchName: j['branchName'] as String?,
        didChange: j['didChange'] as bool? ?? false,
        created: j['created'] as bool? ?? false,
        summary: j['summary'] is Map
            ? GitSummary.fromJson(
                Map<String, dynamic>.from(j['summary'] as Map),
              )
            : null,
        issues: [
          for (final i in (j['issues'] as List<dynamic>? ?? const []))
            if (i is Map)
              (
                (i['code'] as String? ?? ''),
                (i['message'] as String? ?? ''),
              ),
        ],
      );
}

class GitDiff {
  final String? patch;

  const GitDiff({required this.patch});

  factory GitDiff.fromJson(Map<String, dynamic> j) =>
      GitDiff(patch: j['patch'] as String?);
}

class GitCommitResult {
  final String commitHash;
  final GitSummary? summary;

  const GitCommitResult({required this.commitHash, required this.summary});

  factory GitCommitResult.fromJson(Map<String, dynamic> j) =>
      GitCommitResult(
        commitHash: j['commitHash'] as String? ?? '',
        summary: j['summary'] is Map
            ? GitSummary.fromJson(
                Map<String, dynamic>.from(j['summary'] as Map),
              )
            : null,
      );
}

List<GitChange> _parseChanges(Map<String, dynamic> body) => [
  for (final c in (body['changes'] as List<dynamic>? ?? const []))
    GitChange.fromJson(Map<String, dynamic>.from(c as Map)),
];

/// git 通道 typed 封装。所有方法参数即 wire 字段, 不多传 (服务端 zod strict)。
class GitApi {
  final RpcCallFn _call;

  GitApi(this._call);

  /// wire 约定: 参数以「数组」上帧 (服务端展开为位置参数), 与 relay_client
  /// 既有方法一致。曾发裸对象导致服务端解构不出参数, 全部 git RPC 报
  /// "Cannot read properties of undefined (reading 'workspacePath')"。
  Future<Map<String, dynamic>> _rpc(String method, dynamic args) =>
      _call(kGitChannel, method, [args]);

  Future<GitSummary> getRepositorySummary(String workspacePath) async =>
      GitSummary.fromJson(
        await _rpc('getRepositorySummary', {'workspacePath': workspacePath}),
      );

  /// sourceId: unstaged / staged / branch
  Future<List<GitChange>> getChanges(
    String workspacePath,
    String sourceId,
  ) async => _parseChanges(
    await _rpc('getChanges', {
      'workspacePath': workspacePath,
      'sourceId': sourceId,
    }),
  );

  Future<GitDiff> getDiff(
    String workspacePath,
    String path,
    String sourceId,
  ) async => GitDiff.fromJson(
    await _rpc('getDiff', {
      'workspacePath': workspacePath,
      'path': path,
      'sourceId': sourceId,
    }),
  );

  Future<({String? headRefType, String? currentBranchName, List<GitBranchInfo> branches})>
  getLocalBranches(String workspacePath) async {
    final b = await _rpc('getLocalBranches', {'workspacePath': workspacePath});
    return (
      headRefType: b['headRefType'] as String?,
      currentBranchName: b['currentBranchName'] as String?,
      branches: [
        for (final x in (b['branches'] as List<dynamic>? ?? const []))
          GitBranchInfo.fromJson(Map<String, dynamic>.from(x as Map)),
      ],
    );
  }

  Future<GitBranchOpResult> switchBranch(
    String workspacePath,
    String targetBranchName,
  ) async => GitBranchOpResult.fromJson(
    await _rpc('switchBranch', {
      'workspacePath': workspacePath,
      'targetBranchName': targetBranchName,
    }),
  );

  Future<GitBranchOpResult> createBranchAndSwitch(
    String workspacePath,
    String branchName,
    String? startPoint,
  ) async => GitBranchOpResult.fromJson(
    await _rpc('createBranchAndSwitch', {
      'workspacePath': workspacePath,
      'branchName': branchName,
      if (startPoint != null && startPoint.isNotEmpty) 'startPoint': startPoint,
    }),
  );

  Future<({List<GitCommitEntry> commits, bool hasMore})> getCommitGraph(
    String workspacePath, {
    int maxCount = 50,
    int skip = 0,
  }) async {
    final b = await _rpc('getCommitGraph', {
      'workspacePath': workspacePath,
      'maxCount': maxCount,
      'skip': skip,
    });
    return (
      commits: [
        for (final c in (b['commits'] as List<dynamic>? ?? const []))
          GitCommitEntry.fromJson(Map<String, dynamic>.from(c as Map)),
      ],
      hasMore: b['hasMore'] as bool? ?? false,
    );
  }

  Future<void> stagePaths(String workspacePath, List<String> paths) async {
    await _rpc('stagePaths', {'workspacePath': workspacePath, 'paths': paths});
  }

  Future<void> unstagePaths(String workspacePath, List<String> paths) async {
    await _rpc('unstagePaths', {
      'workspacePath': workspacePath,
      'paths': paths,
    });
  }

  Future<void> discardPaths(
    String workspacePath,
    List<String> paths, {
    bool staged = false,
  }) async {
    await _rpc('discardPaths', {
      'workspacePath': workspacePath,
      'paths': paths,
      // staged 为可选字段, 默认 (false) 不发送 (zod strict 不多传)。
      if (staged) 'staged': staged,
    });
  }

  /// 返回 AI 生成的提交信息 (生成在桌面端执行, App 只收结果)。
  Future<String> generateCommitMessage(
    String workspacePath, {
    bool includeUnstaged = true,
    String? locale,
  }) async {
    final b = await _rpc('generateCommitMessage', {
      'workspacePath': workspacePath,
      'includeUnstaged': includeUnstaged,
      if (locale != null) 'locale': locale,
    });
    return b['message'] as String? ?? '';
  }

  Future<GitCommitResult> commit(
    String workspacePath,
    String message, {
    List<String>? paths,
    bool stagedOnly = false,
  }) async => GitCommitResult.fromJson(
    await _rpc('commit', {
      'workspacePath': workspacePath,
      'message': message,
      if (paths != null && paths.isNotEmpty) 'paths': paths,
      if (stagedOnly) 'stagedOnly': true,
    }),
  );

  Future<Map<String, dynamic>> push(String workspacePath) async =>
      _rpc('push', {'workspacePath': workspacePath});

  Future<GitSummary> refresh(String workspacePath) async => GitSummary.fromJson(
    await _rpc('refresh', {'workspacePath': workspacePath}),
  );
}
