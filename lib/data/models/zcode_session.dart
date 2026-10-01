/// 用户登录会话 (实测版)
///
/// zcode 认证需要:
/// - mid: 设备 ID (WebSocket URL 参数)
/// - deviceSid: 设备 SID (认证用, URL sid 参数)
/// - passHash: 密码哈希 (HMAC key, URL hash 参数 decode 后)
/// - cookie: 会话 Cookie (WebSocket 连接认证)
class ZcodeSession {
  final String mid;
  final String deviceSid;
  final String passHash;
  final String cookie;
  final String deviceName;
  final DateTime createdAt;

  ZcodeSession({
    required this.mid,
    required this.deviceSid,
    required this.passHash,
    required this.cookie,
    this.deviceName = 'mobile-browser',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isValid =>
      deviceSid.isNotEmpty && passHash.isNotEmpty && cookie.isNotEmpty;

  factory ZcodeSession.fromJson(Map<String, dynamic> json) {
    return ZcodeSession(
      mid: json['mid'] as String? ?? '',
      deviceSid: json['deviceSid'] as String? ?? '',
      passHash: json['passHash'] as String? ?? '',
      cookie: json['cookie'] as String? ?? '',
      deviceName: json['deviceName'] as String? ?? 'mobile-browser',
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'mid': mid,
    'deviceSid': deviceSid,
    'passHash': passHash,
    'cookie': cookie,
    'deviceName': deviceName,
    'createdAt': createdAt.toIso8601String(),
  };
}
