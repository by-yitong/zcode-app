/// 应用用量统计服务 — 走 relay `usage-stats.getAppUsageSnapshot`。
///
/// 契约 (方法与参数见 docs/v4-API协议规格.md usage-stats channel;
/// 响应字段仓库里没有记载, 解析见 [AppUsage.fromJson] 的宽容策略):
/// - channel: `usage-stats`, method: `getAppUsageSnapshot`,
///   args 为单对象包一层数组: `{range, timeZone}`
/// - range: 时间范围, 统计页默认用 '30d' 一次拉取, 近 7 日在页内过滤
///   (趋势图只看最近 7 天, 热力图看全量返回序列)
/// - timeZone: 本地 UTC 偏移, 如 '+08:00'
///
/// 前置与套餐 RPC (session_usage_service) 同款: 不主动开桥,
/// 用 `waitRpcReady(3s)` 探测, 超时/不可用即抛错, 由调用方展示重试。
library;

import '../logging/app_logger.dart';
import '../relay/relay_client.dart';
import '../../data/models/app_usage.dart';

/// 拉取失败时抛出的错误 (message 直接展示给用户)。
class AppUsageException implements Exception {
  final String message;
  const AppUsageException(this.message);

  @override
  String toString() => message;
}

class AppUsageService {
  /// 拉取应用用量统计。range 默认 '30d'。
  Future<AppUsage> fetch(RelayClient client, {String range = '30d'}) async {
    try {
      await client.waitRpcReady(const Duration(seconds: 3));
    } catch (e) {
      throw AppUsageException('设备未就绪 ($e)');
    }

    final tz = _localTimeZoneOffset();
    appLog.d('[AppUsage] getAppUsageSnapshot range=$range timeZone=$tz');
    final Map<String, dynamic> body;
    try {
      final resp = await client.rpcCall('usage-stats', 'getAppUsageSnapshot', [
        {'range': range, 'timeZone': tz},
      ]);
      if (!resp.isOk) {
        throw AppUsageException(
          '统计接口返回错误 (type=${resp.typeCode})'
          '${resp.errorMessage != null ? ': ${resp.errorMessage}' : ''}',
        );
      }
      if (resp.body is! Map) {
        throw AppUsageException('统计接口返回格式异常 (${resp.body.runtimeType})');
      }
      body = Map<String, dynamic>.from(resp.body as Map);
    } catch (e) {
      if (e is AppUsageException) rethrow;
      throw AppUsageException('统计接口调用失败 ($e)');
    }

    // 首次跑通前先记下顶层 key, 便于按实际响应收敛解析字段。
    appLog.d('[AppUsage] response keys: ${body.keys.toList()}');
    final usage = AppUsage.fromJson(body);
    if (usage.longestChatText != null) {
      appLog.d('[AppUsage] longestChatText: ${usage.longestChatText}');
    }
    return usage;
  }

  /// 本地 UTC 偏移, 如 '+08:00' / '-05:00'。
  static String _localTimeZoneOffset() {
    final offset = DateTime.now().timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
  }
}
