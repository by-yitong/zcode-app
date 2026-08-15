// GLM 配额解析测试 — 覆盖 TIME_LIMIT (MCP 月度用量) 与 TOKENS_LIMIT (5h 窗口)
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/services/glm_quota_service.dart';
import 'package:zcode_app/data/models/glm_quota.dart';

/// 固定响应体的 Dio adapter (不发真实网络请求)
class _FakeAdapter implements HttpClientAdapter {
  final Map<String, dynamic> body;
  _FakeAdapter(this.body);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = utf8.encode(jsonEncode(body));
    return ResponseBody.fromBytes(bytes, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

void main() {
  test('解析 TIME_LIMIT 为 MCP 月度用量 + TOKENS_LIMIT 为 5h 窗口 + level', () async {
    const body = {
      'code': 200,
      'msg': 'Operation successful',
      'data': {
        'limits': [
          {
            'type': 'TIME_LIMIT',
            'unit': 5,
            'number': 1,
            'usage': 4000,
            'currentValue': 1020,
            'remaining': 2980,
            'percentage': 25,
            'nextResetTime': 1788405210997,
            'usageDetails': [
              {'modelCode': 'search-prime', 'usage': 414},
              {'modelCode': 'web-reader', 'usage': 606},
              {'modelCode': 'zread', 'usage': 0},
            ],
          },
          {
            'type': 'TOKENS_LIMIT',
            'unit': 3,
            'number': 5,
            'percentage': 1,
            'nextResetTime': 1786725341735,
          },
        ],
        'level': 'max',
      },
      'success': true,
    };

    final dio = Dio()..httpClientAdapter = _FakeAdapter(body);
    final quota = await GlmQuotaService(dio: dio).fetch(
      const GlmCredential(baseUrl: 'https://open.bigmodel.cn', apiKey: 'k'),
    );

    expect(quota.success, true);
    expect(quota.credentialMessage, 'max'); // 套餐类型

    // 5 小时窗口
    final fiveHour = quota.fiveHourTier;
    expect(fiveHour, isNotNull);
    expect(fiveHour!.utilization, 1);
    expect(fiveHour.resetsAt, isNotNull);

    // MCP 月度用量
    final mcp = quota.mcp;
    expect(mcp, isNotNull);
    expect(mcp!.total, 4000);
    expect(mcp.used, 1020);
    expect(mcp.percentage, 25);
    expect(mcp.resetsAt, isNotNull);
    expect(mcp.details, hasLength(3));
    expect(mcp.details[0].modelCode, 'search-prime');
    expect(mcp.details[0].usage, 414);
    expect(mcp.details[1].modelCode, 'web-reader');
    expect(mcp.details[1].usage, 606);
    expect(mcp.details[2].modelCode, 'zread');
    expect(mcp.details[2].usage, 0);
  });

  test('无 TIME_LIMIT 条目时 mcp 为 null (老套餐降级)', () async {
    const body = {
      'code': 200,
      'data': {
        'limits': [
          {'type': 'TOKENS_LIMIT', 'unit': 3, 'percentage': 40},
        ],
        'level': 'lite',
      },
      'success': true,
    };

    final dio = Dio()..httpClientAdapter = _FakeAdapter(body);
    final quota = await GlmQuotaService(dio: dio).fetch(
      const GlmCredential(baseUrl: 'https://api.z.ai', apiKey: 'k'),
    );

    expect(quota.success, true);
    expect(quota.mcp, isNull);
    expect(quota.fiveHourTier!.utilization, 40);
    expect(quota.hasData, true);
  });

  test('MCP 展示名映射', () {
    expect(glmMcpDisplayName('search-prime'), '联网搜索');
    expect(glmMcpDisplayName('web-reader'), '网页读取');
    expect(glmMcpDisplayName('zread'), '开源仓库');
    expect(glmMcpDisplayName('future-mcp'), 'future-mcp'); // 未知原样
  });
}
