/// 账号登录凭据 (3.16+ OAuth 链路)
///
/// OAuth 授权码换票后持久化: jwt 是所有 /api/v1/remote/* 的 Bearer 凭据,
/// userInfo 原样保留 (展示用, 如昵称/头像)。
class ZcodeAccount {
  final String jwt;

  /// 登录供应商 ('zai' | 'bigmodel', 默认 zai — 旧存储无此键时回退)
  final String provider;

  final Map<String, dynamic> userInfo;

  const ZcodeAccount({
    required this.jwt,
    this.provider = 'zai',
    this.userInfo = const {},
  });

  factory ZcodeAccount.fromJson(Map<String, dynamic> json) {
    return ZcodeAccount(
      jwt: json['jwt'] as String? ?? '',
      provider: json['provider'] as String? ?? 'zai',
      userInfo: json['userInfo'] is Map
          ? Map<String, dynamic>.from(json['userInfo'] as Map)
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'jwt': jwt,
    'provider': provider,
    'userInfo': userInfo,
  };
}
