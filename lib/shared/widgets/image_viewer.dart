import 'package:flutter/material.dart';

/// 全屏图片预览: 黑底 + 双指缩放/平移 + 点图或右上角关闭。
Future<void> showImageViewer(BuildContext context, ImageProvider image) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _ImageViewerPage(image: image),
    ),
  );
}

class _ImageViewerPage extends StatelessWidget {
  final ImageProvider image;

  const _ImageViewerPage({required this.image});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Image(image: image, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}
