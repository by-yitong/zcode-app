// extract_history_pair.dart — 从抓包 jsonl 中提取指定方法的 请求→响应 配对
//
// 用法: dart run tool/extract_history_pair.dart <capture.jsonl> <方法名子串>...
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zcode_app/core/relay/rpc_codec.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/extract_history_pair.dart <capture.jsonl> <方法名子串>...');
    exit(1);
  }
  final file = args[0];
  final wanted = args.sublist(1);

  final pending = <int, String>{}; // id → method
  final lines = File(file).readAsLinesSync();
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final data = j['data'];
    if (data is! String) continue;
    Map<String, dynamic>? envelope;
    try {
      final top = jsonDecode(data) as Map<String, dynamic>;
      if (top['type'] == 'data') {
        envelope = top['payload'] as Map<String, dynamic>?;
      }
    } catch (_) {
      continue;
    }
    final payload = envelope;
    if (payload == null || payload['zcode_type'] != 'rpc-frame') continue;
    final b64 = payload['dataBase64'] as String? ?? payload['messageBytes'] as String?;
    if (b64 == null) continue;
    final RpcFrame frame;
    try {
      frame = RpcCodec.decode(Uint8List.fromList(base64Decode(b64)));
    } catch (_) {
      continue;
    }
    final id = frame.id;
    if (id == null) continue;
    final dirIn = j['dir'] == 'in';

    if (!dirIn && frame.methodOrEvent != null) {
      pending[id] = frame.methodOrEvent!;
      if (wanted.any((w) => frame.methodOrEvent!.contains(w))) {
        print('→ #$id ${frame.methodOrEvent} ${_trunc(frame.body)}');
      }
    } else if (dirIn && frame.isOk) {
      final m = pending[id];
      if (m != null && wanted.any((w) => m.contains(w))) {
        print('← #$id $m OK ${_trunc(frame.body)}');
      }
    }
  }
}

String _trunc(Object? body, [int n = 300000]) {
  final s = body == null ? 'null' : jsonEncode(body);
  return s.length > n ? '${s.substring(0, n)}…(${s.length}字)' : s;
}
