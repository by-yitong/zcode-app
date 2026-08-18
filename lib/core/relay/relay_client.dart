import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io' show WebSocket;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;

import 'relay_events.dart';
import 'relay_protocol.dart';
import 'rpc_codec.dart';

/// Relay 连接配置 (实测验证)
class RelayConfig {
  /// WebSocket URL: wss://zcode.z.ai/ws?mid={mid}
  final String wsUrl;

  /// 设备 SID (URL sid 参数, 含 d_ 前缀)
  final String deviceSid;

  /// 密码哈希 (URL hash 参数, URL decode 后)
  final String passHash;

  /// Cookie (会话认证, 至少含 acw_tc)
  final String cookie;

  /// 设备名
  final String deviceName;

  /// 应用版本
  final String appVersion;

  const RelayConfig({
    required this.wsUrl,
    required this.deviceSid,
    required this.passHash,
    required this.cookie,
    this.deviceName = 'mobile-browser',
    this.appVersion = '3.7.7',
  });

  /// 从 URL 参数构建配置
  factory RelayConfig.fromUrl({
    required String mid,
    required String deviceSid,
    required String passHash,
    required String cookie,
    String deviceName = 'mobile-browser',
  }) {
    return RelayConfig(
      wsUrl: 'wss://zcode.z.ai/ws?mid=$mid',
      deviceSid: deviceSid,
      passHash: passHash,
      cookie: cookie,
      deviceName: deviceName,
    );
  }
}

/// ZCode Relay 协议客户端
///
/// 完整实现 (实测 2026-06-15):
/// 1. WebSocket 连接 + 4 步 HMAC 认证
/// 2. Bootstrap (工作区/任务列表)
/// 3. Workspace Bridge + RPC Init 握手
/// 4. RPC 二进制协议 (varint+tag 编解码)
/// 5. 业务方法: 发消息 / 加载历史 / 订阅事件
class RelayClient {
  final RelayConfig config;
  final void Function(String level, String message)? logger;

  WebSocket? _socket;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  RelayConnectionState _state = RelayConnectionState.idle;
  RelayConnectionState get state => _state;

  // requestId → pending completer (data 层请求/响应配对)
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  // RPC 请求 ID → completer (rpc-frame 层配对)
  final Map<int, Completer<RpcFrame>> _pendingRpc = {};

  // RPC 订阅 ID → 事件流控制器 (type=204 事件分发)
  final Map<int, StreamController<SessionEvent>> _eventSubs = {};

  /// rpc-frame 分片重组缓冲 (messageSeq → 按序分片)
  final Map<int, List<Uint8List?>> _fragBufs = {};

  // bridge 状态
  int _bridgeGeneration = 0;
  String? _activeBridgeSession;
  String? _currentWorkspaceKey;
  String? _currentTaskId;
  bool _rpcReady = false;
  Completer<void>? _rpcReadyCompleter;

  // 序列号
  int _seqCounter = 0;
  int _rpcReqId = 0;

  // 事件流 (对 UI 暴露)
  final _stateController = StreamController<RelayConnectionState>.broadcast();
  final _agentEventController = StreamController<AgentEvent>.broadcast();
  final _sessionEventController = StreamController<SessionEvent>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _rpcReadyController = StreamController<bool>.broadcast();

  Stream<RelayConnectionState> get onStateChange => _stateController.stream;

  /// AI agent 事件流 (旧, 兼容 chat_screen)
  Stream<AgentEvent> get onAgentEvent => _agentEventController.stream;

  /// session 事件流 (新, 实测的 session.event 推送)
  ///
  /// 所有 onDynamicSessionEvent 订阅的事件都会推到这里。
  /// UI 用 event.type 区分内容 (tool.updated / text 流式 等)。
  Stream<SessionEvent> get onSessionEvent => _sessionEventController.stream;

  Stream<String> get onError => _errorController.stream;

  /// 工作区/任务列表变更推送 (zcode_type=workspace-list-updated)。
  /// payload.result 含全量 workspaces[] + tasks[] (与 bootstrap 同构)。
  /// 3.7.7 抓包实测: bridge 就绪后服务端主动推, 列表有变化时再推。
  Stream<Map<String, dynamic>> get onWorkspaceListUpdated =>
      _workspaceListController.stream;
  final _workspaceListController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// RPC 就绪状态变化: true=bridge open+RPC Init; false=bridge 拆除/socket 关闭。
  /// 全局模型列表等账号级数据据此刷新 (重连/切工作区会自动重载)。
  Stream<bool> get onRpcReadyChange => _rpcReadyController.stream;

  /// 等 RPC ready (同步检查 + stream 等待), 带超时。
  Future<void> waitRpcReady(Duration timeout) async {
    if (_rpcReady) return;
    await onRpcReadyChange
        .firstWhere((ready) => ready)
        .timeout(timeout);
  }

  int _reconnectAttempts = 0;
  bool _intentionallyClosed = false;

  /// 进行中的连接 Future (单飞: 保证同一时刻只开一个 socket)
  /// zcode relay 同一 device_sid 只允许一个终端, 开两个会互相 KICK。
  Future<void>? _connectFuture;

  static const _maxReconnectAttempts = 10;
  static const _heartbeatInterval = Duration(seconds: 30);

  RelayClient({required this.config, this.logger});

  void _log(String level, String msg) => logger?.call(level, msg);

  /// 日志用截断 (长 payload 只保留前 [n] 字符)
  static String _trunc(Object? s, [int n = 300]) {
    final str = s.toString();
    return str.length > n ? str.substring(0, n) : str;
  }

  void _setState(RelayConnectionState s) {
    if (_state == s) return;
    _log('info', 'Relay: ${_state.name} → ${s.name}');
    _state = s;
    // dispose() 后迟到的 WS 回调会走到这里 — controller 已关闭, 静默丢弃
    if (!_stateController.isClosed) _stateController.add(s);
  }

  String _genId(String prefix) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rand = Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return '${prefix}_${ts}_$rand';
  }

  String _genUuid() {
    final r = Random();
    final hex = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  // ================================================================
  // 连接 + 认证
  // ================================================================

  /// 连接并完成认证
  ///
  /// 单飞 (single-flight): 并发调用复用同一个进行中的连接 Future,
  /// 保证同一时刻只有一个 socket — 避免违反"单设备"约束导致 self-kick。
  Future<void> connect() async {
    // 已连上: 直接返回
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      return;
    }
    // 复用进行中的连接 (bootstrap/load 并发调用时不再开第二个 socket)
    final pending = _connectFuture;
    if (pending != null) {
      _log('debug', 'connect() 复用进行中的连接');
      return pending;
    }
    final future = _doConnect();
    _connectFuture = future;
    try {
      await future;
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _doConnect() async {
    _intentionallyClosed = false;
    _setState(RelayConnectionState.connecting);
    _log('info', 'Connecting to ${config.wsUrl}');

    // ★ 必须带超时: 后台挂起时网络被系统掐断, 无超时的 connect 会永久挂起,
    // _connectFuture 停在 pending, 前台恢复后也无法恢复 (一直"正在重连")
    _socket = await WebSocket.connect(
      config.wsUrl,
      headers: {
        'Cookie': config.cookie,
        'Origin': 'https://zcode.z.ai',
        'User-Agent': 'Mozilla/5.0',
      },
    ).timeout(const Duration(seconds: 20));
    // 协议级心跳: 探针实测无心跳 ~30s 会被服务端空闲关闭
    _socket!.pingInterval = const Duration(seconds: 20);

    _log('info', 'WebSocket connected');
    _setState(RelayConnectionState.connected);

    _socket!.listen(
      _onMessage,
      onError: (e) => _onError(e),
      onDone: () => _onDone(),
      cancelOnError: true,
    );

    // 等待认证完成
    final authCompleter = Completer<void>();
    _authCompleter = authCompleter;

    // Step 1: 发送 auth_init
    _sendRaw({
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': config.deviceSid,
      'meta': {
        'platform': 'web',
        'version': config.appVersion,
        'name': config.deviceName,
      },
      'client_ts': _ts(),
    });

    await authCompleter.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('Auth timeout'),
    );

    _startHeartbeat();
    // 认证成功才重置退避: 之前每次重连都在这里清零, 导致永远 2s 猛重连
    _reconnectAttempts = 0;
    _setState(RelayConnectionState.ready);
    _log('info', 'Authenticated successfully');

    // WS 级重连后 bridge 不会自动恢复 (服务端只回 auth, 不重开桥),
    // 之前有工作区则主动重开 — rpcReady 变 true 会触发上层自动重订阅
    if (_currentWorkspaceKey != null && !_rpcReady) {
      unawaited(_reopenBridge('ws-reconnected'));
    }
  }

  Completer<void>? _authCompleter;

  /// 最后收到任意 WS 帧的时间 (revive 探活参考: 近期有帧 = 连接活跃)
  DateTime? _lastFrameAt;

  /// 进行中的 bridge 打开 Future (single-flight: 重连钩子/ensureBridgeOpen/init
  /// 并发开桥会互相顶掉 generation, 必须串行)
  Future<void>? _bridgeOpenFuture;

  /// 探活回执 completer (pair_status_query → pair_status_ack)
  Completer<bool>? _livenessProbe;

  /// 发送 pair_status_query 探活 (3.7.7 网页端同款心跳)。
  /// 5s 无响应判定连接已死 (半开: 后台被系统静默掐断但 onDone 不触发)。
  Future<bool> _probeLiveness() async {
    final c = Completer<bool>();
    _livenessProbe = c;
    _sendRaw({
      'type': 'pair_status_query',
      'device_sid': config.deviceSid,
      'client_ts': _ts(),
    });
    try {
      await c.future.timeout(const Duration(seconds: 5));
      return true;
    } on TimeoutException {
      return false;
    } finally {
      _livenessProbe = null;
    }
  }

  /// 前台恢复时调用 (AppLifecycleState.resumed)。
  ///
  /// 后台挂起期间 socket 可能被系统静默掐断:
  /// - 明确断开 (onDone 已触发) → state 卡在 reconnecting/connecting, 重连
  /// - 看似健康 → pair_status_query 探活, 半开则强制重连
  /// - WS 活着但 bridge 掉了 → 只重开 bridge
  Future<void> revive() async {
    if (_intentionallyClosed) return;
    // 初始连接还在进行中: 不拆它 (connect 带 20s 超时, 挂不死)
    if (_connectFuture != null || _state == RelayConnectionState.connecting) {
      return;
    }
    final socketOpen = _socket != null && _socket!.readyState == WebSocket.open;

    if (socketOpen && _state == RelayConnectionState.ready) {
      if (_rpcReady) {
        // 近 45s 收到过任意帧 → 连接活跃, 无需探活 (避免误杀刚重建的连接)
        final lastFrame = _lastFrameAt;
        if (lastFrame != null &&
            DateTime.now().difference(lastFrame) < const Duration(seconds: 45)) {
          return;
        }
        final alive = await _probeLiveness();
        if (alive) return;
        _log('warn', 'revive(): 探活无响应, 判定半开连接 → 强制重连');
      } else if (_currentWorkspaceKey != null) {
        // WS 活着但 bridge 掉了 (后台期间服务端拆桥)
        await _reopenBridge('revive-bridge-only');
        return;
      } else {
        return;
      }
    } else {
      _log('info', 'revive(): 前台恢复, 状态=${_state.name} socketOpen=$socketOpen → 强制重连');
    }

    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    // 卡死的 _connectFuture 必须清掉, 否则 connect() 会复用它
    _connectFuture = null;
    try {
      await connect();
      // bridge 重开由 _doConnect 认证成功后的钩子触发
    } catch (e) {
      _log('warn', 'revive(): 重连失败: $e');
      _scheduleReconnect();
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    _intentionallyClosed = true;
    _log('info', 'Disconnecting');
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    await _socket?.close();
    _socket = null;
    for (final c in _pending.values) {
      c.completeError('Disconnected');
    }
    _pending.clear();
    _setState(RelayConnectionState.disconnected);
  }

  // ================================================================
  // 消息处理
  // ================================================================

  int _ts() => DateTime.now().millisecondsSinceEpoch;

  void _sendRaw(Map<String, dynamic> msg) {
    if (_socket == null) return;
    _socket!.add(jsonEncode(msg));
  }

  /// 上报移动端查看状态 + 设备信息 (mobile-view-state-update, 非 RPC 的
  /// 独立信封)。桌面端用它显示"连接的设备"; [activeTaskId] 打开会话后携带。
  void sendMobileViewState({
    required String activeWorkspaceKey,
    String? activeTaskId,
    required Map<String, dynamic> deviceInfo,
  }) {
    _sendPayload({
      'zcode_type': 'mobile-view-state-update',
      'viewState': {
        'activeWorkspaceKey': activeWorkspaceKey,
        if (activeTaskId != null) 'activeTaskId': activeTaskId,
        'updatedAt': _ts(),
      },
      'deviceInfo': deviceInfo,
    });
    _log('debug',
        'mobile-view-state-update 已发送 (task=${activeTaskId ?? '-'})');
  }

  /// 发送 data 层消息 (认证后的所有消息都通过 data 包裹)
  void _sendPayload(Map<String, dynamic> payload) {
    _sendRaw({
      'type': 'data',
      'payload': payload,
      'client_ts': _ts(),
    });
  }

  /// 发送 data 层消息并等待响应 (requestId 配对)
  Future<Map<String, dynamic>> _requestResponse(
    String zcodeType,
    Map<String, dynamic> extra, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestId = extra['requestId'] as String? ?? _genId(zcodeType);
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;

    _sendPayload({
      'zcode_type': zcodeType,
      'requestId': requestId,
      ...extra,
    });

    Future.delayed(timeout, () {
      if (_pending.containsKey(requestId)) {
        _pending.remove(requestId);
        completer.completeError(TimeoutException('Timeout: $zcodeType'));
      }
    });

    return completer.future;
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    _lastFrameAt = DateTime.now();
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw);
    } catch (e) {
      // 非 JSON 帧可能是服务端纯文本通知 (如 kick), 留样便于排查协议问题
      _log('warn', 'WS 消息 JSON 解析失败: $e, raw=${_trunc(raw, 200)}');
      return;
    }

    final type = msg['type'] as String?;

    switch (type) {
      case 'auth_challenge':
        _handleAuthChallenge(msg);
      case 'auth_ack':
        _handleAuthAck(msg);
      case 'pair_status_ack':
        // 3.7.7 客户端心跳的响应, 兼作探活回执
        if (!(_livenessProbe?.isCompleted ?? true)) {
          _livenessProbe!.complete(true);
        }
      case 'data':
        _handleData(msg['payload'] as Map<String, dynamic>);
      case 'error':
        final code = msg['code'] ?? 'unknown';
        _log('error', 'Server error: $code');
        if (!_errorController.isClosed) _errorController.add('Server error: $code');
      default:
        _log('debug', 'RECV [$type]');
    }
  }

  void _handleAuthChallenge(Map<String, dynamic> msg) {
    final nonce = msg['nonce'] as String;
    _log('info', 'Auth challenge received');

    // proof = base64url(HMAC-SHA256(passHash, "nonce|terminal|deviceSid"))
    final dataStr = '$nonce|terminal|${config.deviceSid}';
    final hmac = crypto.Hmac(crypto.sha256, utf8.encode(config.passHash));
    final proof = base64Url
        .encode(hmac.convert(utf8.encode(dataStr)).bytes)
        .replaceAll('=', '');

    _sendRaw({
      'type': 'auth_response',
      'device_sid': config.deviceSid,
      'proof': proof,
      'client_ts': _ts(),
    });
  }

  void _handleAuthAck(Map<String, dynamic> msg) {
    final terminalSid = msg['terminal_sid'] as String?;
    final pairStatus = msg['pair_status'] as String?;
    _log('info', 'Auth ACK: terminal_sid=$terminalSid, pair=$pairStatus');

    if (pairStatus == 'matched') {
      _authCompleter?.complete();
    } else {
      _authCompleter?.completeError('Pair status: $pairStatus');
    }
  }

  void _handleData(Map<String, dynamic> payload) {
    final zt = payload['zcode_type'] as String?;
    final requestId = payload['requestId'] as String?;

    // 配对 data 层请求-响应 (bootstrap / workspace-bridge 等)
    if (requestId != null && _pending.containsKey(requestId)) {
      final completer = _pending.remove(requestId)!;
      completer.complete(payload);
      return;
    }

    // 分发 rpc-frame 和 rpc-frame-ack
    if (zt == 'rpc-frame') {
      _handleRpcFrame(payload);
      return;
    }
    // V4: rpc-frame-ack — 服务端确认收到, 简单客户端忽略
    if (zt == 'rpc-frame-ack') {
      _log('debug', '← rpc-frame-ack seq=${payload['ackMessageSeq']}');
      return;
    }

    // 其他 data 层消息
    if (zt == 'bridge-degraded') {
      _log('warn', '★ bridge-degraded! payload=$payload');
      _log('warn', '  pending RPC: ${_pendingRpc.length}, rpcReady=$_rpcReady, bridgeGen=$_bridgeGeneration');
      _onBridgeDegraded();
      return;
    }
    if (zt == 'workspace-list-updated') {
      _log('debug', '← workspace-list-updated (列表变更推送)');
      if (!_workspaceListController.isClosed) {
        if (!_workspaceListController.isClosed) _workspaceListController.add(payload);
      }
      return;
    }
    _log('debug', '→ DATA [$zt] payload=${_trunc(payload)}');
  }

  int _degradedCount = 0;
  DateTime? _lastReconnectTime;

  /// bridge 降级: 立即 fail 所有 pending RPC, 尝试重连 (带防抖)
  void _onBridgeDegraded() {
    _rpcReady = false;
    if (!_rpcReadyController.isClosed) _rpcReadyController.add(false);

    // fail 所有 pending RPC
    final pendingRpc = Map<int, Completer<RpcFrame>>.from(_pendingRpc);
    _pendingRpc.clear();
    for (final entry in pendingRpc.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(
          TimeoutException('Bridge degraded'),
        );
      }
    }

    // 关闭 V4 frame 订阅 (会通过 onRpcReadyChange 重订阅)
    // 不关闭 controller — resync 会复用

    // 防抖: 10 秒内最多重连 3 次，避免死循环
    final now = DateTime.now();
    if (_lastReconnectTime != null &&
        now.difference(_lastReconnectTime!).inSeconds < 10) {
      _degradedCount++;
      if (_degradedCount > 3) {
        _log('warn', 'Bridge degraded ${_degradedCount}x in 10s, stop auto-reconnect');
        return;
      }
    } else {
      _degradedCount = 0;
    }
    _lastReconnectTime = now;

    // 尝试自动重连 bridge (带上 taskId)
    if (_currentWorkspaceKey != null) {
      Future.delayed(const Duration(seconds: 2), () {
        _reopenBridge('degraded');
      });
    }
  }

  /// 重开工作区桥接 (bridge-degraded / WS 重连 / 前台恢复共用)。
  /// 内部吞错只记日志; 成功后 rpcReady=true, 上层经 onRpcReadyChange 自动重订阅。
  Future<void> _reopenBridge(String reason) async {
    final key = _currentWorkspaceKey;
    if (key == null) return;
    // 已有可用 bridge (如并发的完整打开赢了) 或已有打开在进行中 → 跳过
    if (_rpcReady || _bridgeOpenFuture != null) {
      _log('debug', 'Reopen bridge ($reason) skipped: rpcReady=$_rpcReady opening=${_bridgeOpenFuture != null}');
      return;
    }
    _log('info', 'Reopening bridge ($reason): $key (taskId=${_currentTaskId ?? "none"}, attempt ${_degradedCount + 1})');
    _bridgeGeneration++;
    _seqCounter = 0;
    _rpcReqId = 0;
    _activeBridgeSession = _genId('bridge');
    _rpcReady = false;
    if (!_rpcReadyController.isClosed) _rpcReadyController.add(false);
    _rpcReadyCompleter = Completer<void>();
    _v4HandshakeDone = false;
    _v4HandshakeFuture = null;
    try {
      final resp = await _requestResponse('workspace-bridge-open', {
        'bridgeSessionId': _activeBridgeSession!,
        'bridgeGeneration': _bridgeGeneration,
        if (_currentRecoveryId != null) 'recoveryId': _currentRecoveryId,
        'workspaceKey': key,
        if (_currentTaskId != null) 'taskId': _currentTaskId!,
      });
      // 更新 recoveryId
      final bridgeData = resp['bridge'] as Map<String, dynamic>?;
      final newRid = bridgeData?['recoveryId'] as String? ??
          resp['recoveryId'] as String?;
      if (newRid != null) _currentRecoveryId = newRid;
      await _rpcReadyCompleter!.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('RPC init timeout (reconnect)'),
      );
      _log('info', 'Bridge reopened ✓ ($reason)');
      _degradedCount = 0;
    } catch (e) {
      _log('error', 'Bridge reopen failed ($reason): $e');
    }
  }

  // ================================================================
  // RPC 二进制帧处理
  // ================================================================

  void _handleRpcFrame(Map<String, dynamic> frame) {
    // V4: 收到服务端 rpc-frame 后必须发 rpc-frame-ack 回去
    final messageSeq = frame['messageSeq'];
    if (messageSeq != null && _activeBridgeSession != null) {
      _sendRaw({
        'type': 'data',
        'payload': {
          'zcode_type': 'rpc-frame-ack',
          'bridgeSessionId': _activeBridgeSession,
          'bridgeGeneration': _bridgeGeneration,
          'ackMessageSeq': messageSeq,
        },
        'client_ts': _ts(),
      });
    }

    final dataBase64 = frame['dataBase64'] as String?;
    if (dataBase64 == null) return;

    final bytes = base64Decode(dataBase64);

    // ★ 分片重组: 服务端传输大帧 (如全量快照, 实测 786KB+) 会按
    // fragmentIndex/fragmentCount 切片, 必须收齐拼接后才能解码 —
    // 之前把分片当完整帧解码, 读到跨分片字符串即 RangeError 崩溃。
    final seqKey = (frame['messageSeq'] as int?) ?? (frame['seq'] as int?) ?? 0;
    final fragIndex = frame['fragmentIndex'] as int? ?? 0;
    final fragCount = frame['fragmentCount'] as int? ?? 1;
    final Uint8List data;
    if (fragCount > 1) {
      final buf = _fragBufs.putIfAbsent(
          seqKey, () => List<Uint8List?>.filled(fragCount, null));
      if (fragIndex < buf.length) buf[fragIndex] = Uint8List.fromList(bytes);
      final received = buf.whereType<Uint8List>().length;
      if (received < buf.length) {
        _log('debug', 'rpc-frame 分片 $seqKey: ${received}/${buf.length}');
        return; // 未收齐
      }
      _fragBufs.remove(seqKey);
      final total = buf.fold<int>(0, (s, e) => s + e!.length);
      final merged = Uint8List(total);
      var offset = 0;
      for (final chunk in buf) {
        merged.setAll(offset, chunk!);
        offset += chunk.length;
      }
      data = merged;
      _log('info', 'rpc-frame 分片重组完成 #$seqKey: ${buf.length} 片, ${total}B');
    } else {
      data = Uint8List.fromList(bytes);
    }

    final RpcFrame rpc;
    try {
      rpc = RpcCodec.decode(data);
    } catch (e) {
      // 解码失败不能让它变成未捕获异常 (会中断帧处理循环)
      _log('error', 'rpc-frame 解码失败 (${data.length}B): $e');
      return;
    }

    // RPC Init (bridge 就绪通告)
    if (rpc.isInit && !_rpcReady) {
      _rpcReady = true;
      _log('info', 'RPC ready (bridge init received)');
      _rpcReadyCompleter?.complete();
      if (!_rpcReadyController.isClosed) _rpcReadyController.add(true);
      return;
    }

    // 成功响应 → 配对的请求
    if (rpc.isOk && rpc.id is int) {
      final id = rpc.id as int;
      final completer = _pendingRpc.remove(id);
      if (completer != null && !completer.isCompleted) {
        _log('debug', '← RPC #$id OK: body=${_trunc(rpc.body, 800)}');
        completer.complete(rpc);
        return;
      }
      // V4: listen 的 OK 响应可能直接带 snapshot/frames
      final v4Sub = _v4FrameSubs[id];
      if (v4Sub != null && !v4Sub.isClosed && rpc.body is Map) {
        try {
          final frame = V4Frame.fromJson(Map<String, dynamic>.from(rpc.body as Map));
          _log('debug', '← V4 frame via OK #$id: payload kind=${frame.payload.runtimeType}');
          v4Sub.add(frame);
        } catch (e) {
          _log('error', 'V4 frame decode (via OK) error: $e');
        }
        return;
      }
      _log('warn', '← RPC #$id OK: no pending completer (orphan)');
      return;
    }

    // 错误响应
    if ((rpc.isError || rpc.isErrorObject) && rpc.id is int) {
      final id = rpc.id as int;
      final completer = _pendingRpc.remove(id);
      _log('error', '← RPC #$id ERROR: ${rpc.errorMessage}');
      if (completer != null && !completer.isCompleted) {
        completer.completeError(RpcException(rpc.errorMessage ?? 'RPC error'));
        return;
      }
      return;
    }

    // 事件推送 (type=204)
    if (rpc.isEvent && rpc.id is int) {
      final subId = rpc.id as int;

      // V4 frame 分发
      final v4Sub = _v4FrameSubs[subId];
      if (v4Sub != null && !v4Sub.isClosed) {
        if (rpc.body is Map) {
          try {
            final frame = V4Frame.fromJson(Map<String, dynamic>.from(rpc.body as Map));
            v4Sub.add(frame);
          } catch (e) {
            _log('error', 'V4 frame decode error: $e');
          }
        }
      }

      // sessions-index frame 分发 (原始 map)
      final indexSub = _indexFrameSubs[subId];
      if (indexSub != null && !indexSub.isClosed && rpc.body is Map) {
        indexSub.add(Map<String, dynamic>.from(rpc.body as Map));
      }

      // V3 session event 分发 (保留兼容)
      final event = SessionEvent.fromBody(rpc.body);
      _log('debug', '← EVENT sub=$subId kind=${event.kind} sid=${event.sessionId}');

      // 推到对应订阅的 controller
      final sub = _eventSubs[subId];
      if (sub != null && !sub.isClosed) {
        sub.add(event);
      }

      // 也推到全局 session 事件流
      if (!_sessionEventController.isClosed) {
        _sessionEventController.add(event);
      }
      return;
    }
  }

  /// 发送 RPC 请求并等待 OK 响应
  Future<RpcFrame> _rpcCall(
    String channel,
    String method,
    dynamic args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_rpcReady) {
      throw StateError('RPC not ready (bridge not open)');
    }

    _rpcReqId++;
    final id = _rpcReqId;
    final completer = Completer<RpcFrame>();
    _pendingRpc[id] = completer;

    // ★ 详细日志: 发送的 RPC 请求
    _log('debug', '→ RPC #$id: $channel.$method args=${_trunc(args)}');

    final data = RpcCodec.encodeRequest(id, channel, method, args);
    _sendRpcFrameData(data);

    Future.delayed(timeout, () {
      if (_pendingRpc.containsKey(id)) {
        _pendingRpc.remove(id);
        completer.completeError(TimeoutException('RPC timeout: $channel.$method'));
      }
    });

    return completer.future;
  }

  /// 订阅 RPC 事件流
  ///
  /// 返回事件 Stream, 同时注册全局 onSessionEvent。
  Future<Stream<SessionEvent>> _rpcSubscribe(
    String channel,
    String event,
    dynamic args,
  ) async {
    if (!_rpcReady) {
      throw StateError('RPC not ready');
    }

    _rpcReqId++;
    final id = _rpcReqId;
    final controller = StreamController<SessionEvent>.broadcast();
    _eventSubs[id] = controller;

    // ★ 日志
    _log('info', '→ LISTEN #$id: $channel.$event args=${_trunc(args, 200)}');

    // 订阅请求本身可能也有响应 (确认订阅)
    final data = RpcCodec.encodeListen(id, channel, event, args);
    _sendRpcFrameData(data);

    return controller.stream;
  }

  /// 取消 RPC 订阅 (帧类型 103)
  ///
  /// 3.7.7 抓包实测: 网页端取消订阅发 header=[103, listenId] 的帧
  /// (例如 [103, 30] 对应 LISTEN #30 model-provider.onDidChangeProviderRegistry)。
  void rpcUnlisten(int id) {
    if (!_rpcReady) return;
    _log('info', '→ UNLISTEN #$id');
    _sendRpcFrameData(RpcCodec.encodeUnlisten(id));
    _eventSubs.remove(id)?.close();
    _v4FrameSubs.remove(id)?.close();
  }

  void _sendRpcFrameData(Uint8List data) {
    if (_activeBridgeSession == null) return;
    _seqCounter++;
    final messageBytes = data.length;
    final checksum = _crc32(data);
    _log('debug', '_sendRpcFrameData: seq=$_seqCounter bridgeGen=$_bridgeGeneration bridgeSession=$_activeBridgeSession bytes=$messageBytes checksum=$checksum');
    _sendPayload({
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': _activeBridgeSession,
      'bridgeGeneration': _bridgeGeneration,
      'seq': _seqCounter,
      'messageSeq': _seqCounter,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': messageBytes,
      'checksum': {'algorithm': 'crc32', 'value': checksum},
      'dataBase64': base64Encode(data),
    });
  }

  /// CRC32 (hex, 8 chars, lowercase) — v4 transport checksum
  static String _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final b in data) {
      crc ^= b;
      for (var i = 0; i < 8; i++) {
        crc = (crc >>> 1) ^ (0xEDB88320 & -(crc & 1));
      }
    }
    return (crc ^ 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  }

  // ================================================================
  // 心跳 + 重连
  // ================================================================

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      // TODO: 确定心跳格式 (可能不需要, WS 自带 keepalive)
    });
  }

  void _scheduleReconnect() {
    if (_intentionallyClosed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _setState(RelayConnectionState.error);
      return;
    }
    _reconnectAttempts++;
    _setState(RelayConnectionState.reconnecting);
    final delay = Duration(seconds: min(30, pow(2, _reconnectAttempts).toInt()));
    _log('info', 'Reconnect in ${delay.inSeconds}s (#$_reconnectAttempts)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      try {
        await connect();
      } catch (e) {
        _log('warn', '重连尝试失败: $e');
        _scheduleReconnect();
      }
    });
  }

  void _onError(dynamic error) {
    _log('error', 'WebSocket error: $error');
    if (!_errorController.isClosed) _errorController.add('$error');
    _setState(RelayConnectionState.error);
    _scheduleReconnect();
  }

  void _onDone() {
    _log('info', 'WebSocket closed');
    _heartbeatTimer?.cancel();
    _rpcReady = false;
    if (!_rpcReadyController.isClosed) _rpcReadyController.add(false);
    _fragBufs.clear(); // 断线后未收齐的分片作废
    if (!_intentionallyClosed) {
      _scheduleReconnect();
    } else {
      _setState(RelayConnectionState.disconnected);
    }
  }

  // ================================================================
  // 公开 API — data 层 (不需要 bridge)
  // ================================================================

  /// Bootstrap — 获取工作区和任务列表
  Future<Map<String, dynamic>> bootstrap() {
    return _requestResponse('bootstrap-request', {});
  }

  /// 刷新工作区列表
  Future<Map<String, dynamic>> requestWorkspaceList() {
    return _requestResponse('workspace-list-request', {});
  }

  // ================================================================
  // 公开 API — bridge 层
  // ================================================================

  String? _currentRecoveryId;

  /// V4 握手是否已完成 (幂等: 同一 bridge 只握一次, 网页端模式)
  bool _v4HandshakeDone = false;

  /// 确保 bridge 打开并指向 [workspaceKey] ★ 打开会话前调用
  ///
  /// 网页端模式: bridge 全局只开一次, 切换/打开会话仅重新订阅 (零开销返回)。
  /// 只有 RPC 未就绪或目标工作区不同才完整 (重) 开。
  Future<void> ensureBridgeOpen(String workspaceKey, {String? taskId}) async {
    if (_rpcReady && _currentWorkspaceKey == workspaceKey) {
      // 已有可用 bridge: 只更新恢复上下文 (degraded 时带回 taskId)
      _currentTaskId = taskId;
      return;
    }
    await openWorkspaceBridge(workspaceKey, taskId: taskId);
  }

  /// 打开工作区桥接, 等待 RPC Init
  ///
  /// [workspaceKey]: ★ 3.7.7 抓包实测, 远程工作区必须传 workspaceIdentity
  /// (形如 remote:ssh:host:22:user:path), 传裸路径会 bridge-ready 但永远收不到
  /// RPC Init。本地工作区 identity == 路径, 统一传 identity 即可。
  ///
  /// 调用后 _rpcReady 变 true, 才能调 RPC 方法。
  /// 打开工作区桥接 (single-flight: 并发调用复用同一次打开, 防止 generation 互顶)
  Future<Map<String, dynamic>> openWorkspaceBridge(
    String workspaceKey, {
    String? taskId,
  }) {
    final pending = _bridgeOpenFuture;
    if (pending != null) {
      _log('debug', 'openWorkspaceBridge: 复用进行中的打开');
      return pending.then((_) => {'bridgeSessionId': _activeBridgeSession, 'rpcReady': true});
    }
    final future = _doOpenWorkspaceBridge(workspaceKey, taskId: taskId);
    _bridgeOpenFuture = future;
    return future.whenComplete(() => _bridgeOpenFuture = null);
  }

  Future<Map<String, dynamic>> _doOpenWorkspaceBridge(
    String workspaceKey, {
    String? taskId,
  }) async {
    final sw = Stopwatch()..start();
    _currentWorkspaceKey = workspaceKey;
    _currentTaskId = taskId;
    _bridgeGeneration++;
    _seqCounter = 0;
    _rpcReqId = 0;
    final bridgeSessionId = _genId('bridge');
    _activeBridgeSession = bridgeSessionId;
    _rpcReady = false;
    if (!_rpcReadyController.isClosed) _rpcReadyController.add(false);
    _rpcReadyCompleter = Completer<void>();
    _log('info', 'Opening bridge: workspace=$workspaceKey taskId=${taskId ?? "none"}');

    final resp = _requestResponse('workspace-bridge-open', {
      'bridgeSessionId': bridgeSessionId,
      'bridgeGeneration': _bridgeGeneration,
      'workspaceKey': workspaceKey,
      if (taskId != null) 'taskId': taskId,
    });
    _v4HandshakeDone = false;
    _v4HandshakeFuture = null;

    // 同时等 bridge-ready + RPC Init
    final bridgeReady = await resp;
    // ★ V4: 从 bridge-ready 响应提取 recoveryId
    final bridgeData = bridgeReady['bridge'] as Map<String, dynamic>?;
    _currentRecoveryId = bridgeData?['recoveryId'] as String? ??
        bridgeReady['recoveryId'] as String?;
    _log('info', 'bridge-ready: recoveryId=$_currentRecoveryId (${sw.elapsedMilliseconds}ms)');

    // 等 RPC Init 帧 (服务器自动推送)
    await _rpcReadyCompleter!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('RPC init timeout'),
    );
    _log('info', 'bridge open 完成 (RPC ready, 总耗时 ${sw.elapsedMilliseconds}ms)');

    return {'bridgeSessionId': bridgeSessionId, 'rpcReady': true};
  }

  /// 更新移动端视图状态
  void updateMobileViewState({
    String? activeTaskId,
    String? activeWorkspaceKey,
    String navigationIntent = 'chat',
  }) {
    _sendPayload({
      'zcode_type': 'mobile-view-state-update',
      if (activeTaskId != null) 'activeTaskId': activeTaskId,
      if (activeWorkspaceKey != null) 'activeWorkspaceKey': activeWorkspaceKey,
      'navigationIntent': navigationIntent,
    });
  }

  // ================================================================
  // 公开 API — RPC 业务方法 (实测, 见 docs/API协议规格.md §5)
  // ================================================================

  /// 发送消息 ★
  ///
  /// 调用 zcode-task.enqueueTaskCommand, 立即返回 {accepted:true}。
  /// AI 的流式回复通过 [subscribeSessionEvents] 接收。
  Future<Map<String, dynamic>> enqueueTaskCommand({
    required String taskId,
    required String workspacePath,
    required String content,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    final resp = await _rpcCall('zcode-task', 'enqueueTaskCommand', [
      {
        'workspacePath': workspacePath,
        'taskId': taskId,
        'commandId': 'queued_${now}_$rand',
        'traceId': _genUuid(),
        'queryId': _genUuid(),
        'type': 'send_prompt',
        'content': content,
        'clientId': 'renderer:${_genUuid()}',
        'clientLabel': config.deviceName,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 回答工具权限确认 ★ — enqueueTaskCommand(type: respond_permission)
  ///
  /// wire 实测自 host bundle Zod schema (2026-06-19, 规格 §11.2):
  ///   enqueueTaskCommand type 除了 "send_prompt" 还有 "respond_permission",
  ///   携带 permissionRequestId + optionId + response.decision。
  ///
  /// [permissionRequestId] 来自 permission.requested 事件的 payload.requestId。
  /// [optionId] 来自用户选择的 option.optionId。
  /// [decision] "allow" | "deny" | "escalate" | "modify"。
  /// ★ 回复权限请求 — 网页端实测调的是 zcode-task.respondPermission (独立 RPC 方法!)
  /// 不是 enqueueTaskCommand! 网页端 JS 源码确认:
  ///   zcodeTaskService.respondPermission({taskId, workspacePath, runId, requestId, optionId, response})
  /// Service Proxy 把方法名直接映射为 RPC method name → channel="zcode-task", method="respondPermission"
  Future<Map<String, dynamic>> respondPermission({
    required String taskId,
    required String workspacePath,
    required String traceId,
    required String permissionRequestId,
    required String optionId,
    required String decision,
    Map<String, dynamic>? fullResponse,
    String? reason,
  }) async {
    final responseMap = fullResponse ??
        {
          'decision': decision,
          if (reason != null) 'reason': reason,
        };
    // ★ 直接调 respondPermission 方法 (与网页端 zcodeTaskService.respondPermission 一致)
    final resp = await _rpcCall('zcode-task', 'respondPermission', [
      {
        'taskId': taskId,
        'workspacePath': workspacePath,
        'workspaceKey': workspacePath,
        'runId': traceId,
        'requestId': permissionRequestId,
        'optionId': optionId,
        'response': responseMap,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 加载历史消息 ★
  ///
  /// 调用 zcode-task.getTaskSnapshotWithEtag, 返回 {snapshot, etag}。
  /// snapshot 含 meta + messages[] (见 docs §5.3)。
  Future<Map<String, dynamic>> getTaskSnapshot({
    required String taskId,
    required String workspacePath,
    String? workspaceIdentity,
    int messageLimit = 50,
    int byteBudget = 204800,
    String? etag,
  }) async {
    _log('debug', 'getTaskSnapshot: taskId=$taskId limit=$messageLimit');
    final resp = await _rpcCall('zcode-task', 'getTaskSnapshotWithEtag', [
      {
        'taskId': taskId,
        'workspacePath': workspacePath,
        // ★ 远程工作区必须传 identity: 服务端 workspaceKey = identity||path,
        //   缺失时按本地 path 找不到活跃会话 → 报「没有可用的模型供应商」
        if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
        'messageLimit': messageLimit,
        'byteBudget': byteBudget,
        'clientMode': 'web-remote-replayable',
        if (etag != null) 'etag': etag,
      }
    ]);
    _log('debug', 'getTaskSnapshot: resp.body type=${resp.body.runtimeType}');
    if (resp.body is Map) {
      final m = Map<String, dynamic>.from(resp.body as Map);
      _log('debug', 'getTaskSnapshot: keys=${m.keys.toList()}');
      // 双形状兼容: 标准包装 {snapshot, etag}; 部分 host 版本直接返回快照本体
      // (含 meta/messages 顶层键)。快照缺失时打 warn 便于定位静默失败。
      var snapshot = m['snapshot'] as Map<String, dynamic>?;
      snapshot ??= (m.containsKey('meta') || m.containsKey('messages'))
          ? m
          : null;
      if (snapshot == null) {
        _log('warn', 'getTaskSnapshot: 无 snapshot (keys=${m.keys.toList()})');
      }
      return {'snapshot': snapshot, 'etag': m['etag']};
    }
    _log('warn', 'getTaskSnapshot: body is NOT a Map! body=${_trunc(resp.body)}');
    return {'raw': resp.body};
  }

  /// 列出工作区文件 (file.listWorkspaceFiles)
  /// 网页端 @ 文件提及用此方法获取完整文件列表, 客户端做模糊过滤。
  /// 返回 [{path, relativePath, name, type}, ...]
  Future<List<Map<String, dynamic>>> listWorkspaceFiles({
    required String rootPath,
  }) async {
    final resp = await _rpcCall('file', 'listWorkspaceFiles', [
      {'rootPath': rootPath}
    ]);
    if (resp.body is List) {
      return (resp.body as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return [];
  }

  /// 读取会话详情
  ///
  /// 调用 zcode-session.readSession, 返回完整 session + settings + messages。
  Future<Map<String, dynamic>> readSession({
    required String sessionId,
    required String workspacePath,
    int messageLimit = 1,
  }) async {
    final resp = await _rpcCall('zcode-session', 'readSession', [
      {
        'workspacePath': workspacePath,
        'sessionId': sessionId,
        'messageLimit': messageLimit,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 新建会话/对话 ★
  ///
  /// 调用 zcode-session.createSession, 返回新 session (含 sessionId)。
  /// 参数 (实测自客户端 JS): {workspacePath, workspaceIdentity, mode, model, thoughtLevel}
  Future<Map<String, dynamic>> createSession({
    required String workspacePath,
    String? workspaceIdentity,
    String mode = 'build',
    String? model,
    String thoughtLevel = 'max',
  }) async {
    final resp = await _rpcCall('zcode-session', 'createSession', [
      {
        'workspacePath': workspacePath,
        if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
        'mode': mode,
        if (model != null) 'model': model,
        'thoughtLevel': thoughtLevel,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 订阅 session 事件流 ★
  ///
  /// 调用 zcode-session.onDynamicSessionEvent 订阅,
  /// 返回事件 Stream。AI 的流式回复 (text_delta / reasoning_delta 等)
  /// 都会推到这里。也可监听全局 [onSessionEvent]。
  ///
  /// 参数 (实测自客户端 index-DMg1tzSS.js):
  ///   {workspacePath, sessionId, deliveryKind, includeSnapshot}
  /// 关键: sessionId 指定要订阅哪个会话的事件, 缺了服务器不推事件。
  Future<Stream<SessionEvent>> subscribeSessionEvents({
    required String workspacePath,
    required String sessionId,
    String deliveryKind = 'web-remote-replayable',
    bool includeSnapshot = true,
  }) {
    return _rpcSubscribe('zcode-session', 'onDynamicSessionEvent', {
      'workspacePath': workspacePath,
      'sessionId': sessionId,
      'deliveryKind': deliveryKind,
      'includeSnapshot': includeSnapshot,
    });
  }

  /// 获取 Token 用量
  Future<Map<String, dynamic>> getTaskTokenUsage({
    required String taskId,
    required String workspacePath,
  }) async {
    final resp = await _rpcCall('zcode-task', 'getTaskTokenUsage', [
      {'taskId': taskId, 'workspacePath': workspacePath}
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 切换已有会话的代理模式 ★ (zcode-session.setMode)
  ///
  /// 实测自 host bundle: `request(session/setMode, {sessionId, mode, expectedRevision})`。
  /// **推翻旧结论 "mode 创建时固定"** —— 已有会话也能改 mode。
  /// 新会话仍走 createSession.mode (首发消息时); 此方法用于已有会话热切换。
  Future<Map<String, dynamic>> setSessionMode({
    required String workspacePath,
    required String sessionId,
    required String mode,
    int? expectedRevision,
  }) async {
    final resp = await _rpcCall('zcode-session', 'setMode', [
      {
        'workspacePath': workspacePath,
        'sessionId': sessionId,
        'mode': mode,
        if (expectedRevision != null) 'expectedRevision': expectedRevision,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 压缩对话 (/compact 命令) — zcode-session.compact
  Future<Map<String, dynamic>> compactSession({
    required String workspacePath,
    required String sessionId,
  }) async {
    final resp = await _rpcCall('zcode-session', 'compact', [
      {'workspacePath': workspacePath, 'sessionId': sessionId}
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 读取工作区状态 (含可用模型列表) ★
  ///
  /// host bundle 实测: `readState()` 返回含 `modelProviders`/`bots` 的对象。
  /// 模型 ID 形如 `<providerUuid>/<slug>` (如 `…/glm-5.2`), UUID 为**账号级**
  /// (不在 bundle 里硬编码 → 不能写死), 故可用模型必须运行时从这里取。
  ///
  /// channel: 3.7.7 抓包实测网页端调的是 `zcode-session.readWorkspaceState`;
  /// 旧名 `readState` (zcode-session / zcode-workspace) 保留为回退。
  Future<Map<String, dynamic>> readWorkspaceState({
    required String workspacePath,
    String? workspaceIdentity,
  }) async {
    RpcFrame resp;
    try {
      resp = await _rpcCall('zcode-session', 'readWorkspaceState', [
        {
          'workspacePath': workspacePath,
          if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
        }
      ]);
    } on RpcException {
      try {
        resp = await _rpcCall('zcode-session', 'readState', [
          {
            'workspacePath': workspacePath,
            if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
          }
        ]);
      } on RpcException {
        resp = await _rpcCall('zcode-workspace', 'readState', [
          {
            'workspacePath': workspacePath,
            if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
          }
        ]);
      }
    }
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body, 'typeCode': resp.typeCode};
  }

  /// 获取模型的**显示顺序**列表 — model-provider.getDisplayOrder (规格 §5.5)。
  /// 桌面端模型下拉用的就是它 (比 getAll 更精简/有序); getAll 会列出所有
  /// provider×模型组合 (含 zai/bigmodel/start-plan 等, 多重复), 显示太杂。
  Future<Map<String, dynamic>> getModelDisplayOrder() async {
    final resp = await _rpcCall('model-provider', 'getDisplayOrder', []);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body, 'typeCode': resp.typeCode};
  }

  /// 获取账号可用模型列表 — model-provider.getAll (规格 §5.5 表)。
  /// 这是模型列表的**权威来源** (区别于 zcode-workspace/readState, 后者在 relay 桥为
  /// Unknown channel)。getAll 失败回退 getAllCached。
  Future<Map<String, dynamic>> getModelProviders() async {
    RpcFrame resp;
    try {
      resp = await _rpcCall('model-provider', 'getAll', []);
    } on RpcException {
      resp = await _rpcCall('model-provider', 'getAllCached', []);
    }
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body, 'typeCode': resp.typeCode};
  }

  /// 热切换会话模型 — zcode-session.setModel
  /// [model] 为完整 ID `<providerUuid>/<slug>` (来自 readWorkspaceState)。
  Future<Map<String, dynamic>> setSessionModel({
    required String workspacePath,
    required String sessionId,
    required String model,
  }) async {
    final resp = await _rpcCall('zcode-session', 'setModel', [
      {'workspacePath': workspacePath, 'sessionId': sessionId, 'model': model}
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  // ================================================================
  // V4 对话方法 (全部在 zcode-agent channel)
  // ================================================================

  String _clientId = '';

  String get _v4ClientId {
    if (_clientId.isEmpty) {
      _clientId = 'client-${_genUuid()}';
    }
    return _clientId;
  }

  /// V4 握手: hello + initialize
  /// 在 openWorkspaceBridge 后、subscribeConversationV4 前调用。
  /// 幂等: 同一 bridge 已握过 (或握手进行中) 则直接复用 —
  /// 多处并发调用 (聊天订阅/会话索引订阅) 只握手一次。
  Future<Map<String, dynamic>> v4Handshake() {
    final existing = _v4HandshakeFuture;
    if (existing != null) return existing;
    final future = _doV4Handshake();
    _v4HandshakeFuture = future;
    // 失败允许重试: 清除单飞记录
    future.catchError((_) {
      if (identical(_v4HandshakeFuture, future)) _v4HandshakeFuture = null;
    });
    return future;
  }

  Future<Map<String, dynamic>>? _v4HandshakeFuture;

  Future<Map<String, dynamic>> _doV4Handshake() async {
    if (_v4HandshakeDone) return {};
    // hello
    final hello = await _rpcCall('zcode-agent', 'helloConversationV4', []);
    if (hello.body is Map) {
      _log('info', 'V4 hello: ${hello.body}');
    }
    // initialize
    await _rpcCall('zcode-agent', 'initializeConversationV4', [
      {
        'kind': 'clientHello',
        'protocolVersion': 3,
        'clientId': _v4ClientId,
        'appVersion': config.appVersion,
        'clientKind': 'mobileApp',
      }
    ]);
    _log('info', 'V4 initialized (clientId=$_v4ClientId)');
    _v4HandshakeDone = true;
    if (hello.body is Map) return Map<String, dynamic>.from(hello.body as Map);
    return {};
  }

  /// V4 订阅会话事件流 ★
  ///
  /// 返回 Frame Stream。每个 Frame 含 snapshot 或 deltas。
  Future<Stream<V4Frame>> subscribeConversationV4({
    required String workspacePath,
    required String sessionId,
    String? workspaceIdentity,
    Map<String, dynamic>? base,
    String? visibility,
  }) async {
    // 先 listen 再 subscribe: 初始快照在 subscribe 时投给已注册的监听
    // (网页端顺序: onDynamicConversationFrame → subscribeConversationV4)。
    // 非 broadcast: 缓冲 subscribe 等待期间到达的快照帧。
    _rpcReqId++;
    final id = _rpcReqId;
    final controller = StreamController<V4Frame>();
    _v4FrameSubs[id] = controller;
    _sendRpcFrameData(RpcCodec.encodeListen(id, 'zcode-agent',
        'onDynamicConversationFrame',
          {
            'workspacePath': workspacePath,
            if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
          }
        ));

    try {
      final subResp = await _rpcCall('zcode-agent', 'subscribeConversationV4', [
        {
          'workspacePath': workspacePath,
          if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
          'sessionId': sessionId,
          if (base != null) 'base': base,
          if (visibility != null) 'visibility': visibility,
        }
      ]);
      final subData = subResp.body is Map ? Map<String, dynamic>.from(subResp.body as Map) : <String, dynamic>{};
      final subscriptionId = subData['ack']?['subscriptionId'] as String? ??
          subData['subscriptionId'] as String? ?? '';
      _log('info', 'V4 subscribe: subscriptionId=$subscriptionId');
      _log('debug', 'V4 subscribe: subData=${_trunc(subData, 300)}');
      return controller.stream;
    } catch (e) {
      _v4FrameSubs.remove(id);
      unawaited(controller.close());
      _sendRpcFrameData(RpcCodec.encodeUnlisten(id));
      rethrow;
    }
  }

  /// V4 取消订阅
  Future<void> unsubscribeConversationV4({required String subscriptionId}) async {
    await _rpcCall('zcode-agent', 'unsubscribeConversationV4', [
      {'subscriptionId': subscriptionId}
    ]);
  }

  /// V4 重新同步 (bridge 重连后)
  Future<void> resyncConversationV4({
    required String subscriptionId,
    Map<String, dynamic>? base,
    bool? forceSnapshot,
  }) async {
    await _rpcCall('zcode-agent', 'resyncConversationV4', [
      {
        'subscriptionId': subscriptionId,
        if (base != null) 'base': base,
        if (forceSnapshot != null) 'forceSnapshot': forceSnapshot,
      }
    ]);
  }

  /// V4 发送命令 ★★★ — 替代 v3 的 enqueueTaskCommand + respondPermission 等
  ///
  /// [commandType] 是命令类型: sendText, stop, compact, resolveInteraction,
  ///   switchModelConfig, switchCollaborationMode, createSession, etc.
  /// [payload] 是命令的参数 Map (不含公共字段)。
  Future<Map<String, dynamic>> sendConversationCommandV4({
    required String workspacePath,
    required String commandType,
    Map<String, dynamic> payload = const {},
    String? workspaceIdentity,
    String? sessionId,
    int? baseRevision,
    String? baseLogEpoch,
    Map<String, dynamic>? envelopeExtras,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cmdId = 'cmd_${now}_${Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0')}';

    final envelope = <String, dynamic>{
      // 3.7.7 抓包实测: 网页端 envelope 无 kind 字段 (旧版多发的 kind 服务端兼容)
      'type': commandType,
      'payload': payload,
      'commandId': cmdId,
      'clientId': _v4ClientId,
      'issuedAt': now,
      'sessionId': sessionId,  // null for createSession, sessionId for others
      if (baseRevision != null) 'baseRevision': baseRevision,
      if (baseLogEpoch != null) 'baseLogEpoch': baseLogEpoch,
      // 命令专属信封字段 (如队列命令的 queueItemId — 协议信封基类字段)
      ...?envelopeExtras,
    };

    final resp = await _rpcCall('zcode-agent', 'sendConversationCommandV4', [
      {
        'workspacePath': workspacePath,
        if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
        'envelope': envelope,
      }
    ]);

    if (resp.body is Map) {
      final body = resp.body as Map<String, dynamic>;
      // ★ 服务端命令裁决: rejected 必须抛错 — 否则调用方静默失败
      //   (曾导致 rewind/editUserQuery 无效果但 UI 无任何提示)
      if (body['status'] == 'rejected') {
        final msg = body['message'] is List
            ? (body['message'] as List).map((e) => '$e').join('; ')
            : '${body['message'] ?? ''}';
        throw StateError(
            '命令被拒绝 [${body['reasonCode']}]: $msg');
      }
      return body;
    }
    return {'raw': resp.body};
  }

  /// V4 创建会话 ★ — sendConversationCommandV4(type: createSession)
  ///
  /// 3.7.7 抓包实测 (2026-08-15): 网页端已不再调 zcode-session.createSession RPC,
  /// 改走 V4 命令, envelope 不带 baseRevision, payload 结构:
  ///   {workspaceId: <workspaceIdentity>, config: {mode, followupMode: "queue"}}
  /// 响应: {status: "accepted", result: {type: "createSession", sessionId}}
  /// 返回新 sessionId。
  Future<String> createSessionV4({
    required String workspacePath,
    String? workspaceIdentity,
    required String mode,
  }) async {
    final resp = await sendConversationCommandV4(
      workspacePath: workspacePath,
      workspaceIdentity: workspaceIdentity,
      commandType: 'createSession',
      payload: {
        'workspaceId': workspaceIdentity ?? workspacePath,
        'config': {'mode': mode, 'followupMode': 'queue'},
      },
    );
    final result = resp['result'];
    final sessionId = result is Map ? result['sessionId'] as String? : null;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('createSessionV4 未返回 sessionId: $resp');
    }
    return sessionId;
  }

  /// V4 分页加载历史消息
  Future<Map<String, dynamic>> conversationRowsRangeV4({
    required String workspacePath,
    required String sessionId,
    int? beforeRowId,
    int limit = 50,
    String? workspaceIdentity,
  }) async {
    final resp = await _rpcCall('zcode-agent', 'conversationRowsRangeV4', [
      {
        'workspacePath': workspacePath,
        if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
        'sessionId': sessionId,
        if (beforeRowId != null) 'beforeRowId': beforeRowId,
        'limit': limit,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// V4 获取计划
  Future<Map<String, dynamic>> conversationPlansV4({
    required String workspacePath,
    required String sessionId,
    String? workspaceIdentity,
  }) async {
    final resp = await _rpcCall('zcode-agent', 'conversationPlansV4', [
      {
        'workspacePath': workspacePath,
        if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
        'sessionId': sessionId,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// V4 获取文件变更
  Future<Map<String, dynamic>> conversationFileChangesV4({
    required String workspacePath,
    required String sessionId,
    String? workspaceIdentity,
    required int baseRevision,
    required String baseLogEpoch,
  }) async {
    final resp = await _rpcCall('zcode-agent', 'conversationFileChangesV4', [
      {
        'workspacePath': workspacePath,
        if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
        'sessionId': sessionId,
        'baseRevision': baseRevision,
        'baseLogEpoch': baseLogEpoch,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  // V4 frame 订阅分发表 (替代 _eventSubs for V4 frames)
  final Map<int, StreamController<V4Frame>> _v4FrameSubs = {};

  // sessions-index 帧订阅分发表 (原始 map, 结构与 conversation 帧不同)
  final Map<int, StreamController<Map<String, dynamic>>> _indexFrameSubs = {};

  /// V4 订阅工作区会话索引 ★ (网页端模式)
  ///
  /// 推送 topic=sessions-index/<identity> 的帧:
  /// payload.kind=snapshot → {sessions:[{sessionId,title,phase,lastActivityAt,...}]}
  /// payload.kind=deltas   → [{op:"session.upserted",session:{...}} | {op:"session.removed",...}]
  /// 返回 (subscriptionId, 帧流) — 退订时需携带 subscriptionId
  Future<({String subscriptionId, Stream<Map<String, dynamic>> stream})>
      subscribeSessionsIndexV4({
    required String workspacePath,
    String? workspaceIdentity,
    String runtimePolicy = 'existing-only',
  }) async {
    // 先 listen 再 subscribe: 服务端在 subscribe 时向"当前已注册的监听"投递
    // 初始快照 (网页端顺序: onDynamicSessionsIndexFrame → subscribeSessionsIndexV4,
    // 顺序反了快照永远收不到)。非 broadcast: 缓冲 listen 附着前到达的帧。
    _rpcReqId++;
    final id = _rpcReqId;
    final controller = StreamController<Map<String, dynamic>>();
    _indexFrameSubs[id] = controller;
    _sendRpcFrameData(RpcCodec.encodeListen(id, 'zcode-agent',
        'onDynamicSessionsIndexFrame',
        {
          'workspacePath': workspacePath,
          if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
        }));

    try {
      final subResp = await _rpcCall('zcode-agent', 'subscribeSessionsIndexV4', [
        {
          'workspacePath': workspacePath,
          if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
          'runtimePolicy': runtimePolicy,
        }
      ]);
      final subData = subResp.body is Map
          ? Map<String, dynamic>.from(subResp.body as Map)
          : <String, dynamic>{};
      final subscriptionId =
          subData['ack']?['subscriptionId'] as String? ?? '';
      _log('info', 'V4 sessions-index subscribe: $subscriptionId');
      return (subscriptionId: subscriptionId, stream: controller.stream);
    } catch (e) {
      _indexFrameSubs.remove(id);
      unawaited(controller.close());
      _sendRpcFrameData(RpcCodec.encodeUnlisten(id));
      rethrow;
    }
  }

  /// V4 取消会话索引订阅 (重订阅/切换工作区时调用, 避免服务端订阅堆积)
  Future<void> unsubscribeSessionsIndexV4({required String subscriptionId}) async {
    await _rpcCall('zcode-agent', 'unsubscribeSessionsIndexV4', [
      {'subscriptionId': subscriptionId}
    ]);
    _log('info', 'V4 sessions-index unsubscribe: $subscriptionId');
  }

  /// 通用 RPC 调用 (兜底, 用于尚未封装的方法)
  Future<RpcFrame> rpcCall(String channel, String method, dynamic args) {
    return _rpcCall(channel, method, args);
  }

  // ================================================================
  // session 域方法 (规格 §5.5 — session/stop, session/messages, etc.)
  // ================================================================

  /// 停止当前生成 ★ — session/stop
  Future<Map<String, dynamic>> stopSession({
    required String workspacePath,
    required String sessionId,
  }) async {
    final resp = await _rpcCall('zcode-session', 'stop', [
      {'workspacePath': workspacePath, 'sessionId': sessionId}
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 加载更多历史消息 (分页) — session/messages
  ///
  /// afterSeq: 返回此序号之后的消息 (用于增量加载)。
  Future<Map<String, dynamic>> getSessionMessages({
    required String workspacePath,
    required String sessionId,
    int? afterSeq,
    int limit = 50,
  }) async {
    final resp = await _rpcCall('zcode-session', 'messages', [
      {
        'workspacePath': workspacePath,
        'sessionId': sessionId,
        if (afterSeq != null) 'afterSeq': afterSeq,
        'limit': limit,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 回退对话 (撤销最后一轮) — session/rewind
  Future<Map<String, dynamic>> rewindSession({
    required String workspacePath,
    required String sessionId,
    int? toTurnIndex,
  }) async {
    final resp = await _rpcCall('zcode-session', 'rewind', [
      {
        'workspacePath': workspacePath,
        'sessionId': sessionId,
        if (toTurnIndex != null) 'toTurnIndex': toTurnIndex,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 关闭/结束会话 — session/close
  Future<Map<String, dynamic>> closeSession({
    required String workspacePath,
    required String sessionId,
  }) async {
    final resp = await _rpcCall('zcode-session', 'close', [
      {'workspacePath': workspacePath, 'sessionId': sessionId}
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 获取 Token 用量 — session/usage
  Future<Map<String, dynamic>> getSessionUsage({
    required String workspacePath,
    required String sessionId,
  }) async {
    final resp = await _rpcCall('zcode-session', 'usage', [
      {'workspacePath': workspacePath, 'sessionId': sessionId}
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 切换思考级别 — session/setThoughtLevel
  Future<Map<String, dynamic>> setSessionThoughtLevel({
    required String workspacePath,
    required String sessionId,
    required String thoughtLevel, // 'max' | 'medium' | 'nothink'
  }) async {
    final resp = await _rpcCall('zcode-session', 'setThoughtLevel', [
      {
        'workspacePath': workspacePath,
        'sessionId': sessionId,
        'thoughtLevel': thoughtLevel,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 列出会话 — session/list
  Future<Map<String, dynamic>> listSessions({
    required String workspacePath,
  }) async {
    final resp = await _rpcCall('zcode-session', 'list', [
      {'workspacePath': workspacePath}
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  // ================================================================
  // skills 域方法 — skills/list, skills/setEnabled
  // ================================================================

  /// 获取技能列表 — skills/list
  ///
  /// 返回 {skills: [...], capability: {...}, diagnostics: [...]}
  /// 每个 skill: {id, name, description, enabled, scope, source}
  Future<Map<String, dynamic>> getSkills({
    required String workspacePath,
    String? workspaceIdentity,
    String provider = 'glm',
  }) async {
    final resp = await _rpcCall('skills', 'list', [
      {
        'workspacePath': workspacePath,
        if (workspaceIdentity != null && workspaceIdentity.isNotEmpty)
          'workspaceIdentity': workspaceIdentity,
        'provider': provider,
      }
    ]);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    return {'raw': resp.body};
  }

  /// 启用/禁用技能 — skills/setEnabled
  Future<void> setSkillEnabled({
    required String workspacePath,
    required String skillId,
    required bool enabled,
    String? workspaceIdentity,
    String provider = 'glm',
    String? scope,
  }) async {
    await _rpcCall('skills', 'setEnabled', [
      {
        'workspacePath': workspacePath,
        if (workspaceIdentity != null && workspaceIdentity.isNotEmpty)
          'workspaceIdentity': workspaceIdentity,
        'provider': provider,
        'skillId': skillId,
        'enabled': enabled,
        if (scope != null) 'scope': scope,
      }
    ]);
  }

  // ================================================================
  // Agent 能力域方法 (skills/subagents/commands/hooks/mcp-sync/
  // skill-sync/settings-sync/plugins) — 协议见 docs/v4-API协议规格.md
  // ================================================================

  /// 通用: 调用并归一为 Map
  Future<Map<String, dynamic>> _mapCall(
      String channel, String method, List<dynamic> args) async {
    final resp = await _rpcCall(channel, method, args);
    if (resp.body is Map) return resp.body as Map<String, dynamic>;
    if (resp.body == null) return {};
    return {'raw': resp.body};
  }

  Map<String, dynamic> _ws({
    required String workspacePath,
    String? workspaceIdentity,
    Map<String, dynamic>? extra,
  }) {
    return {
      'workspacePath': workspacePath,
      if (workspaceIdentity != null && workspaceIdentity.isNotEmpty)
        'workspaceIdentity': workspaceIdentity,
      ...?extra,
    };
  }

  // ── skills ──

  /// 删除技能 — skills/deleteSkill (plugin 技能会报错, 需卸载插件)
  Future<void> deleteSkill({
    required String workspacePath,
    required String skillId,
    String? workspaceIdentity,
  }) async {
    await _rpcCall('skills', 'deleteSkill', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'skillId': skillId})
    ]);
  }

  /// 复制技能到通用目录 — skills/copyToCommon
  Future<Map<String, dynamic>> copySkillToCommon({
    required String workspacePath,
    required String skillId,
    String? workspaceIdentity,
  }) async {
    return _mapCall('skills', 'copyToCommon', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'skillId': skillId})
    ]);
  }

  /// 从通用目录移除技能 — skills/removeFromCommon
  Future<Map<String, dynamic>> removeSkillFromCommon({
    required String workspacePath,
    required String skillId,
    String? workspaceIdentity,
  }) async {
    return _mapCall('skills', 'removeFromCommon', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'skillId': skillId})
    ]);
  }

  // ── subagents ──

  /// 子智能体列表 — subagents/list
  Future<Map<String, dynamic>> listSubagents({
    required String workspacePath,
    String? workspaceIdentity,
    String mode = 'allRuntimeScopes',
  }) async {
    return _mapCall('subagents', 'list', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'mode': mode})
    ]);
  }

  /// 启用/禁用子智能体 — subagents/setEnabled
  Future<void> setSubagentEnabled({
    required String agentId,
    required bool enabled,
  }) async {
    await _rpcCall('subagents', 'setEnabled', [
      {'agentId': agentId, 'enabled': enabled}
    ]);
  }

  /// 内置子智能体的模型/思考级别覆盖 — subagents/setBuiltInModelOverride
  Future<void> setSubagentBuiltInModelOverride({
    required String agentName,
    required String? model,
    String? thoughtLevel,
  }) async {
    await _rpcCall('subagents', 'setBuiltInModelOverride', [
      {'agentName': agentName, 'model': model, 'thoughtLevel': thoughtLevel}
    ]);
  }

  /// 新建子智能体 — subagents/createAgent
  Future<Map<String, dynamic>> createSubagent({
    required Map<String, dynamic> config,
    String provider = 'glm',
  }) async {
    return _mapCall('subagents', 'createAgent', [
      {'provider': provider, 'config': config}
    ]);
  }

  /// 更新子智能体 — subagents/updateAgent
  Future<Map<String, dynamic>> updateSubagent({
    required String agentId,
    required Map<String, dynamic> config,
    String? oldFilePath,
    String provider = 'glm',
  }) async {
    return _mapCall('subagents', 'updateAgent', [
      {
        'provider': provider,
        'agentId': agentId,
        'config': config,
        if (oldFilePath != null) 'oldFilePath': oldFilePath,
      }
    ]);
  }

  /// 删除子智能体 — subagents/deleteAgent
  Future<void> deleteSubagent({
    required String agentId,
    required String filePath,
  }) async {
    await _rpcCall('subagents', 'deleteAgent', [
      {'agentId': agentId, 'filePath': filePath}
    ]);
  }

  // ── commands ──

  /// 命令列表 — commands/list
  Future<Map<String, dynamic>> listCommands({
    required String workspacePath,
    String? workspaceIdentity,
  }) async {
    return _mapCall('commands', 'list', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
    ]);
  }

  /// 新建命令 — commands/writeCommandFile
  Future<Map<String, dynamic>> writeCommandFile({
    required Map<String, dynamic> config,
    String storageLevel = 'user',
    String? workspacePath,
  }) async {
    return _mapCall('commands', 'writeCommandFile', [
      {
        'storageLevel': storageLevel,
        if (workspacePath != null && storageLevel == 'workspace')
          'workspacePath': workspacePath,
        'config': config,
      }
    ]);
  }

  /// 更新命令 — commands/updateCommandFile
  Future<Map<String, dynamic>> updateCommandFile({
    required Map<String, dynamic> config,
    required String oldFilePath,
    String storageLevel = 'user',
    String? workspacePath,
  }) async {
    return _mapCall('commands', 'updateCommandFile', [
      {
        'storageLevel': storageLevel,
        if (workspacePath != null && storageLevel == 'workspace')
          'workspacePath': workspacePath,
        'config': config,
        'oldFilePath': oldFilePath,
      }
    ]);
  }

  /// 删除命令 — commands/deleteCommandFile
  Future<void> deleteCommandFile({required String filePath}) async {
    await _rpcCall('commands', 'deleteCommandFile', [
      {'filePath': filePath}
    ]);
  }

  /// 启用/禁用命令 — commands/setCommandEnabled
  Future<void> setCommandEnabled({
    required String filePath,
    required bool enabled,
  }) async {
    await _rpcCall('commands', 'setCommandEnabled', [
      {'filePath': filePath, 'enabled': enabled}
    ]);
  }

  // ── hooks ──

  /// 加载钩子 — hooks/loadHooks
  Future<Map<String, dynamic>> loadHooks({
    required String workspacePath,
    String? workspaceIdentity,
  }) async {
    return _mapCall('hooks', 'loadHooks', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
    ]);
  }

  /// 保存钩子 — hooks/saveHooks
  Future<void> saveHooks({
    required String workspacePath,
    required List<Map<String, dynamic>> hooks,
    String? workspaceIdentity,
  }) async {
    await _rpcCall('hooks', 'saveHooks', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'hooks': hooks})
    ]);
  }

  // ── mcp-sync ──

  /// MCP 服务器列表 (用户+工作区) — mcp-sync/loadMcpFromUserDirectory
  Future<Map<String, dynamic>> loadMcpServers({
    required String workspacePath,
    String? workspaceIdentity,
  }) async {
    return _mapCall('mcp-sync', 'loadMcpFromUserDirectory', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
    ]);
  }

  /// MCP 保存 (upsert/删除/启停) — mcp-sync/saveMcpToUserDirectory
  /// [action] 'upsert' | 'delete' | 'set-enabled'
  Future<void> saveMcpServer({
    required String action,
    required String name,
    Map<String, dynamic>? config,
    bool? enabled,
    String? projectPath,
  }) async {
    await _rpcCall('mcp-sync', 'saveMcpToUserDirectory', [
      {
        'action': action,
        'name': name,
        if (config != null) 'config': config,
        if (enabled != null) 'enabled': enabled,
        if (projectPath != null && projectPath.isNotEmpty)
          'projectPath': projectPath,
      }
    ]);
  }

  /// MCP 服务器运行状态 (每服务器 connected/toolCount/error) — mcp-sync
  Future<Map<String, dynamic>> listMcpServerStatuses({
    required String workspacePath,
    String? workspaceIdentity,
    String mode = 'status',
  }) async {
    final arg = _ws(workspacePath: workspacePath,
        workspaceIdentity: workspaceIdentity, extra: {'mode': mode});
    try {
      return await _mapCall('mcp-sync', 'listWorkspaceMcpServerStatuses', [arg]);
    } catch (_) {
      // 旧 agent 走 zcode-agent 通道
      return _mapCall('zcode-agent', 'listMcpServerStatuses', [arg]);
    }
  }

  // ── settings-sync (外部 Agent 导入) ──

  /// 扫描外部 Agent 可导入资源 — settings-sync/detect
  Future<Map<String, dynamic>> detectExternalAgents({
    String? workspacePath,
    String? workspaceIdentity,
    required List<String> categories,
    String intent = 'manualImport',
  }) async {
    return _mapCall('settings-sync', 'detect', [
      {
        if (workspacePath != null && workspacePath.isNotEmpty)
          'workspacePath': workspacePath,
        if (workspaceIdentity != null && workspaceIdentity.isNotEmpty)
          'workspaceIdentity': workspaceIdentity,
        'categories': categories,
        'intent': intent,
      }
    ]);
  }

  /// 导入外部 Agent 资源 — settings-sync/importSelected
  Future<Map<String, dynamic>> importExternalAgents({
    String? workspacePath,
    String? workspaceIdentity,
    required List<Map<String, dynamic>> selections,
  }) async {
    return _mapCall('settings-sync', 'importSelected', [
      {
        if (workspacePath != null && workspacePath.isNotEmpty)
          'workspacePath': workspacePath,
        if (workspaceIdentity != null && workspaceIdentity.isNotEmpty)
          'workspaceIdentity': workspaceIdentity,
        'selections': selections,
      }
    ]);
  }

  // ── plugins ──

  /// 插件启停 — plugins/setPluginEnabled
  Future<void> setPluginEnabled({
    required String workspacePath,
    required String pluginId,
    required bool enabled,
    String? workspaceIdentity,
  }) async {
    await _rpcCall('plugins', 'setPluginEnabled', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'pluginId': pluginId, 'enabled': enabled})
    ]);
  }

  /// 插件概览 — zcode-agent/getPluginsOverview
  Future<Map<String, dynamic>> getPluginsOverview({
    required String workspacePath,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'getPluginsOverview', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
    ]);
  }

  /// 插件列表 — zcode-agent/listPlugins
  Future<Map<String, dynamic>> listPlugins({
    required String workspacePath,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'listPlugins', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
    ]);
  }

  /// 插件市场目录 (可浏览安装的插件) — zcode-agent/getPluginReferenceCatalog
  /// 返回 {plugins: [...], authority}
  Future<Map<String, dynamic>> getPluginReferenceCatalog({
    required String workspacePath,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'getPluginReferenceCatalog', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity)
    ]);
  }

  /// 插件详情 (组件清单: 命令/技能/钩子/MCP 等) — zcode-agent/describePlugin
  Future<Map<String, dynamic>> describePlugin({
    required String workspacePath,
    required String marketplace,
    required String pluginName,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'describePlugin', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'marketplace': marketplace, 'pluginName': pluginName})
    ]);
  }

  /// 安装插件 — zcode-agent/installPlugin
  Future<Map<String, dynamic>> installPlugin({
    required String workspacePath,
    required String pluginName,
    required String marketplace,
    String? scope,
    String? operationId,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'installPlugin', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {
        'pluginName': pluginName,
        'marketplace': marketplace,
        if (scope != null) 'scope': scope,
        if (operationId != null) 'operationId': operationId,
      })
    ]);
  }

  /// 卸载插件 — zcode-agent/uninstallPlugin
  Future<Map<String, dynamic>> uninstallPlugin({
    required String workspacePath,
    String? pluginId,
    String? pluginName,
    String? marketplace,
    bool removeCache = false,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'uninstallPlugin', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {
        if (pluginId != null) 'pluginId': pluginId,
        if (pluginName != null) 'pluginName': pluginName,
        if (marketplace != null) 'marketplace': marketplace,
        'removeCache': removeCache,
      })
    ]);
  }

  /// 更新插件 — zcode-agent/updatePlugin
  Future<Map<String, dynamic>> updatePlugin({required String pluginId}) async {
    return _mapCall('zcode-agent', 'updatePlugin', [
      {'pluginId': pluginId}
    ]);
  }

  /// 取消插件操作 — zcode-agent/cancelPluginOperation
  Future<void> cancelPluginOperation({required String operationId}) async {
    await _rpcCall('zcode-agent', 'cancelPluginOperation', [
      {'operationId': operationId}
    ]);
  }

  /// 恢复内置插件 — zcode-agent/restoreBuiltinPlugin
  Future<Map<String, dynamic>> restoreBuiltinPlugin(
      {required String pluginId}) async {
    return _mapCall('zcode-agent', 'restoreBuiltinPlugin', [
      {'pluginId': pluginId}
    ]);
  }

  /// 添加插件市场 — zcode-agent/addPluginMarketplace
  Future<Map<String, dynamic>> addPluginMarketplace({
    required String workspacePath,
    required String source,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'addPluginMarketplace', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'source': source})
    ]);
  }

  /// 移除插件市场 — zcode-agent/removePluginMarketplace
  Future<Map<String, dynamic>> removePluginMarketplace({
    required String workspacePath,
    required String marketplace,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'removePluginMarketplace', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {'marketplace': marketplace})
    ]);
  }

  /// 更新插件市场 — zcode-agent/updatePluginMarketplace
  Future<Map<String, dynamic>> updatePluginMarketplace({
    required String workspacePath,
    String? marketplace,
    String? workspaceIdentity,
  }) async {
    return _mapCall('zcode-agent', 'updatePluginMarketplace', [
      _ws(workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
          extra: {if (marketplace != null) 'marketplace': marketplace})
    ]);
  }

  // ── setting (桌面端设置) ──

  /// 读取桌面端设置 — setting/get (无参 = 全部)
  Future<Map<String, dynamic>> getSettings() async {
    return _mapCall('setting', 'get', []);
  }

  /// 更新桌面端设置 — setting/update
  Future<void> updateSettings(Map<String, dynamic> settings) async {
    await _rpcCall('setting', 'update', [settings]);
  }

  void dispose() {
    _log('info', 'RelayClient disposed');
    disconnect();
    for (final c in _eventSubs.values) {
      c.close();
    }
    _eventSubs.clear();
    for (final c in _v4FrameSubs.values) {
      c.close();
    }
    _v4FrameSubs.clear();
    for (final c in _indexFrameSubs.values) {
      c.close();
    }
    _indexFrameSubs.clear();
    _stateController.close();
    _agentEventController.close();
    _sessionEventController.close();
    _errorController.close();
    _rpcReadyController.close();
    _workspaceListController.close();
  }
}

/// RPC 调用异常
class RpcException implements Exception {
  final String message;
  RpcException(this.message);

  @override
  String toString() => 'RpcException: $message';
}
