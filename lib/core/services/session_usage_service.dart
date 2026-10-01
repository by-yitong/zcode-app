/// 会话 RPC 套餐用量服务 — 走 relay `usage-stats.getEntitlementSnapshot`
///
/// 契约 (实测冻结, 2026-10-01, host 3.14.4, 详见 docs/API协议规格.md §5):
/// - channel: `usage-stats`, method: `getEntitlementSnapshot`, args 为单对象包一层数组
/// - 响应帧 typeCode 201=ok / 202=error
/// - 按 ID 顺序尝试, 第一个返回**无 unavailableReason 字段**的即成功:
///   1. `account:bigmodel-individual-coding-plan` (family: bigmodel)
///   2. `account:zai-individual-coding-plan` (family: zai)
/// - accountAccess 必填, 缺了返回 not_configured (实测)
///
/// 前置: relay bridge 已 open 且 RPC ready。**不主动开桥** — 用
/// `waitRpcReady(3s)` 探测, 超时/不可用即返回 null, 让调用方回退 API key 直调。
library;

import '../logging/app_logger.dart';
import '../relay/relay_client.dart';
import '../../data/models/glm_quota.dart';
import 'glm_quota_service.dart';

class SessionUsageService {
  final RelayClient _client;

  SessionUsageService(this._client);

  /// 查询当前账号的 coding plan 套餐用量
  ///
  /// 返回 null = 会话路径不可用 (RPC 未就绪 / 两个 providerId 都失败 /
  /// unavailableReason / 报错), 调用方应回退 GlmQuotaService 直调。
  Future<GlmQuota?> fetch() async {
    // 探测 RPC 就绪 (不主动开桥); 超时/异常 → 走兜底
    try {
      await _client.waitRpcReady(const Duration(seconds: 3));
    } catch (e) {
      appLog.d('[GLM-RPC] RPC 未就绪 (${e.runtimeType}), 跳过会话路径');
      return null;
    }

    const attempts = <({String providerId, Map<String, String> accountAccess})>[
      (
        providerId: 'account:bigmodel-individual-coding-plan',
        accountAccess: {'type': 'zhipu-account', 'family': 'bigmodel', 'planKind': 'individual-coding-plan'},
      ),
      (
        providerId: 'account:zai-individual-coding-plan',
        accountAccess: {'type': 'zhipu-account', 'family': 'zai', 'planKind': 'individual-coding-plan'},
      ),
    ];

    for (final a in attempts) {
      final body = await _callOnce(a.providerId, a.accountAccess);
      if (body == null) continue;
      final quota = parseSnapshot(body);
      if (quota != null) return quota;
      // 带 unavailableReason 的失败形态 → 尝试下一个 providerId
    }
    return null;
  }

  /// 单次 RPC 调用, 返回 ok 帧的 body; 报错/错误帧返回 null
  Future<Map<String, dynamic>?> _callOnce(
    String providerId,
    Map<String, String> accountAccess,
  ) async {
    try {
      final resp = await _client.rpcCall('usage-stats', 'getEntitlementSnapshot', [
        {'includeSubscription': true, 'preferredProviderId': providerId, 'accountAccess': accountAccess},
      ]);
      if (!resp.isOk) {
        appLog.w('[GLM-RPC] $providerId → 错误帧 type=${resp.typeCode}: ${resp.errorMessage}');
        return null;
      }
      if (resp.body is! Map) {
        appLog.w('[GLM-RPC] $providerId → 响应 body 非 Map: ${resp.body.runtimeType}');
        return null;
      }
      return Map<String, dynamic>.from(resp.body as Map);
    } catch (e) {
      appLog.w('[GLM-RPC] $providerId 调用异常: $e');
      return null;
    }
  }

  /// 解析 snapshot body → GlmQuota
  ///
  /// body 带 `unavailableReason` (not_configured / no_plan / unavailable) 时
  /// 返回 null (数据字段全 null 的失败形态); 成功时字段映射:
  /// - quota.limits[] → parseZhipuTokenTiers / parseZhipuMcpQuota (与直调 API 同构, 直接复用)
  /// - subscription.details[0].productName/expireTime/billingCycle → planName/planExpireAt/planBillingCycle
  /// - quota.level → quotaLevel
  static GlmQuota? parseSnapshot(Map<String, dynamic> body) {
    final reason = body['unavailableReason'];
    if (reason is String && reason.isNotEmpty) {
      appLog.d('[GLM-RPC] snapshot 不可用: $reason');
      return null;
    }

    final quotaObj = body['quota'];
    final data = quotaObj is Map ? Map<String, dynamic>.from(quotaObj) : const <String, dynamic>{};
    final tiers = GlmQuotaService.parseZhipuTokenTiers(data);
    final mcp = GlmQuotaService.parseZhipuMcpQuota(data);
    final level = data['level'] as String?;

    // 套餐信息: 优先 subscription.details[0], 兜底 context.displayName
    String? planName;
    String? planExpireAt;
    String? planBillingCycle;
    final sub = body['subscription'];
    if (sub is Map) {
      final details = sub['details'];
      if (details is List && details.isNotEmpty && details.first is Map) {
        final d = Map<String, dynamic>.from(details.first as Map);
        planName = d['productName'] as String?;
        planExpireAt = d['expireTime'] as String?;
        planBillingCycle = d['billingCycle'] as String?;
      }
    }
    planName ??= _contextDisplayName(body);

    appLog.i(
      '[GLM-RPC] snapshot 解析成功: ${tiers.length} 个 tier, '
      'mcp=${mcp != null ? '${mcp.used}/${mcp.total}' : '无'}, '
      'plan=$planName, level=$level',
    );

    return GlmQuota(
      success: true,
      credentialStatus: GlmCredentialStatus.valid,
      tiers: tiers,
      mcp: mcp,
      planName: planName,
      planExpireAt: planExpireAt,
      planBillingCycle: planBillingCycle,
      quotaLevel: level,
      source: 'session',
    );
  }

  static String? _contextDisplayName(Map<String, dynamic> body) {
    final ctx = body['context'];
    if (ctx is! Map) return null;
    return (ctx['displayName'] as String?);
  }
}
