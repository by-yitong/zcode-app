import 'package:logger/logger.dart';

/// 全局统一日志门面
///
/// 项目内所有日志 (core 层 / provider 层 / UI 层) 都走这一个实例, 取代
/// 之前 debugPrint / print / loggerProvider 三套并存的方式:
/// - debug 模式: 全级别输出 (含 RPC 帧、事件流等高频 debug 日志)
/// - release 模式: 仅 info 及以上 (错误、警告、关键节点)
///
/// 级别约定:
/// - d: 高频/协议细节 (每帧、每次 delta、例行成功) — release 不输出
/// - i: 关键节点 (连接建立、会话创建、登录/登出、启动阶段)
/// - w: 可恢复异常 (降级、回退、超时放弃)
/// - e: 请求失败、状态错误等需要关注的异常 (带堆栈)
///
/// ⚠️ ProductionFilter 使 release 也按级别输出 (Logger 默认的
/// DevelopmentFilter 在 release 下丢弃所有日志, 线上问题会无线索)。
final appLog = AppLogger();

class AppLogger {
  AppLogger()
      : _logger = Logger(
          filter: ProductionFilter(),
          // 协议调试期: release 真机也需要 d 级 (RPC keys / V4 帧 / 解析路径),
          // 否则线上问题无线索。稳定后可改回 kDebugMode ? trace : info。
          level: Level.trace,
          printer: PrettyPrinter(
            methodCount: 0,
            errorMethodCount: 5,
            lineLength: 80,
            colors: true,
            printEmojis: false,
          ),
        );

  final Logger _logger;

  /// 原始 Logger 实例 (供 loggerProvider 等既有 Riverpod 代码使用)
  Logger get logger => _logger;

  void d(String message) => _logger.d(message);
  void i(String message) => _logger.i(message);
  void w(String message) => _logger.w(message);
  void e(String message, [Object? error, StackTrace? stackTrace]) =>
      _logger.e(message, error: error, stackTrace: stackTrace);
}
