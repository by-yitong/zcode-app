// test/git_api_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/relay/git_api.dart';

void main() {
  late List<(String, String, dynamic)> calls;
  late Map<String, dynamic> Function(String, String, dynamic) responder;
  late GitApi api;

  setUp(() {
    calls = [];
    responder = (channel, method, args) {
      calls.add((channel, method, args));
      return const {};
    };
    // 经由变量间接转发: 各测试重赋 responder 后对 api 立即生效
    // (GitApi 构造时捕获的是函数值, 直接传 responder 会固化首个实现)。
    api = GitApi((channel, method, args) async => responder(channel, method, args));
  });

  test('getChanges: channel=git, sourceId 原样透传', () async {
    responder = (c, m, a) {
      calls.add((c, m, a));
      return {
        'changes': [
          {
            'path': 'lib/a.dart',
            'repoRelativePath': 'lib/a.dart',
            'workspaceRelativePath': 'lib/a.dart',
            'kind': 'modified',
            'section': 'unstaged',
            'added': 3,
            'removed': 1,
            'isStaged': false,
            'isUntracked': false,
            'isConflicted': false,
          },
        ],
      };
    };
    final changes = await api.getChanges('/ws', 'unstaged');
    final (channel, method, args) = calls.single;
    expect(channel, 'git');
    expect(method, 'getChanges');
    expect(args, {'workspacePath': '/ws', 'sourceId': 'unstaged'});
    expect(changes.single.path, 'lib/a.dart');
    expect(changes.single.added, 3);
  });

  test('getRepositorySummary 解析 ahead/behind/branchName', () async {
    responder = (c, m, a) {
      calls.add((c, m, a));
      return {
        'branchName': 'main',
        'trackingBranchName': 'origin/main',
        'headRefType': 'branch',
        'ahead': 2,
        'behind': 1,
      };
    };
    final s = await api.getRepositorySummary('/ws');
    expect(calls.single.$1, 'git');
    expect(s.branchName, 'main');
    expect(s.ahead, 2);
    expect(s.isDetached, isFalse);
  });

  test('commit 参数严格, 返回 commitHash+summary', () async {
    responder = (c, m, a) {
      calls.add((c, m, a));
      return {
        'commitHash': 'abc123',
        'summary': {'branchName': 'main', 'headRefType': 'branch'},
      };
    };
    final r = await api.commit('/ws', 'msg', paths: ['a.dart']);
    expect(calls.single.$3, {
      'workspacePath': '/ws',
      'message': 'msg',
      'paths': ['a.dart'],
    });
    expect(r.commitHash, 'abc123');
    expect(r.summary!.branchName, 'main');
  });

  test('getCommitGraph 解析 commits+hasMore', () async {
    responder = (c, m, a) {
      calls.add((c, m, a));
      return {
        'commits': [
          {
            'hash': 'h1',
            'parents': ['p0'],
            'refs': ['origin/main', 'main'],
            'subject': 'feat: x',
            'authorName': 'yt',
            'authoredAtMs': 1700000000000,
          },
        ],
        'hasMore': true,
      };
    };
    final page = await api.getCommitGraph('/ws', maxCount: 50, skip: 0);
    expect(calls.single.$3, {'workspacePath': '/ws', 'maxCount': 50, 'skip': 0});
    expect(page.commits.single.subject, 'feat: x');
    expect(page.hasMore, isTrue);
  });

  test('getLocalBranches 解析 branches, 当前分支标记', () async {
    responder = (c, m, a) {
      return {
        'headRefType': 'branch',
        'currentBranchName': 'main',
        'branches': [
          {'name': 'main', 'isCurrent': true, 'upstreamName': 'origin/main'},
          {'name': 'dev', 'isCurrent': false},
        ],
      };
    };
    final r = await api.getLocalBranches('/ws');
    expect(r.currentBranchName, 'main');
    expect(r.branches.first.isCurrent, isTrue);
    expect(r.branches.last.upstreamName, isNull);
  });

  test('switchBranch 返回 didChange/issues 解析', () async {
    responder = (c, m, a) {
      calls.add((c, m, a));
      return {
        'action': 'switch',
        'branchName': 'dev',
        'didChange': true,
        'created': false,
        'issues': [],
      };
    };
    final r = await api.switchBranch('/ws', 'dev');
    expect(calls.single.$3, {'workspacePath': '/ws', 'targetBranchName': 'dev'});
    expect(r.didChange, isTrue);
    expect(r.issues, isEmpty);
  });

  test('写操作: stage/discard/push/refresh 参数正确', () async {
    await api.stagePaths('/ws', ['a.dart']);
    expect(calls[0].$2, 'stagePaths');
    expect(calls[0].$3, {'workspacePath': '/ws', 'paths': ['a.dart']});

    await api.discardPaths('/ws', ['a.dart']);
    expect(calls[1].$3, {'workspacePath': '/ws', 'paths': ['a.dart']});

    await api.push('/ws');
    expect(calls[2].$3, {'workspacePath': '/ws'});

    await api.refresh('/ws');
    expect(calls[3].$3, {'workspacePath': '/ws'});
  });

  test('generateCommitMessage: 默认 includeUnstaged=true + locale 透传', () async {
    responder = (c, m, a) {
      calls.add((c, m, a));
      return {'message': 'feat: 生成的信息'};
    };
    final msg = await api.generateCommitMessage('/ws', locale: 'zh-CN');
    expect(calls.single.$3, {
      'workspacePath': '/ws',
      'includeUnstaged': true,
      'locale': 'zh-CN',
    });
    expect(msg, 'feat: 生成的信息');
  });

  test('getDiff 解析 patch', () async {
    responder = (c, m, a) {
      calls.add((c, m, a));
      return {'patch': '+++ b/a.dart', 'summary': null};
    };
    final d = await api.getDiff('/ws', 'a.dart', 'unstaged');
    expect(calls.single.$3, {
      'workspacePath': '/ws',
      'path': 'a.dart',
      'sourceId': 'unstaged',
    });
    expect(d.patch, '+++ b/a.dart');
  });
}
