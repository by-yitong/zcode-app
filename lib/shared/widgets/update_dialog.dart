/// 版本更新对话框 — 应用内下载 (进度) + 浏览器下载兜底
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/update_service.dart';
import '../theme/app_design_tokens.dart';

/// 弹出更新对话框; 返回用户是否选择了"本次忽略"
Future<bool> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(info: info),
  ).then((v) => v ?? false);
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null=未开始, -1=完成, 0..1=下载中
  String? _error;
  DownloadCancel? _cancel;

  String get _sizeLabel {
    final mb = widget.info.apkSize / 1024 / 1024;
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${widget.info.apkSize} B';
  }

  Future<void> _startDownload() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    _cancel = DownloadCancel();
    try {
      final path = await UpdateService.download(
        widget.info,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onCancel: _cancel,
      );
      if (!mounted) return;
      setState(() => _progress = -1);
      await UpdateService.install(path);
    } catch (e) {
      if (_cancel?.token.isCancelled ?? false) return; // 用户取消, 不算错误
      if (mounted) {
        setState(() {
          _error = '下载失败: $e';
          _progress = null;
        });
      }
    }
  }

  Future<void> _openBrowser() async {
    final uri = Uri.tryParse(widget.info.apkUrl);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.info;
    final downloading = _progress != null && _progress! >= 0;

    return AlertDialog(
      title: Text('发现新版本 v${info.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (info.notes.trim().isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(
                  info.notes,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '安装包 $_sizeLabel · 来源 GitHub Releases',
            style: TextStyle(
              fontSize: AppTextSizes.caption,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (downloading) ...[
            const SizedBox(height: AppSpacing.md),
            LinearProgressIndicator(
              value: _progress,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '正在下载 ${(_progress! * 100).toStringAsFixed(0)}%'
              '${_progress! > 0.99 ? ' · 即将安装' : ''}',
              style: TextStyle(
                fontSize: AppTextSizes.caption,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
      actions: [
        if (!downloading) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('本次忽略'),
          ),
          TextButton(
            onPressed: _openBrowser,
            child: const Text('浏览器下载'),
          ),
          FilledButton(
            onPressed: _startDownload,
            child: const Text('应用内更新'),
          ),
        ] else ...[
          if (_progress! < 0.99)
            TextButton(
              onPressed: () {
                _cancel?.cancel();
                Navigator.of(context).pop(false);
              },
              child: const Text('取消'),
            ),
        ],
      ],
    );
  }
}
