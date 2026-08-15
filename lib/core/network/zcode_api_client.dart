import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../logging/app_logger.dart';

/// ZCode HTTP API 客户端
///
/// 处理 REST API 调用:
/// - Bootstrap (工作区列表)
/// - Platform RPC
/// - Mobile View State
class ZcodeApiClient {
  final Dio _dio;

  ZcodeApiClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: AppConfig.relayOrigin,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {
                'Content-Type': 'application/json',
              },
            )) {
    _dio.interceptors.add(LogInterceptor(
      requestBody: false,
      responseBody: false,
      requestHeader: false,
    ));
    // LogInterceptor 关闭了请求/响应体, 失败时只有 URL; 补一条带状态的错误日志
    _dio.interceptors.add(InterceptorsWrapper(
      onError: (e, handler) {
        final req = e.requestOptions;
        appLog.w('[Http] ${req.method} ${req.path} 失败 '
            '(HTTP ${e.response?.statusCode ?? "-"}): ${e.message}');
        handler.next(e);
      },
    ));
  }

  /// Bootstrap — 获取工作区列表
  Future<Map<String, dynamic>> bootstrap(String token) async {
    final response = await _dio.get(
      '${AppConfig.remoteControlApiPrefix}/windows/bootstrap/$token',
    );
    return response.data as Map<String, dynamic>;
  }

  /// Platform RPC
  Future<dynamic> platformRpc(
    String token,
    String method,
    List<dynamic> args,
  ) async {
    final response = await _dio.post(
      '${AppConfig.remoteControlApiPrefix}/platform/$token',
      data: {
        'method': method,
        'args': args,
      },
    );
    final data = response.data as Map<String, dynamic>;
    return data['result'];
  }

  /// 更新移动端视图状态
  Future<void> updateMobileViewState(
    String token,
    Map<String, dynamic> state,
  ) async {
    await _dio.post(
      '${AppConfig.remoteControlApiPrefix}/windows/$token/mobile-view-state',
      data: state,
    );
  }

  /// 打开工作区桥接
  Future<Map<String, dynamic>> openWorkspaceBridge(
    String token,
    String workspaceKey, {
    String? taskId,
  }) async {
    final response = await _dio.post(
      '${AppConfig.remoteControlApiPrefix}/windows/$token/workspace-bridge',
      data: {
        'workspaceKey': workspaceKey,
        if (taskId != null) 'taskId': taskId,
      },
    );
    return response.data as Map<String, dynamic>;
  }
}
