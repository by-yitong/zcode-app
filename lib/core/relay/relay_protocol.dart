/// ZCode Relay 协议消息类型
///
/// 基于 zcode web client (v3.0.1) 逆向分析
enum ZcodeMessageType {
  // 连接生命周期
  bootstrapRequest('bootstrap-request'),
  bootstrapResponse('bootstrap-response'),
  workspaceListRequest('workspace-list-request'),
  workspaceListResponse('workspace-list-response'),
  workspaceReconnectRequest('workspace-reconnect-request'),
  workspaceReconnectResponse('workspace-reconnect-response'),

  // 工作区桥接
  workspaceBridgeOpen('workspace-bridge-open'),
  workspaceBridgeReady('workspace-bridge-ready'),
  workspaceBridgeError('workspace-bridge-error'),
  bridgeDegraded('bridge-degraded'),

  // RPC
  platformRequest('platform-request'),
  platformResponse('platform-response'),
  rpcFrame('rpc-frame'),

  // 错误
  appError('app-error'),

  // 移动端
  mobileDiagnostic('mobile-diagnostic'),
  mobileViewStateUpdate('mobile-view-state-update');

  final String value;
  const ZcodeMessageType(this.value);

  static ZcodeMessageType? fromString(String? value) {
    if (value == null) return null;
    for (final type in ZcodeMessageType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// Relay 连接状态
enum RelayConnectionState {
  idle,
  connecting,
  connected,
  bootstrapping,
  ready,
  reconnecting,
  disconnected,
  error,
}
