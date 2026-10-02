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

  test('commit 成功后 push 失败 → error 写入且变更列表已清空', () async {
    var committed = false;
    var pushed = false;
    Map<String, dynamic> change(String path) => {
          'path': path,
          'repoRelativePath': path,
          'workspaceRelativePath': path,
          'kind': 'modified',
          'section': 'unstaged',
          'added': 1,
          'removed': 0,
          'isStaged': false,
          'isUntracked': false,
          'isConflicted': false,
        };
    final c = make((m) {
      if (m == 'commit') {
        committed = true;
        return {'commitHash': 'abc', 'summary': okSummary()};
      }
      if (m == 'push') {
        pushed = true;
        throw Exception('push rejected (no upstream)');
      }
      if (m == 'getChanges') {
        // commit 后 refresh → 变更已清空 (提交成功语义)。
        return {'changes': committed ? [] : [change('a.dart')]};
      }
      return okSummary();
    });
    await pumpEventQueue();
    expect(c.state.unstaged, hasLength(1));
    await c.commitAndMaybePush(
      message: 'msg',
      stagedOnly: false,
      pushAfter: true,
    );
    expect(committed, isTrue);
    expect(pushed, isTrue);
    expect(c.state.error, contains('push rejected (no upstream)'));
    expect(c.state.unstaged, isEmpty); // 变更列表已清空, 不因 push 失败回滚
    expect(c.state.staged, isEmpty);
    expect(c.state.busyOps, isEmpty); // 'commit' busy 键已清
  });

  test('commit 本身失败 → error 写入, push 不发, 变更保留', () async {
    final methods = <String>[];
    final c = make((m) {
      methods.add(m);
      if (m == 'commit') throw Exception('nothing to commit');
      if (m == 'getChanges') {
        return {
          'changes': [
            {
              'path': 'a.dart', 'repoRelativePath': 'a.dart',
              'workspaceRelativePath': 'a.dart', 'kind': 'modified',
              'section': 'unstaged', 'added': 1, 'removed': 0,
              'isStaged': false, 'isUntracked': false, 'isConflicted': false,
            },
          ],
        };
      }
      return okSummary();
    });
    await pumpEventQueue();
    await c.commitAndMaybePush(
      message: 'msg',
      stagedOnly: false,
      pushAfter: true,
    );
    expect(methods, isNot(contains('push'))); // 提交失败不推送
    expect(c.state.error, contains('nothing to commit'));
    expect(c.state.unstaged, hasLength(1)); // 未清空 (提交未成功)
    expect(c.state.busyOps, isEmpty);
  });

  test('generateMessage: 参数含非空 locale (系统语言, spec §3.4)', () async {
    final argsSeen = <Map<String, dynamic>>[];
    final c = GitController(
      gitRef,
      GitApi((channel, method, args) async {
        if (method == 'generateCommitMessage') {
          argsSeen.add(Map<String, dynamic>.from(args as Map));
          return {'message': 'feat: ai'};
        }
        return okSummary();
      }),
    );
    await pumpEventQueue();
    final msg = await c.generateMessage();
    expect(msg, 'feat: ai');
    expect(argsSeen, hasLength(1));
    final locale = argsSeen.single['locale'] as String?;
    expect(locale, isNotNull);
    expect(locale, isNotEmpty);
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
