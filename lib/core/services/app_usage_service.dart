/// 应用用量统计服务 — 走 relay `usage-stats.getAppUsageSnapshot`。
///
/// 契约 (2026-11-02 网页端抓包实测, rpcId 295/296):
/// - channel: `usage-stats`, method: `getAppUsageSnapshot`,
///   args 为单对象包一层数组: `{range, timeZone}`
/// - range: 网页端一次拉两条 — `"all"` (汇总 + 热力图) 与 `"7d"/"30d"`
///   (趋势图); 时间范围切换时只重拉趋势那条
/// - timeZone: IANA 名, 如 `"Asia/Shanghai"` (网页端实测值;
///   规则与 DeviceInfoService._timezone 同款: +08:00 → Asia/Shanghai)
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
  /// 拉取一次应用用量统计快照。range: 'all' / '7d' / '30d'。
  Future<AppUsage> fetch(RelayClient client, {required String range}) async {
    try {
      await client.waitRpcReady(const Duration(seconds: 3));
    } catch (e) {
      throw AppUsageException('设备未就绪 ($e)');
    }

    final tz = _timeZone();
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

    appLog.d('[AppUsage] response keys: ${body.keys.toList()}');
    return AppUsage.fromJson(body);
  }

  /// IANA 时区名, 与 DeviceInfoService._timezone 同款规则。
  static String _timeZone() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    if (offset.inMinutes == 480) return 'Asia/Shanghai';
    final name = now.timeZoneName;
    if (name.isNotEmpty) return name;
    return 'UTC${offset.isNegative ? '+' : '-'}${offset.inHours.abs()}';
  }
}
