// 会话 RPC 套餐用量解析测试 — snapshot body (2026-10-01 实测样例, host 3.14.4)
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/services/session_usage_service.dart';
import 'package:zcode_app/data/models/glm_quota.dart';

/// 2026-10-01 真实会话实测的成功响应 body (usage-stats.getEntitlementSnapshot)
const Map<String, dynamic> kSnapshotSample = {
  'generatedAt': 1790854996569,
  'authenticated': true,
  'context': {
    'scope': 'personal',
    'productId': 'product-7fd668',
    'displayName': 'GLM Coding Max',
  },
  'provider': {
    'id': 'account:bigmodel-individual-coding-plan',
    'name': 'BigModel - Coding Plan',
  },
  'remaining': {
    'count': 709,
    'isShow': true,
    'percentage': 82,
    'nextResetTime': 1790997210997,
  },
  'subscription': {
    'identityType': 'unknown',
    'identityMasked': null,
    'details': [
      {
        'productId': 'product-7fd668',
        'productName': 'GLM Coding Max',
        'billingCycle': 'annually',
        'renewTime': null,
        'expireTime': '2026-12-03T00:00:00.000Z',
        'purchaseTime': null,
        'beginTime': null,
      },
    ],
  },
  'quota': {
    'level': 'max',
    'limits': [
      {
        'type': 'TIME_LIMIT',
        'unit': 5,
        'number': 1,
        'usage': 4000,
        'currentValue': 3291,
        'remaining': 709,
        'percentage': 82,
        'nextResetTime': 1790997210997,
        'usageDetails': [
          {'modelCode': 'search-prime', 'usage': 2344},
          {'modelCode': 'web-reader', 'usage': 947},
          {'modelCode': 'zread', 'usage': 0},
        ],
      },
      {
        'type': 'TOKENS_LIMIT',
        'unit': 3,
        'number': 5,
        'percentage': 10,
        'nextResetTime': 1790859608269,
        'usageDetails': [],
      },
    ],
  },
  'mcpQuota': null,
};

void main() {
  test('snapshot JSON → tiers(1条 five_hour 10%) + mcp(3291/4000, 3条明细) + 套餐信息', () {
    final quota = SessionUsageService.parseSnapshot(kSnapshotSample);

    expect(quota, isNotNull);
    final q = quota!;

    // 基本状态
    expect(q.success, true);
    expect(q.credentialStatus, GlmCredentialStatus.valid);
    expect(q.source, 'session');

    // tiers: 仅 TOKENS_LIMIT unit:3 → 1 条 five_hour 10% (TIME_LIMIT 不进 tiers)
    expect(q.tiers, hasLength(1));
    expect(q.fiveHourTier, isNotNull);
    expect(q.fiveHourTier!.name, GlmQuotaTier.fiveHour);
    expect(q.fiveHourTier!.utilization, 10);
    expect(q.fiveHourTier!.resetsAt, isNotNull);
    expect(q.weeklyTier, isNull);

    // MCP 月度用量: usage=4000(总) / currentValue=3291(已用) / 82%
    final mcp = q.mcp;
    expect(mcp, isNotNull);
    expect(mcp!.total, 4000);
    expect(mcp.used, 3291);
    expect(mcp.percentage, 82);
    expect(mcp.resetsAt, isNotNull);
    expect(mcp.details, hasLength(3));
    expect(mcp.details[0].modelCode, 'search-prime');
    expect(mcp.details[0].usage, 2344);
    expect(mcp.details[1].modelCode, 'web-reader');
    expect(mcp.details[1].usage, 947);
    expect(mcp.details[2].modelCode, 'zread');
    expect(mcp.details[2].usage, 0);

    // 套餐信息
    expect(q.planName, 'GLM Coding Max');
    expect(q.planExpireAt, '2026-12-03T00:00:00.000Z');
    expect(q.planBillingCycle, 'annually');
    expect(q.quotaLevel, 'max');
  });

  test('unavailableReason 失败形态 → null (调用方回退直调)', () {
    const unavailable = <String, dynamic>{
      'unavailableReason': 'not_configured',
      'context': null,
      'provider': null,
      'remaining': null,
      'subscription': null,
      'quota': null,
      'mcpQuota': null,
    };
    expect(SessionUsageService.parseSnapshot(unavailable), isNull);
  });

  test('subscription.details 为空时 planName 兜底 context.displayName', () {
    final body = Map<String, dynamic>.from(kSnapshotSample);
    body['subscription'] = <String, dynamic>{'details': <dynamic>[]};
    final quota = SessionUsageService.parseSnapshot(body);
    expect(quota, isNotNull);
    expect(quota!.planName, 'GLM Coding Max');
    expect(quota.planExpireAt, isNull);
  });
}
