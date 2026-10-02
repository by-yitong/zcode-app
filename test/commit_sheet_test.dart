// test/commit_sheet_test.dart
// Task 4: showCommitSheet (勾选列表 / 按勾选提交 / AI 生成 / 空 message 禁用)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/features/git/widgets/commit_sheet.dart';
import 'package:zcode_app/providers/git_provider.dart';

Map<String, dynamic> _okSummary() =>
    {'branchName': 'main', 'headRefType': 'branch', 'ahead': 0, 'behind': 0};

Map<String, dynamic> _changeJson(
  String path, {
  bool isStaged = false,
  String section = 'unstaged',
}) =>
    {
      'path': path,
      'repoRelativePath': path,
      'workspaceRelativePath': path,
      'kind': 'modified',
      'section': section,
      'added': 1,
      'removed': 0,
      'isStaged': isStaged,
      'isUntracked': false,
      'isConflicted': false,
    };

/// 假 api: 记录每次 RPC args 到 [calls]; 变更 = a.dart(未暂存) + b.dart(已暂存)。
GitApi _fakeApi(Map<String, Map<String, dynamic>> calls) => GitApi((
      channel,
      method,
      args,
    ) async {
      calls[method] = Map<String, dynamic>.from(args as Map);
      if (method == 'getRepositorySummary') return _okSummary();
      if (method == 'getChanges') {
        return {
          'changes': [
            _changeJson('a.dart'),
            _changeJson('b.dart', isStaged: true, section: 'staged'),
          ],
        };
      }
      if (method == 'generateCommitMessage') return {'message': 'feat: ai'};
      if (method == 'commit') return {'commitHash': 'h1'};
      return <String, dynamic>{};
    });

Future<void> _pumpSheet(
  WidgetTester tester,
  Map<String, Map<String, dynamic>> calls,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gitProvider(const GitRef(workspacePath: '/ws')).overrideWith(
          (ref) => GitController(const GitRef(workspacePath: '/ws'), _fakeApi(calls)),
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () =>
                    showCommitSheet(context, ref, const GitRef(workspacePath: '/ws')),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('弹出后渲染勾选列表, 默认全选 (勾选计数 = 变更数)', (tester) async {
    await _pumpSheet(tester, {});
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    final tiles = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(tiles.every((t) => t.value == true), isTrue);
  });

  testWidgets('勾掉一个文件提交 → commit 收到剩余 paths, 弹窗关闭', (tester) async {
    final calls = <String, Map<String, dynamic>>{};
    await _pumpSheet(tester, calls);
    await tester.tap(find.text('b.dart'));
    await tester.pumpAndSettle();
    // message 必填 (空则提交按钮禁用), 先填入再提交。
    await tester.enterText(find.byType(TextField), 'test: msg');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '提交'));
    await tester.pumpAndSettle();
    expect(calls['commit']?['paths'], ['a.dart']);
    expect(find.byType(CheckboxListTile), findsNothing); // 提交成功 → 弹窗已关
  });

  testWidgets('点 AI 生成 → TextField 填入假返回 message', (tester) async {
    await _pumpSheet(tester, {});
    await tester.tap(find.byIcon(Icons.auto_awesome));
    await tester.pumpAndSettle();
    expect(find.text('feat: ai'), findsOneWidget);
  });

  testWidgets('message 为空时提交按钮 onPressed == null; 输入后可用', (tester) async {
    await _pumpSheet(tester, {});
    FilledButton btnOf() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '提交'));
    expect(btnOf().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'fix: x');
    await tester.pumpAndSettle();
    expect(btnOf().onPressed, isNotNull);
  });

  // 缺陷复现 (勿删): task-7-brief:16 契约「summary.isDetached=true 时
  // GitScreen 不提供 push 入口」, 但 commit_sheet.dart:185-196 的
  // 「提交后推送」Checkbox 无 isDetached 门控, detached 下仍可达。
  // 修复后去掉 skip, 本用例应转绿。
  testWidgets('detached HEAD: 提交弹窗不应提供「提交后推送」入口', (tester) async {
    final calls = <String, Map<String, dynamic>>{};
    final api = GitApi((channel, method, args) async {
      calls[method] = Map<String, dynamic>.from(args as Map);
      if (method == 'getRepositorySummary') {
        // detached: headRefType 非 'branch' (与 branchName 不同时为 null)。
        return <String, dynamic>{
          'branchName': null,
          'trackingBranchName': null,
          'headRefType': 'commit',
          'ahead': 0,
          'behind': 0,
        };
      }
      if (method == 'getChanges') {
        return {'changes': [_changeJson('a.dart')]};
      }
      return <String, dynamic>{};
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gitProvider(const GitRef(workspacePath: '/ws')).overrideWith(
            (ref) => GitController(const GitRef(workspacePath: '/ws'), api),
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showCommitSheet(
                    context,
                    ref,
                    const GitRef(workspacePath: '/ws'),
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    // 契约: detached 时 push 入口不可达 → 「提交后推送」不得出现。
    expect(find.text('提交后推送'), findsNothing);
  }, skip: true); // skip 原因见上方注释: detached 未隐藏 push 入口, 待派修
}
