import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart' as connectivity_plus;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../core/logging/app_logger.dart';
import '../core/network/zcode_api_client.dart';
import '../core/notifications/notification_service.dart';
import '../core/relay/relay_client.dart';
import '../core/relay/relay_protocol.dart';
import '../core/services/glm_quota_service.dart';
import '../core/storage/secure_storage.dart';
import '../data/models/glm_quota.dart';
import '../data/models/workspace.dart';
import '../data/models/zcode_session.dart';
import '../data/repositories/repositories.dart';

// ================================================================
// 基础设施 Providers
// ================================================================

/// 统一走全局 [appLog] 门面 (级别随 kDebugMode 收敛)。
/// 注意不能在 dispose 时 close — 它是全局单例, 关掉会导致全应用无日志。
final loggerProvider = Provider<Logger>((ref) => appLog.logger);

final secureStorageProvider = Provider<SecureStorageService>((ref) {
  return SecureStorageService();
});

final preferencesProvider =
    FutureProvider<PreferencesService>((ref) async {
  final prefs = PreferencesService();
  await prefs.init();
  return prefs;
});

// ================================================================
// 网络状态
// ================================================================

/// 网络连接状态变化 (connectivity_plus 6.x: 每次发出 List<ConnectivityResult>)。
///
/// 单独维护 `wasOffline`: 仅在网络从 `ConnectivityResult.none` 恢复到任意在线
/// 类型时输出 info 日志, 供上层监听并触发自动刷新。
final networkInfoProvider =
    StreamProvider<List<connectivity_plus.ConnectivityResult>>((ref) async* {
  final connectivity = connectivity_plus.Connectivity();
  var wasOffline = false;
  yield* connectivity.onConnectivityChanged.map((results) {
    final logger = ref.read(loggerProvider);
    final offline = results.contains(connectivity_plus.ConnectivityResult.none);
    if (offline) {
      wasOffline = true;
    } else if (wasOffline) {
      wasOffline = false;
      logger.i('[Network] 网络已恢复: $results');
    }
    return results;
  });
});

// ================================================================
// 主题模式
// ================================================================

/// 主题模式状态 (深色 / 浅色 / 跟随系统)。默认深色 (dev tool 主场)。
/// 初始值在 main() 中根据 SharedPreferences 持久化数据 override。
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);

/// SharedPreferences 中存储的主题字符串 key
const kThemeModePrefKey = 'themeMode';

/// SharedPreferences 字符串 → ThemeMode。null / 未知值回退到深色。
ThemeMode themeModeFromString(String? value) {
  switch (value) {
    case 'light':
      return ThemeMode.light;
    case 'system':
      return ThemeMode.system;
    case 'dark':
    default:
      return ThemeMode.dark;
  }
}

/// ThemeMode → 持久化字符串
String themeModeToString(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.system:
      return 'system';
    case ThemeMode.dark:
      return 'dark';
  }
}

/// 中文显示标签
String themeModeLabel(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.dark:
      return '深色';
    case ThemeMode.light:
      return '浅色';
    case ThemeMode.system:
      return '跟随系统';
  }
}

final zcodeApiClientProvider = Provider<ZcodeApiClient>((ref) {
  return ZcodeApiClient();
});

// ================================================================
// Session / Auth
// ================================================================

/// 当前会话
final sessionProvider =
    StateNotifierProvider<SessionNotifier, AsyncValue<ZcodeSession?>>((ref) {
  return SessionNotifier(ref.watch(secureStorageProvider));
});

class SessionNotifier extends StateNotifier<AsyncValue<ZcodeSession?>> {
  final SecureStorageService _storage;

  SessionNotifier(this._storage) : super(const AsyncValue.loading()) {
    _restore();
  }

  Future<void> _restore() async {
    try {
      final session = await _storage.getSession();
      if (session != null && session.isValid) {
        appLog.i('[Session] 恢复已保存的会话');
        state = AsyncValue.data(session);
      } else {
        appLog.i('[Session] 无可用会话 (session=${session == null ? "未存储" : "已失效"})');
        state = const AsyncValue.data(null);
      }
    } catch (e, st) {
      appLog.e('[Session] 恢复会话异常', e, st);
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> loginWithSession(ZcodeSession session) async {
    appLog.i('[Session] 登录成功, 保存会话');
    await _storage.saveSession(session);
    state = AsyncValue.data(session);
  }

  Future<void> logout() async {
    appLog.i('[Session] 退出登录, 清除本地会话');
    await _storage.clearSession();
    state = const AsyncValue.data(null);
  }
}

// ================================================================
// RelayClient
// ================================================================

/// 当前活跃的 RelayClient (依赖 session)
final relayClientProvider = Provider<RelayClient?>((ref) {
  final session = ref.watch(sessionProvider);

  return session.whenOrNull(
    data: (session) {
      if (session == null || !session.isValid) return null;

      final logger = ref.read(loggerProvider);
      final config = RelayConfig(
        wsUrl: 'wss://zcode.z.ai/ws?mid=${session.mid}',
        deviceSid: session.deviceSid,
        passHash: session.passHash,
        cookie: session.cookie,
        deviceName: session.deviceName,
      );

      final client = RelayClient(
        config: config,
        logger: (level, message) {
          switch (level) {
            case 'error':
              logger.e('[Relay] $message');
            case 'warn':
              logger.w('[Relay] $message');
            case 'info':
              logger.i('[Relay] $message');
            default:
              logger.d('[Relay] $message');
          }
        },
      );

      ref.onDispose(client.dispose);
      return client;
    },
  );
});

/// Relay 连接状态
final relayConnectionStateProvider = StreamProvider<RelayConnectionState>((ref) async* {
  final client = ref.watch(relayClientProvider);
  if (client == null) return;
  // 先 yield 当前状态, 避免 StreamProvider 卡在 loading (broadcast stream 不重放缓存)
  yield client.state;
  yield* client.onStateChange;
});

// ================================================================
// 后台保活 (前台服务)
// ================================================================

/// 登录 → 启动前台服务 (常驻通知, 进程保活, 后台持续收 WS 消息);
/// 登出 → 停止。需被 UI 长期 watch 才激活 (ZcodeApp build 中 watch)。
final keepAliveProvider = Provider<bool>((ref) {
  final client = ref.watch(relayClientProvider);
  if (client != null) {
    NotificationService.startKeepAlive();
  } else {
    NotificationService.stopKeepAlive();
  }
  return client != null;
});

// ================================================================
// Repositories
// ================================================================

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(secureStorageProvider));
});

final workspaceRepositoryProvider = Provider<WorkspaceRepository?>((ref) {
  final client = ref.watch(relayClientProvider);
  if (client == null) return null;
  return WorkspaceRepository(client);
});

final chatRepositoryProvider = Provider<ChatRepository?>((ref) {
  final client = ref.watch(relayClientProvider);
  if (client == null) return null;
  return ChatRepository(client);
});

// ================================================================
// 工作区列表
// ================================================================

/// 工作区列表
final workspaceListProvider =
    StateNotifierProvider<WorkspaceListNotifier, AsyncValue<List<Workspace>>>((ref) {
  final repo = ref.watch(workspaceRepositoryProvider);
  return WorkspaceListNotifier(repo, ref);
});

class WorkspaceListNotifier
    extends StateNotifier<AsyncValue<List<Workspace>>> {
  final WorkspaceRepository? _repo;
  final Ref _ref;
  StreamSubscription<Map<String, dynamic>>? _pushSub;

  WorkspaceListNotifier(this._repo, this._ref) : super(const AsyncValue.loading()) {
    // 3.7.7: 服务端 workspace-list-updated 推送 (payload.result 与 bootstrap 同构),
    // 接入后任务/工作区列表实时更新, 不再依赖手动 refresh
    final client = _ref.read(relayClientProvider);
    _pushSub = client?.onWorkspaceListUpdated.listen(_onPushUpdate);
  }

  /// 解析推送 payload 并更新 state + allTasks
  void _onPushUpdate(Map<String, dynamic> payload) {
    if (payload['result'] is! Map) return;
    try {
      final workspaces = Workspace.parseList(payload);
      final tasks = Workspace.parseTasks(payload);

      // ★ 任务完成通知: displayStatus running → 非 running (任何页面/任何任务,
      // 含桌面端跑的会话)。挂在这个长生命周期推送上, 而非聊天页的 ChatNotifier
      // (它是 autoDispose, 退出聊天页就销毁了, 后台看不到状态翻转)。
      final prevTasks = {for (final p in _ref.read(allTasksProvider)) p.id: p};
      for (final t in tasks) {
        if (t.archived) continue;
        final prev = prevTasks[t.id];
        if (prev == null || prev.archived) continue;
        if (prev.status == TaskStatus.running && t.status != TaskStatus.running) {
          appLog.i('[Workspace] 任务完成: ${t.title} (${t.id})');
          NotificationService.notifyTurnComplete(
            taskId: t.id,
            workspaceKey: t.workspaceKey,
            sessionTitle: t.title,
          );
        }
      }

      _ref.read(allTasksProvider.notifier).state = tasks;
      state = AsyncValue.data(workspaces);
      appLog.d('[Workspace] 推送更新: ${workspaces.length} 工作区 / ${tasks.length} 任务');
    } catch (e) {
      appLog.w('[Workspace] 推送 payload 解析失败: $e');
    }
  }

  Future<void> load() async {
    if (_repo == null) {
      state = AsyncValue.error('No relay client', StackTrace.current);
      return;
    }
    state = const AsyncValue.loading();
    try {
      final resp = await _repo!.bootstrap();
      final workspaces = Workspace.parseList(resp);
      final tasks = Workspace.parseTasks(resp);
      _ref.read(allTasksProvider.notifier).state = tasks;
      state = AsyncValue.data(workspaces);
      appLog.i('[Workspace] bootstrap 完成: ${workspaces.length} 个工作区, ${tasks.length} 个任务');
    } catch (e, st) {
      appLog.e('[Workspace] bootstrap 加载失败', e, st);
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() async {
    if (_repo == null) return;
    try {
      final resp = await _repo!.refresh();
      final workspaces = Workspace.parseList(resp);
      final tasks = Workspace.parseTasks(resp);
      _ref.read(allTasksProvider.notifier).state = tasks;
      state = AsyncValue.data(workspaces);
      appLog.d('[Workspace] 列表刷新完成: ${workspaces.length} 个工作区, ${tasks.length} 个任务');
    } catch (e, st) {
      appLog.e('[Workspace] 列表刷新失败', e, st);
      state = AsyncValue.error(e, st);
    }
  }

  @override
  void dispose() {
    _pushSub?.cancel();
    super.dispose();
  }
}

// ================================================================
// 当前选中的工作区
// ================================================================

final selectedWorkspaceProvider = StateProvider<Workspace?>((ref) => null);

// ================================================================
// 当前工作区的任务列表
// ================================================================

final taskListProvider = FutureProvider.family<List<Task>, String>((ref, workspaceKey) async {
  // 任务从 bootstrap 响应中获取 (result.tasks 含所有工作区任务)
  final workspacesAsync = ref.watch(workspaceListProvider);
  return workspacesAsync.maybeWhen(
    data: (_) {
      // 任务缓存在 allTasksProvider (bootstrap 只取一次, 任务随之确定)
      final allTasks = ref.watch(allTasksProvider);
      return allTasks.where((t) => t.workspaceKey == workspaceKey).toList();
    },
    orElse: () => <Task>[],
  );
});

/// 所有任务 (从 bootstrap 解析, 供 UI 筛选)
final allTasksProvider = StateProvider<List<Task>>((ref) => const <Task>[]);

// ================================================================
// 全局模型目录 (RPC 就绪后加载一次, 所有对话共享)
// ================================================================

class ModelListState {
  final List<String> models; // <providerId>/<slug> 全 ID
  final Map<String, String> providerNames; // providerId → 友好名
  const ModelListState({this.models = const [], this.providerNames = const {}});

  ModelListState copyWith({
    List<String>? models,
    Map<String, String>? providerNames,
  }) =>
      ModelListState(
        models: models ?? this.models,
        providerNames: providerNames ?? this.providerNames,
      );
}

final modelListProvider =
    StateNotifierProvider<ModelListNotifier, AsyncValue<ModelListState>>((ref) {
  final client = ref.watch(relayClientProvider);
  return ModelListNotifier(client);
});

class ModelListNotifier extends StateNotifier<AsyncValue<ModelListState>> {
  final RelayClient? _client;
  StreamSubscription<bool>? _readySub;

  ModelListNotifier(this._client) : super(const AsyncValue.loading()) {
    if (_client == null) {
      state = const AsyncValue.data(ModelListState());
      return;
    }
    // 启动即尝试加载 (等 RPC ready 后拉取), 同时监听重连事件
    _maybeLoad();
    _readySub = _client!.onRpcReadyChange.listen((ready) {
      if (ready) {
        // 只在首次加载或出错时重新拉取, 避免每次开 bridge 都刷新
        final cur = state.valueOrNull;
        if (cur == null || cur.models.isEmpty || state.hasError) {
          _maybeLoad();
        }
      }
    });
  }

  Future<void> _maybeLoad() async {
    if (_client == null) return;
    // 等 RPC ready (最多 10 秒, 覆盖 bridge 连接延迟)
    try {
      await _client!.waitRpcReady(const Duration(seconds: 10));
    } catch (e) {
      appLog.w('[Model] 等待 RPC ready 超时, 保留上次模型列表: $e');
      return;
    }
    if (!mounted) return;
    state = const AsyncValue.loading();
    try {
      final ids = <String>{};
      final names = <String, String>{};

      // getAll 是主数据源 (网页端 useModelProviders 也是先 getAllCached 再 getAll)
      // getDisplayOrder 只返回 {providerIds: [...]} 排序信息, 不含模型
      try {
        final resp = await _client!.getModelProviders();
        _collectFromProviders(resp, ids, names);
      } catch (e) {
        // getAll 失败 → 试 getAllCached
        appLog.w('[Model] getModelProviders 失败, 重试: $e');
        try {
          final resp = await _client!.getModelProviders();
          _collectFromProviders(resp, ids, names);
        } catch (e) {
          appLog.e('[Model] 模型列表两次加载均失败', e);
        }
      }

      // 合并已发现的 ID (保留退役模型)
      final cur = state.valueOrNull;
      if (cur != null) {
        ids.addAll(cur.models);
        names.addAll(cur.providerNames);
      }

      if (ids.isEmpty && cur == null) {
        state = const AsyncValue.data(ModelListState());
        appLog.w('[Model] 未发现任何模型 (响应格式可能变化)');
      } else {
        state = AsyncValue.data(ModelListState(
          models: ids.toList()..sort(),
          providerNames: names,
        ));
        appLog.d('[Model] 模型列表加载完成: ${ids.length} 个模型');
      }
    } catch (e, st) {
      appLog.e('[Model] 模型列表加载失败', e, st);
      state = AsyncValue.error(e, st);
    }
  }

  /// 并入 snapshot/createSession 发现的模型 ID (保留退役模型)
  void mergeDiscoveredIds(Set<String> ids) {
    if (ids.isEmpty) return;
    final cur = state.valueOrNull;
    if (cur == null) return;
    final merged = <String>{...cur.models, ...ids};
    if (merged.length == cur.models.length) return;
    state = AsyncValue.data(cur.copyWith(models: merged.toList()..sort()));
  }

  Future<void> refresh() => _maybeLoad();

  /// 从 model-provider 响应解析模型 ID + provider 名。
  /// 兼容: ① [{id, name, models:[{id}]}]  ② [{id:"p/m"}]  ③ ["p/m"]
  /// 同时过滤掉网页端隐藏的不可用模型 (Fl 函数逻辑):
  ///   - zcode-anthropic / zcode-openai-compatible 自定义模型
  ///   - origin === 'injected'
  ///   - description 以 "custom model" 开头
  void _collectFromProviders(
      Object? node, Set<String> out, Map<String, String> names) {
    Object? root = node is Map && node.containsKey('raw') ? node['raw'] : node;
    if (root is! List) {
      // getDisplayOrder 可能返回 Map (如 {models:[...], providers:[...]})
      // 尝试从常见 key 中提取 List
      if (root is Map) {
        for (final key in ['models', 'providers', 'data', 'result', 'items']) {
          final v = root[key];
          if (v is List) {
            _parseProviderList(v, out, names);
            return;
          }
        }
      }
      return;
    }
    _parseProviderList(root, out, names);
  }

  void _parseProviderList(
      List list, Set<String> out, Map<String, String> names) {

    // 网页端隐藏的 provider 前缀 (Nl/Al 逻辑)
    const hiddenProviders = {'zcode-anthropic', 'zcode-openai-compatible'};

    for (final e in list) {
      if (e is String) {
        if (e.contains('/')) {
          final pid = e.substring(0, e.indexOf('/'));
          if (!hiddenProviders.contains(pid)) out.add(e);
        }
      } else if (e is Map) {
        final id = e['id']?.toString();
        if (id == null) continue;

        // 过滤: hidden provider 前缀
        if (hiddenProviders.contains(id)) continue;

        // 网页端 xHe 逻辑: provider 必须可用才显示
        //   apiKey 非空 → 可用; 否则需要有效 endpoint (内置 provider)
        final apiKey = e['apiKey']?.toString().trim() ?? '';
        final enabled = e['enabled'] == true;
        // 只有 enabled==true 且有 apiKey (或内置 provider) 才显示
        if (!enabled && apiKey.isEmpty) continue;

        final name = e['name']?.toString();
        if (name != null && name.isNotEmpty) names[id] = name;

        final models = e['models'];
        if (models is List) {
          for (final m in models) {
            if (m is Map) {
              final mid = m['id']?.toString();
              if (mid == null || mid.isEmpty) continue;
              // Fl 过滤: origin injected 或 description 以 "custom model" 开头
              final mOrigin = m['origin']?.toString();
              if (mOrigin == 'injected') continue;
              final mDesc = m['description']?.toString().trim().toLowerCase();
              if (mDesc != null && mDesc.startsWith('custom model')) continue;
              out.add('$id/$mid');
            }
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _readySub?.cancel();
    super.dispose();
  }
}

/// 用户全局偏好模型 (null=用工作区默认)。不 autoDispose — 切对话不丢失。
final preferredModelProvider = StateProvider<String?>((ref) => null);

// ================================================================
// GLM Coding Plan 余量
// ================================================================
//
// 独立链路: 不依赖 relay, 直连 bigmodel.cn / z.ai 查询 coding plan 余量。
// 实现来源 cc-switch `coding_plan.rs` 智谱段; 凭据走 SecureStorage。

final glmQuotaServiceProvider = Provider<GlmQuotaService>((ref) {
  return GlmQuotaService();
});

/// GLM 凭据 (持久化在 SecureStorage)。null = 未配置。
final glmCredentialProvider =
    StateNotifierProvider<GlmCredentialNotifier, GlmCredential?>((ref) {
  return GlmCredentialNotifier(ref.watch(secureStorageProvider));
});

class GlmCredentialNotifier extends StateNotifier<GlmCredential?> {
  final SecureStorageService _storage;

  GlmCredentialNotifier(this._storage) : super(null) {
    _restore();
  }

  Future<void> _restore() async {
    state = await _storage.getGlmCredential();
  }

  Future<void> save({required String baseUrl, required String apiKey}) async {
    await _storage.saveGlmCredential(baseUrl: baseUrl, apiKey: apiKey);
    state = await _storage.getGlmCredential();
  }

  Future<void> clear() async {
    await _storage.clearGlmCredential();
    state = null;
  }
}

/// GLM 余量查询状态。无凭据时不自动查询 (state 保持 null, 不显示 loading)。
final glmQuotaProvider =
    StateNotifierProvider<GlmQuotaNotifier, AsyncValue<GlmQuota?>>((ref) {
  final cred = ref.watch(glmCredentialProvider);
  return GlmQuotaNotifier(cred, ref.watch(glmQuotaServiceProvider));
});

class GlmQuotaNotifier extends StateNotifier<AsyncValue<GlmQuota?>> {
  final GlmCredential? _cred;
  final GlmQuotaService _service;

  GlmQuotaNotifier(this._cred, this._service) : super(const AsyncValue.data(null)) {
    // 有凭据时启动即查一次, 给用户卡片立即可用的摘要
    if (_cred != null && _cred.isValid) {
      Future.microtask(load);
    }
  }

  Future<void> load() async {
    final cred = _cred;
    if (cred == null || !cred.isValid) {
      state = const AsyncValue.data(null);
      return;
    }
    state = const AsyncValue.loading();
    try {
      final quota = await _service.fetch(cred);
      state = AsyncValue.data(quota);
      if (quota.success) {
        appLog.d('[GLM] 配额查询成功: ${quota.tiers.length} 个 tier');
      } else {
        appLog.w('[GLM] 配额查询返回失败: ${quota.error}');
      }
    } catch (e, st) {
      appLog.e('[GLM] 配额查询异常', e, st);
      state = AsyncValue.error(e, st);
    }
  }

  /// 别名, 与 WorkspaceListNotifier 一致
  Future<void> refresh() => load();
}

// ================================================================
// Skills (技能管理)
// ================================================================

/// 技能项模型
class SkillItem {
  final String name;
  final String description;
  final bool enabled;
  final String? id;
  final String? scope;

  const SkillItem({
    required this.name,
    required this.description,
    this.enabled = true,
    this.id,
    this.scope,
  });

  factory SkillItem.fromJson(Map<String, dynamic> json) {
    return SkillItem(
      id: json['id'] as String?,
      name: json['name'] as String? ?? json['id'] as String? ?? 'Unknown',
      description: json['description'] as String? ??
          json['desc'] as String? ??
          '',
      enabled: json['enabled'] as bool? ??
          json['active'] as bool? ??
          true,
      scope: json['scope'] as String?,
    );
  }

  SkillItem copyWith({String? name, String? description, bool? enabled}) {
    return SkillItem(
      name: name ?? this.name,
      description: description ?? this.description,
      enabled: enabled ?? this.enabled,
      id: id,
      scope: scope,
    );
  }
}

/// 技能列表 — 从 RPC 加载
///
/// 正确调用: channel='skills', method='list', 参数={workspacePath, provider}
/// 返回: {skills: [...], capability: {...}, diagnostics: [...]}
final skillsProvider =
    StateNotifierProvider<SkillsNotifier, AsyncValue<List<SkillItem>>>((ref) {
  final client = ref.watch(relayClientProvider);
  return SkillsNotifier(client, ref);
});

class SkillsNotifier
    extends StateNotifier<AsyncValue<List<SkillItem>>> {
  final RelayClient? _client;
  final Ref _ref;
  StreamSubscription<bool>? _readySub;
  int _loadAttempts = 0;

  SkillsNotifier(this._client, this._ref)
      : super(const AsyncValue.loading()) {
    if (_client == null) {
      state = const AsyncValue.data([]);
      return;
    }
    _maybeLoad();
    _readySub = _client!.onRpcReadyChange.listen((ready) {
      if (ready) {
        final cur = state.valueOrNull;
        if (cur == null || cur.isEmpty || state.hasError) {
          _maybeLoad();
        }
      }
    });
  }

  Future<void> _maybeLoad() async {
    if (_client == null) return;
    try {
      await _client!.waitRpcReady(const Duration(seconds: 10));
    } catch (e) {
      appLog.w('[Skills] 等待 RPC ready 超时, 放弃本次加载: $e');
      if (mounted) state = const AsyncValue.data([]);
      return;
    }
    if (!mounted) return;

    // 获取工作区路径 — 如果还没加载完, 延迟重试
    final workspaces = _ref.read(workspaceListProvider).valueOrNull;
    if (workspaces == null || workspaces.isEmpty) {
      _loadAttempts++;
      appLog.d('[Skills] 工作区未就绪, 500ms 后重试 ($_loadAttempts/10)');
      if (_loadAttempts < 10 && mounted) {
        state = const AsyncValue.loading();
        Future.delayed(const Duration(milliseconds: 500), _maybeLoad);
      } else if (mounted) {
        appLog.w('[Skills] 等待工作区超时, 返回空列表');
        state = const AsyncValue.data([]);
      }
      return;
    }

    state = const AsyncValue.loading();
    try {
      final ws = workspaces.first;
      final resp = await _client!.getSkills(
        workspacePath: ws.workspacePath,
        workspaceIdentity: ws.workspaceIdentity,
      );
      final parsed = _parseSkillsResponse(resp['skills'] ?? resp);
      if (mounted) state = AsyncValue.data(parsed);
      appLog.d('[Skills] 技能列表加载完成: ${parsed.length} 个');
    } catch (e, st) {
      if (mounted) state = AsyncValue.error(e, st);
      appLog.e('[Skills] 技能列表加载失败', e, st);
    }
  }

  Future<void> refresh() => _maybeLoad();

  @override
  void dispose() {
    _readySub?.cancel();
    super.dispose();
  }
}

/// 从 RPC 响应中解析技能列表 (兼容多种格式)
List<SkillItem> _parseSkillsResponse(dynamic body) {
  List<dynamic> skillsJson;
  if (body is List) {
    skillsJson = body;
  } else if (body is Map) {
    final map = body as Map<String, dynamic>;
    skillsJson = map['skills'] as List<dynamic>? ??
        map['result'] as List<dynamic>? ??
        map['data'] as List<dynamic>? ??
        map['items'] as List<dynamic>? ??
        const [];
  } else {
    return [];
  }

  return skillsJson
      .map((e) {
        if (e is Map<String, dynamic>) return SkillItem.fromJson(e);
        if (e is String) return SkillItem(name: e, description: '');
        return null;
      })
      .whereType<SkillItem>()
      .toList();
}

// ================================================================
// 任务归档
// ================================================================

/// 归档/取消归档任务
///
/// 调用 zcode-task.archive / unarchive RPC, 成功后更新 [allTasksProvider]。
/// [task] 的当前 archived 状态决定调用 archive 还是 unarchive。
Future<void> archiveTask(WidgetRef ref, Task task) async {
  final client = ref.read(relayClientProvider);
  if (client == null) {
    throw StateError('Relay client not available');
  }

  final method = task.archived ? 'unarchive' : 'archive';
  await client.rpcCall('zcode-task', method, [
    {'taskId': task.id, 'workspacePath': task.workspaceKey},
  ]);

  // RPC 成功, 更新本地状态
  final tasks = List<Task>.from(ref.read(allTasksProvider));
  final i = tasks.indexWhere((t) => t.id == task.id);
  if (i != -1) {
    tasks[i] = tasks[i].copyWith(
      archived: !task.archived,
      updatedAt: DateTime.now(),
    );
    ref.read(allTasksProvider.notifier).state = tasks;
  }
}
