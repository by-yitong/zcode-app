// FileTreeScreen widget 测试 (不跑 golden): 三态/展开/长按菜单/过滤门控/加入对话。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/core/relay/file_api.dart';
import 'package:zcode_app/core/relay/git_api.dart';
import 'package:zcode_app/features/files/screens/file_tree_screen.dart';
import 'package:zcode_app/providers/file_tree_provider.dart';
import 'package:zcode_app/providers/git_provider.dart';

class FakeFileApi implements FileApi {
  FakeFileApi(this.dirs);
  final Map<String, List<FileEntry>> dirs;

  @override
  Future<List<FileEntry>> readdir(String path) async => dirs[path] ?? const [];

  // controller 走 GitApi.getIgnoredPaths, 本方法不被调用 (FileApi 接口成员, 补齐可编译)。
  @override
  Future<List<String>> getIgnoredPaths(
    String workspacePath,
    List<String> paths,
  ) async => const [];

  @override
  Future<FileWatcherInfo?> probeWatcher({
    required String rootPath,
    RawSubscribeFn? subscribeRaw,
  }) async => null;

  @override
  Future<String?> watchDir({required String channel, required String path}) async => null;

  @override
  Future<void> unwatch({required String channel, required String watchId}) async {}
}

class FakeGitApi implements GitApi {
  FakeGitApi({this.changes = const [], this.ignored = const [], this.isRepo = true});
  final List<GitChange> changes;
  final List<String> ignored;
  final bool isRepo;

  @override
  Future<List<GitChange>> getChanges(String ws, String sourceId) async =>
      sourceId == 'branch' ? const [] : changes;

  @override
  Future<List<String>> getIgnoredPaths(String ws, List<String> paths) async =>
      ignored.where(paths.contains).toList();

  @override
  Future<GitSummary> getRepositorySummary(String ws) async => GitSummary(
    branchName: isRepo ? 'main' : null,
    trackingBranchName: null,
    headRefType: isRepo ? 'branch' : null,
    ahead: 0,
    behind: 0,
    isGitAvailable: isRepo,
    isRepository: isRepo,
  );

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName} 未在测试中使用');
}

const treeRef = FileTreeRef(workspacePath: '/ws');

final rootEntries = [
  const FileEntry(name: 'lib', path: '/ws/lib', type: 'directory', isSymbolicLink: false),
  const FileEntry(name: 'README.md', path: '/ws/README.md', type: 'file', isSymbolicLink: false),
];

// 形参放宽为 FileApi: 根读取失败用例传 _FailingFileApi (非 FakeFileApi 子类)。
Widget wrap(Widget child, FileApi api, FakeGitApi git) => ProviderScope(
  overrides: [
    fileApiProvider.overrideWith((ref) => api),
    gitApiProvider.overrideWith((ref) => git),
    gitAvailabilityProvider.overrideWith((ref, arg) => Future.value(git.isRepo)),
  ],
  child: MaterialApp(home: child),
);

Future<void> pump(WidgetTester tester, FakeFileApi api, FakeGitApi git,
    {void Function(String)? onAddToChat}) async {
  await tester.pumpWidget(wrap(
    FileTreeScreen(treeRef: treeRef, onAddToChat: onAddToChat ?? (_) {}),
    api,
    git,
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('变更过滤默认开: 未命中文件剪枝; 切「全部」后可见', (tester) async {
    await pump(tester, FakeFileApi({'/ws': rootEntries}), FakeGitApi(changes: [
      GitChange.fromJson({
        'path': '/ws/lib/a.dart', 'repoRelativePath': 'lib/a.dart',
        'workspaceRelativePath': 'lib/a.dart', 'kind': 'modified',
      }),
    ]));
    expect(find.text('文件树'), findsOneWidget);
    // lib 目录按前缀命中保留; README.md 无变更被剪
    expect(find.text('lib'), findsOneWidget);
    expect(find.text('README.md'), findsNothing);

    await tester.tap(find.byTooltip('显示全部文件'));
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('点目录展开懒加载, 子层 ignored 过滤', (tester) async {
    await pump(
      tester,
      FakeFileApi({
        '/ws': rootEntries,
        '/ws/lib': [
          const FileEntry(name: 'node_modules', path: '/ws/lib/node_modules', type: 'directory', isSymbolicLink: false),
          const FileEntry(name: 'a.dart', path: '/ws/lib/a.dart', type: 'file', isSymbolicLink: false),
        ],
      }),
      FakeGitApi(ignored: ['/ws/lib/node_modules']),
    );
    // 先切全部, 让目录可见
    await tester.tap(find.byTooltip('显示全部文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('node_modules'), findsNothing);
  });

  testWidgets('长按文件弹 4 项菜单; 长按目录弹 2 项 (无加入对话/打开预览)', (tester) async {
    await pump(tester, FakeFileApi({'/ws': rootEntries}), FakeGitApi());
    await tester.tap(find.byTooltip('显示全部文件'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('README.md'));
    await tester.pumpAndSettle();
    expect(find.text('复制绝对路径'), findsOneWidget);
    expect(find.text('复制相对路径'), findsOneWidget);
    expect(find.text('加入对话'), findsOneWidget);
    expect(find.text('打开预览'), findsOneWidget);
    // 点 sheet 外关闭 (左上角空白)
    await tester.tapAt(const Offset(5, 60));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('lib'));
    await tester.pumpAndSettle();
    expect(find.text('复制绝对路径'), findsOneWidget);
    expect(find.text('加入对话'), findsNothing);
  });

  testWidgets('「加入对话」: pop 自身并回调相对路径 (不带 @)', (tester) async {
    String? added;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        fileApiProvider.overrideWith((ref) => FakeFileApi({'/ws': rootEntries})),
        gitApiProvider.overrideWith((ref) => FakeGitApi()),
        gitAvailabilityProvider.overrideWith((ref, arg) => Future.value(true)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.push(
              ctx,
              MaterialPageRoute<void>(
                builder: (_) => FileTreeScreen(
                  treeRef: treeRef,
                  onAddToChat: (rel) => added = rel,
                ),
              ),
            ),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('显示全部文件'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('README.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入对话'));
    await tester.pumpAndSettle();
    expect(added, 'README.md');
    expect(find.byType(FileTreeScreen), findsNothing);
    expect(find.text('OPEN'), findsOneWidget); // 回到了宿主页
  });

  testWidgets('非 git 项目: 过滤切换隐藏, 行照常渲染', (tester) async {
    await pump(
      tester,
      FakeFileApi({'/ws': rootEntries}),
      FakeGitApi(isRepo: false),
    );
    expect(find.byTooltip('仅显示变更文件'), findsNothing);
    expect(find.byTooltip('显示全部文件'), findsNothing);
    expect(find.text('README.md'), findsOneWidget); // 无过滤 = 全部可见
  });

  testWidgets('空目录空态; 根读取失败显示重试', (tester) async {
    await pump(tester, FakeFileApi({'/ws': const []}), FakeGitApi());
    expect(find.text('空目录'), findsOneWidget);
  });

  testWidgets('根读取失败: 「读取失败 + 重试」空态', (tester) async {
    final failing = _FailingFileApi();
    await tester.pumpWidget(wrap(
      FileTreeScreen(treeRef: treeRef, onAddToChat: (_) {}),
      failing,
      FakeGitApi(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}

class _FailingFileApi implements FileApi {
  @override
  Future<List<FileEntry>> readdir(String path) async => throw StateError('x');

  @override
  Future<List<String>> getIgnoredPaths(
    String workspacePath,
    List<String> paths,
  ) async => const [];

  @override
  Future<FileWatcherInfo?> probeWatcher({
    required String rootPath,
    RawSubscribeFn? subscribeRaw,
  }) async => null;

  @override
  Future<String?> watchDir({required String channel, required String path}) async => null;

  @override
  Future<void> unwatch({required String channel, required String watchId}) async {}
}
