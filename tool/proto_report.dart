// proto_report.dart — 抓包协议汇总 + 版本间 diff
//
// 用法:
//   dart run tool/proto_report.dart tool/captures/web_xxx.jsonl
//   dart run tool/proto_report.dart --diff 基线.jsonl 新版.jsonl
//   dart run tool/proto_report.dart --samples tool/captures/web_xxx.jsonl   # 每种消息附一个样例(截断)
//
// 输入: capture_web.mjs 产出的 JSONL (每行 {ts, dir, ws, opcode, data})。
// 解析层级:
//   1. 顶层 type        (auth_init / auth_challenge / data / error / ...)
//   2. data 层 zcode_type (bootstrap-request / rpc-frame / rpc-frame-ack / ...)
//   3. rpc-frame 二进制  (RpcCodec 解码 → REQ ch.method / LISTEN ch.event /
//                        OK / ERROR / EVENT / INIT, 事件推送按订阅 id 归属到 ch.event)
//
// 协议漂移的典型信号:
//   - REQ/LISTEN 集合变化 (新版加了方法 / 旧方法消失)
//   - ERROR 帧出现且 message 提到 unknown method / deprecated
//   - 解码失败数 > 0 (wire format 本身变了, RpcCodec 认不出 tag)
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zcode_app/core/relay/rpc_codec.dart';

void main(List<String> args) {
  final samples = args.contains('--samples');
  final diffIdx = args.indexOf('--diff');
  if (diffIdx >= 0 && diffIdx + 2 < args.length) {
    _diffReport(args[diffIdx + 1], args[diffIdx + 2]);
    return;
  }
  final files = args.where((a) => !a.startsWith('--')).toList();
  if (files.isEmpty) {
    stderr.writeln('用法: dart run tool/proto_report.dart [--samples] capture.jsonl');
    stderr.writeln('      dart run tool/proto_report.dart --diff 基线.jsonl 新版.jsonl');
    exitCode = 1;
    return;
  }
  for (final f in files) {
    _singleReport(f, samples: samples);
  }
}

// ================================================================
// 解析一份抓包 → 统计表
// ================================================================

class Report {
  final topTypes = <String, int>{}; // 顶层 type
  final zcodeTypes = <String, int>{}; // data 层 zcode_type
  final calls = <String, int>{}; // 'REQ ch.method' / 'LISTEN ch.event'
  final events = <String, int>{}; // 'EVENT ch.event' (按订阅 id 归属)
  final resp = <String, int>{}; // OK / ERROR / INIT
  final errors = <String, int>{}; // distinct 错误消息
  final samplesByKey = <String, String>{};
  int totalFrames = 0;
  int binaryFrames = 0;
  int nonJson = 0;
  int decodeFailures = 0;
  final listenById = <dynamic, String>{}; // rpc 订阅 id → 'ch.event'

  void sample(String key, String data) {
    samplesByKey.putIfAbsent(key, () {
      final s = data.replaceAll('\n', ' ');
      return s.length > 200 ? '${s.substring(0, 200)}…' : s;
    });
  }
}

Report parseFile(String path) {
  final r = Report();
  final lines = File(path).readAsLinesSync();
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> f;
    try {
      f = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      r.nonJson++;
      continue;
    }
    r.totalFrames++;
    final dir = f['dir'] as String? ?? '?';
    final data = f['data'] as String? ?? '';
    if (f['opcode'] == 2) {
      r.binaryFrames++;
      continue;
    }

    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      r.nonJson++;
      r.sample('非JSON文本[$dir]', data);
      continue;
    }

    final top = msg['type'] as String? ?? '(no type)';
    r.topTypes[top] = (r.topTypes[top] ?? 0) + 1;
    if (top != 'data') {
      r.sample('type=$top', data);
      continue;
    }

    final payload = msg['payload'];
    if (payload is! Map<String, dynamic>) continue;
    final zt = payload['zcode_type'] as String? ?? '(no zcode_type)';
    r.zcodeTypes[zt] = (r.zcodeTypes[zt] ?? 0) + 1;

    if (zt != 'rpc-frame') {
      r.sample('zcode_type=$zt [$dir]', data);
      continue;
    }

    // rpc-frame: 解码二进制
    final b64 = payload['dataBase64'] as String?;
    if (b64 == null) {
      r.decodeFailures++;
      continue;
    }
    try {
      final frame = RpcCodec.decode(Uint8List.fromList(base64Decode(b64)));
      final id = frame.id;
      final ch = frame.channel ?? '?';
      final m = frame.methodOrEvent ?? '?';
      switch (frame.typeCode) {
        case RpcCodec.typePromiseRequest:
          _bump(r.calls, 'REQ $ch.$m');
          r.sample('REQ $ch.$m', jsonEncode(frame.body));
        case RpcCodec.typeEventListen:
          _bump(r.calls, 'LISTEN $ch.$m');
          listenLabel(r, id, '$ch.$m');
          r.sample('LISTEN $ch.$m', jsonEncode(frame.body));
        case RpcCodec.typeOk:
          _bump(r.resp, 'OK');
        case RpcCodec.typeError:
        case RpcCodec.typeErrorObject:
          _bump(r.resp, 'ERROR');
          final msg2 = frame.errorMessage ?? '?';
          _bump(r.errors, msg2);
          r.sample('ERROR #$id', msg2);
        case RpcCodec.typeEventFire:
          _bump(r.events, 'EVENT ${r.listenById[id] ?? '#$id(未知订阅)'}');
        case RpcCodec.typeInit:
          _bump(r.resp, 'INIT');
        default:
          _bump(r.resp, 'type=${frame.typeCode}');
          r.sample('未知typeCode=${frame.typeCode}', jsonEncode(frame.body));
      }
    } catch (e) {
      r.decodeFailures++;
      r.sample('解码失败', '$e | ${b64.substring(0, b64.length > 60 ? 60 : b64.length)}');
    }
  }
  return r;
}

void listenLabel(Report r, dynamic id, String label) {
  r.listenById[id] = label;
}

void _bump(Map<String, int> m, String k) => m[k] = (m[k] ?? 0) + 1;

// ================================================================
// 输出
// ================================================================

void _singleReport(String path, {bool samples = false}) {
  final r = parseFile(path);
  stdout.writeln('════════ $path ════════');
  stdout.writeln('帧总数 ${r.totalFrames} (二进制 ${r.binaryFrames}, 非JSON ${r.nonJson}, 解码失败 ${r.decodeFailures})');
  _printSection('顶层 type', r.topTypes);
  _printSection('data 层 zcode_type', r.zcodeTypes);
  _printSection('RPC 调用 (C→S)', r.calls);
  _printSection('RPC 响应 (S→C)', r.resp);
  _printSection('事件推送 (S→C)', r.events);
  if (r.errors.isNotEmpty) {
    stdout.writeln('\n── 错误消息 (distinct ${r.errors.length}) ──');
    final sorted = r.errors.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted.take(15)) {
      stdout.writeln('  ×${e.value}  ${e.key}');
    }
  }
  if (r.decodeFailures > 0) {
    stdout.writeln('\n⚠️  解码失败 ${r.decodeFailures} 帧 — wire format 可能已变化!');
  }
  if (samples) {
    stdout.writeln('\n── 消息样例 ──');
    for (final e in r.samplesByKey.entries) {
      stdout.writeln('  [${e.key}] ${e.value}');
    }
  }
  stdout.writeln('');
}

void _printSection(String title, Map<String, int> m) {
  if (m.isEmpty) return;
  stdout.writeln('\n── $title (${m.length} 种) ──');
  final sorted = m.entries.toList()..sort((a, b) {
    final c = b.value.compareTo(a.value);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  for (final e in sorted) {
    stdout.writeln('  ${e.value.toString().padLeft(5)}  ${e.key}');
  }
}

void _diffReport(String oldPath, String newPath) {
  final a = parseFile(oldPath);
  final b = parseFile(newPath);
  stdout.writeln('════════ 协议 diff ════════');
  stdout.writeln('基线: $oldPath (${a.totalFrames} 帧, ${a.calls.length} 个调用)');
  stdout.writeln('新版: $newPath (${b.totalFrames} 帧, ${b.calls.length} 个调用)');
  stdout.writeln('(注意: 调用集合取决于当时页面操作, 消失≠一定删了; 重点看新增和报错)');

  _diffSection('RPC 调用', a.calls, b.calls);
  _diffSection('zcode_type', a.zcodeTypes, b.zcodeTypes);
  _diffSection('顶层 type', a.topTypes, b.topTypes);

  stdout.writeln('\n── 错误对比 ──');
  stdout.writeln('基线: ${a.errors.length} 种 / ${a.errors.values.fold(0, (x, y) => x + y)} 条'
      '${a.decodeFailures > 0 ? ' (解码失败 ${a.decodeFailures})' : ''}');
  stdout.writeln('新版: ${b.errors.length} 种 / ${b.errors.values.fold(0, (x, y) => x + y)} 条'
      '${b.decodeFailures > 0 ? ' (解码失败 ${b.decodeFailures})' : ''}');
  final newErrors = b.errors.keys.where((k) => !a.errors.containsKey(k));
  for (final e in newErrors) {
    stdout.writeln('  ★ 新错误: $e');
  }
  if (b.decodeFailures > a.decodeFailures) {
    stdout.writeln('  ⚠️  新版解码失败增多 (${a.decodeFailures} → ${b.decodeFailures}), wire format 可能变化!');
  }
}

void _diffSection(String title, Map<String, int> a, Map<String, int> b) {
  final added = b.keys.where((k) => !a.containsKey(k)).toList()..sort();
  final removed = a.keys.where((k) => !b.containsKey(k)).toList()..sort();
  if (added.isEmpty && removed.isEmpty) {
    stdout.writeln('\n── $title: 无差异 ──');
    return;
  }
  stdout.writeln('\n── $title ──');
  for (final k in added) {
    stdout.writeln('  + $k  (×${b[k]})');
  }
  for (final k in removed) {
    stdout.writeln('  - $k  (基线 ×${a[k]})');
  }
}
