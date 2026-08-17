import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../providers/chat_provider.dart';
import '../logging/app_logger.dart';
import '../relay/relay_events.dart';

/// 消息本地缓存 (离线可见优化, 非数据源)
///
/// 用 Hive 存储每个 task 的消息列表 (精简 JSON 字符串)。
/// key = taskId, value = jsonEncode(List<Map>) (每条含
/// id/role/content/thought/model/createdAt 的 millisecondsSinceEpoch)。
///
/// 简洁起见: 一个 JSON 字符串存一个 task 的全部消息, 不注册 Hive adapter。
class MessageCache {
  static const _boxName = 'message_cache';

  static Box<String>? _box;

  /// 每个 task 最近一次落盘的稳定消息指纹 (同载荷跳过重编码:
  /// 流式期间稳定集合不变, 每 2s 的防抖落盘不产生任何新内容)
  static final Map<String, int> _lastSavedFp = {};

  MessageCache._();

  /// 初始化缓存 box (应用启动时调用一次)。
  /// 必须先 await Hive.initFlutter() / Hive.init()。
  static Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    _box = await Hive.openBox<String>(_boxName);
  }

  static Box<String> get _safeBox {
    final box = _box;
    if (box == null || !box.isOpen) {
      throw StateError('MessageCache 未初始化, 请先调用 MessageCache.init()');
    }
    return box;
  }

  /// 稳定 (非流式) 消息集合的轻量指纹: 非流式消息不可变, 变化只可能是
  /// 追加/删除/流式转完成/完成元数据 (workedMs/interrupted/fileChanges) 补齐。
  static int _fingerprint(List<DisplayMessage> stable) {
    var h = stable.length * 31;
    for (final m in stable) {
      h = Object.hashAll(<Object?>[
        h,
        m.id,
        m.content.length,
        m.thought?.length,
        m.parts.length,
        m.workedMs,
        m.interrupted,
        m.fileChanges?.files,
        m.activities.length,
      ]);
    }
    return h;
  }

  /// 缓存一个 task 的消息列表 (覆盖式写入)。
  /// jsonEncode 在 isolate 执行 — 长会话编码是 MB 级字符串,
  /// 在主 isolate 做会造成周期性卡顿 (每 2s 防抖落盘/退出会话 flush)。
  static Future<void> saveMessages(
    String taskId,
    List<DisplayMessage> messages,
  ) async {
    try {
      final stable = messages
          .where((m) => !m.isStreaming)
          .toList(growable: false);
      final fp = _fingerprint(stable);
      if (fp == _lastSavedFp[taskId]) return;
      final encoded = await compute(_encodeStable, stable);
      await _safeBox.put(taskId, encoded);
      _lastSavedFp[taskId] = fp;
    } catch (e) {
      // 缓存只是体验优化, 任何失败都不应影响主流程
      appLog.w('[MessageCache] saveMessages 失败: $e');
    }
  }

  /// isolate 入口: 必须是 static/顶层函数
  static String _encodeStable(List<DisplayMessage> messages) =>
      jsonEncode(messages.map(_toJson).toList());

  /// 读取一个 task 的缓存消息 (无缓存或解析失败返回空列表)。
  static List<DisplayMessage> loadMessages(String taskId) {
    try {
      final raw = _safeBox.get(taskId);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => _fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      appLog.w('[MessageCache] loadMessages 失败: $e');
      return const [];
    }
  }

  /// 清除单个 task 的缓存。
  static Future<void> clearTask(String taskId) async {
    _lastSavedFp.remove(taskId);
    try {
      await _safeBox.delete(taskId);
    } catch (e) {
      appLog.w('[MessageCache] clearTask 失败: $e');
    }
  }

  /// 清空全部缓存。
  static Future<void> clearAll() async {
    _lastSavedFp.clear();
    try {
      await _safeBox.clear();
    } catch (e) {
      appLog.w('[MessageCache] clearAll 失败: $e');
    }
  }

  // ------------------------------ 序列化 ------------------------------

  /// DisplayMessage -> 精简 JSON Map。
  static Map<String, dynamic> _toJson(DisplayMessage m) => {
        'id': m.id,
        'role': m.role,
        'content': m.content,
        if (m.thought != null) 'thought': m.thought,
        if (m.model != null) 'model': m.model,
        if (m.interrupted) 'interrupted': true,
        'createdAt': m.createdAt.millisecondsSinceEpoch,
        if (m.workedMs != null) 'workedMs': m.workedMs,
        if (m.turnStartedAt != null)
          'turnStartedAt': m.turnStartedAt!.millisecondsSinceEpoch,
        if (m.fileChanges != null)
          'fileChanges': {
            'additions': m.fileChanges!.additions,
            'deletions': m.fileChanges!.deletions,
            'files': m.fileChanges!.files,
          },
        if (m.parts.isNotEmpty)
          'parts': m.parts.map((p) {
            if (p is TextPart) return {'type': 'text', 'text': p.text};
            if (p is ThoughtPart)
              return {
                'type': 'thought',
                'text': p.text,
                if (p.durationMs != null) 'durationMs': p.durationMs,
              };
            if (p is ToolPart)
              return {
                'type': 'tool',
                'toolCallId': p.activity.toolCallId,
                'toolName': p.activity.toolName,
                'status': p.activity.status,
                if (p.activity.elapsedMs != null)
                  'elapsedMs': p.activity.elapsedMs,
                if (p.activity.input != null) 'input': p.activity.input,
                if (p.activity.result != null) 'result': p.activity.result,
              };
            if (p is StepPart) return {'type': 'step', 'isStart': p.isStart};
            return {'type': 'text', 'text': ''};
          }).toList(),
        if (m.activities.isNotEmpty)
          'activities': m.activities
              .map((a) => {
                    'toolCallId': a.toolCallId,
                    'toolName': a.toolName,
                    'status': a.status,
                    if (a.elapsedMs != null) 'elapsedMs': a.elapsedMs,
                    if (a.input != null) 'input': a.input,
                    if (a.result != null) 'result': a.result,
                  })
              .toList(),
      };

  /// 精简 JSON Map -> DisplayMessage。
  static DisplayMessage _fromJson(Map<String, dynamic> json) {
    final createdAt = json['createdAt'];
    ToolActivity actFromJson(Map a) => ToolActivity(
          toolCallId: a['toolCallId'] as String? ?? '',
          toolName: a['toolName'] as String? ?? '',
          status: a['status'] as String? ?? '',
          elapsedMs: a['elapsedMs'] as int?,
          input: a['input'] as Map<String, dynamic>?,
          result: a['result'] as String?,
        );
    final activitiesRaw = json['activities'] as List<dynamic>?;
    final activities = activitiesRaw
            ?.map((a) => actFromJson(Map<String, dynamic>.from(a as Map)))
            .toList() ??
        const <ToolActivity>[];
    final partsRaw = json['parts'] as List<dynamic>?;
    final parts = partsRaw
            ?.map((p) {
              final pm = Map<String, dynamic>.from(p as Map);
              switch (pm['type'] as String?) {
                case 'text':
                  return TextPart(pm['text'] as String? ?? '');
                case 'thought':
                  return ThoughtPart(pm['text'] as String? ?? '',
                      durationMs: pm['durationMs'] as int?);
                case 'tool':
                  return ToolPart(actFromJson(pm));
                case 'step':
                  return StepPart(pm['isStart'] as bool? ?? true);
              }
              return null;
            })
            .whereType<MessagePart>()
            .toList() ??
        const <MessagePart>[];
    final fcRaw = json['fileChanges'];
    final turnStartedAt = json['turnStartedAt'];
    return DisplayMessage(
      id: json['id'] as String? ?? '',
      role: json['role'] as String? ?? 'assistant',
      content: json['content'] as String? ?? '',
      thought: json['thought'] as String?,
      model: json['model'] as String?,
      interrupted: json['interrupted'] == true,
      createdAt: createdAt is int
          ? DateTime.fromMillisecondsSinceEpoch(createdAt)
          : null,
      activities: activities,
      parts: parts,
      workedMs: json['workedMs'] as int?,
      turnStartedAt: turnStartedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(turnStartedAt)
          : null,
      fileChanges: fcRaw is Map
          ? V4TurnFileChanges.fromJson(
              Map<String, dynamic>.from(fcRaw),
            )
          : null,
    );
  }
}
