import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/workspace.dart';

/// 选入口工作区 (启动/登录后直达聊天用):
/// 上次打开的 → 默认工作区 (网页端"不在项目中工作") → 第一个
Future<Workspace?> pickEntryWorkspace(List<Workspace> workspaces) async {
  if (workspaces.isEmpty) return null;
  try {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('lastWorkspaceKey');
    if (last != null && workspaces.any((w) => w.workspaceKey == last)) {
      return workspaces.firstWhere((w) => w.workspaceKey == last);
    }
  } catch (_) {}
  final def = workspaces
      .where((w) => w.workspacePath.endsWith('.zcode/workspace/default'));
  if (def.isNotEmpty) return def.first;
  return workspaces.first;
}
