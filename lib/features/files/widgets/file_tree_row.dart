// lib/features/files/widgets/file_tree_row.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../providers/file_tree_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';

/// 长按操作菜单 (对齐网页端右键: 复制双路径 / 加入对话 / 打开预览)。
/// [onOpenPreview] 仅文件项出现; 页面侧注入 (负责 pop 页面 + push 预览路由)。
Future<void> showFileEntryActionsSheet(
  BuildContext context, {
  required FileTreeNode node,
  required String workspacePath,
  required void Function(String relativePath) onAddToChat,
  VoidCallback? onOpenPreview,
}) {
  final e = node.entry;
  final rel = relativePathOf(e.path, workspacePath);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                e.name,
                style: Theme.of(sheetCtx).textTheme.titleMedium,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('复制绝对路径'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: e.path));
              Navigator.pop(sheetCtx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: const Text('复制相对路径'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: rel));
              Navigator.pop(sheetCtx);
            },
          ),
          if (!e.isDirectory)
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded),
              title: const Text('加入对话'),
              onTap: () {
                Navigator.pop(sheetCtx); // 关 sheet
                Navigator.pop(context); // 关文件树页
                onAddToChat(rel);
              },
            ),
          if (!e.isDirectory)
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: const Text('打开预览'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onOpenPreview?.call();
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// 树行: 深度缩进 + 目录/文件图标 + 名称 + git 状态标记 + 目录 chevron。
class FileTreeRow extends StatelessWidget {
  final FileTreeNode node;
  final int depth;

  /// 文件: 自身状态字母; 目录: 子树聚合字母; null = 无。
  final String? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const FileTreeRow({
    super.key,
    required this.node,
    required this.depth,
    this.badge,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = node.entry;
    final icon = e.isDirectory
        ? (e.isSymbolicLink
              // 简报给的 Icons.folder_symlink_rounded 在本 SDK 图标集不存在,
              // 取 folder_copy_outlined (双轮廓 = 指向他处的链接)。
              ? Icons.folder_copy_outlined
              : Icons.folder_rounded)
        : Icons.description_outlined;
    final iconColor = e.isDirectory
        ? (e.isSymbolicLink
              ? const Color(0xFF94A3B8)
              : const Color(0xFFF59E0B))
        : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md + depth * 16.0,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            if (node.loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor(badge!).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: statusColor(badge!),
                    ),
                  ),
                ),
              if (e.isDirectory)
                Icon(
                  node.expanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
