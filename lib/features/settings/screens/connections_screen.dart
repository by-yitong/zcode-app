/// 远程连接管理 — 已保存连接列表 + 切换 + 扫码/粘贴添加 + 重命名/删除
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/relay/relay_protocol.dart';
import '../../../data/models/saved_connection.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/connections_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/app_router.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../../shared/widgets/app_tile_group.dart';
import '../../auth/screens/scanner_screen.dart';

class ConnectionsScreen extends ConsumerStatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends ConsumerState<ConnectionsScreen> {
  bool _switching = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final session = ref.watch(sessionProvider).valueOrNull;
    final conns = ref.watch(connectionsProvider);
    final connState = ref.watch(relayConnectionStateProvider).valueOrNull;

    final currentSid = session?.deviceSid;

    return Scaffold(
      appBar: AppBar(title: const Text('远程连接')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _switching ? null : _addConnection,
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded, size: 22),
        label: const Text('添加连接'),
      ),
      body: conns.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
        error: (e, _) => AppEmptyState(
          icon: Icons.cloud_off_rounded,
          title: '加载失败',
          subtitle: e.toString(),
          actionLabel: '重试',
          onAction: () => ref.read(connectionsProvider.notifier).load(),
        ),
        data: (list) => ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            // 当前连接
            const AppSectionHeader(title: '当前连接'),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.accentContainer,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Icon(Icons.computer_rounded,
                        size: 22, color: AppColors.accent),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session?.deviceName ?? '未连接',
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          session != null
                              ? 'SID ${session.deviceSid.length > 14 ? '${session.deviceSid.substring(0, 14)}…' : session.deviceSid}'
                              : '扫码或粘贴地址连接桌面端',
                          style: AppText.mono(context,
                              size: AppTextSizes.monoXs,
                              color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  _statePill(connState),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // 已保存列表
            AppSectionHeader(
                title: '已保存 (${list.length})'),
            if (list.isEmpty)
              AppEmptyState(
                icon: Icons.devices_rounded,
                title: '暂无其他连接',
                subtitle: '每个 ZCode 桌面端扫码后会自动保存在这里,\n方便一键切换',
              )
            else
              AppTileGroup(
                tiles: [
                  for (final c in list)
                    GestureDetector(
                      onLongPress: () => _itemActions(c),
                      behavior: HitTestBehavior.translucent,
                      child: AppTile(
                      icon: c.id == currentSid
                          ? Icons.check_circle_rounded
                          : Icons.computer_rounded,
                      iconTint: c.id == currentSid
                          ? AppColors.success
                          : cs.onSurfaceVariant,
                      title: c.label,
                      subtitle:
                          '${c.name} · 上次使用 ${_timeAgo(c.lastUsedAt)}',
                      subtitleMaxLines: 1,
                      value: c.id == currentSid ? '当前' : null,
                      showChevron: c.id != currentSid,
                      onTap: c.id == currentSid || _switching
                          ? null
                          : () => _switch(c),
                      trailing: c.id == currentSid
                          ? CapsPillCurrent(cs)
                          : null,
                      ),
                    ),
                ],
              ),
            if (list.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Text(
                  '长按条目可重命名或删除; 切换需要对应电脑的 ZCode 在线',
                  style: TextStyle(
                      fontSize: AppTextSizes.caption,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  Widget _statePill(RelayConnectionState? connState) {
    final (label, color) = switch (connState) {
      RelayConnectionState.ready => ('已连接', AppColors.success),
      RelayConnectionState.connecting ||
      RelayConnectionState.bootstrapping ||
      RelayConnectionState.reconnecting =>
        ('连接中', AppColors.warning),
      _ => ('离线', AppColors.danger),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm + 2, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: AppTextSizes.caption,
              fontWeight: FontWeight.w600,
              color: color)),
    );
  }

  Future<void> _switch(SavedConnection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('切换到「${c.label}」'),
        content: const Text('将断开当前连接并重新连接该桌面端。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('切换')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _switching = true);
    try {
      await ref.read(connectionsProvider.notifier).switchTo(c);
      if (mounted) context.go(AppRoutes.splash);
    } catch (e) {
      appLog.w('[Connections] 切换失败: $e');
      _snack('切换失败: $e\n请确认对方电脑 ZCode 在线');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _addConnection() async {
    final url = await _pickUrl();
    if (url == null || url.isEmpty) return;
    setState(() => _switching = true);
    try {
      final authRepo = ref.read(authRepositoryProvider);
      final session = await authRepo.loginFromUrl(url);
      await authRepo.saveSession(session);
      await registerLogin(ref, url, session);
      await ref.read(sessionProvider.notifier).loginWithSession(session);
      if (mounted) context.go(AppRoutes.splash);
    } catch (e) {
      appLog.w('[Connections] 添加失败: $e');
      _snack('连接失败: $e');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 扫码 / 粘贴 二选一
  Future<String?> _pickUrl() async {
    final controller = TextEditingController();
    final url = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            AppSpacing.lg, 0, AppSpacing.lg, MediaQuery.of(ctx).viewInsets.bottom + AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text('添加远程连接',
                    style: Theme.of(ctx).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              IconButton(
                icon: const Icon(Icons.qr_code_scanner_rounded),
                tooltip: '扫码',
                onPressed: () async {
                  Navigator.pop(ctx);
                  final result = await Navigator.of(context).push<String>(
                    MaterialPageRoute(builder: (_) => const ScannerScreen()),
                  );
                  if (result != null && result.isNotEmpty && mounted) {
                    _addConnectionWith(result);
                  }
                },
              ),
            ]),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              maxLines: 2,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '连接地址',
                hintText: 'https://zcode.z.ai/remote/v4?sid=...',
                prefixIcon: const Icon(Icons.link),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste_rounded),
                  onPressed: () async {
                    final d = await Clipboard.getData('text/plain');
                    if (d?.text != null) controller.text = d!.text!;
                  },
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
              child: const Text('连接'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return url;
  }

  Future<void> _addConnectionWith(String url) async {
    setState(() => _switching = true);
    try {
      final authRepo = ref.read(authRepositoryProvider);
      final session = await authRepo.loginFromUrl(url);
      await authRepo.saveSession(session);
      await registerLogin(ref, url, session);
      await ref.read(sessionProvider.notifier).loginWithSession(session);
      if (mounted) context.go(AppRoutes.splash);
    } catch (e) {
      appLog.w('[Connections] 添加失败: $e');
      _snack('连接失败: $e');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 长按: 重命名 / 删除
  Future<void> _itemActions(SavedConnection c) async {
    final n = ref.read(connectionsProvider.notifier);
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded, size: 20),
              title: const Text('重命名'),
              onTap: () async {
                Navigator.pop(ctx);
                final controller = TextEditingController(text: c.label);
                final name = await showDialog<String>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    title: const Text('重命名连接'),
                    content: TextField(controller: controller, autofocus: true),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dctx),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () =>
                              Navigator.pop(dctx, controller.text.trim()),
                          child: const Text('确定')),
                    ],
                  ),
                );
                controller.dispose();
                if (name != null && name.isNotEmpty) {
                  await n.rename(c.id, name);
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded,
                  size: 20, color: AppColors.danger),
              title: Text('删除',
                  style: TextStyle(color: AppColors.danger)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    title: Text('删除「${c.label}」'),
                    content: const Text('仅移除保存的连接记录, 不影响桌面端。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dctx, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(dctx, true),
                          child: const Text('删除')),
                    ],
                  ),
                );
                if (ok == true) await n.remove(c.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
    }
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }
}

/// 当前连接小徽章
class CapsPillCurrent extends StatelessWidget {
  final ColorScheme cs;
  const CapsPillCurrent(this.cs, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm + 2, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text('当前',
          style: TextStyle(
              fontSize: AppTextSizes.caption,
              fontWeight: FontWeight.w600,
              color: AppColors.success)),
    );
  }
}
