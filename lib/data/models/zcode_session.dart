/// 用户登录会话 (账号链路, 桌面端 3.16+)
///
/// - mid: 设备 ID (ws2 URL 参数)
/// - deviceSid: 设备 SID (认证用, URL sid 参数)
/// - deviceName: 设备名 (auth_init meta.name)
/// - appVersion: 对端桌面端版本 (auth_init meta.version)
///
/// fromJson 兼容旧存储: 忽略旧链路遗留的多余键, 只读四字段。
class ZcodeSession {
  final String mid;
  final String deviceSid;
  final String deviceName;
  final String appVersion;

  ZcodeSession({
    required this.mid,
    required this.deviceSid,
    this.deviceName = 'mobile-browser',
    this.appVersion = '3.16.2',
  });

  /// deviceSid + mid 非空即有效 (ws2 URL 参数)
  bool get isValid => deviceSid.isNotEmpty && mid.isNotEmpty;

  factory ZcodeSession.fromJson(Map<String, dynamic> json) {
    return ZcodeSession(
      mid: json['mid'] as String? ?? '',
      deviceSid: json['deviceSid'] as String? ?? '',
      deviceName: json['deviceName'] as String? ?? 'mobile-browser',
      appVersion: json['appVersion'] as String? ?? '3.16.2',
    );
  }

  Map<String, dynamic> toJson() => {
    'mid': mid,
    'deviceSid': deviceSid,
    'deviceName': deviceName,
    'appVersion': appVersion,
  };
}
