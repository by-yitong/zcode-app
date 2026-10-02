// test/git_screen_test.dart
// GitScreen 三 Tab 骨架 + 更改 Tab 全操作 (Task 3)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/features/git/screens/git_screen.dart';
import 'package:zcode_app/providers/git_provider.dart';

GitApi fakeApi(
  Map<String, dynamic> Function(String method) respond,
) => GitApi((channel, method, args) async => respond(method));

Map<String, dynamic> okSummary({int ahead = 0, int behind = 0}) => {
  'branchName': 'main',
  'headRefType': 'branch',
  'ahead': ahead,
  'behind': behind,
};

Map<String, dynamic> changeJson(
  String path, {
  String kind = 'modified',
  String section = 'unstaged',
  int added = 1,
  int removed = 0,
  bool isStaged = false,
  bool isUntracked = false,
  bool isConflicted = false,
}) => {
  'path': path,
  'repoRelativePath': path,
  'workspaceRelativePath': path,
  'kind': kind,
  'section': section,
  'added': added,
  'removed': removed,
  'isStaged': isStaged,
  'isUntracked': isUntracked,
  'isConflicted': isConflicted,
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
  testWidgets('ready 态: 渲染 TabBar (更改/分支/历史) + 分支名 + ahead/behind 徽标', (
    tester,
  ) async {
    await pumpGitScreen(
      tester,
      fakeApi((m) => m == 'getRepositorySummary'
          ? okSummary(ahead: 2, behind: 3)
          : <String, dynamic>{'changes': []}),
    );
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('更改'), findsOneWidget);
    expect(find.text('分支'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.textContaining('↑2'), findsOneWidget);
    expect(find.textContaining('↓3'), findsOneWidget);
  });

  testWidgets('未暂存文件行渲染路径与 +1 −0', (tester) async {
    await pumpGitScreen(
      tester,
      fakeApi((m) {
        if (m == 'getChanges') {
          return {
            'changes': [changeJson('a.dart')],
          };
        }
        return okSummary();
      }),
    );
    expect(find.text('未暂存 (1)'), findsOneWidget);
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.textContaining('+1 −0', findRichText: true), findsOneWidget);
    expect(find.text('已暂存 (0)'), findsOneWidget);
    expect(find.text('没有已暂存的更改'), findsOneWidget);
  });

  testWidgets('点行内「暂存」→ 假 api 收到 stagePaths', (tester) async {
    final calls = <String>[];
    await pumpGitScreen(
      tester,
      fakeApi((m) {
        calls.add(m);
        if (m == 'getRepositorySummary') return okSummary();
        if (m == 'getChanges') {
          return {
            'changes': [changeJson('a.dart')],
          };
        }
        return {};
      }),
    );
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂存'));
    await tester.pumpAndSettle();
    expect(calls, contains('stagePaths'));
  });

  testWidgets('丢弃 → 确认弹窗 → discardPaths', (tester) async {
    final calls = <String>[];
    final api = GitApi((c, m, a) async {
      calls.add(m);
      if (m == 'getRepositorySummary') {
        return {'branchName': 'main', 'headRefType': 'branch', 'ahead': 0, 'behind': 0};
      }
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
      return {};
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gitProvider(const GitRef(workspacePath: '/ws')).overrideWith(
            (ref) => GitController(const GitRef(workspacePath: '/ws'), api),
          ),
        ],
        child: const MaterialApp(home: GitScreen(gitRef: GitRef(workspacePath: '/ws'))),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first); // 行内操作菜单
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不可恢复'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '丢弃').last);
    await tester.pumpAndSettle();
    expect(calls, contains('discardPaths'));
  });

  testWidgets('branchName/headRefType 均空 → 引导文案, 无 TabBar', (tester) async {
    await pumpGitScreen(
      tester,
      fakeApi((m) => m == 'getRepositorySummary'
          ? <String, dynamic>{'branchName': null, 'headRefType': null}
          : <String, dynamic>{'changes': []}),
    );
    expect(find.text('当前工作区不是 Git 仓库或 git 不可用'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
  });
}
