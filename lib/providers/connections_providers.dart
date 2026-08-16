/// 多远程连接 providers
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/saved_connection.dart';
import '../data/models/zcode_session.dart';
import '../data/repositories/repositories.dart';
import 'app_providers.dart';

/// 已保存连接列表
final connectionsProvider =
    StateNotifierProvider<ConnectionsNotifier, AsyncValue<List<SavedConnection>>>(
        (ref) => ConnectionsNotifier(ref));

class ConnectionsNotifier
    extends StateNotifier<AsyncValue<List<SavedConnection>>> {
  ConnectionsNotifier(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;

  AuthRepository get _auth => _ref.read(authRepositoryProvider);

  Future<void> load() async {
    try {
      state = AsyncValue.data(await _auth.listConnections());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> remove(String id) async {
    await _auth.deleteConnection(id);
    await load();
  }

  Future<void> rename(String id, String label) async {
    await _auth.renameConnection(id, label);
    await load();
  }

  /// 切换连接: 重新登录 (取新 Cookie) → 激活会话。
  /// 成功后由 UI 跳 splash 重新 bootstrap。
  Future<void> switchTo(SavedConnection conn) async {
    final session = await _auth.reconnect(conn);
    await _auth.addConnection(conn.loginUrl, session);
    await _ref.read(sessionProvider.notifier).loginWithSession(session);
    await load();
  }
}

/// 登录成功后登记连接 (loginFromUrl 之后调用)
Future<void> registerLogin(
    WidgetRef ref, String loginUrl, ZcodeSession session) async {
  try {
    await ref.read(authRepositoryProvider).addConnection(loginUrl, session);
    ref.read(connectionsProvider.notifier).load();
  } catch (_) {
    // 登记失败不阻塞主流程
  }
}
