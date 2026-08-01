import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../shared/theme/app_design_tokens.dart';

/// 二维码扫码页
///
/// 扫描 zcode 桌面端显示的连接二维码 (内容是 /remote/v3?sid=... URL),
/// 扫到后返回 URL 字符串给登录页。
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _detected = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_detected) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final value = barcodes.first.rawValue;
    if (value == null || value.isEmpty) return;

    // 只接受 zcode 连接地址 (含 sid + hash + mid)
    if (!value.contains('zcode.z.ai') ||
        !value.contains('sid=') ||
        !value.contains('hash=') ||
        !value.contains('mid=')) {
      // 不是 zcode 二维码, 忽略继续扫
      return;
    }

    _detected = true;
    _controller.stop();
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫码连接'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          // 手电筒
          IconButton(
            icon: const Icon(Icons.flash_on),
            tooltip: '手电筒',
            onPressed: () => _controller.toggleTorch(),
          ),
          // 切换前后摄像头
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            tooltip: '切换摄像头',
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 扫码视图
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // 扫码框遮罩
          CustomPaint(
            painter: _ScannerOverlayPainter(),
            child: const SizedBox.expand(),
          ),
          // 底部提示
          Positioned(
            left: 0,
            right: 0,
            bottom: 48,
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Text(
                    '将 ZCode 桌面端的二维码对准框内',
                    style: TextStyle(color: Colors.white, fontSize: AppTextSizes.bodyMd),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 扫码框遮罩绘制
class _ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 扫码框 (屏幕宽度的 70%, 正方形)
    final boxSize = w * 0.7;
    final left = (w - boxSize) / 2;
    final top = (h - boxSize) / 2;

    // 半透明遮罩 (框外区域)
    final paint = Paint()..color = Colors.black54;
    // 上
    canvas.drawRect(Rect.fromLTRB(0, 0, w, top), paint);
    // 下
    canvas.drawRect(Rect.fromLTRB(0, top + boxSize, w, h), paint);
    // 左
    canvas.drawRect(Rect.fromLTRB(0, top, left, top + boxSize), paint);
    // 右
    canvas.drawRect(
        Rect.fromLTRB(left + boxSize, top, w, top + boxSize), paint);

    // 框边角
    final cornerPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    const cornerLen = 24.0;
    // 左上
    canvas.drawLine(Offset(left, top), Offset(left + cornerLen, top), cornerPaint);
    canvas.drawLine(Offset(left, top), Offset(left, top + cornerLen), cornerPaint);
    // 右上
    canvas.drawLine(Offset(left + boxSize, top), Offset(left + boxSize - cornerLen, top), cornerPaint);
    canvas.drawLine(Offset(left + boxSize, top), Offset(left + boxSize, top + cornerLen), cornerPaint);
    // 左下
    canvas.drawLine(Offset(left, top + boxSize), Offset(left + cornerLen, top + boxSize), cornerPaint);
    canvas.drawLine(Offset(left, top + boxSize), Offset(left, top + boxSize - cornerLen), cornerPaint);
    // 右下
    canvas.drawLine(Offset(left + boxSize, top + boxSize), Offset(left + boxSize - cornerLen, top + boxSize), cornerPaint);
    canvas.drawLine(Offset(left + boxSize, top + boxSize), Offset(left + boxSize, top + boxSize - cornerLen), cornerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
