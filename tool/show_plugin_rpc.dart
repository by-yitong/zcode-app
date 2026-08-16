// show_plugin_rpc.dart — 演示"插件 overview"请求的完整 WSS 消息 (不发送, 仅编码展示)
//
// 用法: dart run tool/show_plugin_rpc.dart
import 'dart:convert';

import '../lib/core/relay/rpc_codec.dart';

void main() {
  // ── 1. 二进制 RPC 帧: header [100, id, channel, method] + body(args) ──
  final data = RpcCodec.encodeRequest(
    42, // 请求 id (自增)
    'zcode-agent',
    'getPluginsOverview',
    [
      {
        'workspacePath': '/home/you/projects/demo',
        'workspaceIdentity': 'remote:ssh:host:22:you:/home/you/projects/demo',
      }
    ],
  );
  print('== 二进制 RPC 帧 (${data.length} 字节) ==');
  print('hex: ${data.take(48).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}${data.length > 48 ? ' …' : ''}');
  print('base64: ${base64Encode(data)}');
  print('解码回读: ${RpcCodec.decode(data)}');

  // ── 2. 包进 rpc-frame 桥接信封 (与 RelayClient._sendRpcFrameData 相同) ──
  final envelope = {
    'zcode_type': 'rpc-frame',
    'bridgeSessionId': 'b_1786841762791_c34f',
    'bridgeGeneration': 1,
    'seq': 7,
    'messageSeq': 7,
    'fragmentIndex': 0,
    'fragmentCount': 1,
    'messageBytes': data.length,
    'checksum': {'algorithm': 'crc32', 'value': 'a1b2c3d4'},
    'dataBase64': base64Encode(data),
  };

  // ── 3. 最终 WSS 文本帧 ──
  final wsFrame = jsonEncode({
    'type': 'data',
    'payload': envelope,
    'client_ts': DateTime.now().millisecondsSinceEpoch,
  });
  print('');
  print('== 实际发出的 WebSocket 文本帧 ==');
  print(wsFrame);
}
