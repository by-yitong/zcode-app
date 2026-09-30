// 输入框顶部"后台运行"指示条 — 运行中子智能体提取纯函数测试。
// runningSubagentsIn 是指示条的计数数据源: 只认 parts 里的
// SubagentPart.running (与网页端一致, backgroundWorks 的 subagent 条目不计数)。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/providers/chat_provider.dart';

DisplayMessage _msg(String id, List<MessagePart> parts) => DisplayMessage(
      id: id,
      role: 'assistant',
      content: '',
      parts: parts,
    );

SubagentPart _subagent(String rowIdKey, String status) => SubagentPart(
      subagentType: 'Explore',
      status: status,
      summaryText: '',
      rowIdKey: rowIdKey,
    );

void main() {
  test('空消息列表 → 空', () {
    expect(runningSubagentsIn(const []), isEmpty);
  });

  test('含 running SubagentPart → 含它', () {
    final s = _subagent('subagent_1', 'running');
    final out = runningSubagentsIn([_msg('m1', [s])]);
    expect(out, hasLength(1));
    expect(out.first, same(s));
  });

  test('success 状态的 SubagentPart → 不含', () {
    final out = runningSubagentsIn([
      _msg('m1', [_subagent('subagent_1', 'success')]),
    ]);
    expect(out, isEmpty);
  });

  test('多消息多个 running → 全部按序', () {
    final a = _subagent('subagent_1', 'running');
    final b = _subagent('subagent_2', 'running');
    final c = _subagent('subagent_3', 'running');
    final out = runningSubagentsIn([
      _msg('m1', [TextPart('hi'), a]),
      _msg('m2', [_subagent('x', 'failed'), b]),
      _msg('m3', [c, _subagent('y', 'cancelled')]),
    ]);
    expect(out, hasLength(3));
    expect(out[0], same(a));
    expect(out[1], same(b));
    expect(out[2], same(c));
  });

  test('ToolPart running 不算', () {
    final out = runningSubagentsIn([
      _msg('m1', [
        ToolPart(ToolActivity(
          toolCallId: 'tc_1',
          toolName: 'Bash',
          status: 'running',
        )),
      ]),
    ]);
    expect(out, isEmpty);
  });
}
