import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../core/relay/relay_client.dart';
import '../../core/relay/relay_events.dart';
import '../../core/storage/secure_storage.dart';
import '../../data/models/saved_connection.dart';
import '../../data/models/zcode_session.dart';

/// 认证 Repository
class AuthRepository {
  final SecureStorageService _storage;

  AuthRepository(this._storage);

  Future<ZcodeSession?> restoreSession() async {
    return _storage.getSession();
  }

  /// 从 zcode 连接地址登录 (自动获取 Cookie, 无需用户手动输入)
  ///
  /// 流程:
  /// 1. 解析 URL 参数 (sid/hash/mid/name)
  /// 2. HTTP GET 连接地址 → 服务器 Set-Cookie 自动返回 acw_tc 等
  /// 3. 组装 ZcodeSession
  ///
  /// URL 格式:
  /// https://zcode.z.ai/remote/v3?sid=d_xxx&hash=xxx&mid=xxx&name=xxx
  ///
  /// 抛出 [ArgumentError] 如果 URL 缺少必要参数。
  /// 抛出 [Exception] 如果 HTTP 请求失败或没拿到 cookie。
  Future<ZcodeSession> loginFromUrl(String urlString) async {
    final uri = Uri.parse(urlString);
    final params = uri.queryParameters;

    // 不打印完整 URL — query 里有 sid/hash 等敏感参数
    appLog.i('[Auth] 开始登录: host=${uri.host}');

    final sid = params['sid'];
    final hashEncoded = params['hash'];
    final mid = params['mid'];

    if (sid == null || sid.isEmpty) {
      appLog.w('[Auth] URL 缺少 sid 参数');
      throw ArgumentError('URL 缺少 sid 参数');
    }
    if (hashEncoded == null || hashEncoded.isEmpty) {
      appLog.w('[Auth] URL 缺少 hash 参数');
      throw ArgumentError('URL 缺少 hash 参数');
    }
    if (mid == null || mid.isEmpty) {
      appLog.w('[Auth] URL 缺少 mid 参数');
      throw ArgumentError('URL 缺少 mid 参数');
    }

    // hash 是 URL encode 的, 需要 decode
    final hashDecoded = Uri.decodeComponent(hashEncoded);
    final name = params['name'] ?? 'mobile-browser';

    // HTTP GET 连接地址, 服务器自动返回 cookie
    final cookie = await _fetchCookie(urlString);
    if (cookie.isEmpty) {
      appLog.w('[Auth] 服务器未返回 Cookie, 连接地址可能已失效');
      throw Exception('服务器未返回 Cookie, 请检查连接地址是否有效');
    }
    appLog.i('[Auth] 登录成功: 拿到 ${cookie.split('; ').length} 个 cookie 字段');

    return ZcodeSession(
      mid: mid,
      deviceSid: sid,
      passHash: hashDecoded,
      cookie: cookie,
      deviceName: name,
    );
  }

  /// HTTP GET 拿 Set-Cookie (acw_tc 等)
  ///
  /// APP 不需要用户手动输入 cookie — 访问连接地址时服务器自动下发。
  Future<String> _fetchCookie(String urlString) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(urlString));
      req.headers.set('user-agent', 'Mozilla/5.0');
      final res = await req.close();
      await res.drain<void>();

      // 收集所有 set-cookie
      final cookies = <String>[];
      for (final h in res.headers[HttpHeaders.setCookieHeader] ?? <String>[]) {
        final part = h.split(';').first.trim();
        if (part.isNotEmpty) cookies.add(part);
      }
      appLog.d('[Auth] _fetchCookie: HTTP ${res.statusCode}, set-cookie ${cookies.length} 条');
      return cookies.join('; ');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> saveSession(ZcodeSession session) async {
    await _storage.saveSession(session);
  }

  Future<void> logout() async {
    await _storage.clearSession();
  }

  // ── 多远程连接 ──────────────────────────────────────────

  /// 已保存的连接列表 (按最近使用倒序)
  Future<List<SavedConnection>> listConnections() {
    return _storage.getConnections();
  }

  /// 保存/更新一条连接 (按 deviceSid 去重, 更新 lastUsedAt 与最新 URL)
  Future<void> addConnection(String loginUrl, ZcodeSession session) async {
    final conns = await _storage.getConnections();
    final fresh = SavedConnection.fromUrl(loginUrl);
    final idx = conns.indexWhere((c) => c.id == fresh.id);
    if (idx >= 0) {
      // 保留用户改过的 label, 更新 URL 与时间
      conns[idx] = conns[idx]
          .copyWith(loginUrl: fresh.loginUrl, lastUsedAt: DateTime.now());
    } else {
      conns.insert(0, fresh);
    }
    await _storage.saveConnections(conns);
  }

  Future<void> deleteConnection(String id) async {
    final conns = await _storage.getConnections();
    await _storage
        .saveConnections([for (final c in conns) if (c.id != id) c]);
  }

  Future<void> renameConnection(String id, String label) async {
    final conns = await _storage.getConnections();
    final idx = conns.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    conns[idx] = conns[idx].copyWith(label: label.trim());
    await _storage.saveConnections(conns);
  }

  /// 切换到已保存的连接: 重新走 loginFromUrl (取新 Cookie, 规避过期)。
  /// 目标桌面端需在线, 否则抛错。
  Future<ZcodeSession> reconnect(SavedConnection conn) async {
    return loginFromUrl(conn.loginUrl);
  }
}

/// 工作区 Repository
class WorkspaceRepository {
  final RelayClient _relay;

  WorkspaceRepository(this._relay);

  /// Bootstrap — 获取工作区和任务列表
  Future<Map<String, dynamic>> bootstrap() async {
    await _relay.connect();
    return _relay.bootstrap();
  }

  /// 刷新工作区列表
  Future<Map<String, dynamic>> refresh() async {
    return _relay.requestWorkspaceList();
  }

  /// 打开工作区桥接
  Future<Map<String, dynamic>> openWorkspace(
    String workspaceKey, {
    String? taskId,
  }) async {
    return _relay.openWorkspaceBridge(workspaceKey, taskId: taskId);
  }
}

/// 聊天 Repository (实测 2026-06-15)
///
/// 发消息: zcode-task.enqueueTaskCommand → 立即入队, 流式回复走事件订阅
/// 加载历史: zcode-task.getTaskSnapshotWithEtag → snapshot.messages[]
class ChatRepository {
  final RelayClient _relay;

  ChatRepository(this._relay);

  /// 发送消息
  ///
  /// 返回 {accepted:true, command:{commandId, taskId, traceId, queryId}}。
  /// AI 的回复通过 [RelayClient.onSessionEvent] 流接收。
  Future<Map<String, dynamic>> sendMessage({
    required String taskId,
    required String workspacePath,
    required String content,
  }) {
    return _relay.enqueueTaskCommand(
      taskId: taskId,
      workspacePath: workspacePath,
      content: content,
    );
  }

  /// 加载历史消息
  ///
  /// 返回 {snapshot:{meta, messages[]}, etag}。
  /// messages 含 role/content/thought/parts/model/turnIndex。
  Future<Map<String, dynamic>> loadHistory({
    required String taskId,
    required String workspacePath,
    int messageLimit = 50,
    String? etag,
  }) {
    return _relay.getTaskSnapshot(
      taskId: taskId,
      workspacePath: workspacePath,
      messageLimit: messageLimit,
      etag: etag,
    );
  }

  /// 订阅 session 事件流 (AI 回复)
  Future<Stream<SessionEvent>> subscribeEvents({
    required String workspacePath,
    required String sessionId,
  }) {
    return _relay.subscribeSessionEvents(
      workspacePath: workspacePath,
      sessionId: sessionId,
    );
  }
}
