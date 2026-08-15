/// GLM Coding Plan 余量查询结果模型
///
/// 移植自 cc-switch `src-tauri/src/services/coding_plan.rs` 的智谱 GLM 段:
/// - tool 固定为 'coding_plan'
/// - tiers 最多 2 条 (five_hour / weekly_limit)
/// - 解析层不做范围裁剪, utilization 可能负 / 超 100, 原样透传给 UI 层
class GlmQuota {
  final bool success;
  final GlmCredentialStatus credentialStatus;
  final String? credentialMessage; // data.level (套餐等级)
  final List<GlmQuotaTier> tiers;
  final GlmMcpQuota? mcp; // TIME_LIMIT 条目 (MCP 月度用量)
  final String? error;
  final int? queriedAt; // ms

  const GlmQuota({
    required this.success,
    required this.credentialStatus,
    this.credentialMessage,
    this.tiers = const [],
    this.mcp,
    this.error,
    this.queriedAt,
  });

  GlmQuota copyWith({
    bool? success,
    GlmCredentialStatus? credentialStatus,
    String? credentialMessage,
    List<GlmQuotaTier>? tiers,
    GlmMcpQuota? mcp,
    String? error,
    int? queriedAt,
  }) {
    return GlmQuota(
      success: success ?? this.success,
      credentialStatus: credentialStatus ?? this.credentialStatus,
      credentialMessage: credentialMessage ?? this.credentialMessage,
      tiers: tiers ?? this.tiers,
      mcp: mcp ?? this.mcp,
      error: error ?? this.error,
      queriedAt: queriedAt ?? this.queriedAt,
    );
  }

  /// 5 小时窗口 tier (可能为 null: 老套餐或未返回)
  GlmQuotaTier? get fiveHourTier {
    for (final t in tiers) {
      if (t.name == GlmQuotaTier.fiveHour) return t;
    }
    return null;
  }

  /// 每周窗口 tier (可能为 null)
  GlmQuotaTier? get weeklyTier {
    for (final t in tiers) {
      if (t.name == GlmQuotaTier.weeklyLimit) return t;
    }
    return null;
  }

  /// 是否有可渲染的数据 (至少一条 tier 且无错误)
  bool get hasData => success && tiers.isNotEmpty;
}

/// 一条限额 tier
class GlmQuotaTier {
  static const fiveHour = 'five_hour';
  static const weeklyLimit = 'weekly_limit';

  /// 窗口名 (GlmQuotaTier.fiveHour / GlmQuotaTier.weeklyLimit)
  final String name;
  /// 已用百分比 (0-100, 解析层不裁剪)
  final double utilization;
  /// 重置时间 (ISO 8601, 可空: 0% 状态可能无 reset)
  final String? resetsAt;

  const GlmQuotaTier({
    required this.name,
    required this.utilization,
    this.resetsAt,
  });
}

/// MCP 月度用量 (limits[] 中 type=='TIME_LIMIT' 的条目, 2026-08 新增)
///
/// 字段对应: usage=月总额度次数 / currentValue=已用次数 /
/// remaining=剩余 / percentage=已用百分比 / usageDetails=各 MCP 明细。
class GlmMcpQuota {
  /// 月总额度 (次), 如 4000
  final int total;
  /// 已用次数 (currentValue), 如 1020
  final int used;
  /// 已用百分比 (0-100, 解析层不裁剪)
  final double percentage;
  /// 重置时间 (ISO 8601, 可空)
  final String? resetsAt;
  /// 各 MCP 使用明细
  final List<GlmMcpUsageDetail> details;

  const GlmMcpQuota({
    required this.total,
    required this.used,
    required this.percentage,
    this.resetsAt,
    this.details = const [],
  });
}

/// 单个 MCP 的使用次数明细 (TIME_LIMIT.usageDetails[] 条目)
class GlmMcpUsageDetail {
  /// MCP 标识 (search-prime / web-reader / zread ...)
  final String modelCode;
  /// 已用次数
  final int usage;

  const GlmMcpUsageDetail({required this.modelCode, required this.usage});
}

/// MCP modelCode → 展示名 (未匹配的 code 原样展示)
String glmMcpDisplayName(String code) => switch (code) {
      'search-prime' => '联网搜索',
      'web-reader' => '网页读取',
      'zread' => '开源仓库',
      _ => code,
    };

/// 凭据状态 (对齐 cc-switch CredentialStatus)
enum GlmCredentialStatus {
  valid,
  expired,
  notFound,
}
