import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/app_router.dart';

// ================================================================
// 路径解析纯函数 (供单测 / message_bubble / plan_card 复用)
// ================================================================

/// 文件链接解析结果 (路径 + 可选 1-based 初始行号)
class FileLinkTarget {
  final String path;

  /// 尾缀 `:42` 解析出的初始行号 (1-based), 无则 null
  final int? line;

  const FileLinkTarget({required this.path, this.line});
}

/// 行号后缀 `:42` (纯数字才算行号, 避免误伤普通冒号路径)
final RegExp _lineSuffixRe = RegExp(r':(\d+)$');

/// 解析 markdown 链接 / 变更文件条目 → (绝对或相对)路径 + 可选行号。
///
/// - `file://` URI → 去掉 scheme 得本地路径
/// - `/` 开头绝对路径 → 原样; 尾缀 `:42` 解析为初始行号并剥离
///   (仅处理 `/` 开头路径, 避免误伤 Windows 盘符场景)
/// - 相对路径 → 与 [workspace] 拼接 (剥离开头 `./`); 无 workspace 时原样返回
FileLinkTarget parseFileLinkTarget(String raw, {String? workspace}) {
  var p = raw.trim();

  // file:// URI → 去掉 scheme 得本地路径
  if (p.startsWith('file://')) {
    p = p.substring('file://'.length);
  }

  // 尾缀 :42 → 行号 (仅 `/` 开头路径处理, 防 Windows 盘符误伤)
  int? line;
  if (p.startsWith('/')) {
    final m = _lineSuffixRe.firstMatch(p);
    if (m != null) {
      line = int.tryParse(m.group(1)!);
      p = p.substring(0, m.start);
    }
  }

  // 相对路径 → 与 workspace 拼接
  final ws = (workspace ?? '').trim();
  if (!p.startsWith('/') && ws.isNotEmpty) {
    var rel = p;
    while (rel.startsWith('./')) {
      rel = rel.substring(2);
    }
    p = ws.endsWith('/') ? '$ws$rel' : '$ws/$rel';
  }

  return FileLinkTarget(path: p, line: line);
}

/// 构造文件预览页路由 URL (query 已 encode; [path] 传解析后的目标路径)
String filePreviewRouteUrl(String path, {String? workspace, int? line}) {
  final q = <String>[
    'path=${Uri.encodeComponent(path)}',
    if (workspace != null && workspace.isNotEmpty)
      'workspace=${Uri.encodeComponent(workspace)}',
    if (line != null) 'line=$line',
  ].join('&');
  return '${AppRoutes.filePreview}?$q';
}

// ================================================================
// 文件预览页
// ================================================================

/// 文件预览页 — 通过 relay 会话 RPC (file/readTextFile) 读远端文件内容。
///
/// go_router query 参数: `path`(原始路径, 可绝对可相对)、
/// `workspace`(可选, workspacePath)、`line`(可选, 1-based 初始行)。
class FilePreviewScreen extends ConsumerStatefulWidget {
  /// 原始路径 (可绝对可相对, 可带 `:42` 行号尾缀)
  final String path;

  /// workspacePath — 相对路径拼接用
  final String? workspace;

  /// 1-based 初始行号
  final int? line;

  const FilePreviewScreen({
    super.key,
    required this.path,
    this.workspace,
    this.line,
  });

  @override
  ConsumerState<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends ConsumerState<FilePreviewScreen> {
  /// 超过 256KB 只显示前 256KB
  static const int _maxBytes = 256 * 1024;

  /// 行号跳转估算: 20px/行 (mono 13px × height 1.5 ≈ 19.5, 取整)
  static const double _lineHeightPx = 20;

  late Future<String> _future = _load();
  final ScrollController _scroll = ScrollController();

  /// 解析后的目标路径
  FileLinkTarget get _target =>
      parseFileLinkTarget(widget.path, workspace: widget.workspace);

  /// 经 relay RPC 读远端文件全文 (契约: channel 'file' / readTextFile)
  Future<String> _load() async {
    final client = ref.read(relayClientProvider);
    if (client == null) {
      throw Exception('未连接桌面端, 无法读取文件');
    }
    final resp = await client.rpcCall('file', 'readTextFile', [
      {'path': _target.path},
    ]);
    if (!resp.isOk) {
      throw Exception(resp.errorMessage ?? '未知错误');
    }
    final body = resp.body;
    if (body is Map && body['content'] is String) {
      return body['content'] as String;
    }
    throw Exception('响应格式异常');
  }

  void _retry() {
    setState(() => _future = _load());
  }

  /// 按初始行号跳转 (20px/行 估算, 简单实现)
  void _jumpToLine() {
    final line = widget.line;
    if (line == null || line <= 1 || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final offset = (line - 1) * _lineHeightPx;
    _scroll.jumpTo(offset > max ? max : offset);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _target.path.isEmpty ? '(未指定路径)' : _target.path.split('/').last;

    return Scaffold(
      appBar: AppBar(
        // 长按标题查看完整路径
        title: GestureDetector(
          onLongPress: () => _showFullPath(context),
          child: Text(name),
        ),
      ),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _errorView(theme, '${snap.error}');
          }
          final content = snap.data ?? '';
          if (content.isEmpty) {
            return Center(
              child: Text(
                '(空文件)',
                style: TextStyle(
                  fontSize: AppTextSizes.bodySm,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          return _contentView(theme, content);
        },
      ),
    );
  }

  /// 正文: 行号 (4 位右对齐) + 全文, mono 等宽
  Widget _contentView(ThemeData theme, String content) {
    var text = content;
    var truncated = false;
    if (text.length > _maxBytes) {
      text = text.substring(0, _maxBytes);
      truncated = true;
    }
    final buf = StringBuffer();
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      buf.writeln('${(i + 1).toString().padLeft(4)}  ${lines[i]}');
    }
    // 内容落地后跳初始行 (每帧调度幂等, 无副作用)
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToLine());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (truncated)
          Container(
            width: double.infinity,
            color: AppColors.warningContainer,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: const Text(
              '文件过大, 仅显示前 256KB',
              style: TextStyle(
                fontSize: AppTextSizes.caption,
                color: AppColors.warning,
              ),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.all(AppSpacing.md),
            child: SelectableText(
              buf.toString(),
              style: AppText.mono(context, size: AppTextSizes.mono),
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorView(ThemeData theme, String message) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: AppColors.danger),
            const SizedBox(height: AppSpacing.md),
            Text(
              '无法读取文件',
              style: TextStyle(
                fontSize: AppTextSizes.titleSm,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTextSizes.bodySm,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _target.path,
              textAlign: TextAlign.center,
              style: AppText.mono(
                context,
                size: AppTextSizes.monoXs,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 长按标题 → 完整路径弹窗
  void _showFullPath(BuildContext context) {
    final path = _target.path;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完整路径'),
        content: SelectableText(
          path.isEmpty ? '(未指定)' : path,
          style: AppText.mono(ctx, size: AppTextSizes.monoSm),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
