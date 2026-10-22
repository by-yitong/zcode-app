import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/network/zcode_account_api.dart';
import '../../../../data/models/zcode_session.dart';
import '../../../../shared/theme/app_design_tokens.dart';
import '../../../../shared/theme/app_router.dart';
import '../../../providers/app_providers.dart';

/// 设备选择页 (账号登录后, design §3)
///
/// listDevices 拉取已配对桌面端 → 点选 → 组装 accountJwt 会话 →
/// 与旧登录一致地走 splash (连 relay + 加载工作区)。
class DevicePickerScreen extends ConsumerStatefulWidget {
  const DevicePickerScreen({super.key});

  @override
  ConsumerState<DevicePickerScreen> createState() =>
      _DevicePickerScreenState();

  // ── 纯逻辑 (静态, 供单测; 不触网) ────────────────────────

  /// 设备 → 账号链路会话映射 (design §3)
  ///
  /// mid 缺席为空串 (isValid=false, UI 侧禁点)。
  static ZcodeSession sessionFromDevice(RemoteDevice device) {
    return ZcodeSession(
      mid: device.deviceMid ?? '',
      deviceSid: device.deviceSid,
      deviceName: deviceNameOf(device),
      appVersion: appVersionOf(device),
    );
  }

  /// 会话 deviceName: meta.name 优先, 缺席回退 mobile-browser
  static String deviceNameOf(RemoteDevice device) {
    final name = device.meta?['name'];
    return name is String && name.isNotEmpty ? name : 'mobile-browser';
  }

  /// 对端桌面端版本: meta.version 优先, 缺省 3.16.2 (契约缺省值)
  static String appVersionOf(RemoteDevice device) {
    final v = device.meta?['version'];
    return v is String && v.isNotEmpty ? v : '3.16.2';
  }

  /// mid 尾号 (展示用, 无 mid → '—')
  static String midSuffix(String? mid) {
    if (mid == null || mid.isEmpty) return '—';
    return mid.length <= 6 ? mid : mid.substring(mid.length - 6);
  }
}

enum _PickerPhase { loading, ready, empty, error }

class _DevicePickerScreenState extends ConsumerState<DevicePickerScreen> {
  final ZcodeAccountApi _api = ZcodeAccountApi();

  List<RemoteDevice> _devices = const [];
  _PickerPhase _phase = _PickerPhase.loading;
  String? _error;

  /// 上次连接设备的 sid (进页回填, 列表项标「上次使用」)
  String? _lastDeviceSid;

  /// JWT 过期 (401) → 引导重新登录而非重试
  bool _authExpired = false;

  /// 正在连接的设备 sid (防重复点击)
  String? _connectingSid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _phase = _PickerPhase.loading;
      _error = null;
      _authExpired = false;
    });

    try {
      final account = await ref.read(authRepositoryProvider).restoreAccount();
      if (account == null || account.jwt.isEmpty) {
        // 没有账号凭据 → 回账号登录页
        if (!mounted) return;
        context.go(AppRoutes.accountLogin);
        return;
      }
      // 上次连接设备 (本地读, 与设备列表并行无依赖, 先取再拉列表)
      final storage = ref.read(secureStorageProvider);
      final lastDevice = await storage.getLastDevice();
      final lastSid = lastDevice?['deviceSid'];
      _lastDeviceSid = lastSid is String && lastSid.isNotEmpty ? lastSid : null;

      final devices = await _api.listDevices(jwtOverride: account.jwt);
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _phase = devices.isEmpty ? _PickerPhase.empty : _PickerPhase.ready;
      });
      appLog.i('[DevicePicker] 设备列表加载: ${devices.length} 台');
    } on AccountAuthExpiredException {
      if (!mounted) return;
      setState(() {
        _phase = _PickerPhase.error;
        _authExpired = true;
        _error = '账号登录已过期';
      });
    } catch (e) {
      if (!mounted) return;
      appLog.w('[DevicePicker] 设备列表加载失败: $e');
      setState(() {
        _phase = _PickerPhase.error;
        _error = '设备列表加载失败: $e';
      });
    }
  }

  /// 选中设备 → 组装会话 → 走 splash 连接 (与旧登录 _login() 接线一致)
  Future<void> _onTapDevice(RemoteDevice device) async {
    // ws2 URL 需要 mid, 缺 mid 的设备无法连接
    if ((device.deviceMid ?? '').isEmpty) return;
    if (_connectingSid != null) return;
    setState(() => _connectingSid = device.deviceSid);

    try {
      final session = DevicePickerScreen.sessionFromDevice(device);
      final authRepo = ref.read(authRepositoryProvider);
      await authRepo.saveSession(session);
      // 记住上次设备 (下次进设备选择页标「上次使用」)
      await ref.read(secureStorageProvider).saveLastDevice({
        'deviceSid': device.deviceSid,
        'deviceMid': device.deviceMid ?? '',
        'deviceName': session.deviceName,
        'appVersion': session.appVersion,
      });
      await ref.read(sessionProvider.notifier).loginWithSession(session);
      if (!mounted) return;
      // 走 Splash: 连 relay + 加载工作区 + 直达聊天页
      context.go(AppRoutes.splash);
    } catch (e) {
      appLog.w('[DevicePicker] 会话保存失败: $e');
      if (!mounted) return;
      setState(() => _connectingSid = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('连接失败: $e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择设备'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed:
                _phase == _PickerPhase.loading || _connectingSid != null
                ? null
                : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: switch (_phase) {
          _PickerPhase.loading => const Center(
            child: CircularProgressIndicator(),
          ),
          _PickerPhase.empty => _statusView(
            icon: Icons.desktop_access_disabled_rounded,
            title: '暂无可用设备',
            subtitle: '桌面端未上报设备, 请先在桌面端开启远程控制',
            action: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ),
          _PickerPhase.error => _statusView(
            icon: Icons.key_off_rounded,
            title: _authExpired ? '账号登录已过期' : '加载失败',
            subtitle: _error ?? '未知错误',
            action: _authExpired
                ? FilledButton.icon(
                    onPressed: () => context.go(AppRoutes.accountLogin),
                    icon: const Icon(Icons.login_rounded, size: 18),
                    label: const Text('重新登录'),
                  )
                : FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重试'),
                  ),
          ),
          _PickerPhase.ready => ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: _devices.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, i) => _deviceCard(theme, _devices[i]),
          ),
        },
      ),
    );
  }

  /// 单台设备卡片 (仪表盘卡片风格: 圆角 + 细描边, 复用主题 cardTheme)
  Widget _deviceCard(ThemeData theme, RemoteDevice device) {
    final hasMid = (device.deviceMid ?? '').isNotEmpty;
    final connecting = _connectingSid == device.deviceSid;
    final platform = device.meta?['platform'];
    final platformLabel = platform is String && platform.isNotEmpty
        ? platform
        : '未知平台';

    return Card(
      child: ListTile(
        onTap: hasMid && !connecting ? () => _onTapDevice(device) : null,
        leading: _onlineDot(theme, device.online),
        title: Row(
          children: [
            Flexible(
              child: Text(
                device.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (device.deviceSid == _lastDeviceSid) ...[
              const SizedBox(width: AppSpacing.sm),
              _lastUsedBadge(theme),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: Text(
            '$platformLabel · v${DevicePickerScreen.appVersionOf(device)} · '
            'MID 尾号 ${DevicePickerScreen.midSuffix(device.deviceMid)}',
            style: AppText.mono(
              context,
              size: AppTextSizes.monoXs,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        trailing: connecting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : hasMid
            ? Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              )
            : Tooltip(
                message: '设备缺少 mid, 无法连接',
                child: Icon(
                  Icons.block_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }

  /// 「上次使用」小标签 (primary 电光蓝低透明底 + primary 文字, 非绿/紫/琥珀)
  Widget _lastUsedBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        '上次使用',
        style: TextStyle(
          fontSize: AppTextSizes.caption,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  /// 在线状态点: 主题色 (电光蓝) = 在线; 描边空心 = 离线。
  /// 按任务卡禁用绿色系指示色。
  Widget _onlineDot(ThemeData theme, bool online) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: online ? theme.colorScheme.primary : Colors.transparent,
        border: Border.all(
          color: online
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: 2,
        ),
      ),
    );
  }

  Widget _statusView({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.lg),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.xl),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
