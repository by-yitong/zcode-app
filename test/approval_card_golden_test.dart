import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/features/chat/widgets/approval_cards.dart';
import 'package:zcode_app/providers/chat_provider.dart';

/// 空白审批卡排查: 用真实 wire 数据形状渲染 Bash / Write 两种权限卡,
/// matchesGoldenFile 落盘 PNG (--update-goldens 生成后人工查看)。
void main() {
  final dark = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF3B82F6),
      brightness: Brightness.dark,
    ),
  );

  PendingPermission bashPerm() => PendingPermission(
        id: 'perm_test_bash',
        toolCallId: 'call_bash',
        toolName: 'Bash',
        reason: '运行 grep 命令搜索权限相关代码，需要执行前确认',
        riskLevel: 'medium',
        input: const {
          'command': 'grep -rn "allowOnce" lib/ | head -20',
          'description': 'Search code',
        },
        options: const [
          PermissionOption(
              optionId: 'allowOnce', kind: 'allowOnce', name: 'Allow once'),
          PermissionOption(
              optionId: 'allowAlways',
              kind: 'allowAlways',
              name: 'Always allow in this project'),
          PermissionOption(
              optionId: 'deny',
              kind: 'deny',
              name: 'Deny',
              decision: 'deny'),
        ],
      );

  PendingPermission writePerm() => PendingPermission(
        id: 'perm_test_write',
        toolCallId: 'call_write',
        toolName: 'Write',
        reason: '创建新文件',
        riskLevel: 'medium',
        input: const {
          'file_path': '/home/admins/projects/zocde-app/lib/new_file.dart',
        },
        options: const [
          PermissionOption(
              optionId: 'allowOnce', kind: 'allowOnce', name: 'Allow once'),
          PermissionOption(
              optionId: 'allowAlways',
              kind: 'allowAlways',
              name: 'Always allow in this project'),
          PermissionOption(
              optionId: 'deny',
              kind: 'deny',
              name: 'Deny',
              decision: 'deny'),
        ],
      );

  Widget host(PendingPermission perm) => MaterialApp(
        theme: dark,
        home: Scaffold(
          backgroundColor: const Color(0xFF09090A),
          body: Center(
            child: ListView(
              reverse: true,
              padding: const EdgeInsets.all(12),
              children: [
                ApprovalCard(
                  perm: perm,
                  theme: dark,
                  onAnswer: (_, __) {},
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('ApprovalCard Bash 渲染 golden', (tester) async {
    tester.view.physicalSize = const Size(1080, 600);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(host(bashPerm()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ApprovalCard),
      matchesGoldenFile('goldens/approval_card_bash.png'),
    );
  });

  testWidgets('ApprovalCard Write 渲染 golden', (tester) async {
    tester.view.physicalSize = const Size(1080, 600);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(host(writePerm()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ApprovalCard),
      matchesGoldenFile('goldens/approval_card_write.png'),
    );
  });
}
