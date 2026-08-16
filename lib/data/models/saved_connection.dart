/// 已保存的远程连接 (多连接切换)
///
/// id = deviceSid (一个桌面端配对对应一个 sid, 天然去重键)。
/// loginUrl 保留完整原始地址, 切换时重新 loginFromUrl 获取新 Cookie。
class SavedConnection {
  final String id; // deviceSid
  final String label; // 显示名 (可改)
  final String loginUrl;
  final String mid;
  final String name; // URL 里的 name 参数 (机器名)
  final DateTime createdAt;
  final DateTime lastUsedAt;

  const SavedConnection({
    required this.id,
    required this.label,
    required this.loginUrl,
    required this.mid,
    required this.name,
    required this.createdAt,
    required this.lastUsedAt,
  });

  factory SavedConnection.fromUrl(String url, {String? label}) {
    final uri = Uri.parse(url);
    final p = uri.queryParameters;
    final name = p['name'] ?? '未知设备';
    final now = DateTime.now();
    return SavedConnection(
      id: p['sid'] ?? now.microsecondsSinceEpoch.toString(),
      label: label ?? name,
      loginUrl: url,
      mid: p['mid'] ?? '',
      name: name,
      createdAt: now,
      lastUsedAt: now,
    );
  }

  SavedConnection copyWith({
    String? label,
    DateTime? lastUsedAt,
    String? loginUrl,
  }) =>
      SavedConnection(
        id: id,
        label: label ?? this.label,
        loginUrl: loginUrl ?? this.loginUrl,
        mid: mid,
        name: name,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'loginUrl': loginUrl,
        'mid': mid,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'lastUsedAt': lastUsedAt.toIso8601String(),
      };

  static SavedConnection fromJson(Map<String, dynamic> j) => SavedConnection(
        id: (j['id'] ?? '').toString(),
        label: (j['label'] ?? j['name'] ?? '未知设备').toString(),
        loginUrl: (j['loginUrl'] ?? '').toString(),
        mid: (j['mid'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        createdAt: DateTime.tryParse((j['createdAt'] ?? '').toString()) ??
            DateTime.now(),
        lastUsedAt: DateTime.tryParse((j['lastUsedAt'] ?? '').toString()) ??
            DateTime.now(),
      );
}
