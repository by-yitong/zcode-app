import '../../core/relay/relay_client.dart';
import '../../core/relay/relay_events.dart';
import '../../core/storage/secure_storage.dart';
import '../../data/models/zcode_account.dart';
import '../../data/models/zcode_session.dart';

/// 认证 Repository (账号链路, 桌面端 3.16+)
class AuthRepository {
  final SecureStorageService _storage;

  AuthRepository(this._storage);

  Future<ZcodeSession?> restoreSession() async {
    return _storage.getSession();
  }

  Future<void> saveSession(ZcodeSession session) async {
    await _storage.saveSession(session);
  }

  Future<void> clearSession() async {
    await _storage.clearSession();
  }

  // ── 账号登录 (3.16+ OAuth) ─────────────────────────────

  /// 恢复已存储的账号凭据 (未登录返回 null)
  Future<ZcodeAccount?> restoreAccount() async {
    return _storage.getAccount();
  }

  /// 持久化账号凭据 (OAuth 换票成功后调用)
  Future<void> saveAccount(ZcodeAccount account) async {
    await _storage.saveAccount(account);
  }

  /// 清除账号凭据 (退出账号登录)
  Future<void> clearAccount() async {
    await _storage.clearAccount();
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
