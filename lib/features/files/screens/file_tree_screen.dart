// lib/features/files/screens/file_tree_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/file_tree_provider.dart';
import '../../../providers/git_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../agent/widgets/caps_page_chrome.dart';
import '../../chat/screens/file_preview_screen.dart';
import '../widgets/file_tree_row.dart';

/// 项目文件树 (对齐网页端 WorkspaceFileTree; 只读)。
class FileTreeScreen extends ConsumerStatefulWidget {
  final FileTreeRef treeRef;

  /// 加入对话 (相对路径, 不带 @); 触发时本页已 pop。
  final void Function(String relativePath) onAddToChat;

  const FileTreeScreen({
    super.key,
    required this.treeRef,
    required this.onAddToChat,
  });

  @override
  ConsumerState<FileTreeScreen> createState() => _FileTreeScreenState();
}

class _FileTreeScreenState extends ConsumerState<FileTreeScreen> {
  String get _ws => widget.treeRef.workspacePath;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileTreeProvider(widget.treeRef));
    final ctrl = ref.read(fileTreeProvider(widget.treeRef).notifier);
    final gitOk = ref.watch(gitAvailabilityProvider(_ws)).valueOrNull == true;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: CapsPageHeader.overlayStyle(context),
      child: Scaffold(
        appBar: const CapsPageHeader(title: '文件树'),
        body: Column(
          children: [
            _ToolRow(
              searchQuery: state.searchQuery,
              onSearch: ctrl.setSearch,
              showFilter: gitOk,
              filterChangedOnly: state.filterChangedOnly,
              onToggleFilter: ctrl.toggleFilter,
              onRefresh: ctrl.refresh,
            ),
            const Divider(height: 1),
            Expanded(child: _body(state, gitOk)),
          ],
        ),
      ),
    );
  }

  Widget _body(FileTreeState state, bool gitOk) {
    if (state.phase == FileTreePhase.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.rootError != null) {
      return AppEmptyState(
        icon: Icons.error_outline_rounded,
        title: '读取失败',
        subtitle: state.rootError.toString(),
        actionLabel: '重试',
        actionIcon: Icons.refresh_rounded,
        onAction: () =>
            ref.read(fileTreeProvider(widget.treeRef).notifier).refresh(),
        iconTint: AppColors.dangerContainer,
      );
    }
    if (state.roots.isEmpty) {
      return const AppEmptyState(
        icon: Icons.folder_off_outlined,
        title: '空目录',
        subtitle: '当前项目没有可见文件',
      );
    }
    final rows = visibleRows(
      roots: state.roots,
      workspacePath: _ws,
      statusByPath: state.statusByPath,
      // 非 git 项目切换 UI 隐藏, 过滤同样不生效 (无过滤 = 全部可见)。
      changedOnly: state.filterChangedOnly && gitOk,
      search: state.searchQuery,
    );
    if (rows.isEmpty) {
      return const AppEmptyState(
        icon: Icons.search_off_rounded,
        title: '无匹配文件',
        subtitle: '换个关键词试试',
      );
    }
    final badges = dirBadges(state.statusByPath);
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (node, depth) = rows[i];
        final rel = relativePathOf(node.entry.path, _ws);
        final badge = node.entry.isDirectory
            ? badges[rel]
            : state.statusByPath[rel];
        return FileTreeRow(
          node: node,
          depth: depth,
          badge: badge,
          onTap: () => _onTap(node),
          onLongPress: () => _onLongPress(node),
        );
      },
    );
  }

  void _onTap(FileTreeNode node) {
    if (node.entry.isDirectory) {
      ref.read(fileTreeProvider(widget.treeRef).notifier).toggleDir(node.entry.path);
      return;
    }
    context.push(filePreviewRouteUrl(node.entry.path, workspace: _ws));
  }

  void _onLongPress(FileTreeNode node) {
    showFileEntryActionsSheet(
      context,
      node: node,
      workspacePath: _ws,
      onAddToChat: widget.onAddToChat,
      onOpenPreview: () =>
          context.push(filePreviewRouteUrl(node.entry.path, workspace: _ws)),
    );
  }
}

/// 工具行: 搜索框 + (git 可用时) 变更/全部切换 + 刷新。
/// 搜索框自带 controller (State 持有), 外部清空 (clear 按钮) 走 onSearch('')。
class _ToolRow extends StatefulWidget {
  final String searchQuery;
  final ValueChanged<String> onSearch;
  final bool showFilter;
  final bool filterChangedOnly;
  final VoidCallback onToggleFilter;
  final VoidCallback onRefresh;

  const _ToolRow({
    required this.searchQuery,
    required this.onSearch,
    required this.showFilter,
    required this.filterChangedOnly,
    required this.onToggleFilter,
    required this.onRefresh,
  });

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.searchQuery,
  );

  @override
  void didUpdateWidget(covariant _ToolRow old) {
    super.didUpdateWidget(old);
    // 外部清空 (onSearch('') 后 state 回 0) 时同步输入框
    if (widget.searchQuery.isEmpty && _ctrl.text.isNotEmpty) {
      _ctrl.clear();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              onChanged: widget.onSearch,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索文件',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: widget.searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => widget.onSearch(''),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          if (widget.showFilter)
            IconButton(
              tooltip: widget.filterChangedOnly ? '显示全部文件' : '仅显示变更文件',
              onPressed: widget.onToggleFilter,
              icon: Icon(
                widget.filterChangedOnly
                    ? Icons.difference_rounded
                    : Icons.apps_rounded,
                size: 20,
              ),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
