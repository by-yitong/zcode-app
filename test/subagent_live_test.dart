// 子智能体详情弹窗实时刷新 — 停止条件纯函数测试。
// hasRunningActivity 是弹窗轮询的停止条件: 嵌套子代理 (主行流查不到
// 权威行状态) 刷新后靠子会话内容判断是否仍在跑。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/providers/chat_provider.dart';

ToolPart _tool(String status) => ToolPart(ToolActivity(
      toolCallId: 'tc_1',
      toolName: 'Bash',
      status: status,
    ));

SubagentPart _subagent(String status) => SubagentPart(
      subagentType: 'Explore',
      status: status,
      summaryText: '摘要',
      rowIdKey: 'subagent_1',
    );

void main() {
  group('hasRunningActivity (弹窗轮询停止条件)', () {
    test('ToolPart running → true', () {
      expect(hasRunningActivity([_tool('running')]), isTrue);
    });

    test('ToolPart done + SubagentPart running → true', () {
      expect(
        hasRunningActivity([_tool('done'), _subagent('running')]),
        isTrue,
      );
    });

    test('全部 done → false', () {
      expect(
        hasRunningActivity([_tool('done'), _subagent('success')]),
        isFalse,
      );
    });

    test('空列表 → false', () {
      expect(hasRunningActivity(const <MessagePart>[]), isFalse);
    });

    test('混入 TextPart/ThoughtPart 不影响判定', () {
      // 只有文本/思考 → 不算运行中
      expect(
        hasRunningActivity([
          const TextPart('正文'),
          const ThoughtPart('思考'),
        ]),
        isFalse,
      );
      // 混在 running 工具前后 → 仍检出运行中
      expect(
        hasRunningActivity([
          const TextPart('正文'),
          _tool('progress'),
          const ThoughtPart('思考'),
        ]),
        isTrue,
      );
    });

    test('工具 running 的各种 wire 状态都算运行中', () {
      for (final s in [
        'scheduled',
        'started',
        'progress',
        'running',
        'inputStreaming',
        'pendingApproval',
      ]) {
        expect(hasRunningActivity([_tool(s)]), isTrue, reason: 'status=$s');
      }
    });

    test('子代理 success/failed/cancelled 均不算运行中', () {
      for (final s in ['success', 'failed', 'cancelled']) {
        expect(hasRunningActivity([_subagent(s)]), isFalse, reason: 'status=$s');
      }
    });
  });
}
