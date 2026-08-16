// dump_index_frames.dart — 从抓包 jsonl 中提取 sessions-index 推送帧
//
// 推送帧 (type=204) 只带 listen id 不带方法名, 所以要传 listen 帧
// (→ #N onDynamicSessionsIndexFrame) 的 id 来定位。
//
// 用法: dart run tool/dump_index_frames.dart <capture.jsonl> <listenId>...
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zcode_app/core/relay/rpc_codec.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/dump_index_frames.dart <capture.jsonl> <listenId>...');
    exit(1);
  }
  final wantIds = args.sublist(1).map(int.parse).toSet();
  for (final line in File(args[0]).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final data = j['data'];
    if (data is! String || j['dir'] != 'in') continue;
    Map<String, dynamic>? envelope;
    try {
      final top = jsonDecode(data) as Map<String, dynamic>;
      if (top['type'] == 'data') {
        envelope = top['payload'] as Map<String, dynamic>?;
      }
    } catch (_) {
      continue;
    }
    if (envelope == null || envelope['zcode_type'] != 'rpc-frame') continue;
    final b64 = envelope['dataBase64'] as String? ?? envelope['messageBytes'] as String?;
    if (b64 == null) continue;
    try {
      final f = RpcCodec.decode(Uint8List.fromList(base64Decode(b64)));
      if (f.id == null || f.isOk || !wantIds.contains(f.id)) continue;
      final s = jsonEncode(f.body);
      print('◆ id=${f.id} len=${s.length}');
      print(s.length > 5500 ? '${s.substring(0, 5500)}…(${s.length}字)' : s);
      print('===');
    } catch (_) {}
  }
}
