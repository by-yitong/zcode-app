/// GLM Coding Plan 余量查询服务
///
/// 完整移植自 cc-switch `src-tauri/src/services/coding_plan.rs` 的智谱 GLM 段
/// (query_zhipu + parse_zhipu_token_tiers + zhipu_quota_base, L191-376)。
///
/// 协议要点 (实测, 2026-06):
/// - 端点: {base}/api/monitor/usage/quota/limit
/// - base 路由: open.bigmodel.cn / api.z.ai (二者响应结构相同)
/// - 鉴权: Authorization: {apiKey}  ⚠️ 不加 Bearer 前缀, 裸 key
/// - 响应 data.limits[]: type=='TOKENS_LIMIT' 的条目按 unit 分类
///     unit:3 → five_hour / unit:6 → weekly_limit
///     type=='TIME_LIMIT' 的条目为 MCP 月度用量 (usage/currentValue/usageDetails)
/// - percentage 为字符串/null 时按 0 处理; 超过 2 条 TOKENS_LIMIT 的丢弃
library;

import 'package:dio/dio.dart';

import '../../data/models/glm_quota.dart';
import '../logging/app_logger.dart';

/// GLM coding plan 凭据
class GlmCredential {
  final String baseUrl;
  final String apiKey;

  const GlmCredential({required this.baseUrl, required this.apiKey});

  bool get isValid => apiKey.trim().isNotEmpty;
}

class GlmQuotaService {
  final Dio _dio;

  GlmQuotaService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              headers: {
                'Content-Type': 'application/json',
                'Accept-Language': 'en-US,en',
              },
            ));

  /// 路由 quota endpoint base
  ///
  /// bigmodel.cn (CN) → open.bigmodel.cn
  /// 否则 (含 api.z.ai / 中转 / 未知) → api.z.ai (国际站更通用)
  /// 大小写不敏感 (与 cc-switch detect_provider 对齐)。
  static String zhipuQuotaBase(String baseUrl) {
    if (baseUrl.toLowerCase().contains('bigmodel.cn')) {
      return 'https://open.bigmodel.cn';
    }
    return 'https://api.z.ai';
  }

  /// 查询 GLM coding plan 余量
  Future<GlmQuota> fetch(GlmCredential cred) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (!cred.isValid) {
      return GlmQuota(
        success: false,
        credentialStatus: GlmCredentialStatus.notFound,
        error: 'API key 为空',
        queriedAt: now,
      );
    }

    final base = zhipuQuotaBase(cred.baseUrl);
    final url = '$base/api/monitor/usage/quota/limit';
    appLog.d('[GLM] 查询配额: $url');

    Response<Map<String, dynamic>> resp;
    try {
      resp = await _dio.get<Map<String, dynamic>>(
        url,
        options: Options(
          headers: {
            // ⚠️ 智谱不加 Bearer 前缀, 直接裸 key
            'Authorization': cred.apiKey,
          },
        ),
      );
    } on DioException catch (e) {
      // 401/403 → 凭据失效
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        appLog.w('[GLM] 鉴权失败 (HTTP $code), 凭据可能已失效');
        return GlmQuota(
          success: false,
          credentialStatus: GlmCredentialStatus.expired,
          credentialMessage: 'Invalid API key',
          error: '鉴权失败 (HTTP $code)',
          queriedAt: now,
        );
      }
      appLog.w('[GLM] 网络错误: ${e.message}');
      return GlmQuota(
        success: false,
        credentialStatus: GlmCredentialStatus.valid,
        error: '网络错误: ${e.message}',
        queriedAt: now,
      );
    }

    final status = resp.statusCode ?? 0;
    if (status != 401 && status != 403 && (status < 200 || status >= 300)) {
      appLog.w('[GLM] API 错误 (HTTP $status)');
      return GlmQuota(
        success: false,
        credentialStatus: GlmCredentialStatus.valid,
        error: 'API 错误 (HTTP $status)',
        queriedAt: now,
      );
    }

    final body = resp.data ?? const {};

    // 业务级错误 (success: false)
    if (body['success'] is bool && body['success'] as bool == false) {
      final msg = (body['msg'] as String?) ?? 'Unknown error';
      appLog.w('[GLM] API 业务错误: $msg');
      return GlmQuota(
        success: false,
        credentialStatus: GlmCredentialStatus.valid,
        error: 'API 错误: $msg',
        queriedAt: now,
      );
    }

    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      appLog.w("[GLM] 响应缺少 'data' 字段: ${body.keys.toList()}");
      return GlmQuota(
        success: false,
        credentialStatus: GlmCredentialStatus.valid,
        error: "响应缺少 'data' 字段",
        queriedAt: now,
      );
    }

    final tiers = _parseZhipuTokenTiers(data);
    final mcp = _parseZhipuMcpQuota(data);
    final level = data['level'] as String?;
    appLog.i('[GLM] 配额查询成功: ${tiers.length} 个 tier, '
        'mcp=${mcp != null ? '${mcp.used}/${mcp.total}' : '无'}, level=$level');

    return GlmQuota(
      success: true,
      credentialStatus: GlmCredentialStatus.valid,
      credentialMessage: level,
      tiers: tiers,
      mcp: mcp,
      queriedAt: now,
    );
  }

  /// 解析 data.limits[] 中的 TIME_LIMIT 条目为 MCP 月度用量
  ///
  /// 取第一条 TIME_LIMIT (当前上游只有 1 条: unit:5+number:1 = 1 个月窗口)。
  /// usageDetails 缺失/为空时仍返回总量信息, details 为空列表。
  GlmMcpQuota? _parseZhipuMcpQuota(Map<String, dynamic> data) {
    final limits = data['limits'];
    if (limits is! List) return null;

    for (final raw in limits) {
      if (raw is! Map<String, dynamic>) continue;
      final type = (raw['type'] as String?) ?? '';
      if (type.toLowerCase() != 'time_limit') continue;

      final percentage = _parseF64(raw['percentage']) ?? 0.0;
      final resetMs = (raw['nextResetTime'] is num)
          ? (raw['nextResetTime'] as num).toInt()
          : null;
      final details = <GlmMcpUsageDetail>[];
      final rawDetails = raw['usageDetails'];
      if (rawDetails is List) {
        for (final d in rawDetails) {
          if (d is! Map<String, dynamic>) continue;
          final code = d['modelCode'] as String?;
          if (code == null) continue;
          details.add(GlmMcpUsageDetail(
            modelCode: code,
            usage: (d['usage'] is num) ? (d['usage'] as num).toInt() : 0,
          ));
        }
      }

      return GlmMcpQuota(
        total: (raw['usage'] is num) ? (raw['usage'] as num).toInt() : 0,
        used: (raw['currentValue'] is num)
            ? (raw['currentValue'] as num).toInt()
            : 0,
        percentage: percentage,
        resetsAt: resetMs != null ? _millisToIso8601(resetMs) : null,
        details: details,
      );
    }
    return null;
  }

  /// 解析智谱 data.limits[] 为 tier 列表
  ///
  /// 分类优先级 (移植自 cc-switch, 严格对齐):
  /// 1. 显式 unit: 3→five_hour / 6→weekly_limit (主分类, 不看 reset 时间)
  ///    原因: 周期末尾每周桶可能比 5h 桶更早重置, 按时间排序会标反 (issue #3036)
  /// 2. 兜底 (unit 缺失/未识别): 按 reset 升序依次填入空缺槽位,
  ///    无 reset 的优先归 five_hour
  /// 老套餐 (2026-02-12 前订阅) 只回 1 条, 自然降级为仅 five_hour。
  List<GlmQuotaTier> _parseZhipuTokenTiers(Map<String, dynamic> data) {
    final limits = data['limits'];
    if (limits is! List) return const [];

    // 用可变 nullable 槽位收集, 末尾用 final 局部变量做类型收窄 (避免 promotion 警告)
    ({int? resetMs, double percentage, String? resetsAt})? fiveHourSlot;
    ({int? resetMs, double percentage, String? resetsAt})? weeklySlot;
    final unclassified = <({int? resetMs, double percentage, String? resetsAt})>[];

    for (final raw in limits) {
      if (raw is! Map<String, dynamic>) continue;
      final type = (raw['type'] as String?) ?? '';
      // 大小写不敏感: 上游若把 TOKENS_LIMIT 改成小写/驼峰仍能识别。
      // 注意: 不含分隔符的变体 (如 TokensLimit) 不在兼容范围。
      if (type.toLowerCase() != 'tokens_limit') {
        continue;
      }
      final percentage = _parseF64(raw['percentage']) ?? 0.0;
      final resetMs = (raw['nextResetTime'] is num)
          ? (raw['nextResetTime'] as num).toInt()
          : null;
      final resetsAt = resetMs != null ? _millisToIso8601(resetMs) : null;
      final entry = (
        resetMs: resetMs,
        percentage: percentage,
        resetsAt: resetsAt,
      );

      // unit 主分类
      final unit = raw['unit'];
      final unitInt = unit is int
          ? unit
          : (unit is num ? unit.toInt() : null);
      if (unitInt == 3 && fiveHourSlot == null) {
        fiveHourSlot = entry;
      } else if (unitInt == 6 && weeklySlot == null) {
        weeklySlot = entry;
      } else {
        unclassified.add(entry);
      }
    }

    // 兜底: 按 reset 升序填入空缺槽位 (无 reset 优先归 five_hour)
    unclassified.sort((a, b) {
      // 有 reset 的排后面, 让无 reset 的先填 five_hour
      final aHas = a.resetMs != null;
      final bHas = b.resetMs != null;
      if (aHas != bHas) return aHas ? 1 : -1;
      final av = a.resetMs ?? -1 << 62;
      final bv = b.resetMs ?? -1 << 62;
      return av.compareTo(bv);
    });
    for (final entry in unclassified) {
      if (fiveHourSlot == null) {
        fiveHourSlot = entry;
      } else if (weeklySlot == null) {
        weeklySlot = entry;
      }
      // 智谱当前最多两条, 多余的忽略
    }

    final tiers = <GlmQuotaTier>[];
    // 拷贝到 final 局部变量, 让编译器在此处做确定的非空收窄
    final fiveHour = fiveHourSlot;
    if (fiveHour != null) {
      tiers.add(GlmQuotaTier(
        name: GlmQuotaTier.fiveHour,
        utilization: fiveHour.percentage,
        resetsAt: fiveHour.resetsAt,
      ));
    }
    final weekly = weeklySlot;
    if (weekly != null) {
      tiers.add(GlmQuotaTier(
        name: GlmQuotaTier.weeklyLimit,
        utilization: weekly.percentage,
        resetsAt: weekly.resetsAt,
      ));
    }
    return tiers;
  }

  /// 兼容数字和字符串格式 (100 / "100")
  double? _parseF64(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  String? _millisToIso8601(int ms) {
    try {
      return DateTime.fromMillisecondsSinceEpoch(ms).toUtc().toIso8601String();
    } catch (_) {
      return null;
    }
  }
}
