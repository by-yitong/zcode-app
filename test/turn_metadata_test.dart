import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zcode_app/core/relay/relay_events.dart';
import 'package:zcode_app/core/storage/message_cache.dart';
import 'package:zcode_app/providers/chat_provider.dart';

/// turnHeader 工作时长/文件变更元数据测试 (对齐 ZCode 桌面端 3.7.7 逆向结论)。
void main() {
  group('V4TurnHeaderRow 时间字段解析', () {
    test('完整字段: activeMs 优先于 endedAt-startedAt', () {
      final row = V4TurnHeaderRow.fromJson({
        'kind': 'turnHeader',
        'rowId': 1,
        'turnId': 't1',
        'state': 'completedSuccess',
        'startedAt': 1786800000000,
        'endedAt': 1786800123456,
        'activeMs': 95000, // 与 wall time 123s 不同, 应取 activeMs
        'fileChanges': {'additions': 42, 'deletions': 7, 'files': 3},
      });
      expect(row.startedAt, 1786800000000);
      expect(row.endedAt, 1786800123456);
      expect(row.isRunning, isFalse);
      expect(row.workedMs, 95000);
      expect(row.fileChanges?.additions, 42);
      expect(row.fileChanges?.deletions, 7);
      expect(row.fileChanges?.files, 3);
    });

    test('无 activeMs: 用 endedAt-startedAt', () {
      final row = V4TurnHeaderRow.fromJson({
        'kind': 'turnHeader',
        'rowId': 2,
        'state': 'completedSuccess',
        'startedAt': 1000000,
        'endedAt': 1062000,
      });
      expect(row.workedMs, 62000);
    });

    test('运行中: workedMs 为 null (UI 实时跳动)', () {
      final row = V4TurnHeaderRow.fromJson({
        'kind': 'turnHeader',
        'rowId': 3,
        'state': 'running',
        'startedAt': 1000000,
      });
      expect(row.isRunning, isTrue);
      expect(row.workedMs, isNull);
    });

    test('缺 endedAt 的完成态: 无时长', () {
      final row = V4TurnHeaderRow.fromJson({
        'kind': 'turnHeader',
        'rowId': 4,
        'state': 'failed',
        'startedAt': 1000000,
      });
      expect(row.workedMs, isNull);
    });
  });

  group('进行中状态判定 (V4 状态兼容)', () {
    test('inputStreaming / pendingApproval 都算进行中, 过程不收起', () {
      const streaming = ToolActivity(
        toolCallId: 'a',
        toolName: 'Bash',
        status: 'inputStreaming',
      );
      const pending = ToolActivity(
        toolCallId: 'b',
        toolName: 'Edit',
        status: 'pendingApproval',
      );
      const done = ToolActivity(
        toolCallId: 'c',
        toolName: 'Read',
        status: 'success',
      );
      expect(streaming.isRunning, isTrue,
          reason: '工具参数流式写入中不应判定为完成');
      expect(pending.isRunning, isTrue, reason: '等待用户批准不应判定为完成');
      expect(done.isRunning, isFalse);
    });

    test('V4ToolCallRow.isRunning 含 pendingApproval', () {
      final row = V4ToolCallRow.fromJson({
        'kind': 'toolCall',
        'rowId': 9,
        'toolCallId': 'tc',
        'toolName': 'Write',
        'status': 'pendingApproval',
      });
      expect(row.isRunning, isTrue);
      expect(row.isPendingApproval, isTrue);
    });
  });

  group('MessageCache 新字段往返', () {
    test('workedMs/turnStartedAt/fileChanges/parts 序列化无损', () async {
      final tmp = await Directory.systemTemp.createTemp('hive_test_');
      Hive.init(tmp.path);
      await MessageCache.init();

      final msg = DisplayMessage(
        id: 'turn_t9_r1',
        role: 'assistant',
        content: '正文',
        thought: '思考',
        isStreaming: false,
        workedMs: 204000,
        turnStartedAt: DateTime.fromMillisecondsSinceEpoch(1786800000000),
        fileChanges: V4TurnFileChanges(
          additions: 10,
          deletions: 2,
          files: 1,
        ),
        activities: const [
          ToolActivity(
            toolCallId: 'tc1',
            toolName: 'Bash',
            status: 'success',
          ),
        ],
        parts: const [
          ThoughtPart('想一想', durationMs: 3000),
          ToolPart(ToolActivity(
            toolCallId: 'tc1',
            toolName: 'Bash',
            status: 'success',
          )),
          TextPart('结论'),
        ],
      );

      await MessageCache.saveMessages('task-x', [msg]);
      final back = MessageCache.loadMessages('task-x').first;

      expect(back.workedMs, 204000);
      expect(back.turnStartedAt?.millisecondsSinceEpoch, 1786800000000);
      expect(back.fileChanges?.files, 1);
      expect(back.fileChanges?.additions, 10);
      expect(back.parts, hasLength(3));
      expect(back.parts[0], isA<ThoughtPart>());
      expect((back.parts[0] as ThoughtPart).durationMs, 3000);
      expect(back.parts[1], isA<ToolPart>());
      expect(back.parts[2], isA<TextPart>());
      expect((back.parts[2] as TextPart).text, '结论');
      expect(back.activities, hasLength(1));

      await MessageCache.clearTask('task-x');
    });
  });
}
