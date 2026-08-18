// 探索折叠组 (桌面端同款) 的分类器与吸收逻辑测试。
// 规则来源: 桌面端 app.asar 渲染 bundle 逆向 (VB/S2e/V6e/H6e)。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/features/chat/widgets/execution_trace.dart';
import 'package:zcode_app/providers/chat_provider.dart';

ToolActivity _act(
  String name, {
  String status = 'completed',
  Map<String, dynamic>? input,
}) => ToolActivity(
  toolCallId: 'tc_$name',
  toolName: name,
  status: status,
  input: input,
);

void main() {
  group('toolFamily (桌面端 VB 正则链)', () {
    test('家族分类', () {
      expect(toolFamily('read'), 'file-read');
      expect(toolFamily('Read'), 'file-read');
      expect(toolFamily('read_file'), 'file-read');
      expect(toolFamily('view'), 'file-read');
      expect(toolFamily('edit'), 'file-write');
      expect(toolFamily('apply_patch'), 'file-write');
      expect(toolFamily('bash'), 'shell');
      expect(toolFamily('execute_command'), 'shell');
      expect(toolFamily('grep'), 'search');
      expect(toolFamily('glob'), 'search');
      expect(toolFamily('web_search'), 'search');
      expect(toolFamily('ls'), 'search');
      expect(toolFamily('explore'), 'explore');
      expect(toolFamily('inspect'), 'explore');
      expect(toolFamily('mcp__srv__tool'), isNull);
      // 与桌面端 VB 一致: todo_write 按正则落 file-write
      // (todo 工具在上游 isTodoTool 已被跳过, 不进投影)
      expect(toolFamily('todo_write'), 'file-write');
    });
  });

  group('exploreEligible (桌面端 S2e)', () {
    test('只读家族直接可进', () {
      expect(exploreEligible(_act('grep')), isTrue);
      expect(exploreEligible(_act('read')), isTrue);
      expect(exploreEligible(_act('glob')), isTrue);
    });

    test('shell 按命令判定', () {
      expect(exploreEligible(_act('bash', input: {'command': 'rg foo'})),
          isTrue);
      expect(
          exploreEligible(
              _act('bash', input: {'command': 'sed -n "10,20p" file.txt'})),
          isTrue);
      expect(exploreEligible(_act('bash', input: {'command': 'git status'})),
          isTrue);
      expect(exploreEligible(_act('bash', input: {'command': 'ls -la'})),
          isTrue);
      // 写操作黑名单
      expect(exploreEligible(_act('bash', input: {'command': 'rm -rf /tmp/x'})),
          isFalse);
      expect(
          exploreEligible(
              _act('bash', input: {'command': 'cat a && sed -i s/a/b/ c'})),
          isFalse);
      // 输出重定向
      expect(exploreEligible(_act('bash', input: {'command': 'cat a > b'})),
          isFalse);
      // 无只读白名单命令
      expect(exploreEligible(_act('bash', input: {'command': 'echo hi'})),
          isFalse);
      // 无命令
      expect(exploreEligible(_act('bash')), isFalse);
    });

    test('写文件/MCP 永不进组', () {
      expect(exploreEligible(_act('edit')), isFalse);
      expect(exploreEligible(_act('write')), isFalse);
      expect(exploreEligible(_act('mcp__srv__search')), isFalse);
    });
  });

  group('exploreBucket / exploreSummary (桌面端 V6e/H6e)', () {
    test('用户实例: grep+grep+sed -n → 2 搜索, 1 文件', () {
      final acts = [
        _act('grep', input: {'pattern': 'foo'}),
        _act('bash', input: {'command': 'rg bar'}),
        _act('bash', input: {'command': 'sed -n "1p" f'}),
      ];
      expect(exploreBucket(acts[0]), 'search');
      expect(exploreBucket(acts[1]), 'search'); // input 是 rg 命令
      expect(exploreBucket(acts[2]), 'file'); // sed -n 不在桶关键词里
      expect(exploreSummary(acts), '2 搜索, 1 文件');
    });

    test('列表桶与顺序 (glob 属列表桶, 与桌面端 V6e 一致)', () {
      expect(exploreSummary([_act('ls'), _act('read'), _act('read')]),
          '1 列表, 2 文件');
      expect(exploreSummary([_act('glob')]), '1 列表');
    });
  });

  group('buildExecutionNodes 连续吸收', () {
    test('连续只读工具合成一组', () {
      final nodes = buildExecutionNodes([
        ToolPart(_act('grep', input: {'pattern': 'a'})),
        ToolPart(_act('grep', input: {'pattern': 'b'})),
        ToolPart(_act('read', input: {'path': 'x'})),
      ]);
      expect(nodes.length, 1);
      expect(nodes.first.kind, ExecutionNodeKind.explore);
      expect(nodes.first.children.length, 3);
      expect(nodes.first.subtitle, '2 搜索, 1 文件');
    });

    test('思考断开吸收', () {
      final nodes = buildExecutionNodes([
        ToolPart(_act('grep')),
        const ThoughtPart('想一想'),
        ToolPart(_act('grep')),
      ]);
      expect(nodes.length, 3);
      expect(nodes.where((n) => n.kind == ExecutionNodeKind.explore), isEmpty);
    });

    test('写文件工具断开吸收; 单个只读不合组', () {
      final nodes = buildExecutionNodes([
        ToolPart(_act('grep')),
        ToolPart(_act('edit')),
        ToolPart(_act('read')),
      ]);
      expect(nodes.length, 3);
      expect(nodes.first.kind, ExecutionNodeKind.tool);
    });

    test('运行中子项 → 组状态 running', () {
      final nodes = buildExecutionNodes([
        ToolPart(_act('grep', status: 'completed')),
        ToolPart(_act('read', status: 'running')),
      ]);
      expect(nodes.single.status, ExecutionStatus.running);
    });

    test('plan/todo 工具不参与', () {
      // isPlanTool 认的是 wire 名 exitplanmode/switch_mode
      final nodes = buildExecutionNodes([
        ToolPart(_act('exitplanmode')),
        ToolPart(_act('grep')),
      ]);
      expect(nodes.length, 1);
      expect(nodes.first.kind, ExecutionNodeKind.tool);
    });
  });
}
