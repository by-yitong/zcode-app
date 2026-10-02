// test/git_tabs_test.dart
// 分支 Tab (列表/切换/新建) + 历史 Tab (分页提交列表) (Task 5)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/features/git/screens/git_screen.dart';
import 'package:zcode_app/providers/git_provider.dart';

/// 假 api: [calls] 非空时记录方法名; args 原样透传给 [respond]。
GitApi fakeApi(
  Map<String, dynamic> Function(String method, Map<String, dynamic> args)
  respond, {
  List<String>? calls,
}) =>
    GitApi((channel, method, args) async {
      calls?.add(method);
      return respond(method, Map<String, dynamic>.from(args as Map));
    });

Map<String, dynamic> summaryJson({
  String branch = 'main',
  String refType = 'branch',
  int ahead = 0,
  int behind = 0,
}) =>
    {
      'branchName': branch,
      'trackingBranchName': null,
      'headRefType': refType,
      'ahead': ahead,
      'behind': behind,
    };

Map<String, dynamic> branchJson(
  String name, {
  bool current = false,
  String? upstream,
}) =>
    {
      'name': name,
      'isCurrent': current,
      'upstreamName': upstream,
      'commitHash': 'abcdef1234567890',
      'commitTimestampMs': 1700000000000,
    };

Map<String, dynamic> commitJson(
  String hash,
  String subject, {
  List<String> refs = const [],
  String author = 'alice',
  int? ageMs,
}) =>
    {
      'hash': hash,
      'parents': [],
      'refs': refs,
      'subject': subject,
      'authorName': author,
      'authoredAtMs': ageMs ??
          DateTime.now()
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
    };

Future<void> pumpGitScreen(WidgetTester tester, GitApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gitProvider(const GitRef(workspacePath: '/ws')).overrideWith(
          (ref) => GitController(const GitRef(workspacePath: '/ws'), api),
        ),
      ],
      child: const MaterialApp(
        home: GitScreen(gitRef: GitRef(workspacePath: '/ws')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('分支 Tab: 列表渲染 + 当前行高亮 + tracking 副标题', (tester) async {
    await pumpGitScreen(
      tester,
      fakeApi((m, a) {
        if (m == 'getRepositorySummary') return summaryJson(branch: 'develop');
        if (m == 'getLocalBranches') {
          return {
            'branches': [
              branchJson('develop', current: true, upstream: 'origin/develop'),
              branchJson('feature/x'),
            ],
          };
        }
        if (m == 'getChanges') return {'changes': []};
        return {'commits': [], 'hasMore': false};
      }),
    );
    await tester.tap(find.text('分支'));
    await tester.pumpAndSettle();

    expect(find.text('feature/x'), findsOneWidget);
    expect(find.text('origin/develop'), findsOneWidget); // tracking 副标题
    expect(find.byIcon(Icons.check_rounded), findsOneWidget); // 当前行勾标
    expect(find.text('当前'), findsOneWidget); // 当前行高亮标签
    expect(find.text('新建分支'), findsOneWidget);
  });

  testWidgets('detached HEAD: 分支 Tab 琥珀提示条 + 无「当前」行 + 头部 HEAD (detached)', (
    tester,
  ) async {
    await pumpGitScreen(
      tester,
      fakeApi((m, a) {
        // detached 模拟: headRefType 非 'branch' 即 isDetached (git_api.dart:31)。
        // 注意 branchName 与 headRefType 不可同时为 null — 会被 GitController
        // 判为非仓库 empty 态 (git_provider.dart:143), 故 headRefType 用 'commit'。
        if (m == 'getRepositorySummary') {
          return summaryJson(branch: '', refType: 'commit');
        }
        if (m == 'getLocalBranches') {
          // 服务端即使标记 isCurrent=true, 客户端以 summary 推导 → 不得高亮。
          return {
            'branches': [branchJson('main', current: true)],
          };
        }
        if (m == 'getChanges') return {'changes': []};
        return {'commits': [], 'hasMore': false};
      }),
    );
    await tester.tap(find.text('分支'));
    await tester.pumpAndSettle();

    // 琥珀提示条: 文案 + task-5 brief 指定色 Color(0xFFF59E0B)。
    expect(find.textContaining('HEAD 处于分离状态'), findsOneWidget);
    final containers = tester.widgetList<Container>(
      find.ancestor(
        of: find.textContaining('HEAD 处于分离状态'),
        matching: find.byType(Container),
      ),
    );
    expect(
      containers.map((c) => c.color),
      contains(const Color(0xFFF59E0B)),
    );
    // 无当前行: 不出现「当前」标签与勾标 (服务端 isCurrent 被忽略)。
    expect(find.text('当前'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    // 头部卡片 detached 兜底文案 (git_screen.dart:195)。
    expect(find.text('HEAD (detached)'), findsOneWidget);
  });

  testWidgets('点非当前分支 → 确认弹窗 → switchBranch → summary 更新', (tester) async {
    final calls = <String>[];
    final captured = <String, Map<String, dynamic>>{};
    var current = 'develop';
    await pumpGitScreen(
      tester,
      fakeApi((m, a) {
        if (m == 'getRepositorySummary') return summaryJson(branch: current);
        if (m == 'getLocalBranches') {
          return {
            'branches': [
              branchJson('develop', current: current == 'develop'),
              branchJson('feature/x', current: current == 'feature/x'),
            ],
          };
        }
        if (m == 'switchBranch') {
          captured[m] = a;
          current = a['targetBranchName'] as String? ?? current;
          return {
            'action': 'switch',
            'branchName': current,
            'didChange': true,
            'created': false,
            'issues': [],
          };
        }
        if (m == 'getChanges') return {'changes': []};
        return {'commits': [], 'hasMore': false};
      }, calls: calls),
    );
    await tester.tap(find.text('分支'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('feature/x'));
    await tester.pumpAndSettle();
    expect(find.textContaining('切换到 feature/x'), findsOneWidget);

    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();

    expect(calls, contains('switchBranch'));
    expect(captured['switchBranch']?['targetBranchName'], 'feature/x');
    expect(find.textContaining('切换到 feature/x'), findsNothing); // 弹窗已关
    expect(find.text('feature/x'), findsWidgets); // 头部卡片已切到新分支
    expect(find.text('当前'), findsOneWidget);
  });

  testWidgets('新建分支: 输入名 + 展开起点输入 → createBranchAndSwitch', (tester) async {
    final calls = <String>[];
    final captured = <String, Map<String, dynamic>>{};
    await pumpGitScreen(
      tester,
      fakeApi((m, a) {
        if (m == 'getRepositorySummary') return summaryJson(branch: 'develop');
        if (m == 'getLocalBranches') {
          return {
            'branches': [branchJson('develop', current: true)],
          };
        }
        if (m == 'createBranchAndSwitch') {
          captured[m] = a;
          return {
            'action': 'create',
            'branchName': a['branchName'],
            'didChange': true,
            'created': true,
            'issues': [],
          };
        }
        if (m == 'getChanges') return {'changes': []};
        return {'commits': [], 'hasMore': false};
      }, calls: calls),
    );
    await tester.tap(find.text('分支'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建分支'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'feature/new');
    await tester.pump();
    await tester.tap(find.text('指定起点 (可选)')); // 折叠项展开
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'develop');
    await tester.pump();

    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(calls, contains('createBranchAndSwitch'));
    expect(captured['createBranchAndSwitch']?['branchName'], 'feature/new');
    expect(captured['createBranchAndSwitch']?['startPoint'], 'develop');
  });

  testWidgets('历史 Tab: 短 hash + subject + 作者·相对时间 + refs Chip', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await pumpGitScreen(
      tester,
      fakeApi((m, a) {
        if (m == 'getRepositorySummary') return summaryJson();
        if (m == 'getChanges') return {'changes': []};
        if (m == 'getCommitGraph') {
          return {
            'commits': [
              commitJson(
                'abcdef1234567890abcdef1234567890abcdef12',
                'feat: add tabs',
                refs: ['HEAD -> main', 'tag: v1.0'],
                ageMs: now - 2 * 3600 * 1000,
              ),
              commitJson(
                '11111122223333',
                'chore: cleanup',
                author: 'bob',
                ageMs: now - 3 * 24 * 3600 * 1000,
              ),
            ],
            'hasMore': false,
          };
        }
        return {'branches': []};
      }),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();

    expect(find.text('abcdef1'), findsOneWidget); // 7 位短 hash
    expect(find.text('feat: add tabs'), findsOneWidget);
    expect(find.text('alice · 2 小时前'), findsOneWidget);
    expect(find.text('bob · 3 天前'), findsOneWidget);
    expect(find.text('v1.0'), findsOneWidget); // ref chip (去 tag: 前缀)
    expect(find.text('main'), findsNWidgets(2)); // 头部卡片 + 当前分支 chip
  });

  testWidgets('历史触底 → hasMore 时拉下一页 (skip=50)', (tester) async {
    final skips = <int>[];
    List<Map<String, dynamic>> page(int skip, int n) => [
          for (var i = 0; i < n; i++)
            commitJson(
              (skip + i).toRadixString(16).padLeft(40, 'a'),
              'commit $skip-$i',
            ),
        ];
    await pumpGitScreen(
      tester,
      fakeApi((m, a) {
        if (m == 'getRepositorySummary') return summaryJson();
        if (m == 'getChanges') return {'changes': []};
        if (m == 'getCommitGraph') {
          final skip = (a['skip'] as num?)?.toInt() ?? 0;
          skips.add(skip);
          return {
            'commits': page(skip, skip == 0 ? 50 : 10),
            'hasMore': skip == 0,
          };
        }
        return {'branches': []};
      }),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(skips, [0]); // 首屏第一页

    // 触底触发分页 (大列表一次拖不到底, 循环拖到 skip=50 出现)
    for (var i = 0; i < 6 && !skips.contains(50); i++) {
      await tester.drag(
        find.byKey(const Key('history-list')),
        const Offset(0, -2000),
      );
      await tester.pump();
      await tester.pumpAndSettle();
    }

    expect(skips, contains(50));
    expect(find.textContaining('commit 50-0'), findsOneWidget); // 第二页已渲染
  });
}
