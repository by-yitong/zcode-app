import 'dart:convert';
import 'dart:typed_data';

/// ZCode RPC 二进制编解码 (实测自客户端通信 2026-06-15)
///
/// wire format: 自描述 varint + tag 字节 (类 MessagePack), 非固定头。
/// 每帧 = 两个 value 顺序拼接: [header] + [body]
///   header 是 list: [typeCode, id, channel, method] 或 [typeCode, id]
///   body 是任意值 (object/list/null)
///
/// 完整规格见 docs/API协议规格.md §4.5
class RpcCodec {
  RpcCodec._();

  // ── tag 字节 ──
  static const int tagNull = 0;
  static const int tagString = 1;
  static const int tagBinary = 2;
  static const int tagBinaryAlt = 3;
  static const int tagList = 4;
  static const int tagJson = 5;
  static const int tagInt = 6;

  // ── RPC 帧类型码 ──
  static const int typePromiseRequest = 100; // C→S 请求
  static const int typeEventListen = 102; // C→S 订阅
  static const int typeInit = 200; // S→C 桥接就绪
  static const int typeOk = 201; // S→C 成功响应
  static const int typeError = 202; // S→C 错误
  static const int typeErrorObject = 203; // S→C 错误 (带 stack)
  static const int typeEventFire = 204; // S→C 事件推送

  // ================================================================
  // 编码
  // ================================================================

  /// 写 varint (LEB128, 小端, 高位=继续标志)
  static void writeVarint(List<int> w, int v) {
    if (v == 0) {
      w.add(0);
      return;
    }
    // Dart int 是 64 位有符号, 转无符号处理
    var uv = v;
    while (uv != 0) {
      int b = uv & 0x7f;
      uv = uv >>> 7;
      if (uv > 0) b |= 0x80;
      w.add(b);
    }
  }

  /// 序列化一个值到 w
  static void serialize(List<int> w, dynamic v) {
    if (v == null) {
      w.add(tagNull);
    } else if (v is int) {
      w.add(tagInt);
      writeVarint(w, v);
    } else if (v is String) {
      w.add(tagString);
      final bytes = utf8.encode(v);
      writeVarint(w, bytes.length);
      w.addAll(bytes);
    } else if (v is List) {
      w.add(tagList);
      writeVarint(w, v.length);
      for (final item in v) {
        serialize(w, item);
      }
    } else if (v is Map) {
      w.add(tagJson);
      final bytes = utf8.encode(jsonEncode(v));
      writeVarint(w, bytes.length);
      w.addAll(bytes);
    } else {
      // 其他类型走 JSON
      w.add(tagJson);
      final bytes = utf8.encode(jsonEncode(v));
      writeVarint(w, bytes.length);
      w.addAll(bytes);
    }
  }

  /// 编码 RPC 请求 (type=100)
  ///
  /// [id] 请求号 (客户端自增)
  /// [channel] e.g. "zcode-task", "zcode-session"
  /// [method] e.g. "enqueueTaskCommand", "getTaskSnapshotWithEtag"
  /// [args] 调用参数 (通常是 List 包一个 Map)
  static Uint8List encodeRequest(
    int id,
    String channel,
    String method,
    dynamic args,
  ) {
    final w = <int>[];
    serialize(w, [typePromiseRequest, id, channel, method]); // header
    serialize(w, args); // body
    return Uint8List.fromList(w);
  }

  /// 编码事件订阅 (type=102)
  ///
  /// [id] 订阅号
  /// [channel] e.g. "zcode-session"
  /// [event] e.g. "onDynamicSessionEvent"
  /// [args] 订阅参数
  static Uint8List encodeListen(
    int id,
    String channel,
    String event,
    dynamic args,
  ) {
    final w = <int>[];
    serialize(w, [typeEventListen, id, channel, event]); // header
    // V4: args 是单个 object (tag=5 JSON), 不是 array
    if (args is List) {
      serialize(w, (args as List).isNotEmpty ? (args as List).first : null);
    } else {
      serialize(w, args);
    }
    return Uint8List.fromList(w);
  }

  // ================================================================
  // 解码
  // ================================================================

  static int _readU8(_Reader r) => r.bytes[r.pos++];

  static int _readVarint(_Reader r) {
    var result = 0, shift = 0;
    while (true) {
      final b = r.bytes[r.pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }

  static Uint8List _readBytes(_Reader r, int n) {
    final out = Uint8List.sublistView(r.bytes, r.pos, r.pos + n);
    r.pos += n;
    return out;
  }

  /// 反序列化一个值
  static dynamic _deserialize(_Reader r) {
    final tag = _readU8(r);
    switch (tag) {
      case tagNull:
        return null;
      case tagString:
        final n = _readVarint(r);
        return utf8.decode(_readBytes(r, n));
      case tagBinary:
      case tagBinaryAlt:
        final n = _readVarint(r);
        return _readBytes(r, n);
      case tagList:
        final n = _readVarint(r);
        return List.generate(n, (_) => _deserialize(r));
      case tagJson:
        final n = _readVarint(r);
        return jsonDecode(utf8.decode(_readBytes(r, n)));
      case tagInt:
        return _readVarint(r);
      default:
        return '<unknown tag $tag>';
    }
  }

  /// 解码一帧, 返回 header + body
  ///
  /// 返回 [RpcFrame], 含 typeCode/id/channel/method (来自 header) 和 body。
  static RpcFrame decode(Uint8List data) {
    final r = _Reader(data);
    final header = _deserialize(r) as List?;
    final body = _deserialize(r);

    final typeCode =
        (header != null && header.isNotEmpty) ? header[0] as int : -1;
    final id = (header != null && header.length > 1) ? header[1] : null;
    final channel = (header != null && header.length > 2) ? header[2] : null;
    final methodOrEvent =
        (header != null && header.length > 3) ? header[3] : null;

    return RpcFrame(
      typeCode: typeCode,
      id: id,
      channel: channel is String ? channel : null,
      methodOrEvent: methodOrEvent is String ? methodOrEvent : null,
      body: body,
    );
  }
}

/// 解码后的 RPC 帧
class RpcFrame {
  /// 帧类型码 (RpcCodec.type*)
  final int typeCode;

  /// 请求/响应 ID (用于配对)
  final dynamic id;

  /// channel 名 (仅请求/订阅帧有)
  final String? channel;

  /// method 或 event 名 (仅请求/订阅帧有)
  final String? methodOrEvent;

  /// 帧体 (返回值 / 错误 / 事件 payload)
  final dynamic body;

  const RpcFrame({
    required this.typeCode,
    this.id,
    this.channel,
    this.methodOrEvent,
    this.body,
  });

  bool get isOk => typeCode == RpcCodec.typeOk;
  bool get isError => typeCode == RpcCodec.typeError;
  bool get isErrorObject => typeCode == RpcCodec.typeErrorObject;
  bool get isEvent => typeCode == RpcCodec.typeEventFire;
  bool get isInit => typeCode == RpcCodec.typeInit;

  /// 提取错误消息
  String? get errorMessage {
    if (!isError && !isErrorObject) return null;
    if (body is Map) return body['message'] as String? ?? body.toString();
    return body?.toString();
  }

  @override
  String toString() =>
      'RpcFrame(type=$typeCode, id=$id, ch=$channel, m=$methodOrEvent)';
}

class _Reader {
  final Uint8List bytes;
  int pos = 0;
  _Reader(this.bytes);
}
