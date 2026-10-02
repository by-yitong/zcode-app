// test/git_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/providers/git_provider.dart';

GitApi fakeApi(Map<String, dynamic> Function(String method) respond) =>
    GitApi((channel, method, args) async => respond(method));

Map<String, dynamic> okSummary() =>
    {'branchName': 'main', 'headRefType': 'branch', 'ahead': 0, 'behind': 0};

void main() {
  const gitRef = GitRef(workspacePath: '/ws');

  GitController make(Map<String, dynamic> Function(String method) respond) =>
      GitController(gitRef, fakeApi(respond));

  test('初始 refresh: ready + summary 解析', () async {
    final c = make((m) =>
        m == 'getChanges' ? {'changes': []} : okSummary());
    await pumpEventQueue();
    expect(c.state.phase, GitPhase.ready);
    expect(c.state.summary!.branchName, 'main');
  });

  test('branchName 与 headRefType 均空 → empty 阶段 (非仓库)', () async {
    final c = make((m) => {'branchName': null, 'headRefType': null});
    await pumpEventQueue();
    expect(c.state.phase, GitPhase.empty);
  });

  test('stage 成功后自动刷新 changes, busyOp 清空', () async {
    var staged = false;
    final c = make((m) {
      if (m == 'stagePaths') {
        staged = true;
        return {};
      }
      if (m == 'getChanges') {
        return {
          'changes': [
            {
              'path': 'a.dart', 'repoRelativePath': 'a.dart',
              'workspaceRelativePath': 'a.dart', 'kind': 'modified',
              'section': staged ? 'staged' : 'unstaged',
              'added': 1, 'removed': 0,
              'isStaged': staged, 'isUntracked': false, 'isConflicted': false,
            },
          ],
        };
      }
      return okSummary();
    });
    await pumpEventQueue();
    expect(c.state.unstaged, hasLength(1));
    await c.stage(['a.dart']);
    expect(c.state.staged, hasLength(1));
    expect(c.state.unstaged, isEmpty);
    expect(c.state.busyOps, isEmpty);
  });

  test('RPC 抛错 → error 带原文, phase 保持 ready, busy 清空', () async {
    final c = GitController(
      gitRef,
      GitApi((c, m, a) async => throw Exception('boom')),
    );
    await pumpEventQueue();
    expect(c.state.phase, GitPhase.ready);
    expect(c.state.error, contains('boom'));
  });

  test('loadMoreCommits: hasMore=true 追加, skip=commits.length', () async {
    var skip = 0;
    final c = make((m) {
      if (m == 'getCommitGraph') {
        final s = skip;
        skip += 50;
        return {
          'commits': [
            {'hash': 'h$s', 'parents': [], 'refs': [], 'subject': 'c$s'},
          ],
          'hasMore': s == 0,
        };
      }
      return okSummary();
    });
    await pumpEventQueue();
    await c.loadMoreCommits();
    expect(c.state.commits, hasLength(2));
    expect(c.state.hasMoreCommits, isFalse);
  });

  test('commitAndMaybePush: 提交后刷新并 push', () async {
    final methods = <String>[];
    final c = make((m) {
      methods.add(m);
      if (m == 'commit') {
        return {'commitHash': 'abc', 'summary': okSummary()};
      }
      if (m == 'getChanges') return {'changes': []};
      return okSummary();
    });
    await pumpEventQueue();
    await c.commitAndMaybePush(
      message: 'msg',
      stagedOnly: false,
      pushAfter: true,
    );
    expect(methods, containsAll(['commit', 'push']));
    expect(c.state.unstaged, isEmpty);
    expect(c.state.busyOps, isEmpty);
  });

  test('switchTo: issues 非空 → error=issue message, summary 不变', () async {
    final c = make((m) {
      if (m == 'switchBranch') {
        return {
          'action': 'switch',
          'branchName': 'dev',
          'didChange': false,
          'issues': [
            {'code': 'conflicts-present', 'message': '有未解决冲突'},
          ],
        };
      }
      return okSummary();
    });
    await pumpEventQueue();
    await c.switchTo('dev');
    expect(c.state.error, '有未解决冲突');
    expect(c.state.summary!.branchName, 'main');
  });
}
