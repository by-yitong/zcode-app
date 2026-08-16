import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../../agent/screens/cap_pages.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:markdown/markdown.dart' as md;

import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/relay/relay_events.dart';
import '../../../core/relay/relay_protocol.dart';
import '../../../core/services/update_service.dart';
import '../../../data/models/glm_quota.dart' as glm;
import '../../../data/models/workspace.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/app_router.dart';
import '../../../shared/theme/chat_markdown_style.dart';
import '../../../shared/widgets/code_highlight.dart';
import '../../../shared/widgets/glass_bars.dart';
import '../../../shared/widgets/update_dialog.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../search/screens/search_screen.dart';

/// AI 对话页 — 核心交互界面 (实测对接 2026-06-15)
///
/// 数据流: chatProvider(ChatNotifier)
///   - init: 加载历史 (getTaskSnapshot) + 订阅 session 事件
///   - sendMessage: enqueueTaskCommand 入队, AI 回复走 session 事件
///   - session.event: tool.updated = AI 在调工具; 文本流 = 追加到 AI 消息
class ChatScreen extends ConsumerStatefulWidget {
  final String workspaceKey;
  final String? taskId;

  const ChatScreen({super.key, required this.workspaceKey, this.taskId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  // ⚠️ GlobalKey 必须在 state 里持有 (跨帧稳定), 不能在 build 里 new。
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey();
  // 供抽屉搜索按钮回调进入 _ChatScaffoldState (斜杠命令/模型弹窗在那边)
  final GlobalKey<_ChatScaffoldState> _chatScaffoldKey =
      GlobalKey<_ChatScaffoldState>();

  /// 上次按返回键时间 — 「再按一次退出应用」防误触
  DateTime? _lastBackAt;

  /// 本次进程只自动检查一次更新
  bool _updateChecked = false;

  /// 启动自动检查更新 (24h 节流 + 已忽略版本不再弹)
  void _maybeCheckUpdate() {
    if (_updateChecked) return;
    _updateChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!await UpdateService.shouldAutoCheck()) return;
        await UpdateService.markChecked();
        final info = await UpdateService.check();
        if (info == null) return;
        if (await UpdateService.isDismissed(info.tag)) return;
        if (!mounted) return;
        final dismissed = await showUpdateDialog(context, info);
        if (dismissed) await UpdateService.dismiss(info.tag);
      } catch (_) {}
    });
  }

  /// 打开搜索页 (抽屉已自行关闭)
  void _openSearchFromDrawer() {
    _chatScaffoldKey.currentState?.openSearch();
  }

  /// 新建技能: 关闭 Agent 设置页, 回到对话并预填 skill-creator 引导语
  void _startSkillCreation() {
    Navigator.of(context).pop(); // AgentSettingsScreen
    _chatScaffoldKey.currentState?.prefillInput('帮我创建一个新技能');
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(selectedWorkspaceProvider);
    final title = workspace?.name ?? '对话';
    // 会话列表实时同步 (sessions-index 订阅, 根页面常驻)
    ref.watch(sessionsIndexSyncProvider);
    // 启动自动检查更新 (一次)
    _maybeCheckUpdate();

    // taskId 可空: null = 新会话 (首发消息时创建)
    final chatRef = ChatRef(
      taskId: widget.taskId,
      workspacePath: widget.workspaceKey,
      workspaceIdentity: workspace?.workspaceIdentity,
    );
    final chatState = ref.watch(chatProvider(chatRef));

    // 聊天页是根页面: 拦截返回键, 2 秒内按两次才退出 (防误触)
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackAt != null &&
            now.difference(_lastBackAt!) < const Duration(seconds: 2)) {
          SystemNavigator.pop(); // 真正退出 app
          return;
        }
        _lastBackAt = now;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('再按一次退出应用'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      },
      child: Scaffold(
        key: _scaffoldKey,
        // 右滑任意位置可拉开抽屉 (默认仅屏幕左缘 20px)
        drawerEdgeDragWidth: MediaQuery.sizeOf(context).width,
        drawer: _HistoryDrawer(
          workspacePath: widget.workspaceKey,
          currentTaskId: widget.taskId,
          onSelected: (selectedTaskId) {
            // 选了历史会话: 用新 taskId 跳转
            // replace: 原地替换当前 chat 路由, 不叠加新 chat, 保持工作区列表在栈底
            context.replace(
              '${AppRoutes.chat}?workspace=${Uri.encodeComponent(widget.workspaceKey)}'
              '&task=${Uri.encodeComponent(selectedTaskId)}',
            );
          },
          onNewChat: () {
            // 新对话: 跳回不带 task 的聊天页 (replace: 原地替换, 保持返回栈)
            context.replace(
              '${AppRoutes.chat}?workspace=${Uri.encodeComponent(widget.workspaceKey)}',
            );
          },
          onSwitchWorkspace: (ws) {
            // 切换项目: 更新选中工作区 + 跳转新工作区聊天页 (新会话)
            ref.read(selectedWorkspaceProvider.notifier).state = ws;
            context.replace(
              '${AppRoutes.chat}?workspace=${Uri.encodeComponent(ws.workspaceKey)}',
            );
          },
          onOpenSearch: _openSearchFromDrawer,
          onNewSkill: _startSkillCreation,
        ),
        body: _ChatScaffold(
          key: _chatScaffoldKey,
          title: title,
          workspacePath: widget.workspaceKey,
          chatRef: chatRef,
          state: chatState,
          onMenuTap: () => _scaffoldKey.currentState?.openDrawer(),
        ),
      ),
    );
  }
}

class _ChatScaffold extends ConsumerStatefulWidget {
  final String title;
  final String workspacePath;
  final ChatRef chatRef;
  final ChatState state;
  final VoidCallback onMenuTap;

  const _ChatScaffold({
    super.key,
    required this.title,
    required this.workspacePath,
    required this.chatRef,
    required this.state,
    required this.onMenuTap,
  });

  @override
  ConsumerState<_ChatScaffold> createState() => _ChatScaffoldState();
}

class _ChatScaffoldState extends ConsumerState<_ChatScaffold> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();

  /// 用户是否在底部附近 (用于自动跟随 / 显示滚动按钮)
  bool _isAtBottom = true;

  /// 上一帧的滚动 offset, 用于检测用户主动滚动方向
  double _lastOffset = 0;

  /// 上一次构建时的消息数 (检测新消息)
  int _lastMsgCount = 0;

  /// 底部权限弹窗是否已为当前 permission 弹出 (防重复弹)
  String? _lastPermissionRequestId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrollChanged);
    // 记住本次工作区, 下次启动直达 (splash 读取)
    unawaited(
      SharedPreferences.getInstance().then(
        (p) => p.setString('lastWorkspaceKey', widget.workspacePath),
      ),
    );
    // 键盘弹起 (输入框聚焦) 时消息列表会被压缩, 自动滚到底部,
    // 避免最新消息被输入区遮挡 (等键盘动画完成再滚)
    _inputFocusNode.addListener(() {
      if (_inputFocusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 350), _scrollToBottom);
      }
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  /// 滚动监听: 判断用户是否在底部附近 → 控制悬浮按钮显隐
  /// normal ListView: 底部 = maxScrollExtent
  ///
  /// 关键: 用户主动向上滚动 (offset 减小) 时立即标记 _isAtBottom=false,
  /// 不等超过阈值 —— 否则 AI 流式输出时会把视图"拽回"底部, 打断翻阅。
  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final current = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;
    // 用户主动向上翻 (offset 减小) → 立即脱离"贴底"态
    if (current < _lastOffset - 1) {
      if (_isAtBottom) setState(() => _isAtBottom = false);
      // 滚到顶部附近 → 加载更早历史 (reverse 列表顶部即 offset 0)
      if (current < 120 && !widget.state.isLoadingHistory) {
        ref
            .read(chatProvider(widget.chatRef).notifier)
            .loadOlder();
      }
    } else {
      // 向下滚回底部附近 (距底部 < 60) → 恢复"贴底"态, 重新启用自动跟随
      final nearBottom = (maxScroll - current) < 60;
      if (nearBottom != _isAtBottom) {
        setState(() => _isAtBottom = nearBottom);
      }
    }
    _lastOffset = current;
  }

  /// reverse: true 下新消息自动出现在底部 (offset 0)
  /// 只需处理: 历史加载完成时跳到底部, 以及用户在底部时跟随流式更新
  @override
  void didUpdateWidget(covariant _ChatScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newCount = widget.state.messages.length;
    final oldCount = oldWidget.state.messages.length;

    // 历史加载完成 / 消息从空变非空 → 跳到底部
    // 用 post-frame 包裹: didUpdateWidget 阶段 ListView 可能尚未 attach
    // (hasClients == false 会导致 jumpTo 静默失败)。
    if ((oldWidget.state.isLoadingHistory && !widget.state.isLoadingHistory) ||
        (oldCount == 0 && newCount > 0)) {
      _lastMsgCount = newCount;
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
      return;
    }

    _lastMsgCount = newCount;

    // AI 流式输出时跟随到底部:
    // normal list 下新内容追加到末尾, 若不主动跟随, 视图会停在原位。
    // 仅当用户当前贴在底部 (_isAtBottom) 时才跟随, 避免打断用户向上翻阅。
    if (widget.state.isResponding && _isAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    // 任务运行中不禁发 — followupMode=queue, 服务端会排队 (队列条可管理)

    // 不 await, 让 UI 立即响应; 错误由 chatProvider 状态反映
    ref.read(chatProvider(widget.chatRef).notifier).sendMessage(text);
    _messageController.clear();
    _scrollToBottom();
  }

  /// normal ListView → 底部 = maxScrollExtent
  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;

    // ★ 监听 pendingPermissions 变化
    // ExitPlanMode 权限不再弹底部弹窗 — 按钮直接内嵌在 plan 卡片底部
    // 其他权限仍弹底部弹窗
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final perms = state.pendingPermissions;
      if (perms.isNotEmpty) {
        // 跳过 ExitPlanMode/switch_mode — 它们的按钮在 plan 卡片里
        final nonPlanPerm = perms.firstWhere(
          (p) => p.toolName != 'ExitPlanMode' && p.toolName != 'switch_mode',
          orElse: () => perms.first, // 如果全是 plan 权限, 不弹窗
        );
        final shouldSkip =
            nonPlanPerm.toolName == 'ExitPlanMode' ||
            nonPlanPerm.toolName == 'switch_mode';
        if (!shouldSkip) {
          final reqId = nonPlanPerm.id;
          if (_lastPermissionRequestId != reqId) {
            _lastPermissionRequestId = reqId;
            _showPermissionSheet(nonPlanPerm);
          }
        }
      } else {
        _lastPermissionRequestId = null;
      }
    });

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        // mainAxisSize.min: 无配额行时不撑满 56 高 (NavigationToolbar 松约束),
        // 否则 Column 顶对齐会让标题看起来没有垂直居中
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontSize: AppTextSizes.titleSm),
            ),
            // 状态行: 常驻用量统计 (AI 工作中状态在消息流里已有体现)
            _UsagePill(
              tokenUsage: state.tokenUsage,
              glmQuotaAsync: ref.watch(glmQuotaProvider),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.menu), // 汉堡菜单 (打开历史会话抽屉)
          onPressed: widget.onMenuTap,
        ),
        actions: [
          // 新对话 (+): 搜索右侧
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 22),
            tooltip: '新对话',
            onPressed: () {
              // 跳回不带 task 的聊天页 (replace: 原地替换, 保持返回栈)
              context.replace(
                '${AppRoutes.chat}?workspace=${Uri.encodeComponent(widget.workspacePath)}',
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 占位: extendBodyBehindAppBar=true, body 从 y=0 开始,
          // 需手动留出 状态栏+标题栏(56) 高度, 否则 _PlanList 等被遮挡
          SizedBox(height: MediaQuery.of(context).padding.top + 56),
          // 连接状态条 (非 ready 时显示)
          Consumer(
            builder: (context, ref, _) {
              final connAsync = ref.watch(relayConnectionStateProvider);
              final connState = connAsync.valueOrNull;
              if (connState == null ||
                  connState == RelayConnectionState.ready) {
                return const SizedBox.shrink();
              }
              // error 状态仅在 RelayClient 重连重试次数耗尽后出现
              // → 极可能是 Cookie (acw_tc 30min 过期) 失效, 给出重新登录入口。
              if (connState == RelayConnectionState.error) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: Colors.red.withValues(alpha: 0.15),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.cookie_outlined,
                        size: 14,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Cookie 可能已过期',
                          style: TextStyle(
                            fontSize: AppTextSizes.label,
                            color: Colors.red,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => context.go(AppRoutes.login),
                        icon: const Icon(Icons.refresh, size: 14),
                        label: const Text('重新连接'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                );
              }
              final info = switch (connState) {
                RelayConnectionState.reconnecting => (
                  Icons.wifi_off,
                  Colors.orange,
                  '正在重连...',
                ),
                RelayConnectionState.connecting ||
                RelayConnectionState.connected => (
                  Icons.wifi_find,
                  Colors.orange,
                  '连接中...',
                ),
                RelayConnectionState.disconnected => (
                  Icons.cloud_off,
                  Colors.red,
                  '已断开',
                ),
                _ => (Icons.hourglass_empty, Colors.grey, ''),
              };
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                color: info.$2.withValues(alpha: 0.15),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(info.$1, size: 14, color: info.$2),
                    const SizedBox(width: 6),
                    Text(
                      info.$3,
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        color: info.$2,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          if (state.error != null)
            _ErrorBanner(
              message: state.error!,
              theme: theme,
              onRetry: () => ref
                  .read(chatProvider(widget.chatRef).notifier)
                  .reloadHistory(),
            ),
          // plan 提议批准卡 (AI 调 ExitPlanMode, 等用户批准/拒绝)
          if (state.pendingPlan != null)
            _PlanApprovalCard(
              planText: state.pendingPlan!,
              theme: theme,
              onApprove: () {
                ref
                    .read(chatProvider(widget.chatRef).notifier)
                    .answerPlan(true);
              },
              onReject: () {
                ref
                    .read(chatProvider(widget.chatRef).notifier)
                    .answerPlan(false);
              },
            ),
          // 工具执行前确认 → 改为底部弹窗 (不再内联显示)
          // (权限确认通过 _showPermissionSheet 底部弹窗处理)
          // AskUserQuestion 交互式问题卡片 (AI 提问时显示)
          if (state.pendingQuestion != null)
            _QuestionCard(
              question: state.pendingQuestion!,
              onAnswer: (selected) {
                ref
                    .read(chatProvider(widget.chatRef).notifier)
                    .answerQuestion(selected);
              },
            ),
          Expanded(
            child: Stack(
              children: [
                // 底层: 骨架屏 / 空状态 / 消息列表
                state.isLoadingHistory && state.messages.isEmpty
                    ? _buildSkeleton(theme)
                    : state.messages.isEmpty
                    ? _buildWorkspaceHome(theme)
                    : Stack(
                        children: [
                          // 已有缓存内容时的同步指示条 (断连恢复/刷新中)
                          if (state.isLoadingHistory)
                            const Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: LinearProgressIndicator(
                                minHeight: 2,
                                backgroundColor: Colors.transparent,
                              ),
                            ),
                          ListView.builder(
                            controller: _scrollController,
                            // Column 已在顶部留出 状态栏+标题栏 空间, 这里只需小间距
                            padding: const EdgeInsets.fromLTRB(
                              12,
                              AppSpacing.sm,
                              12,
                              AppSpacing.sm,
                            ),
                            itemCount: state.messages.length,
                            itemBuilder: (context, index) {
                              final realIndex = index;
                              final msg = state.messages[realIndex];
                              // 压缩标记: 居中药丸, 不走消息气泡
                              if (msg.role == 'marker') {
                                return _CompactMarkerPill(
                                  label: msg.content,
                                  running: msg.isStreaming,
                                );
                              }
                              // 日期分组: 第一条(视觉最顶)或日期变化时插入分隔线
                              final showDateSeparator =
                                  realIndex == 0 ||
                                  !_isSameDay(
                                    state.messages[realIndex - 1].createdAt,
                                    msg.createdAt,
                                  );
                              // 判断是否为最后一条用户消息 (用于撤销功能)
                              final isLastUserMessage =
                                  msg.role == 'user' &&
                                  !state.messages
                                      .skip(realIndex + 1)
                                      .any((m) => m.role == 'user');
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (showDateSeparator)
                                    _DateSeparator(date: msg.createdAt),
                                  _MessageBubble(
                                    message: msg,
                                    theme: theme,
                                    isLastUserMessage: isLastUserMessage,
                                    isResponding: state.isResponding,
                                    planPermission: state.pendingPermissions
                                        .where(
                                          (p) =>
                                              p.toolName == 'ExitPlanMode' ||
                                              p.toolName == 'switch_mode',
                                        )
                                        .firstOrNull,
                                    onRespondPermission:
                                        (
                                          permissionId,
                                          optionId,
                                          decision,
                                          options,
                                          traceId,
                                        ) {
                                          ref
                                              .read(
                                                chatProvider(
                                                  widget.chatRef,
                                                ).notifier,
                                              )
                                              .answerPermission(
                                                permissionId,
                                                optionId,
                                                decision,
                                                permOptions: options,
                                                permTraceId: traceId,
                                              );
                                        },
                                    onEdit: (text) => ref
                                        .read(
                                          chatProvider(widget.chatRef).notifier,
                                        )
                                        .sendMessage(text),
                                    onRewind: () => ref
                                        .read(
                                          chatProvider(widget.chatRef).notifier,
                                        )
                                        .rewindLastTurn(),
                                  ),
                                ],
                              );
                            },
                          ),
                          // 滚动到底部悬浮按钮: 不在底部时显示
                          if (!_isAtBottom)
                            Positioned(
                              bottom: AppSpacing.sm,
                              right: 12,
                              child: _ScrollToBottomButton(
                                onPressed: _scrollToBottom,
                                hasNewContent: state.isResponding,
                              ),
                            ),
                        ],
                      ),
                // 浮动: Todo 计划面板 (叠加在消息列表上方, 展开/收起不影响列表滚动)
                if (state.plan.isNotEmpty)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _PlanList(
                      plan: state.plan,
                      theme: theme,
                      isResponding: state.isResponding,
                    ),
                  ),
              ],
            ),
          ),
          _buildInputArea(theme),
        ],
      ),
    );
  }

  /// 底部权限确认弹窗 — permission.requested 时自动弹出
  void _showPermissionSheet(PendingPermission perm) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // ExitPlanMode 的 plan 在 perm.input.plan (wire 实测, permission.requested 事件含完整 input)
    // 兜底: 从最近 assistant 消息的 tool activities 取 ExitPlanMode 的 plan
    String? planText;
    if (perm.toolName == 'ExitPlanMode' || perm.toolName == 'switch_mode') {
      // 优先: permission 的 input.plan
      final inputPlan = perm.input['plan'] as String?;
      if (inputPlan != null && inputPlan.trim().isNotEmpty) {
        planText = inputPlan;
      } else {
        // 兜底: 从消息列表的 tool activity 取
        for (final m in widget.state.messages.reversed) {
          if (m.role != 'assistant') continue;
          for (final a in m.activities.reversed) {
            if (_isPlanTool(a)) {
              final p = a.result ?? a.input?['plan'] as String?;
              if (p != null && p.trim().isNotEmpty) {
                planText = p;
                break;
              }
            }
          }
          if (planText != null) break;
        }
        // 最后兜底: 最近 assistant 消息文本
        planText ??= widget.state.messages
            .lastWhere(
              (m) => m.role == 'assistant' && m.content.trim().isNotEmpty,
              orElse: () => widget.state.messages.first,
            )
            .content;
      }
    }

    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md + MediaQuery.of(sheetCtx).viewInsets.bottom,
            ),
            child: _PermissionSheetContent(
              perm: perm,
              planText: planText,
              theme: theme,
              onAnswer: (optionId, decision) {
                Navigator.pop(sheetCtx);
                ref
                    .read(chatProvider(widget.chatRef).notifier)
                    .answerPermission(
                      perm.id,
                      optionId,
                      decision,
                      permOptions: perm.options,
                      permTraceId: perm.traceId,
                    );
              },
            ),
          ),
        );
      },
    );
  }

  /// 消息加载骨架屏
  Widget _buildSkeleton(ThemeData theme) {
    final shimmerColor = theme.colorScheme.surfaceContainerHighest;
    final topInset = AppSpacing.sm;
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.md, topInset, AppSpacing.md, 0),
      child: Column(
        children: List.generate(4, (i) {
          final isLeft = i % 2 == 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Row(
              mainAxisAlignment: isLeft
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isLeft) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: shimmerColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Container(
                    width: MediaQuery.sizeOf(context).width * 0.7,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: shimmerColor,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          height: 14,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          height: 14,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: i.isEven ? 180 : 120,
                          height: 14,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!isLeft) ...[
                  const SizedBox(width: 6),
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: shimmerColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          );
        }),
      ),
    );
  }

  /// 工作区主页 — 新会话空状态 (时段问候语, 对齐网页手机端)
  Widget _buildWorkspaceHome(ThemeData theme) {
    final (greeting, sub) = _greetingForNow();
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            greeting,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 按时段返回问候语 (主句, 副句)
  (String, String?) _greetingForNow() {
    final h = DateTime.now().hour;
    if (h >= 23 || h < 5) {
      return ('有点晚了，早点休息吧', '还有什么事要交代给我吗？');
    }
    if (h < 9) return ('早上好！', '有什么任务要交给我？');
    if (h < 12) return ('上午好！', '有什么任务要交给我？');
    if (h < 14) return ('中午好呀', '有什么任务要交给我？');
    if (h < 18) return ('下午好', '有什么任务要交给我？');
    return ('晚上好呀，今天辛苦啦', '还有什么要交给我的吗？');
  }

  Widget _buildInputArea(ThemeData theme) {
    final notifier = ref.read(chatProvider(widget.chatRef).notifier);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm,
          AppSpacing.xs,
          AppSpacing.sm,
          AppSpacing.xs,
        ),
        // 整个 composer 是一个圆角卡片 (深灰, 柔边)
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
            AppSpacing.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 排队消息 (任务运行中发送 → 服务端排队): 立即/编辑/删除
              if (widget.state.queuedMessages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final q in widget.state.queuedMessages)
                        _QueuedMessageRow(
                          text: q.text,
                          onSendNow: () => ref
                              .read(chatProvider(widget.chatRef).notifier)
                              .sendQueuedNow(q.id),
                          onEdit: () {
                            ref
                                .read(chatProvider(widget.chatRef).notifier)
                                .removeQueuedItem(q.id);
                            _messageController.text = q.text;
                            _inputFocusNode.requestFocus();
                          },
                          onDelete: () => ref
                              .read(chatProvider(widget.chatRef).notifier)
                              .removeQueuedItem(q.id),
                        ),
                    ],
                  ),
                ),
              // 统一提及面板 (@文件 / #会话 / $技能 / /命令)
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _messageController,
                builder: (context, value, _) {
                  final mention = _detectMentionAtCursor(value);
                  if (mention == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(
                      bottom: AppSpacing.xs,
                      left: AppSpacing.sm,
                      right: AppSpacing.sm,
                    ),
                    child: _MentionOverlay(
                      trigger: mention.$1,
                      query: mention.$2,
                      workspacePath: widget.workspacePath,
                      chatRef: widget.chatRef,
                      onSelected: (insertText) =>
                          _replaceMention(mention, insertText),
                    ),
                  );
                },
              ),
              // 输入行: 输入框 | 发送按钮 (+ 与功能按钮在底部工具栏, 对齐网页端)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 输入框 (无边框, 透明, 自适应高度)
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      focusNode: _inputFocusNode,
                      minLines: 1,
                      maxLines: 6,
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
                      decoration: InputDecoration(
                        hintText: '提出后续修改要求',
                        hintStyle: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: AppSpacing.sm,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  // 右侧发送按钮 (圆形, 上箭头, 有内容才亮)
                  // 必须包 ValueListenableBuilder: TextField 打字不会触发父 build,
                  // 否则 hasText 只在 build 时算一次 → 输入文字后按钮永远禁用。
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _messageController,
                    builder: (context, value, _) {
                      final hasText = value.text.trim().isNotEmpty;
                      // 有文字 = 发送 (任务运行中发送会进入服务端队列);
                      // 无文字且任务运行中 = 暂停
                      final showStop = widget.state.isResponding && !hasText;
                      return showStop
                          ? _ComposerSendButton(
                              icon: Icons.stop_rounded,
                              onPressed: () => notifier.stopResponding(),
                              enabled: true,
                              isStop: true,
                            )
                          : _ComposerSendButton(
                              icon: Icons.arrow_upward_rounded,
                              onPressed: hasText ? _sendMessage : null,
                              enabled: hasText,
                            );
                    },
                  ),
                ],
              ),
              // 工具栏 (输入框内底部一行, 对齐网页端):
              // 左: + 功能 | 执行模式        右: 上下文长度 | 思考级别 | 模型
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Row(
                  children: [
                    // + 功能菜单 (附件/提及/指令)
                    _ComposerIconBtn(
                      icon: Icons.add_rounded,
                      tooltip: '附件 / 功能',
                      onTap: _showPlusMenu,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    // 模式选择器 (变更前确认/计划模式/自动编辑) — 图标随模式变化
                    _ModeSelector(
                      mode: widget.state.mode,
                      onChanged: (m) => notifier.setMode(m),
                    ),
                    const Spacer(),
                    // 上下文用量环 (新对话还没有内容时隐藏)
                    if (widget.state.messages.isNotEmpty) ...[
                      _ContextLengthIndicator(usage: widget.state.tokenUsage),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                    // 模型选择器
                    _ModelSelector(
                      models:
                          ref.watch(modelListProvider).valueOrNull?.models ??
                          const <String>[],
                      current:
                          widget.state.model ??
                          ref.watch(preferredModelProvider),
                      providerNames:
                          ref
                              .watch(modelListProvider)
                              .valueOrNull
                              ?.providerNames ??
                          const <String, String>{},
                      isLoading: ref.watch(modelListProvider).isLoading,
                      onSelected: (m) => notifier.setModel(m),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    // 思考级别选择器 — 图标随级别变化
                    _ThoughtLevelSelector(
                      level: widget.state.thoughtLevel,
                      onChanged: (l) => notifier.setThoughtLevel(l),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// /model 命令 + 模型按钮共用: 打开模型选择底部表 (模型列表读全局 modelListProvider)
  /// 打开全屏搜索页 (抽屉搜索按钮入口; 合并 会话搜索 + 斜杠命令)
  /// 预填输入框 (如"新建技能"引导)
  void prefillInput(String text) {
    _messageController.text = text;
    _inputFocusNode.requestFocus();
    _messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: _messageController.text.length));
  }

  void openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          onSlashCommand: _handleSlashCommand,
          onSelectTask: _handleSearchSelectTask,
        ),
      ),
    );
  }

  /// 搜索页斜杠命令 → 当前对话执行
  void _handleSlashCommand(String command) {
    if (!mounted) return;
    final notifier = ref.read(chatProvider(widget.chatRef).notifier);
    switch (command) {
      case '/compact':
        notifier.compact();
      case '/model':
        _openModelPicker();
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$command — 命令暂未实现'),
            duration: const Duration(seconds: 1),
          ),
        );
    }
  }

  /// 搜索页选择会话 → 跳转 (跨工作区时先切换 selectedWorkspace, ChatRef 需要其 identity)
  void _handleSearchSelectTask(Task task) {
    if (!mounted) return;
    final wsList =
        ref.read(workspaceListProvider).valueOrNull ?? const <Workspace>[];
    for (final w in wsList) {
      if (w.workspaceKey == task.workspaceKey) {
        ref.read(selectedWorkspaceProvider.notifier).state = w;
        break;
      }
    }
    context.replace(
      '${AppRoutes.chat}?workspace=${Uri.encodeComponent(task.workspaceKey)}'
      '&task=${Uri.encodeComponent(task.id)}',
    );
  }

  void _openModelPicker() {
    final modelList = ref.read(modelListProvider).valueOrNull;
    final models = modelList?.models ?? const <String>[];
    if (models.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('模型列表未加载 (relay 可能未就绪)'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final notifier = ref.read(chatProvider(widget.chatRef).notifier);
    showModelPicker(
      context,
      models: models,
      current: ref.read(preferredModelProvider),
      providerNames: modelList?.providerNames ?? const {},
      onSelected: (m) => notifier.setModel(m),
    );
  }

  /// 执行 slash 命令 (/compact→session/compact; /model→选模型; 其余客户端提示)
  void _runCommand(_SlashCommand cmd) {
    final notifier = ref.read(chatProvider(widget.chatRef).notifier);
    _messageController.clear();
    switch (cmd.name) {
      case '/compact':
        notifier.compact();
      case '/model':
        _openModelPicker();
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${cmd.name}：${cmd.desc}'),
            duration: const Duration(seconds: 2),
          ),
        );
    }
  }

  /// + 功能菜单 (图片/文件/@提及/#会话/指令)
  void _showPlusMenu() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '插入',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 4,
                  mainAxisSpacing: AppSpacing.md,
                  crossAxisSpacing: AppSpacing.sm,
                  childAspectRatio: 0.82,
                  children: [
                    _PlusMenuItem(
                      icon: Icons.image_outlined,
                      label: '图片',
                      color: AppColors.accent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertImage();
                      },
                    ),
                    _PlusMenuItem(
                      icon: Icons.description_outlined,
                      label: '文件',
                      color: AppColors.success,
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertFileMention();
                      },
                    ),
                    _PlusMenuItem(
                      icon: Icons.alternate_email,
                      label: '@文件',
                      color: const Color(0xFFF59E0B),
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertAtCursor('@');
                      },
                    ),
                    _PlusMenuItem(
                      icon: Icons.tag,
                      label: '#会话',
                      color: const Color(0xFF8B5CF6),
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertAtCursor('#');
                      },
                    ),
                    _PlusMenuItem(
                      icon: Icons.bolt_outlined,
                      label: r'$技能',
                      color: const Color(0xFFFBBF24),
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertAtCursor(r'$');
                      },
                    ),
                    _PlusMenuItem(
                      icon: Icons.terminal,
                      label: '/指令',
                      color: AppColors.danger,
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertAtCursor('/');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                // 提示文字
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '@文件路径 让 AI 读取桌面端文件；#可引用其他对话',
                          style: TextStyle(
                            fontSize: AppTextSizes.caption,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 在光标位置插入文本
  void _insertAtCursor(String text) {
    final sel = _messageController.selection;
    final currentText = _messageController.text;
    if (sel.isValid) {
      final newText =
          currentText.substring(0, sel.start) +
          text +
          currentText.substring(sel.end);
      _messageController.text = newText;
      final newPos = (sel.start ?? currentText.length) + text.length;
      _messageController.selection = TextSelection.collapsed(offset: newPos);
    } else {
      _messageController.text = currentText + text;
      _messageController.selection = TextSelection.collapsed(
        offset: _messageController.text.length,
      );
    }
    _messageController.notifyListeners();
    // 保持输入框聚焦 (触发提及弹窗)
    FocusScope.of(context).requestFocus(_inputFocusNode);
  }

  /// 检测光标位置的提及触发符 (@ # $ /)
  /// 返回 (触发符, 查询文本, 触发符起始位置) 或 null
  (String, String, int)? _detectMentionAtCursor(TextEditingValue value) {
    final text = value.text;
    final cursor = value.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) return null;

    // 从光标往回扫描, 找到触发符
    for (var i = cursor - 1; i >= 0; i--) {
      final ch = text[i];
      if (ch == ' ' || ch == '\n' || ch == '\t') return null;
      if (ch == '@' || ch == '#' || ch == r'$' || ch == '/') {
        // 触发符必须在词首 (前面是空格或行首)
        if (i > 0) {
          final prev = text[i - 1];
          if (prev != ' ' && prev != '\n' && prev != '\t') return null;
        }
        final query = text.substring(i + 1, cursor);
        // /命令只在行首触发
        if (ch == '/' && i != 0) return null;
        return (ch, query, i);
      }
    }
    return null;
  }

  /// 替换提及文本: 把 [trigger+query] 替换为 [insertText]
  void _replaceMention((String, String, int) mention, String insertText) {
    final trigger = mention.$1;
    final startPos = mention.$3;
    final cursor = _messageController.selection.baseOffset;
    final text = _messageController.text;

    final newText =
        text.substring(0, startPos) + insertText + ' ' + text.substring(cursor);
    _messageController.text = newText;
    final newPos = startPos + insertText.length + 1;
    _messageController.selection = TextSelection.collapsed(offset: newPos);
    _messageController.notifyListeners();

    // 如果是 / 命令, 执行对应操作 (内置命令立即执行; 服务端命令留在输入框补参数)
    if (trigger == '/' && insertText.startsWith('/')) {
      final cmd = _slashCommands.where((c) => c.name == insertText).firstOrNull;
      if (cmd != null) {
        _messageController.clear();
        _runCommand(cmd);
      }
    }
  }

  /// 内置 + 服务端命令合并表 (供面板过滤/选中分发)
  List<_SlashCommand> get _mergedSlashCommands {
    final builtinNames =
        _slashCommands.map((c) => c.name.substring(1)).toSet();
    final skills =
        ref.read(skillsProvider).valueOrNull ?? const <SkillItem>[];
    final server = (ref.read(serverSlashCommandsProvider).valueOrNull ??
            const <String>[])
        .where((s) => !builtinNames.contains(s))
        .map((s) {
      final skill = skills.where((sk) => sk.name == s).firstOrNull;
      return _SlashCommand('/$s', skill?.description ?? '服务端命令');
    }).toList();
    return [..._slashCommands, ...server];
  }

  /// 插入图片 — 从手机选图, 压缩后 base64 嵌入消息
  Future<void> _insertImage() async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 75,
    );
    if (xfile == null) return;

    final bytes = await xfile.readAsBytes();
    // 检查大小 (> 2MB 压缩后仍太大 → 警告)
    if (bytes.length > 2 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('图片过大 (>2MB)，请选择更小的图片'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final base64Data = base64Encode(bytes);
    final ext = xfile.name.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    // 嵌入 markdown 图片语法
    final imageMarkdown = '![${xfile.name}](data:$mime;base64,$base64Data)';
    _insertAtCursor('$imageMarkdown\n\n');
  }

  /// 插入文件 — 从手机选文件, 读取文本内容嵌入消息
  Future<void> _insertFileMention() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final path = file.path;

    // 如果有路径且是文本文件, 读取内容
    if (path != null) {
      try {
        final rawBytes = await File(path).readAsBytes();
        // 限制 200KB
        if (rawBytes.length > 200 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('文件过大 (>200KB)，仅支持文本文件'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return;
        }

        // 尝试解码为文本
        final content = utf8.decode(rawBytes, allowMalformed: true);
        final ext = file.extension ?? '';
        final langTag = switch (ext.replaceAll('.', '').toLowerCase()) {
          'py' => 'python',
          'js' => 'javascript',
          'ts' => 'typescript',
          'dart' => 'dart',
          'java' => 'java',
          'kt' => 'kotlin',
          'go' => 'go',
          'rs' => 'rust',
          'c' || 'cpp' || 'h' => 'cpp',
          'sh' || 'bash' => 'bash',
          'yml' || 'yaml' => 'yaml',
          'json' => 'json',
          'xml' => 'xml',
          'html' => 'html',
          'css' => 'css',
          'sql' => 'sql',
          'md' => 'markdown',
          _ => '',
        };
        // 嵌入为代码块
        final fileBlock = '📎 ${file.name}\n```$langTag\n$content\n```\n\n';
        _insertAtCursor(fileBlock);
      } catch (e) {
        // 二进制文件无法读取 → 只插入文件名提示
        _insertAtCursor('📎 ${file.name}\n\n');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('无法读取文件内容: $e')));
        }
      }
    } else {
      // 无路径 (web 平台)
      _insertAtCursor('📎 ${file.name}\n\n');
    }
  }

  /// 插入会话引用 (#)
  void _insertSessionRef() {
    final allTasks = ref.read(allTasksProvider);
    final tasks =
        allTasks
            .where((t) => t.workspaceKey == widget.workspacePath && !t.archived)
            .toList()
          ..sort(
            (a, b) => (b.updatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
              a.updatedAt?.millisecondsSinceEpoch ?? 0,
            ),
          );

    if (tasks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无可引用的会话')));
      return;
    }

    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  '选择会话引用',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: tasks.length,
                  itemBuilder: (ctx, index) {
                    final task = tasks[index];
                    return ListTile(
                      leading: Icon(
                        task.status == TaskStatus.running
                            ? Icons.autorenew
                            : Icons.chat_bubble_outline,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        task.id,
                        style: AppText.mono(
                          context,
                          size: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        // 插入 #任务标题 作为引用文本
                        _insertAtCursor('#${task.title} ');
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        );
      },
    );
  }

  /// @提及选择器 — 直接弹出提及类型列表
  void _showMentionPicker() {
    final theme = Theme.of(context);
    final mentions = [
      ('@file', '📁 文件路径', '引用桌面端文件，让 AI 读取内容'),
      ('@url', '🔗 网页链接', '粘贴网页 URL 让 AI 分析'),
      ('@image', '🖼️ 图片', '引用桌面端图片文件'),
      ('@folder', '📂 文件夹', '引用桌面端项目文件夹'),
    ];

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '@提及',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '选择提及类型，将插入对应标签',
                  style: TextStyle(
                    fontSize: AppTextSizes.label,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                ...mentions.map(
                  (m) => ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    leading: Text(
                      m.$1,
                      style: TextStyle(
                        fontSize: AppTextSizes.bodyMd,
                        fontWeight: FontWeight.w600,
                        fontFamily: kMonoFont,
                        color: const Color(0xFFF59E0B),
                      ),
                    ),
                    title: Text(
                      m.$2,
                      style: const TextStyle(
                        fontSize: AppTextSizes.bodyMd,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      m.$3,
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _insertAtCursor('${m.$1} ');
                      _messageController.selection = TextSelection.collapsed(
                        offset: _messageController.text.length,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// /指令选择器 — 直接弹出完整指令列表
  void _showCommandPicker() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  '指令',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _slashCommands.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.3,
                    ),
                  ),
                  itemBuilder: (ctx, index) {
                    final cmd = _slashCommands[index];
                    return ListTile(
                      leading: Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(
                        cmd.name,
                        style: const TextStyle(
                          fontSize: AppTextSizes.bodyMd,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        cmd.desc,
                        style: TextStyle(
                          fontSize: AppTextSizes.label,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _runCommand(cmd);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        );
      },
    );
  }
}

/// + 菜单项 (图标 + 文字, 网格布局)
class _PlusMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _PlusMenuItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(icon, size: 24, color: color),
          ),
          const SizedBox(height: AppSpacing.xs + 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: AppTextSizes.label,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final ThemeData theme;
  final VoidCallback? onRetry;

  const _ErrorBanner(
      {required this.message, required this.theme, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.errorContainer,
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: theme.colorScheme.onErrorContainer,
                fontSize: AppTextSizes.bodySm,
              ),
            ),
          ),
          if (onRetry != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: GestureDetector(
                onTap: onRetry,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh_rounded,
                        size: 14, color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 4),
                    Text(
                      '重试',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: AppTextSizes.label,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Todo 计划列表 (来自 runtime.plan[])
///
/// AI 用 TodoWrite 工具产出的任务清单, 实时反映执行进度
/// (pending → in_progress → completed)。默认折叠只显示进度摘要,
/// 展开后列出每项 + 状态图标。
class _PlanList extends StatefulWidget {
  final List<PlanItem> plan;
  final ThemeData theme;
  final bool isResponding;

  const _PlanList({
    required this.plan,
    required this.theme,
    required this.isResponding,
  });

  @override
  State<_PlanList> createState() => _PlanListState();
}

class _PlanListState extends State<_PlanList>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  /// 当前进行的任务文字 (inProgress 优先, 否则最近 pending, 否则全部完成)
  String _currentTaskText(List<PlanItem> plan) {
    final inProgress = plan.firstWhere(
      (p) => p.status == TodoStatus.inProgress,
      orElse: () => plan.firstWhere(
        (p) => p.status == TodoStatus.pending,
        orElse: () => plan.last,
      ),
    );
    return inProgress.title;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final plan = widget.plan;
    if (plan.isEmpty) return const SizedBox.shrink();

    final completed = plan
        .where((p) => p.status == TodoStatus.completed)
        .length;
    final total = plan.length;
    final isDark = theme.brightness == Brightness.dark;
    // ★ 浮动面板必须完全不透明, 否会透出底层消息文字
    final cardBg = isDark ? AppColors.darkBg : AppColors.lightSurface;
    // 有进行中的项, 或 AI 正在工作 → 视为"活跃"
    final isActive =
        widget.isResponding ||
        plan.any((p) => p.status == TodoStatus.inProgress);

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        0,
      ),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: isActive
              ? AppColors.accent.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      constraints: const BoxConstraints(maxHeight: 240),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部: 小圆圈进度 + 当前任务 + 折叠箭头 (单行)
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: 5,
              ),
              child: Row(
                children: [
                  // 小圆圈进度条
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            value: total == 0 ? 0 : completed / total,
                            strokeWidth: 4,
                            backgroundColor: theme.colorScheme.outlineVariant
                                .withValues(alpha: 0.4),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isActive ? AppColors.accent : AppColors.success,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$completed/$total',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 收起时: 当前任务文字 (单行省略)
                  Expanded(
                    child: Text(
                      _currentTaskText(plan),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTextSizes.caption,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开后: 任务列表 (可滚动, 防止过长)
          Flexible(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: _expanded
                  ? ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(
                        bottom: AppSpacing.sm,
                        left: AppSpacing.sm,
                        right: AppSpacing.sm,
                      ),
                      itemCount: plan.length,
                      itemBuilder: (ctx, i) =>
                          _PlanRow(item: plan[i], theme: theme),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 计划单行 (状态图标 + 标题)
class _PlanRow extends StatelessWidget {
  final PlanItem item;
  final ThemeData theme;

  const _PlanRow({required this.item, required this.theme});

  @override
  Widget build(BuildContext context) {
    final (icon, color, deco) = switch (item.status) {
      TodoStatus.completed => (
        Icons.check_circle_rounded,
        AppColors.success,
        TextDecoration.lineThrough,
      ),
      TodoStatus.inProgress => (
        Icons.radio_button_checked,
        AppColors.accent,
        TextDecoration.none,
      ),
      TodoStatus.pending => (
        Icons.radio_button_unchecked,
        theme.colorScheme.onSurfaceVariant,
        TextDecoration.none,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              item.title,
              style: TextStyle(
                fontSize: AppTextSizes.label,
                height: 1.35,
                color: item.status == TodoStatus.completed
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
                decoration: deco,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 权限确认弹窗内容 (底部 sheet)
///
/// ★ wire 实测 (host bundle 2026-06-19, 规格 §11.2):
/// permission.requested 事件含 options[], 每个 option 自带 optionId+name+decision。
/// 用户选哪个 option, 就回传那个 optionId + decision。
class _PermissionSheetContent extends StatelessWidget {
  final PendingPermission perm;
  final ThemeData theme;

  /// ExitPlanMode 时 AI 最近 assistant 消息文本 (wire 上 inputOmitted 兜底)
  final String? planText;
  final void Function(String optionId, String decision) onAnswer;

  const _PermissionSheetContent({
    required this.perm,
    required this.theme,
    this.planText,
    required this.onAnswer,
  });

  String _summarize() {
    final input = perm.input;
    final path =
        input['file_path'] ??
        input['filePath'] ??
        input['path'] ??
        input['file'];
    if (path is String && path.isNotEmpty) return path;
    final cmd = input['command'] ?? input['cmd'];
    if (cmd is String && cmd.isNotEmpty) return cmd;
    return '';
  }

  String _toolLabel(String toolName) {
    return switch (toolName) {
      'ExitPlanMode' => '计划确认',
      'EnterPlanMode' => '进入计划模式',
      'Edit' || 'Write' => '编辑文件',
      'Bash' => '执行命令',
      'MultiEdit' => '批量编辑',
      _ => '执行 $toolName',
    };
  }

  Color _riskColor() {
    return switch (perm.riskLevel) {
      'critical' => Colors.red.shade700,
      'high' => Colors.red,
      'medium' => Colors.orange,
      _ => Colors.blue,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = this.theme;
    final detail = _summarize();
    final riskColor = _riskColor();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行: 图标 + 工具名 + 风险标签
        Row(
          children: [
            Icon(Icons.shield_outlined, size: 22, color: riskColor),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '请求${_toolLabel(perm.toolName)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: riskColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (perm.riskLevel == 'high' || perm.riskLevel == 'critical')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: riskColor,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  perm.riskLevel.toUpperCase(),
                  style: const TextStyle(
                    fontSize: AppTextSizes.caption,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
        // 原因
        if (perm.reason.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            perm.reason,
            style: TextStyle(
              fontSize: AppTextSizes.bodySm,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        // ★ ExitPlanMode: 展示 AI 的 plan markdown (从 perm.input.plan 取, wire 实测完整)
        if (planText != null && planText!.trim().isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          // 计划标题
          Row(
            children: [
              Icon(Icons.checklist_rtl, size: 16, color: riskColor),
              const SizedBox(width: 6),
              Text(
                '计划',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: riskColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          // 计划正文 (可滚动, 不截断)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 400),
            padding: const EdgeInsets.all(AppSpacing.sm + 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: riskColor.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: SingleChildScrollView(
              child: MarkdownBody(
                data: planText!,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: AppTextSizes.bodySm,
                    height: 1.6,
                    color: theme.colorScheme.onSurface,
                  ),
                  h1: TextStyle(
                    fontSize: AppTextSizes.titleSm,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                  h2: TextStyle(
                    fontSize: AppTextSizes.bodyMd,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  h3: TextStyle(
                    fontSize: AppTextSizes.bodySm,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  listBullet: TextStyle(
                    fontSize: AppTextSizes.bodySm,
                    color: theme.colorScheme.onSurface,
                  ),
                  code: TextStyle(
                    backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    fontSize: AppTextSizes.label,
                    fontFamily: kMonoFont,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
              ),
            ),
          ),
        ],
        // 工具入参详情 (文件路径/命令, 非 ExitPlanMode 时显示)
        if (detail.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              detail,
              style: TextStyle(
                fontSize: AppTextSizes.label,
                fontFamily: kMonoFont,
                color: theme.colorScheme.onSurface,
              ),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        // ★ options 按钮
        if (perm.options.isNotEmpty)
          ...perm.options.map((opt) {
            // ★ 按钮中文标签 — 按 kind 映射 (网页端 option.name 是英文)
            final cnLabel = switch (opt.kind) {
              'allow_once' => '允许',
              'allow_always' => '始终允许',
              'deny' => '拒绝',
              'escalate' => '上报',
              'modify' => '修改',
              _ => opt.name, // 未知 kind 用原名
            };
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: SizedBox(
                width: double.infinity,
                child: opt.decision == 'deny'
                    ? OutlinedButton.icon(
                        onPressed: () => onAnswer(opt.optionId, opt.decision),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: Text(cnLabel),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                          minimumSize: const Size.fromHeight(44),
                        ),
                      )
                    : FilledButton.icon(
                        onPressed: () => onAnswer(opt.optionId, opt.decision),
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: Text(cnLabel),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.success,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(44),
                        ),
                      ),
              ),
            );
          })
        else
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => onAnswer('', 'allow'),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('允许'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => onAnswer('', 'deny'),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('拒绝'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.xs),
      ],
    );
  }
}

/// AskUserQuestion 交互式问题卡片
///
/// AI 提交计划后后端暂停, 此卡片展示 plan 内容 (兜底用最近 assistant 消息文本,
/// 因 plan 原文 wire 上 inputOmitted) + 批准/拒绝按钮。
class _PlanApprovalCard extends StatelessWidget {
  final String planText;
  final ThemeData theme;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _PlanApprovalCard({
    required this.planText,
    required this.theme,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final theme = this.theme;
    // 截断过长 plan 文本 (展示用, 避免卡片撑太高)
    final display = planText.length > 600
        ? '\${planText.substring(0, 600)}...'
        : planText;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.event_note_rounded, size: 18, color: AppColors.accent),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'AI 提议的计划',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 280),
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: SingleChildScrollView(
              child: MarkdownBody(
                data: display,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: AppTextSizes.bodySm,
                    height: 1.5,
                    color: theme.colorScheme.onSurface,
                  ),
                  h2: TextStyle(
                    fontSize: AppTextSizes.body,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  code: TextStyle(
                    backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    fontSize: AppTextSizes.label,
                    fontFamily: kMonoFont,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('批准并继续'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(40),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('拒绝'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    minimumSize: const Size.fromHeight(40),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// AskUserQuestion 交互式问题卡片
///
/// AI 调 AskUserQuestion 工具时, 此卡片渲染问题 + 选项,
/// 用户点选后通过 onAnswer 回调提交。
class _QuestionCard extends StatefulWidget {
  final AskUserQuestion question;
  final void Function(List<String> selected) onAnswer;

  const _QuestionCard({required this.question, required this.onAnswer});

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  String? _singleSelect;
  final Set<String> _multiSelect = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = widget.question;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.accentContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行
          Row(
            children: [
              Icon(Icons.help_outline, size: 18, color: AppColors.accent),
              const SizedBox(width: AppSpacing.sm),
              Text(
                q.header.isNotEmpty ? q.header : 'AI 有个问题',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          // 问题文本
          Text(
            q.question,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: AppSpacing.md),
          // 选项列表
          ...q.options.map((opt) {
            final isSelected = q.multiSelect
                ? _multiSelect.contains(opt.label)
                : _singleSelect == opt.label;
            return _QuestionOption(
              label: opt.label,
              description: opt.description,
              selected: isSelected,
              onTap: () {
                setState(() {
                  if (q.multiSelect) {
                    if (_multiSelect.contains(opt.label)) {
                      _multiSelect.remove(opt.label);
                    } else {
                      _multiSelect.add(opt.label);
                    }
                  } else {
                    _singleSelect = opt.label;
                  }
                });
              },
            );
          }),
          // 提交按钮
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: _canSubmit()
                ? () {
                    final selected = q.multiSelect
                        ? _multiSelect.toList()
                        : [_singleSelect!];
                    widget.onAnswer(selected);
                  }
                : null,
            icon: const Icon(Icons.check, size: 18),
            label: Text(q.multiSelect ? '提交选择' : '确认'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ],
      ),
    );
  }

  bool _canSubmit() {
    if (widget.question.multiSelect) return _multiSelect.isNotEmpty;
    return _singleSelect != null;
  }
}

/// 问题选项行
class _QuestionOption extends StatelessWidget {
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const _QuestionOption({
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.12)
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  ),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : theme.dividerColor.withValues(alpha: 0.2),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 选择指示器
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    key: ValueKey(selected),
                    size: 18,
                    color: selected
                        ? AppColors.accent
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm + 2),
              // 文本
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected
                            ? AppColors.accent
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: AppTextSizes.label,
                          height: 1.4,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// slash 命令 (/命令面板)
///
/// 协议层命令多为客户端处理; 仅 /compact 接 session/compact RPC。
/// 命令表硬编码 (zcode 桌面端命令集, 见规格 §5.5)。
class _SlashCommand {
  final String name;
  final String desc;
  const _SlashCommand(this.name, this.desc);
}

const _slashCommands = <_SlashCommand>[
  _SlashCommand('/compact', '压缩对话历史'),
  _SlashCommand('/model', '切换模型'),
  _SlashCommand('/agents', '子代理'),
  _SlashCommand('/help', '查看帮助'),
];

class _CommandPalette extends StatelessWidget {
  final String query;
  final ValueChanged<_SlashCommand> onSelected;
  const _CommandPalette({required this.query, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _slashCommands
        .where((c) => c.name.startsWith(query))
        .toList();
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: matches.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        itemBuilder: (context, i) {
          final c = matches[i];
          return ListTile(
            dense: true,
            leading: Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              c.name,
              style: const TextStyle(
                fontSize: AppTextSizes.bodySm,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              c.desc,
              style: TextStyle(
                fontSize: AppTextSizes.caption,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () => onSelected(c),
          );
        },
      ),
    );
  }
}

// ================================================================
// 统一提及弹窗 (@文件 / #会话 / $技能 / /命令)
// ================================================================

class _MentionOverlay extends ConsumerWidget {
  final String trigger; // @ # $ /
  final String query;
  final String workspacePath;
  final ChatRef chatRef;
  final ValueChanged<String> onSelected; // 传入要插入的完整文本

  const _MentionOverlay({
    required this.trigger,
    required this.query,
    required this.workspacePath,
    required this.chatRef,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final items = _buildItems(ref);
    if (items.isEmpty) return const SizedBox.shrink();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分类标签
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Text(
              _triggerLabel(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: items.length,
              itemBuilder: (context, i) {
                final item = items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  onTap: () => onSelected(item.insertText),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        Icon(item.icon, size: 16, color: item.color),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppTextSizes.bodySm,
                                  fontWeight: FontWeight.w500,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              if (item.subtitle.isNotEmpty)
                                Text(
                                  item.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppTextSizes.caption,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _triggerLabel() {
    switch (trigger) {
      case '@':
        return 'FILES';
      case '#':
        return 'SESSIONS';
      case r'$':
        return 'SKILLS';
      case '/':
        return 'COMMANDS';
      default:
        return '';
    }
  }

  List<_MentionItem> _buildItems(WidgetRef ref) {
    final q = query.toLowerCase();
    switch (trigger) {
      case '/':
        return _buildCommands(ref, q);
      case '@':
        return _buildFiles(ref, q);
      case '#':
        return _buildSessions(ref, q);
      case r'$':
        return _buildSkills(ref, q);
      default:
        return [];
    }
  }

  // /命令 (内置 + 服务端 slashCommands, 描述尽量从技能列表带出)
  List<_MentionItem> _buildCommands(WidgetRef ref, String q) {
    final builtinNames =
        _slashCommands.map((c) => c.name.substring(1)).toSet();
    final skills = ref.watch(skillsProvider).valueOrNull ?? const <SkillItem>[];
    final server = (ref.watch(serverSlashCommandsProvider).valueOrNull ??
            const <String>[])
        .where((s) => !builtinNames.contains(s))
        .map((s) {
      final skill = skills.where((sk) => sk.name == s).firstOrNull;
      return _SlashCommand('/$s', skill?.description ?? '服务端命令');
    }).toList();
    final all = [..._slashCommands, ...server];
    final matches = all
        .where((c) => c.name.toLowerCase().contains(q.isEmpty ? '/' : q))
        .toList();
    return matches
        .map(
          (c) => _MentionItem(
            icon: Icons.chevron_right,
            color: const Color(0xFF60A5FA),
            label: c.name,
            subtitle: c.desc,
            insertText: c.name,
          ),
        )
        .toList();
  }

  // @文件 — 通过 RPC file.listWorkspaceFiles 获取工作区文件列表
  List<_MentionItem> _buildFiles(WidgetRef ref, String q) {
    final client = ref.read(relayClientProvider);
    if (client == null) return [];
    // 同步调用: 从缓存的文件列表过滤
    // 如果没有缓存, 触发异步加载 (下次输入时就有)
    final cached = _workspaceFileCache[workspacePath];
    if (cached == null) {
      // 触发异步加载
      _loadWorkspaceFiles(client);
      return [];
    }

    var files = cached;
    if (q.isNotEmpty) {
      files = files.where((f) => f.toLowerCase().contains(q)).toList();
    }

    if (files.isEmpty && q.isNotEmpty) {
      return [
        _MentionItem(
          icon: Icons.file_present,
          color: const Color(0xFF34D399),
          label: q,
          subtitle: '直接引用此路径',
          insertText: '@$q',
        ),
      ];
    }

    return files.take(20).map((f) {
      final parts = f.split('/');
      final name = parts.last;
      final dir = parts.length > 1
          ? parts.sublist(0, parts.length - 1).join('/')
          : '';
      return _MentionItem(
        icon: Icons.description_outlined,
        color: const Color(0xFF34D399),
        label: name,
        subtitle: dir,
        insertText: '@$f',
      );
    }).toList();
  }

  /// 工作区文件缓存 (per workspacePath)
  static final Map<String, List<String>> _workspaceFileCache = {};
  static final Set<String> _loadingWorkspaces = {};

  void _loadWorkspaceFiles(client) async {
    if (_loadingWorkspaces.contains(workspacePath)) return;
    _loadingWorkspaces.add(workspacePath);
    try {
      final result = await client.listWorkspaceFiles(rootPath: workspacePath);
      final paths = result
          .map(
            (f) =>
                f['relativePath'] as String? ??
                f['path'] as String? ??
                f['name'] as String? ??
                '',
          )
          .where((p) => p.isNotEmpty)
          .toList();
      _workspaceFileCache[workspacePath] = paths;
    } catch (e) {
      // 加载失败, 下次重试
      appLog.w('[Chat] 工作区文件列表加载失败 ($workspacePath): $e');
    } finally {
      _loadingWorkspaces.remove(workspacePath);
    }
  }

  // #会话 — 从 allTasksProvider 获取
  List<_MentionItem> _buildSessions(WidgetRef ref, String q) {
    final allTasks = ref.read(allTasksProvider);
    var tasks =
        allTasks
            .where((t) => t.workspaceKey == workspacePath && !t.archived)
            .toList()
          ..sort(
            (a, b) => (b.updatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
              a.updatedAt?.millisecondsSinceEpoch ?? 0,
            ),
          );

    if (q.isNotEmpty) {
      tasks = tasks.where((t) => t.title.toLowerCase().contains(q)).toList();
    }

    return tasks.take(10).map((t) {
      return _MentionItem(
        icon: t.status == TaskStatus.running
            ? Icons.autorenew
            : Icons.chat_bubble_outline,
        color: const Color(0xFFA78BFA),
        label: t.title,
        subtitle: t.id,
        insertText: '#${t.title}',
      );
    }).toList();
  }

  // $技能 — 从 skillsProvider 获取
  List<_MentionItem> _buildSkills(WidgetRef ref, String q) {
    final skillsAsync = ref.watch(skillsProvider);
    final skills = skillsAsync.valueOrNull ?? [];
    if (skills.isEmpty) return [];

    var filtered = skills.where((s) => s.enabled).toList();
    if (q.isNotEmpty) {
      filtered = filtered
          .where(
            (s) =>
                s.name.toLowerCase().contains(q) ||
                s.description.toLowerCase().contains(q),
          )
          .toList();
    }

    return filtered.take(10).map((s) {
      return _MentionItem(
        icon: Icons.bolt_outlined,
        color: const Color(0xFFFBBF24),
        label: s.name,
        subtitle: s.description.isNotEmpty
            ? (s.description.length > 50
                  ? '${s.description.substring(0, 50)}...'
                  : s.description)
            : (s.scope ?? ''),
        insertText: r'$' + s.name,
      );
    }).toList();
  }
}

class _MentionItem {
  final IconData icon;
  final Color color;
  final String label;
  final String subtitle;
  final String insertText;
  const _MentionItem({
    required this.icon,
    required this.color,
    required this.label,
    required this.subtitle,
    required this.insertText,
  });
}

/// 用量统计小药丸 (标题栏副行)
///
/// 同时显示:
/// - Token 用量: ↑1.2k ↓3.4k (本会话累计, 来自 session/usage)
/// - GLM 余量: 本周 45% (Coding Plan, 来自 glmQuotaProvider)
/// 无数据时显示工作区路径的省略形式。
class _UsagePill extends StatelessWidget {
  final ({int input, int output, int max})? tokenUsage;
  final AsyncValue<glm.GlmQuota?> glmQuotaAsync;

  const _UsagePill({this.tokenUsage, required this.glmQuotaAsync});

  static String _fmt(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final k = n / 1000;
      return k >= 100 ? '${k.toStringAsFixed(0)}k' : '${k.toStringAsFixed(1)}k';
    }
    final m = n / 1000000;
    return m >= 100 ? '${m.toStringAsFixed(0)}M' : '${m.toStringAsFixed(1)}M';
  }

  static String _fmtPct(double v) {
    if (v <= 0) return '0%';
    if (v >= 100) return '100%';
    return v >= 10 ? '${v.toStringAsFixed(0)}%' : '${v.toStringAsFixed(1)}%';
  }

  Color _pctColor(double pct, BuildContext context) {
    if (pct >= 90) return const Color(0xFFEF4444);
    if (pct >= 70) return const Color(0xFFF59E0B);
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quota = glmQuotaAsync.valueOrNull;
    // 未配置 GLM API Key (无配额数据) 时整个隐藏, 让标题垂直居中
    if (quota == null || !quota.hasData) return const SizedBox.shrink();
    final parts = <_UsagePart>[];

    // Token 用量
    if (tokenUsage != null) {
      parts.add(
        _UsagePart(
          icon: Icons.bolt_outlined,
          text: '↑${_fmt(tokenUsage!.input)} ↓${_fmt(tokenUsage!.output)}',
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    // GLM 余量 (优先显示 weekly, 其次 five_hour)
    if (quota != null && quota.hasData) {
      final tier = quota.weeklyTier ?? quota.fiveHourTier;
      if (tier != null) {
        parts.add(
          _UsagePart(
            icon: Icons.local_fire_department_outlined,
            text: _fmtPct(tier.utilization),
            color: _pctColor(tier.utilization, context),
          ),
        );
      }
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 2,
      children: parts
          .map(
            (p) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(p.icon, size: 11, color: p.color),
                const SizedBox(width: 3),
                Text(
                  p.text,
                  style: TextStyle(
                    fontSize: AppTextSizes.caption,
                    fontFamily: kMonoFont,
                    color: p.color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          )
          .toList(),
    );
  }
}

class _UsagePart {
  final IconData icon;
  final String text;
  final Color color;
  const _UsagePart({
    required this.icon,
    required this.text,
    required this.color,
  });
}

/// Token 用量 badge (输入栏内显示)
///
/// AI 每轮回复完成后由 ChatNotifier 刷新 state.tokenUsage (累计 input/output)。
/// composer 圆形发送按钮 (上箭头/停止)
class _ComposerSendButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool enabled;
  final bool isStop;

  const _ComposerSendButton({
    required this.icon,
    required this.onPressed,
    required this.enabled,
    this.isStop = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isStop
        ? AppColors.danger
        : (enabled ? theme.colorScheme.primary : theme.colorScheme.outline);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: (isStop || enabled)
                ? color
                : theme.colorScheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

/// 工具栏 chip (icon + label, 可点击下拉)
class _ToolbarChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ToolbarChip({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: AppTextSizes.label,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 滚动到底部悬浮按钮: 当用户不在底部时出现。
/// AI 正在回复时显示蓝色高亮 + 小红点提示有新内容。
class _ScrollToBottomButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool hasNewContent;

  const _ScrollToBottomButton({
    required this.onPressed,
    this.hasNewContent = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: hasNewContent
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hasNewContent
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: hasNewContent ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 24,
              color: hasNewContent
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            if (hasNewContent)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.surfaceContainerHigh,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Token 用量徽章 (compact, 等宽, 状态行副标题用)。
/// 格式: ↑1.2k ↓3.4k — ↑=输入(prompt), ↓=输出(completion)。
/// 数字: <1000 原值; >=1000 用 1.2k (>=100k 去小数, >=1M 用 M)。
class _TokenUsageBadge extends StatelessWidget {
  final ({int input, int output})? usage;

  const _TokenUsageBadge({this.usage});

  /// 紧凑数字格式化: 999 → 999, 1234 → 1.2k, 12345 → 12.3k, 123456 → 123k, 1234567 → 1.2M
  static String _fmt(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final k = n / 1000;
      return k >= 100 ? '${k.toStringAsFixed(0)}k' : '${k.toStringAsFixed(1)}k';
    }
    final m = n / 1000000;
    return m >= 100 ? '${m.toStringAsFixed(0)}M' : '${m.toStringAsFixed(1)}M';
  }

  @override
  Widget build(BuildContext context) {
    final u = usage;
    if (u == null) return const SizedBox.shrink();
    return Text(
      '↑${_fmt(u.input)} ↓${_fmt(u.output)}',
      style: TextStyle(
        fontSize: AppTextSizes.caption,
        fontFamily: kMonoFont,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 工具栏小图标按钮 (36×36 触达, 18px 图标)
class _ComposerIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  const _ComposerIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      style: IconButton.styleFrom(
        foregroundColor:
            color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.all(6),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 上下文长度指示 (图标 + 已用 token); 点击弹底部详情
class _ContextLengthIndicator extends StatelessWidget {
  final ({int input, int output, int max})? usage;

  const _ContextLengthIndicator({this.usage});

  static String _fmt(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final k = n / 1000;
      return k >= 100 ? '${k.toStringAsFixed(0)}k' : '${k.toStringAsFixed(1)}k';
    }
    final m = n / 1000000;
    return m >= 100 ? '${m.toStringAsFixed(0)}M' : '${m.toStringAsFixed(1)}M';
  }

  /// 底部详情弹窗: 进度条 + 已用/容量 + 输出累计
  void _openDetails(BuildContext context) {
    final theme = Theme.of(context);
    final u = usage;
    if (u == null) return;
    final ratio = u.max > 0 ? (u.input / u.max).clamp(0.0, 1.0) : 0.0;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('上下文用量', style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 8,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  color: ratio > 0.9
                      ? AppColors.danger
                      : ratio > 0.7
                      ? AppColors.warning
                      : theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '已用 ${_fmt(u.input)}',
                    style: TextStyle(
                      fontSize: AppTextSizes.bodySm,
                      fontFamily: kMonoFont,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    u.max > 0 ? '容量 ${_fmt(u.max)}' : '容量未知',
                    style: TextStyle(
                      fontSize: AppTextSizes.bodySm,
                      fontFamily: kMonoFont,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '累计输出 ↓${_fmt(u.output)} · 接近容量时将自动压缩历史',
                style: TextStyle(
                  fontSize: AppTextSizes.label,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final u = usage;
    final has = u != null && u.input > 0;
    final ratio = has && u.max > 0 ? (u.input / u.max).clamp(0.0, 1.0) : 0.0;
    final trackColor = theme.colorScheme.surfaceContainerHighest;
    final barColor = ratio > 0.9
        ? AppColors.danger
        : ratio > 0.7
        ? AppColors.warning
        : theme.colorScheme.primary;
    return InkWell(
      onTap: has ? () => _openDetails(context) : null,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 圆形用量进度环 (无数据时只显示空轨道)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                value: has ? ratio : 0.0,
                strokeWidth: 2.5,
                strokeCap: StrokeCap.round,
                strokeAlign: BorderSide.strokeAlignInside,
                backgroundColor: trackColor,
                color: has ? barColor : trackColor,
              ),
            ),
            if (has) ...[
              const SizedBox(width: 5),
              Text(
                _fmt(u.input),
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  fontFamily: kMonoFont,
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 代理模式选择 (新/已有会话都显示)
///
/// 协议实测只有两种模式 (规格 §5.5 `mode:{current:"yolo"|"build"}`):
/// - build = 确认模式, 工具执行前需用户确认
/// - yolo  = 自动模式, AI 全自动无需确认
/// 新会话设 createSession.mode; 已有会话走 session/setMode 热切换。
/// 代理模式选择器 (popover 下拉, 4 选项)
///
/// 协议只有 build/yolo 两种, UI 映射 4 档自主度:
///   变更前确认 → build (改文件前先问)
///   自动编辑   → yolo (自动编辑文件)
///   计划模式   → build (先出计划, 映射到 build 谨慎态)
///   完全访问   → yolo (最少确认, 映射到 yolo)
/// 模式选择结果 (带计划子态标记)
class _ModeSelector extends StatelessWidget {
  final String mode; // 'build' | 'edit' | 'plan' | 'yolo' (wire 值, 与后端一致)
  final ValueChanged<String> onChanged;

  const _ModeSelector({required this.mode, required this.onChanged});

  // UI 模式定义: (apiMode, icon, title, desc)
  // wire mode 实测四种 (网页端 configOptions 抓取):
  //   build — 变更前确认, 改文件前先问
  //   edit  — 自动编辑, 自动编辑文件
  //   plan  — 计划模式, 先出计划再执行
  //   yolo  — 完全访问, 减少确认次数
  static const _options = <(String, IconData, String, String)>[
    ('build', Icons.back_hand_outlined, '变更前确认', '改文件前先问我'),
    ('edit', Icons.edit_note_outlined, '自动编辑', '自动编辑文件'),
    ('plan', Icons.event_note_outlined, '计划模式', '编辑前先出计划'),
    ('yolo', Icons.shield_outlined, '完全访问', '减少确认次数'),
  ];

  /// 当前选中的 UI 项索引
  int get _selectedIndex {
    for (int i = 0; i < _options.length; i++) {
      if (_options[i].$1 == mode) return i;
    }
    return 0;
  }

  (String, IconData, String, String) get _current => _options[_selectedIndex];

  void _open(BuildContext context) {
    // 用 MenuAnchor 实现锚定 popover
    final theme = Theme.of(context);
    final cur = _selectedIndex;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('执行模式', style: theme.textTheme.titleMedium),
                ),
              ),
              for (int i = 0; i < _options.length; i++)
                _ModeOptionTile(
                  icon: _options[i].$2,
                  title: _options[i].$3,
                  desc: _options[i].$4,
                  selected: i == cur,
                  onTap: () {
                    onChanged(_options[i].$1);
                    Navigator.pop(ctx);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 图标模式: 图标随当前模式变化, 点击弹选择菜单 (对齐网页端)
    return _ComposerIconBtn(
      icon: _current.$2,
      tooltip: '执行模式: ${_current.$3}',
      onTap: () => _open(context),
    );
  }
}

/// 模式选项 tile (图标 + 标题/描述 + 对勾)
class _ModeOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  final bool selected;
  final VoidCallback onTap;

  const _ModeOptionTile({
    required this.icon,
    required this.title,
    required this.desc,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: Icon(
        icon,
        size: 20,
        color: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: theme.colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        desc,
        style: TextStyle(
          fontSize: AppTextSizes.label,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: selected
          ? Icon(
              Icons.check_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            )
          : null,
    );
  }
}

/// 思考级别选择器 (深思考 / 浅思考 / 关闭)
class _ThoughtLevelSelector extends StatelessWidget {
  final String level; // 'max' | 'medium' | 'nothink'
  final ValueChanged<String> onChanged;

  const _ThoughtLevelSelector({required this.level, required this.onChanged});

  static const _options = <(String, IconData, String, String)>[
    ('max', Icons.psychology, 'max', '完整推理链'),
    ('medium', Icons.lightbulb_outline, 'medium', '适度推理'),
    ('nothink', Icons.flash_off_outlined, 'nothink', '直接回答'),
  ];

  (IconData, String) get _current {
    for (final o in _options) {
      if (o.$1 == level) return (o.$2, o.$3);
    }
    return (Icons.psychology, 'max');
  }

  void _open(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('思考级别', style: theme.textTheme.titleMedium),
                ),
              ),
              for (final o in _options)
                _ModeOptionTile(
                  icon: o.$2,
                  title: o.$3,
                  desc: o.$4,
                  selected: o.$1 == level,
                  onTap: () {
                    onChanged(o.$1);
                    Navigator.pop(ctx);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 图标模式: 图标随级别变化, 点击弹选择菜单 (对齐网页端)
    final cur = _current;
    return _ComposerIconBtn(
      icon: cur.$1,
      tooltip: '思考级别: ${cur.$2}',
      onTap: () => _open(context),
    );
  }
}

/// 模型选择底部表 (模型按钮 + /model 命令共用)
void showModelPicker(
  BuildContext context, {
  required List<String> models,
  required String? current,
  required ValueChanged<String> onSelected,
  Map<String, String> providerNames = const {},
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Color.alphaBlend(
      Theme.of(context).colorScheme.surfaceContainerHigh,
      Theme.of(context).colorScheme.surfaceContainerLowest,
    ),
    builder: (ctx) => _ModelPickerSheet(
      models: models,
      current: current,
      onSelected: onSelected,
      providerNames: providerNames,
    ),
  );
}

class _ModelPickerSheet extends StatefulWidget {
  final List<String> models;
  final String? current;
  final ValueChanged<String> onSelected;
  final Map<String, String> providerNames;

  const _ModelPickerSheet({
    required this.models,
    required this.current,
    required this.onSelected,
    required this.providerNames,
  });

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  /// 当前模型的 tile key — 打开时滚动定位到它
  final _currentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 首帧后把当前模型滚进可视区 (默认选中)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 250),
        );
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String slug(String id) => id.split('/').last;
    String providerLabel(String pid) => widget.providerNames[pid] ?? pid;

    // 过滤
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.models
        : widget.models.where((m) => m.toLowerCase().contains(query)).toList();

    // 分组
    final groups = <String, List<String>>{};
    final order = <String>[];
    for (final m in filtered) {
      final pid = m.contains('/') ? m.split('/').first : '其他';
      (groups[pid] ??= []).add(m);
      if (!order.contains(pid)) order.add(pid);
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: Column(
            children: [
              // 标题栏
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Text(
                      '选择模型',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${widget.models.length} 个模型',
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // 搜索框 (模型少时没必要搜索, 隐藏)
              if (widget.models.length > 6)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(fontSize: AppTextSizes.bodyMd),
                    decoration: InputDecoration(
                      hintText: '搜索模型...',
                      hintStyle: TextStyle(
                        fontSize: AppTextSizes.bodyMd,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      suffixIcon: _query.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                            )
                          : null,
                      isDense: true,
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHigh,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              // 模型列表
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          query.isEmpty ? '暂无可用模型' : '未找到匹配的模型',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: AppTextSizes.bodySm,
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 8),
                        children: [
                          for (final pid in order) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.dns_outlined,
                                    size: 13,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    providerLabel(pid),
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: theme.colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${groups[pid]!.length}',
                                    style: TextStyle(
                                      fontSize: AppTextSizes.caption,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (final m in groups[pid]!)
                              ListTile(
                                key: m == widget.current ? _currentKey : null,
                                dense: true,
                                title: Text(
                                  slug(m),
                                  style: TextStyle(
                                    fontSize: AppTextSizes.bodyMd,
                                    fontWeight: m == widget.current
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                                // 选中项: 右侧对勾 (替代单选框)
                                trailing: m == widget.current
                                    ? Icon(
                                        Icons.check_rounded,
                                        size: 20,
                                        color: theme.colorScheme.primary,
                                      )
                                    : null,
                                onTap: () {
                                  widget.onSelected(m);
                                  Navigator.pop(context);
                                },
                              ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 模型选择按钮 (输入栏右侧); 加载中/空列表自适应
class _ModelSelector extends StatelessWidget {
  final List<String> models;
  final String? current;
  final ValueChanged<String> onSelected;
  final Map<String, String> providerNames;
  final bool isLoading;

  const _ModelSelector({
    required this.models,
    required this.current,
    required this.onSelected,
    this.providerNames = const {},
    this.isLoading = false,
  });

  String get _label {
    if (current != null) return current!.split('/').last;
    // 无选择时取第一个可用模型名
    if (models.isNotEmpty) return models.first.split('/').last;
    return '默认';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 图标模式: 芯片图标 + 加载/可用状态 (模型名见 tooltip 与选择菜单, 对齐网页端)
    final Widget icon;
    if (isLoading) {
      icon = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: theme.colorScheme.primary,
        ),
      );
    } else {
      icon = Icon(
        Icons.memory_rounded,
        size: 18,
        color: models.isEmpty
            ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
            : theme.colorScheme.primary,
      );
    }
    return IconButton(
      onPressed: (models.isEmpty && !isLoading)
          ? null
          : () => showModelPicker(
              context,
              models: models,
              current: current,
              onSelected: onSelected,
              providerNames: providerNames,
            ),
      tooltip: models.isEmpty
          ? (isLoading ? '正在加载模型...' : '模型列表未加载')
          : '模型: $_label',
      icon: icon,
      style: IconButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.all(6),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 判断两个 DateTime 是否同一天
bool _isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

/// 排队消息行 (输入框上方; 单行文字 + 立即/编辑/删除)
class _QueuedMessageRow extends StatelessWidget {
  final String text;
  final VoidCallback onSendNow;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _QueuedMessageRow({
    required this.text,
    required this.onSendNow,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            _QueueAction(
              icon: Icons.play_arrow_rounded,
              tooltip: '立即发送',
              onTap: onSendNow,
            ),
            _QueueAction(icon: Icons.edit_outlined, tooltip: '编辑', onTap: onEdit),
            _QueueAction(
              icon: Icons.close_rounded,
              tooltip: '删除',
              onTap: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// 压缩标记 (居中药丸形; running 态转圈)
class _CompactMarkerPill extends StatelessWidget {
  final String label;
  final bool running;

  const _CompactMarkerPill({required this.label, this.running = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                Icon(
                  Icons.compress_outlined,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 日期分组标签 (居中药丸形)
class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  String _format(DateTime d) {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    if (_isSameDay(d, now)) return '今天';
    if (_isSameDay(d, yesterday)) return '昨天';
    return '${d.month}月${d.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            _format(date),
            style: TextStyle(
              fontSize: AppTextSizes.caption,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 消息头像 (AI: 渐变圆 + spark; 用户: 蓝色圆 + person)
class _Avatar extends StatelessWidget {
  final String role; // 'user' | 'assistant'
  final ThemeData theme;

  const _Avatar({required this.role, required this.theme});

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: isUser
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.accent, const Color(0xFF8B5CF6)],
              ),
        color: isUser ? AppColors.accent : null,
      ),
      child: Icon(
        isUser ? Icons.person_rounded : Icons.auto_awesome,
        size: 15,
        color: Colors.white,
      ),
    );
  }
}

/// 消息气泡
///
/// 用户: 强调色填充, 右对齐
/// AI: 透明面 + 左侧强调竖条 (开发者工具气质, 非圆胖聊天气泡)
/// 消息反馈类型 (赞/踩)
/// Markdown 文本按表格分段
class _MarkdownSegment {
  final String text;
  final bool isTable;
  const _MarkdownSegment(this.text, this.isTable);
}

/// 将 markdown 文本按 GFM 表格块拆分。
/// 表格块: 连续以 `|` 开头的行, 且第二行是分隔符 (|---|---|)
/// 其余为普通文本段。
List<_MarkdownSegment> _splitMarkdownByTables(String text) {
  final lines = text.split('\n');
  final segments = <_MarkdownSegment>[];
  final buf = StringBuffer();
  int i = 0;

  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trimLeft();

    // 检测表格起始: 当前行以 | 开头, 且下一行是分隔符
    if (trimmed.startsWith('|') &&
        i + 1 < lines.length &&
        _isTableSeparator(lines[i + 1])) {
      // flush 文本缓冲
      if (buf.isNotEmpty) {
        segments.add(_MarkdownSegment(buf.toString(), false));
        buf.clear();
      }
      // 收集所有表格行
      final tableLines = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
        tableLines.add(lines[i]);
        i++;
      }
      segments.add(_MarkdownSegment(tableLines.join('\n'), true));
    } else {
      buf.writeln(line);
      i++;
    }
  }
  if (buf.isNotEmpty) {
    segments.add(_MarkdownSegment(buf.toString(), false));
  }
  return segments;
}

/// 判断是否是 GFM 表格分隔行: |---|:---:|---|
bool _isTableSeparator(String line) {
  final t = line.trim();
  if (!t.contains('-') || !t.contains('|')) return false;
  final cleaned = t
      .replaceAll('|', '')
      .replaceAll('-', '')
      .replaceAll(':', '')
      .replaceAll(' ', '');
  return cleaned.isEmpty;
}

/// 消息气泡 (用户/AI/错误)
class _MessageBubble extends StatefulWidget {
  final DisplayMessage message;
  final ThemeData theme;

  /// 是否为最后一条用户消息 (用于撤销功能)
  final bool isLastUserMessage;

  /// AI 是否正在响应中 (用于撤销功能的可用性判断)
  final bool isResponding;

  /// 编辑消息回调 (用户消息)
  final void Function(String)? onEdit;

  /// 撤销最后一轮回调
  final VoidCallback? onRewind;

  /// ★ ExitPlanMode 权限 (传给 _PlanCard 内嵌按钮, null=无待确认权限)
  final PendingPermission? planPermission;

  /// ★ 权限响应回调
  final void Function(
    String permissionId,
    String optionId,
    String decision,
    List<PermissionOption>? options,
    String? traceId,
  )?
  onRespondPermission;

  const _MessageBubble({
    required this.message,
    required this.theme,
    this.isLastUserMessage = false,
    this.isResponding = false,
    this.onEdit,
    this.onRewind,
    this.planPermission,
    this.onRespondPermission,
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  /// 从 markdown content 中提取 data URI 图片, 返回 (图片列表, 去除图片后的文本)
  (List<String> images, String text) _extractImages(String content) {
    final images = <String>[];
    // 匹配 ![alt](data:image/...;base64,...)
    final imgRegex = RegExp(r'!\[[^\]]*\]\((data:image/[^)]+)\)');
    String text = content;
    for (final match in imgRegex.allMatches(content)) {
      images.add(match.group(1)!);
    }
    text = text.replaceAll(imgRegex, '').trim();
    return (images, text);
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final theme = widget.theme;
    final isUser = message.role == 'user';
    final isError = message.role == 'error';

    if (isError) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 16, color: AppColors.danger),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message.content,
                style: TextStyle(
                  color: AppColors.danger,
                  fontSize: AppTextSizes.bodySm,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (isUser) {
      // 用户气泡: 强调色填充, 右对齐 + 编辑按钮
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.82,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm + 2,
              ),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.lg),
                  topRight: Radius.circular(AppRadius.lg),
                  bottomLeft: Radius.circular(AppRadius.lg),
                  bottomRight: Radius.circular(AppRadius.xs),
                ),
              ),
              child: Builder(
                builder: (context) {
                  final (images, text) = _extractImages(message.content);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 图片
                      for (final dataUri in images)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.sizeOf(context).width * 0.6,
                              maxHeight: 200,
                            ),
                            child: _DataImage(dataUri: dataUri),
                          ),
                        ),
                      // 文本 (有图片或有文字时才显示)
                      if (text.isNotEmpty)
                        MarkdownBody(
                          data: text,
                          styleSheet: MarkdownStyleSheet(
                            p: const TextStyle(
                              color: Colors.white,
                              fontSize: AppTextSizes.bodyMd,
                              height: 1.5,
                            ),
                            code: TextStyle(
                              backgroundColor: Colors.black26,
                              fontSize: AppTextSizes.bodySm,
                              fontFamily: kMonoFont,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          // 编辑按钮
          if (widget.onEdit != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: AppSpacing.xs),
              child: GestureDetector(
                onTap: () => _showEditSheet(context),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.edit_outlined,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '编辑',
                        style: TextStyle(
                          fontSize: AppTextSizes.label,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }

    // AI 消息: 无气泡, 直接铺在页面上 (对齐网页端; 用户消息保留气泡)
    final isDark = theme.brightness == Brightness.dark;
    final aiInk = theme.colorScheme.onSurface;
    final aiCodeBg = isDark
        ? theme.colorScheme.surfaceContainerLowest
        : theme.colorScheme.surfaceContainerHighest;

    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageMenu(context, message),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.96,
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _buildAssistantContent(message, theme, aiInk, aiCodeBg),
          ),
        ),
      ),
    );
  }

  /// markdown 链接点击 → 外部浏览器打开
  Future<void> _onMarkdownLink(String text, String? href, String? title) async {
    if (href == null) return;
    try {
      await launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
    } catch (_) {
      // 无可处理的应用时静默忽略
    }
  }

  /// AI 气泡的 Markdown 正文块 (统一样式见 chatMarkdownStyleSheet, 两种渲染路径共用)。
  /// 提取并独立渲染 data URI 图片 (MarkdownBody 无法渲染 data: URI)。
  /// ★ 表格 (GFM table) 单独拆出, 用横向滚动渲染, 不受气泡宽度限制。
  Widget _buildMarkdown(
    String data,
    ThemeData theme,
    Color aiInk,
    Color aiCodeBg,
  ) {
    final (images, cleanText) = _extractImages(data);
    final segments = _splitMarkdownByTables(cleanText);
    final styleSheet = chatMarkdownStyleSheet(
      theme,
      ink: aiInk,
      codeBg: aiCodeBg,
    );
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.4);

    final widgets = <Widget>[];

    for (final seg in segments) {
      if (seg.isTable) {
        // ★ 表格: 横向滚动 + 圆角 + 边框, 不压缩列宽
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: borderColor),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: MarkdownBody(
                    data: seg.text,
                    styleSheet: styleSheet,
                    onTapLink: _onMarkdownLink,
                  ),
                ),
              ),
            ),
          ),
        );
      } else if (seg.text.trim().isNotEmpty) {
        widgets.add(
          MarkdownBody(
            data: seg.text,
            styleSheet: styleSheet,
            onTapLink: _onMarkdownLink,
            builders: {'pre': _CodeBlockBuilder(theme: theme)},
          ),
        );
      }
    }

    // 前置图片
    final allChildren = <Widget>[];
    for (final dataUri in images) {
      allChildren.add(
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: _DataImage(dataUri: dataUri),
            ),
          ),
        ),
      );
    }
    allChildren.addAll(widgets);

    if (allChildren.length == 1) return allChildren.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: allChildren,
    );
  }

  /// 构建 AI 消息气泡的内容子项列表。
  ///
  /// ★ 若 [DisplayMessage.parts] 非空 → 按 parts[] 原始顺序交错渲染
  ///   (思考 → 正文 → 工具卡 依真实发生顺序, 匹配 web 客户端):
  ///   - ThoughtPart → _ThoughtBlock
  ///   - TextPart    → MarkdownBody 正文
  ///   - ToolPart    → ExitPlanMode 渲染 _PlanCard; 其余连续工具合并成
  ///                   一个 _ToolActivityCards (避免碎片化)
  /// 否则回退旧的固定顺序 (思考 → 正文 → 计划卡 → 文件摘要 → 工具卡)。
  ///
  /// _ChangedFilesSummary 与赞/踩按钮始终在末尾 (两种路径共享)。
  List<Widget> _buildAssistantContent(
    DisplayMessage message,
    ThemeData theme,
    Color aiInk,
    Color aiCodeBg,
  ) {
    final children = <Widget>[];

    // ★ 查找 ExitPlanMode 权限 (如果有, 传给 _PlanCard 内嵌按钮)
    final planPerm = widget.planPermission;
    final respondPermission = widget.onRespondPermission;

    if (message.parts.isNotEmpty) {
      // ── parts 路径: 按 parts[] 顺序交错渲染 ──
      // 连续的非计划工具先累积, 遇到文本/思考/计划卡时 flush 成一张工具卡。
      final pendingTools = <ToolActivity>[];
      List<Widget> buildRange(List<MessagePart> range) {
        final out = <Widget>[];
        void flushTools() {
          if (pendingTools.isEmpty) return;
          final snapshot = List<ToolActivity>.from(pendingTools);
          out.add(
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: _ToolActivityCards(
                activities: snapshot,
                theme: theme,
                inkColor: aiInk,
              ),
            ),
          );
          pendingTools.clear();
        }

        for (final part in range) {
          switch (part) {
            case TextPart(:final text):
              flushTools();
              out.add(_buildMarkdown(text, theme, aiInk, aiCodeBg));
            case ThoughtPart(:final text, :final durationMs):
              flushTools();
              out.add(
                _ThoughtBlock(
                  thought: text,
                  theme: theme,
                  durationMs: durationMs,
                ),
              );
            case StepPart():
              flushTools();
              // 只在 step-finish 后插入分隔线 (表示一个步骤完成)
              if (!part.isStart && out.isNotEmpty) {
                out.add(
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.3,
                      ),
                    ),
                  ),
                );
              }
            case ToolPart(:final activity):
              if (_isPlanTool(activity)) {
                flushTools();
                out.add(
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: _PlanCard(
                      activity: activity,
                      theme: theme,
                      inkColor: aiInk,
                      permission: planPerm,
                      onRespondPermission: respondPermission,
                    ),
                  ),
                );
              } else {
                pendingTools.add(activity);
              }
          }
        }
        flushTools();
        return out;
      }

      // ★ 历史/尾段拆分 (对齐 ZCode 网页端): 最后一串正文之前的全部内容
      //   (思考/工具/早期正文) 折叠进 "已工作 X" 状态行后面; 尾段正文始终可见。
      //   运行中默认展开 (实时滚动), 完成后自动折叠 (自动隐藏)。
      final hasText = message.parts.any((p) => p is TextPart);
      var splitIdx = message.parts.length;
      if (hasText) {
        for (var i = message.parts.length - 1; i >= 0; i--) {
          if (message.parts[i] is! TextPart) break;
          splitIdx = i;
        }
      }
      final historyParts =
          hasText ? message.parts.sublist(0, splitIdx) : message.parts;
      final tailParts = hasText
          ? message.parts.sublist(splitIdx)
          : const <MessagePart>[];

      if (historyParts.isNotEmpty) {
        children.add(
          _WorkHistory(
            message: message,
            theme: theme,
            // 无正文的轮次折叠会藏掉全部内容, 保持展开 (ZCode 同款)
            defaultOpen: message.isStreaming || !hasText,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: buildRange(historyParts),
            ),
          ),
        );
      }
      children.addAll(buildRange(tailParts));

      // 流式光标 (parts 路径极少流式, 兜底放末尾)
      if (message.isStreaming) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _TypingCursor(color: AppColors.accent),
          ),
        );
      }
      // 变更文件摘要 (始终在末尾; 优先 turnHeader.fileChanges 权威数据)
      final hasFileData = message.fileChanges != null &&
          message.fileChanges!.files > 0;
      if ((hasFileData || message.activities.any(_isFileActivity)) &&
          !message.isStreaming) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: _ChangedFilesSummary(
              activities: message.activities,
              theme: theme,
              inkColor: aiInk,
              fileChanges: message.fileChanges,
            ),
          ),
        );
      }
    } else {
      // ── 旧: 固定顺序渲染 (无 parts 数据时回退, 如缓存消息) ──
      // 轮次状态行 (有 workedMs/turnStartedAt 元数据时)
      if (message.workedMs != null || message.turnStartedAt != null) {
        children.add(
          _TurnStatusLine(
            running: message.isStreaming,
            workedMs: message.workedMs,
            startedAt: message.turnStartedAt,
            theme: theme,
          ),
        );
      }
      // 思考过程 (折叠)
      if (message.thought != null && message.thought!.isNotEmpty) {
        children.add(_ThoughtBlock(thought: message.thought!, theme: theme));
      }
      // 正文 — 硬编码高对比文字
      children.add(
        _buildMarkdown(
          message.content.isEmpty && message.isStreaming
              ? '_(思考中...)_'
              : message.content,
          theme,
          aiInk,
          aiCodeBg,
        ),
      );
      // 流式光标
      if (message.isStreaming) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _TypingCursor(color: AppColors.accent),
          ),
        );
      }
      // 计划卡片 (ExitPlanMode 工具产出, 网页端 g3e 同款)
      children.addAll(
        message.activities
            .where(_isPlanTool)
            .map(
              (a) => Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: _PlanCard(
                  activity: a,
                  theme: theme,
                  inkColor: aiInk,
                  permission: planPerm,
                  onRespondPermission: respondPermission,
                ),
              ),
            ),
      );
      // 变更文件摘要 (优先 turnHeader.fileChanges 权威数据)
      final hasFileData =
          message.fileChanges != null && message.fileChanges!.files > 0;
      if ((hasFileData || message.activities.any(_isFileActivity)) &&
          !message.isStreaming) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: _ChangedFilesSummary(
              activities: message.activities,
              theme: theme,
              inkColor: aiInk,
              fileChanges: message.fileChanges,
            ),
          ),
        );
      }
      // 工具调用详情卡片 (折叠式, 正文之后)
      if (message.activities.isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: _ToolActivityCards(
              activities: message.activities,
              theme: theme,
              inkColor: aiInk,
            ),
          ),
        );
      }
    }

    return children;
  }

  /// 编辑消息 — 底部弹出编辑框 (实色背景)
  void _showEditSheet(BuildContext context) {
    final theme = Theme.of(context);
    final controller = TextEditingController(text: widget.message.content);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  Text(
                    '编辑消息',
                    style: TextStyle(
                      fontSize: AppTextSizes.titleSm,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
            // 编辑框
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: TextField(
                controller: controller,
                maxLines: 5,
                minLines: 1,
                autofocus: true,
                style: TextStyle(
                  fontSize: AppTextSizes.bodyMd,
                  color: theme.colorScheme.onSurface,
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: theme.colorScheme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: AppColors.accent, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.all(AppSpacing.md),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            // 发送按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    final text = controller.text.trim();
                    Navigator.pop(ctx);
                    if (text.isNotEmpty) {
                      widget.onEdit?.call(text);
                    }
                  },
                  icon: const Icon(Icons.send, size: 18),
                  label: const Text('发送'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm + 2,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// AI 消息长按菜单 (复制/分享/撤销)
  void _showMessageMenu(BuildContext context, DisplayMessage message) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 预览 (截断的消息内容)
            if (message.content.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  message.content.length > 120
                      ? '${message.content.substring(0, 120)}...'
                      : message.content,
                  style: TextStyle(
                    fontSize: AppTextSizes.label,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 3,
                ),
              ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制全文'),
              onTap: () async {
                Navigator.pop(ctx);
                await Clipboard.setData(ClipboardData(text: message.content));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享'),
              onTap: () {
                Navigator.pop(ctx);
                Share.share(message.content);
              },
            ),
            // 撤销最后一轮 (仅最后一条用户消息 + 非响应中)
            if (widget.isLastUserMessage &&
                !widget.isResponding &&
                widget.onRewind != null)
              ListTile(
                leading: const Icon(Icons.undo, color: AppColors.warning),
                title: const Text('撤销最后一轮'),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onRewind!.call();
                },
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// 赞/踩按钮 (小尺寸, inline)
/// 判断工具活动是否是计划工具 (ExitPlanMode / switch_mode)
bool _isPlanTool(ToolActivity a) {
  final n = a.toolName.toLowerCase();
  return n == 'exitplanmode' || n == 'switch_mode' || n == 'switchmode';
}

/// 判断工具活动是否是 TodoWrite (已由 _PlanList 单独展示, 从工具卡片排除)
bool _isTodoTool(ToolActivity a) {
  final n = a.toolName.toLowerCase();
  return n == 'todowrite' || n == 'todo_write' || n == 'todowritetool';
}

/// 判断工具活动是否是文件操作 (写/编辑/创建/删除文件)
bool _isFileActivity(ToolActivity a) {
  final n = a.toolName.toLowerCase();
  return n.contains('edit') ||
      n.contains('write') ||
      n.contains('create') ||
      n.contains('str_replace') ||
      n.contains('file') ||
      n.contains('delete') ||
      n.contains('remove');
}

/// 从工具活动中提取变更的文件路径
/// 优先从 input 中取 path/file_path, 回退到 result 中搜索路径模式
String? _extractFilePath(ToolActivity a) {
  final input = a.input;
  if (input != null) {
    for (final key in ['file_path', 'path', 'filename', 'file']) {
      final v = input[key];
      if (v is String && v.isNotEmpty) return v;
    }
  }
  // 回退: 从 result 中提取文件路径 (形如 /path/to/file.ext)
  final result = a.result ?? '';
  final match = RegExp(r'[/\w]+\.\w+').firstMatch(result);
  return match?.group(0);
}

/// 计划卡片 — ExitPlanMode 工具产出的 plan markdown (网页端 g3e 同款)。
/// 显示标题"计划" + markdown 正文 (可折叠)。
class _PlanCard extends StatefulWidget {
  final ToolActivity activity;
  final ThemeData theme;
  final Color inkColor;

  /// ★ 权限确认按钮直接内嵌在卡片底部 (不再弹底部弹窗)
  final PendingPermission? permission;
  final void Function(
    String permissionId,
    String optionId,
    String decision,
    List<PermissionOption>? options,
    String? traceId,
  )?
  onRespondPermission;

  const _PlanCard({
    required this.activity,
    required this.theme,
    required this.inkColor,
    this.permission,
    this.onRespondPermission,
  });

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard>
    with SingleTickerProviderStateMixin {
  /// 历史计划默认折叠; 待确认(plan permission pending)时默认展开
  bool get _defaultExpanded => widget.permission != null;
  late bool _expanded = _defaultExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    // plan 可能在 result (已完成的 ExitPlanMode output) 或 input.plan (待确认, wire 实测 state.input.plan)
    final planText =
        widget.activity.result ??
        widget.activity.input?['plan'] as String? ??
        '';
    if (planText.isEmpty) return const SizedBox.shrink();

    final perm = widget.permission;
    final isPending = perm != null;

    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerHigh;
    final accent = widget.inkColor;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: accent.withValues(alpha: 0.3), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行: 📋 计划 + 折叠按钮 + 待确认标签
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(Icons.checklist_rtl, size: 16, color: accent),
                  const SizedBox(width: 6),
                  Text(
                    '计划',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isPending) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '待确认',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // markdown 正文
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: _expanded
                ? Padding(
                    padding: EdgeInsets.only(
                      left: AppSpacing.sm + 2,
                      right: AppSpacing.sm + 2,
                      bottom: isPending ? 0 : AppSpacing.sm + 2,
                    ),
                    child: MarkdownBody(
                      data: planText,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                        p: theme.textTheme.bodySmall,
                        h1: theme.textTheme.titleSmall,
                        h2: theme.textTheme.titleSmall,
                        h3: theme.textTheme.titleSmall,
                        listBullet: theme.textTheme.bodySmall,
                        code: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          backgroundColor:
                              theme.colorScheme.surfaceContainerLowest,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                      ),
                      builders: {'pre': _CodeBlockBuilder(theme: theme)},
                    ),
                  )
                // 收起时显示前几行预览 (取纯文本, 最多7行)
                : Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.sm + 2,
                      right: AppSpacing.sm + 2,
                      bottom: AppSpacing.sm,
                    ),
                    child: Text(
                      planText
                          .split('\n')
                          .where((l) => l.trim().isNotEmpty)
                          .take(7)
                          .join('\n')
                          .replaceAll(RegExp(r'^[#*\-\d.\s]+'), ''),
                      maxLines: 7,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                  ),
          ),
          // ★ 内嵌权限按钮 (待确认时显示)
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: (isPending && _expanded)
                ? Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.sm + 2,
                      right: AppSpacing.sm + 2,
                      top: AppSpacing.sm,
                      bottom: AppSpacing.sm + 2,
                    ),
                    child: Row(
                      children: perm.options.map((opt) {
                        final cnLabel = switch (opt.kind) {
                          'allow_once' => '允许',
                          'allow_always' => '始终允许',
                          'deny' => '拒绝',
                          'escalate' => '上报',
                          'modify' => '修改',
                          _ => opt.name,
                        };
                        final isDeny = opt.decision == 'deny';
                        return Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: opt != perm.options.last
                                  ? AppSpacing.xs
                                  : 0,
                            ),
                            child: isDeny
                                ? OutlinedButton.icon(
                                    onPressed: () =>
                                        widget.onRespondPermission?.call(
                                          perm.id,
                                          opt.optionId,
                                          opt.decision,
                                          perm.options,
                                          perm.traceId,
                                        ),
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                    ),
                                    label: Text(
                                      cnLabel,
                                      style: const TextStyle(
                                        fontSize: AppTextSizes.bodySm,
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.danger,
                                      minimumSize: const Size.fromHeight(38),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                    ),
                                  )
                                : FilledButton.icon(
                                    onPressed: () =>
                                        widget.onRespondPermission?.call(
                                          perm.id,
                                          opt.optionId,
                                          opt.decision,
                                          perm.options,
                                          perm.traceId,
                                        ),
                                    icon: const Icon(
                                      Icons.check_rounded,
                                      size: 16,
                                    ),
                                    label: Text(
                                      cnLabel,
                                      style: const TextStyle(
                                        fontSize: AppTextSizes.bodySm,
                                      ),
                                    ),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.success,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size.fromHeight(38),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      }).toList(),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 变更文件摘要 (折叠式 — 展示 N 个文件已更改 +N -M)
class _ChangedFilesSummary extends StatefulWidget {
  final List<ToolActivity> activities;
  final ThemeData theme;
  final Color inkColor;
  /// turnHeader.fileChanges 权威统计 (additions/deletions/files);
  /// null 时回退到从工具活动刮取
  final V4TurnFileChanges? fileChanges;

  const _ChangedFilesSummary({
    required this.activities,
    required this.theme,
    required this.inkColor,
    this.fileChanges,
  });

  @override
  State<_ChangedFilesSummary> createState() => _ChangedFilesSummaryState();
}

class _ChangedFilesSummaryState extends State<_ChangedFilesSummary>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = theme.brightness == Brightness.dark;
    final fileActivities = widget.activities
        .where((a) => _isFileActivity(a) && !_isTodoTool(a))
        .toList();

    // 提取唯一文件路径
    final fileMap = <String, ToolActivity>{};
    for (final a in fileActivities) {
      final path = _extractFilePath(a);
      if (path != null && path.isNotEmpty) {
        fileMap[path] = a;
      }
    }
    final files = fileMap.keys.toList();

    // 增删行数: 优先 turnHeader.fileChanges 权威数据, 否则从 result 刮 +N -M
    final fc = widget.fileChanges;
    var totalAdded = 0;
    var totalRemoved = 0;
    if (fc != null) {
      totalAdded = fc.additions;
      totalRemoved = fc.deletions;
    } else {
      for (final a in fileActivities) {
        final result = a.result ?? '';
        final addMatch = RegExp(r'\+(\d+)').firstMatch(result);
        final delMatch = RegExp(r'-(\d+)').firstMatch(result);
        if (addMatch != null) {
          totalAdded += int.tryParse(addMatch.group(1)!) ?? 0;
        }
        if (delMatch != null) {
          totalRemoved += int.tryParse(delMatch.group(1)!) ?? 0;
        }
      }
    }
    final fileCount = fc != null && fc.files > 0 ? fc.files : files.length;

    final cardBg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerHigh;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部: "N 个文件已更改  +N -M"
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.difference_outlined,
                    size: 16,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$fileCount 个文件已更改',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w500,
                      color: widget.inkColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (totalAdded > 0)
                    Text(
                      '+$totalAdded',
                      style: const TextStyle(
                        fontSize: AppTextSizes.caption,
                        color: AppColors.success,
                      ),
                    ),
                  if (totalRemoved > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      '-$totalRemoved',
                      style: const TextStyle(
                        fontSize: AppTextSizes.caption,
                        color: AppColors.danger,
                      ),
                    ),
                  ],
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开详情: 文件列表
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: (_expanded && files.isNotEmpty)
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm + 2,
                      0,
                      AppSpacing.sm + 2,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(
                          height: 1,
                          color: widget.inkColor.withValues(alpha: 0.08),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        for (final path in files)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Icon(
                                  _fileIcon(path),
                                  size: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    path.split('/').last,
                                    style: TextStyle(
                                      fontSize: AppTextSizes.label,
                                      fontFamily: kMonoFont,
                                      color: widget.inkColor,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    path,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  IconData _fileIcon(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'dart' => Icons.flutter_dash,
      'py' => Icons.code,
      'js' || 'ts' || 'jsx' || 'tsx' => Icons.javascript,
      'json' || 'yaml' || 'yml' || 'toml' || 'xml' => Icons.settings,
      'md' => Icons.description,
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'svg' ||
      'webp' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

/// 工具调用统一折叠容器 (所有工具调用合并到一张卡, 节省空间)
///
/// 折叠态: 头部一行摘要 "🔧 N 个工具调用 · M 完成 / K 运行中"
/// 展开态: 内部按工具类型分组:
///   - 子代理 (Agent/Explore/Task): 整体折叠成 "🤖 调用了 N 个子任务"
///   - 普通工具: 精简行列表 (图标+名+状态), 点击单行展开详情
class _ToolActivityCards extends StatefulWidget {
  final List<ToolActivity> activities;
  final ThemeData theme;
  final Color inkColor;

  const _ToolActivityCards({
    required this.activities,
    required this.theme,
    required this.inkColor,
  });

  @override
  State<_ToolActivityCards> createState() => _ToolActivityCardsState();
}

class _ToolActivityCardsState extends State<_ToolActivityCards>
    with SingleTickerProviderStateMixin {
  /// null = 跟随自动状态 (运行中展开, 完成后折叠); 手动点按后固定。
  /// 完成态重新变为运行态时重置 (对齐 ZCode 的 defaultOpen 同步)。
  bool? _manualExpanded;
  // 记录哪些工具行被单独展开 (按 toolCallId)
  final Set<String> _expandedRows = {};

  @override
  void didUpdateWidget(covariant _ToolActivityCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasRunning = oldWidget.activities.any((a) => a.isRunning);
    final nowRunning = widget.activities.any((a) => a.isRunning);
    if (wasRunning != nowRunning) _manualExpanded = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final activities = widget.activities;
    if (activities.isEmpty) return const SizedBox.shrink();

    // plan/todo 工具已单独渲染 (_PlanCard / plan 面板), 这里排除;
    // 子代理 (Agent/Explore/Task) 作为普通行渲染 (专属图标 + 摘要)
    final tools = activities
        .where((a) => !_isPlanTool(a) && !_isTodoTool(a))
        .toList();
    if (tools.isEmpty) return const SizedBox.shrink();

    final running = tools.where((a) => a.isRunning).length;
    final completed = tools
        .where(
          (a) =>
              a.status == 'result' ||
              a.status == 'done' ||
              a.status == 'complete' ||
              a.status == 'completed' ||
              a.status == 'success',
        )
        .length;
    final errors = tools
        .where((a) => a.status == 'error' || a.status == 'failed')
        .length;

    // ★ 自动隐藏: 运行中展开 (实时滚动), 全部完成后折叠成一行摘要
    final expanded = _manualExpanded ?? running > 0;

    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.surfaceContainerHigh;

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.xs),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部: 摘要 + 折叠箭头
          InkWell(
            onTap: () => setState(() => _manualExpanded = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${tools.length} 个工具调用',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 状态摘要: M 完成 · K 运行中 · N 出错
                  Flexible(
                    child: Text(
                      [
                        if (completed > 0) '$completed 完成',
                        if (running > 0) '$running 运行中',
                        if (errors > 0) '$errors 出错',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: AppTextSizes.caption,
                        color: running > 0
                            ? AppColors.accent
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (running > 0)
                    const SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor: AlwaysStoppedAnimation(AppColors.accent),
                      ),
                    )
                  else if (errors > 0)
                    const Icon(
                      Icons.error_outline,
                      size: 13,
                      color: AppColors.danger,
                    ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: AppDur.fast,
                    curve: AppEase.inOut,
                    child: Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开后: 工具行 (含子代理行)
          AnimatedSize(
            duration: AppDur.base,
            curve: AppEase.inOut,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm + 2,
                      0,
                      AppSpacing.sm + 2,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      children: [
                        for (final a in tools) ...[
                          _ToolActivityRow(
                            activity: a,
                            theme: theme,
                            inkColor: widget.inkColor,
                            expanded: _expandedRows.contains(a.toolCallId),
                            onToggle: () => setState(() {
                              if (_expandedRows.contains(a.toolCallId)) {
                                _expandedRows.remove(a.toolCallId);
                              } else {
                                _expandedRows.add(a.toolCallId);
                              }
                            }),
                          ),
                          const SizedBox(height: 2),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 格式化工具名显示: mcp__server__method → "server · method"
String _formatToolName(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('mcp__')) {
    final parts = name.split('__');
    if (parts.length >= 3) {
      final server = parts[1];
      final method = parts.sublist(2).join('_');
      return '$server · $method';
    }
  }
  return name;
}

/// 工具名 → 图标 (按工具类型精确定位, 不用 emoji)
IconData _iconForTool(String name) {
  final n = name.toLowerCase();
  if (n.startsWith('mcp__')) return Icons.extension;
  if (_isSubagentToolName(n)) return Icons.account_tree_outlined;
  if (n.contains('bash') ||
      n.contains('shell') ||
      n.contains('terminal') ||
      n.contains('cmd') ||
      n.contains('exec')) {
    return Icons.terminal;
  }
  if (n.contains('grep') ||
      n.contains('glob') ||
      n.contains('search') ||
      n.contains('find')) {
    return Icons.search;
  }
  if (n.contains('edit') ||
      n.contains('write') ||
      n.contains('create') ||
      n.contains('str_replace')) {
    return Icons.edit_outlined;
  }
  if (n.contains('read') || n.contains('notebook')) return Icons.description_outlined;
  if (n.contains('web') ||
      n.contains('browser') ||
      n.contains('fetch') ||
      n.contains('curl') ||
      n.contains('url')) {
    return Icons.travel_explore;
  }
  if (n.contains('todo') || n.contains('plan')) return Icons.checklist;
  return Icons.build_outlined;
}

bool _isSubagentToolName(String n) {
  return n == 'agent' ||
      n == 'task' ||
      n == 'explore' ||
      n.contains('subagent') ||
      n.startsWith('explore');
}

/// 工具调用的目标摘要 (行内灰色补充): 命令首行 / 文件名 / 搜索词 / URL
String? _toolTarget(ToolActivity a) {
  final input = a.input;
  if (input == null) return null;
  String? firstNonEmpty(List<String> keys) {
    for (final k in keys) {
      final v = input[k];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  final n = a.toolName.toLowerCase();
  if (n.contains('bash') || n.contains('shell') || n.contains('terminal')) {
    final cmd = firstNonEmpty(['command', 'cmd', 'script']);
    if (cmd == null) return null;
    final line = cmd.split('\n').first.trim();
    return line.length > 60 ? '${line.substring(0, 60)}…' : line;
  }
  if (n.startsWith('mcp__')) {
    return firstNonEmpty(['query', 'url', 'path', 'name', 'text']);
  }
  if (_isSubagentToolName(n)) {
    return firstNonEmpty(['description', 'prompt', 'query']);
  }
  if (n.contains('grep') || n.contains('glob') || n.contains('search')) {
    return firstNonEmpty(['pattern', 'query', 'q', 'search']);
  }
  if (n.contains('web') || n.contains('fetch') || n.contains('url')) {
    final url = firstNonEmpty(['url', 'link']);
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    return uri?.host ?? url;
  }
  // 文件类与其余: 显示文件名/路径
  final path = firstNonEmpty(['file_path', 'path', 'filename', 'file']);
  if (path != null) {
    final base = path.split('/').last;
    return base.length > 48 ? '…${base.substring(base.length - 47)}' : base;
  }
  return null;
}

/// 工具调用精简单行 (ZCode 风格: 图标 + mono 工具名 + 目标摘要 + 状态,
/// 无独立卡片背景, 点击展开详情)
class _ToolActivityRow extends StatelessWidget {
  final ToolActivity activity;
  final ThemeData theme;
  final Color inkColor;
  final bool expanded;
  final VoidCallback onToggle;

  const _ToolActivityRow({
    required this.activity,
    required this.theme,
    required this.inkColor,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final theme = this.theme;
    final running = a.isRunning;
    final isError = a.status == 'error' || a.status == 'failed';

    final toolLabel = _formatToolName(a.toolName);
    final target = _toolTarget(a);
    final elapsed = a.elapsedMs != null
        ? (a.elapsedMs! >= 60000
            ? _formatWorkDuration(a.elapsedMs!)
            : '${(a.elapsedMs! / 1000).toStringAsFixed(1)}s')
        : null;

    final Widget statusIcon;
    if (a.status == 'pendingApproval') {
      statusIcon = const Icon(
        Icons.hourglass_top,
        size: 12,
        color: AppColors.warning,
      );
    } else if (running) {
      statusIcon = const SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(
          strokeWidth: 1.3,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    } else if (isError) {
      statusIcon = const Icon(
        Icons.close,
        size: 12,
        color: AppColors.danger,
      );
    } else {
      statusIcon = const SizedBox.shrink();
    }

    final hasDetail =
        (a.input != null && a.input!.isNotEmpty) ||
        (a.result != null && a.result!.isNotEmpty);

    final detailBg = theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerLowest
        : theme.colorScheme.surfaceContainerHighest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: hasDetail ? onToggle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            child: Row(
              children: [
                Icon(
                  _iconForTool(a.toolName),
                  size: 14,
                  color: running
                      ? AppColors.accent
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                // mono 工具名 + 目标摘要 (同行, 摘要灰色收缩)
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      text: toolLabel,
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        fontFamily: kMonoFont,
                        color: isError ? AppColors.danger : inkColor,
                      ),
                      children: [
                        if (target != null)
                          TextSpan(
                            text: '  $target',
                            style: TextStyle(
                              fontSize: AppTextSizes.caption,
                              fontFamily: kMonoFont,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const Spacer(),
                const SizedBox(width: 4),
                if (elapsed != null && !running)
                  Text(
                    elapsed,
                    style: TextStyle(
                      fontSize: AppTextSizes.monoXs,
                      fontFamily: kMonoFont,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 4),
                statusIcon,
                if (hasDetail) ...[
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: AppDur.fast,
                    curve: AppEase.inOut,
                    child: Icon(
                      Icons.chevron_right,
                      size: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // 展开详情 (输入参数 + 结果)
        if (expanded && hasDetail) ...[
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 300),
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: detailBg,
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _buildToolDetail(a, theme, inkColor),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 构建工具展开详情 — 根据工具类型智能渲染
  List<Widget> _buildToolDetail(
    ToolActivity a,
    ThemeData theme,
    Color inkColor,
  ) {
    final n = a.toolName.toLowerCase();
    final isBash =
        n.contains('bash') ||
        n.contains('shell') ||
        n.contains('terminal') ||
        n.contains('exec') ||
        n.contains('run');
    final isFileEdit =
        n.contains('edit') ||
        n.contains('write') ||
        n.contains('str_replace') ||
        n.contains('file');

    final children = <Widget>[];

    // 输入参数
    if (a.input != null && a.input!.isNotEmpty) {
      final label = isBash ? '命令' : (isFileEdit ? '文件' : '参数');
      children.add(
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
      children.add(const SizedBox(height: 3));

      // 对于文件类工具, 优先显示 file_path
      if (isFileEdit) {
        for (final key in ['file_path', 'path', 'filename', 'file']) {
          final v = a.input![key];
          if (v is String && v.isNotEmpty) {
            children.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  v.split('/').last,
                  style: TextStyle(
                    fontSize: AppTextSizes.caption,
                    fontFamily: kMonoFont,
                    color: inkColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
            break;
          }
        }
      }

      // 显示参数键值对 (截取重要部分)
      for (final e in a.input!.entries) {
        if (isFileEdit &&
            ['file_path', 'path', 'filename', 'file'].contains(e.key)) {
          continue;
        }
        final valStr = e.value is String
            ? e.value as String
            : e.value.toString();
        // 对长文本参数 (如 new_string/old_string/content), 用代码块显示
        if (valStr.length > 80) {
          children.add(
            Text(
              e.key,
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
          children.add(const SizedBox(height: 2));
          children.add(
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                valStr.length > 500 ? '${valStr.substring(0, 500)}...' : valStr,
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  fontFamily: kMonoFont,
                  color: inkColor,
                  height: 1.4,
                ),
              ),
            ),
          );
        } else {
          children.add(
            Text(
              '${e.key}: $valStr',
              style: TextStyle(
                fontSize: AppTextSizes.caption,
                fontFamily: kMonoFont,
                color: inkColor,
              ),
            ),
          );
        }
        children.add(const SizedBox(height: 2));
      }
    }

    // 结果
    if (a.result != null && a.result!.isNotEmpty) {
      if (a.input != null && a.input!.isNotEmpty) {
        children.add(const SizedBox(height: AppSpacing.xs));
      }
      children.add(
        Text(
          isBash ? '输出' : '结果',
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
      children.add(const SizedBox(height: 3));

      // 检测是否是 diff 格式 (含 +/- 开头的行)
      final resultText = a.result!.length > 800
          ? '${a.result!.substring(0, 800)}...'
          : a.result!;
      final lines = resultText.split('\n');

      children.add(
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lines.map((line) {
              final trimmed = line.trimLeft();
              Color? lineColor;
              if (trimmed.startsWith('+') && !trimmed.startsWith('+++')) {
                lineColor = AppColors.success;
              } else if (trimmed.startsWith('-') &&
                  !trimmed.startsWith('---')) {
                lineColor = AppColors.danger;
              }
              return Text(
                line,
                style: TextStyle(
                  fontSize: AppTextSizes.caption,
                  fontFamily: kMonoFont,
                  color: lineColor ?? inkColor,
                  height: 1.4,
                ),
              );
            }).toList(),
          ),
        ),
      );
    }

    return children;
  }
}

/// 工作时长格式化 (对齐 ZCode 桌面端 Nvt):
/// 秒级取整 (最少 1s), 天/时/分/秒最多保留两个单位。
/// 62000ms → "1 分 2 秒"; 3900000ms → "1 时 5 分"; 45000 → "45 秒"。
String _formatWorkDuration(int ms) {
  final s = (ms / 1000).round();
  if (s < 1) return '1 秒';
  final d = s ~/ 86400;
  final h = (s % 86400) ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final units = <String>[];
  if (d > 0) units.add('$d 天');
  if (h > 0) units.add('$h 时');
  if (m > 0) units.add('$m 分');
  if (sec > 0 || units.isEmpty) units.add('$sec 秒');
  return units.take(2).join(' ');
}

/// 轮次工作状态行 (ZCode 同款, 桌面端 zvt 组件):
/// 运行中 = "工作中 X 分 Y 秒" (实时跳动); 完成 = "已工作 X 分 Y 秒";
/// 无时长数据 = "已处理"。底部发丝线, 可作为折叠历史的开关头。
class _TurnStatusLine extends StatefulWidget {
  final bool running;
  final int? workedMs;
  final DateTime? startedAt;
  final ThemeData theme;
  /// 折叠历史的展开态 (显示旋转箭头); null = 不作为折叠头
  final bool? expanded;
  final VoidCallback? onToggle;

  const _TurnStatusLine({
    required this.running,
    required this.workedMs,
    required this.startedAt,
    required this.theme,
    this.expanded,
    this.onToggle,
  });

  @override
  State<_TurnStatusLine> createState() => _TurnStatusLineState();
}

class _TurnStatusLineState extends State<_TurnStatusLine> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _TurnStatusLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running) _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 运行中且有起点 → 每秒跳动刷新 "工作中 X"
  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (widget.running && widget.startedAt != null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final ms = widget.workedMs ??
        (widget.running && widget.startedAt != null
            ? DateTime.now().difference(widget.startedAt!).inMilliseconds
            : null);
    final duration = ms != null ? _formatWorkDuration(ms) : '';
    final label = widget.running
        ? (duration.isEmpty ? '工作中' : '工作中 $duration')
        : (duration.isEmpty ? '已处理' : '已工作 $duration');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: InkWell(
        onTap: widget.onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTextSizes.label,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (widget.expanded != null) ...[
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: widget.expanded! ? 0.25 : 0,
                  duration: AppDur.fast,
                  curve: AppEase.inOut,
                  child: Icon(
                    Icons.chevron_right,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 轮次历史折叠区 (ZCode "自动隐藏" 机制):
/// 运行中默认展开实时滚动; 完成后自动折叠到状态行后面, 点按可再展开。
/// 手动开关在运行态翻转时重置 (对齐 ZCode defaultOpen 同步)。
class _WorkHistory extends StatefulWidget {
  final DisplayMessage message;
  final ThemeData theme;
  final bool defaultOpen;
  final Widget child;

  const _WorkHistory({
    required this.message,
    required this.theme,
    required this.defaultOpen,
    required this.child,
  });

  @override
  State<_WorkHistory> createState() => _WorkHistoryState();
}

class _WorkHistoryState extends State<_WorkHistory> {
  /// null = 跟随 defaultOpen
  bool? _userOpen;

  @override
  void didUpdateWidget(covariant _WorkHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.defaultOpen != widget.defaultOpen) {
      _userOpen = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _userOpen ?? widget.defaultOpen;
    final tappable = !widget.defaultOpen;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TurnStatusLine(
            running: widget.message.isStreaming,
            workedMs: widget.message.workedMs,
            startedAt: widget.message.turnStartedAt,
            theme: widget.theme,
            expanded: tappable ? open : null,
            onToggle: tappable ? () => setState(() => _userOpen = !open) : null,
          ),
          AnimatedSize(
            duration: AppDur.base,
            curve: AppEase.inOut,
            child: open ? widget.child : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 思考过程折叠块 (ZCode 风格: 可带耗时, 左侧发丝线, 弱化墨色)
class _ThoughtBlock extends StatefulWidget {
  final String thought;
  final ThemeData theme;
  /// 思考耗时 (wire: reasoning.durationMs)
  final int? durationMs;

  const _ThoughtBlock({
    required this.thought,
    required this.theme,
    this.durationMs,
  });

  @override
  State<_ThoughtBlock> createState() => _ThoughtBlockState();
}

class _ThoughtBlockState extends State<_ThoughtBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final duration = widget.durationMs != null
        ? ' · ${_formatWorkDuration(widget.durationMs!)}'
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: AppDur.fast,
                    curve: AppEase.inOut,
                    child: Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '思考过程$duration',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: AppDur.base,
            curve: AppEase.inOut,
            child: _expanded
                ? Container(
                    margin: const EdgeInsets.only(top: AppSpacing.xs),
                    padding: const EdgeInsets.only(left: AppSpacing.sm + 2),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          width: 2,
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                    child: Text(
                      widget.thought,
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 从 data:image/...;base64,... URI 渲染图片
class _DataImage extends StatelessWidget {
  final String dataUri;
  const _DataImage({required this.dataUri});

  @override
  Widget build(BuildContext context) {
    try {
      final commaIdx = dataUri.indexOf(',');
      if (commaIdx < 0) return const SizedBox.shrink();
      final b64 = dataUri.substring(commaIdx + 1);
      final bytes = base64Decode(b64);
      return Image.memory(bytes, fit: BoxFit.cover);
    } catch (e) {
      appLog.d('[Chat] data URI 图片解码失败: $e');
      return const SizedBox.shrink();
    }
  }
}

/// 打字光标动画
class _TypingCursor extends StatefulWidget {
  final Color color;

  const _TypingCursor({required this.color});

  @override
  State<_TypingCursor> createState() => _TypingCursorState();
}

class _TypingCursorState extends State<_TypingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 16,
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 代码块构建器: 带复制按钮 + 语言标签 + 等宽字体
class _CodeBlockBuilder extends MarkdownElementBuilder {
  final ThemeData theme;
  _CodeBlockBuilder({required this.theme});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String code = '';
    String? language;
    final codeNode = element.children?.first;
    if (codeNode is md.Element && codeNode.tag == 'code') {
      code = codeNode.textContent;
      final cls = codeNode.attributes['class'] ?? '';
      final match = RegExp(r'language-(\w+)').firstMatch(cls);
      language = match?.group(1);
    }
    return _CodeBlock(code: code, language: language, theme: theme);
  }
}

/// 代码块 widget: 顶栏(语言+复制+行数) + 语法高亮 + 折叠展开
class _CodeBlock extends StatefulWidget {
  final String code;
  final String? language;
  final ThemeData theme;
  const _CodeBlock({required this.code, this.language, required this.theme});
  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;
  bool _expanded = false;

  /// 超过此行数默认折叠
  static const _collapseThreshold = 15;

  int get _lineCount => '\n'.allMatches(widget.code).length + 1;
  bool get _shouldCollapse => _lineCount > _collapseThreshold;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = theme.brightness == Brightness.dark;
    final showCollapsed = _shouldCollapse && !_expanded;
    // 折叠时只显示前 N 行
    final displayCode = showCollapsed
        ? widget.code.split('\n').take(_collapseThreshold).join('\n')
        : widget.code;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerLowest
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶栏: 语言标签 + 行数 + 复制按钮
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF161719) : const Color(0xFFEFF2F5),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Row(
              children: [
                if (widget.language != null)
                  Text(
                    widget.language!,
                    style: TextStyle(
                      fontSize: AppTextSizes.caption,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 8),
                Text(
                  '$_lineCount 行',
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: _copy,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check : Icons.copy,
                          size: 14,
                          color: _copied
                              ? Colors.green
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? '已复制' : '复制',
                          style: TextStyle(
                            fontSize: AppTextSizes.caption,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 代码内容: 语法高亮 + 横向滚动
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: CodeHighlightView(
              code: displayCode,
              language: widget.language,
              isDark: isDark,
            ),
          ),
          // 折叠/展开按钮
          if (_shouldCollapse)
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _expanded
                          ? '收起'
                          : '展开剩余 ${_lineCount - _collapseThreshold} 行',
                      style: TextStyle(
                        fontSize: AppTextSizes.label,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 历史会话抽屉 (左滑出)
class _HistoryDrawer extends ConsumerStatefulWidget {
  final String workspacePath;
  final String? currentTaskId;
  final ValueChanged<String> onSelected;
  final VoidCallback onNewChat;

  /// 切换工作区 (底部项目切换器)
  final ValueChanged<Workspace> onSwitchWorkspace;

  /// 打开搜索页 (跳转全屏搜索, 合并原顶栏搜索)
  final VoidCallback onOpenSearch;

  /// 新建技能 (跳会话预填 skill-creator 引导)
  final VoidCallback? onNewSkill;

  const _HistoryDrawer({
    required this.workspacePath,
    required this.currentTaskId,
    required this.onSelected,
    required this.onNewChat,
    required this.onSwitchWorkspace,
    required this.onOpenSearch,
    this.onNewSkill,
  });

  @override
  ConsumerState<_HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends ConsumerState<_HistoryDrawer> {
  bool _showArchived = false;

  /// 默认工作区 = 网页端的"不在项目中工作" (路径以 .zcode/workspace/default 结尾)
  static bool _isDefaultWorkspace(Workspace w) =>
      w.workspacePath.endsWith('.zcode/workspace/default');

  /// 长按会话弹出操作菜单 (归档 / 删除)
  ///
  /// 归档通过 zcode-task.archive/unarchive RPC 调用;
  /// 删除为纯客户端操作 (服务器端删除 RPC 尚不可用)。
  void _showTaskActions(BuildContext context, Task task) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      // surfaceContainerHigh 是半透明白叠加 (设计为叠在实色 bg 上),
      // 单独做弹窗背景会透出底层; 叠到 surfaceContainerLowest(=bg 实色) 上得到不透明等价色。
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 会话标题预览
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  task.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const Divider(
              height: 1,
              indent: AppSpacing.lg,
              endIndent: AppSpacing.lg,
            ),
            // 归档 / 取消归档
            ListTile(
              leading: Icon(
                task.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(task.archived ? '取消归档' : '归档'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleArchive(task);
              },
            ),
            // 删除会话 (危险操作, 红色文字)
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.danger,
              ),
              title: const Text(
                '删除会话',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(context, task);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  /// 切换归档状态 (调用 zcode-task.archive/unarchive RPC, 成功后更新 allTasksProvider)
  Future<void> _toggleArchive(Task task) async {
    try {
      await archiveTask(ref, task);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 删除前确认对话框, 确认后从 allTasksProvider 移除 (纯客户端)
  Future<void> _confirmDelete(BuildContext context, Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定要删除「${task.title}」吗?\n此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final tasks = List<Task>.from(ref.read(allTasksProvider));
      tasks.removeWhere((t) => t.id == task.id);
      ref.read(allTasksProvider.notifier).state = tasks;
    }
  }

  /// 时间分组标签: 今天 / 昨天 / 本周 / 更早
  String _timeGroupLabel(DateTime? time) {
    if (time == null) return '更早';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final t = DateTime(time.year, time.month, time.day);
    final diff = today.difference(t).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff < 7) return '本周';
    return '更早';
  }

  /// mono 相对时间 (14:32 / 昨天 / 周二 / 7/20)
  String _formatHistTime(DateTime? time) {
    if (time == null) return '—';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final t = DateTime(time.year, time.month, time.day);
    final diff = today.difference(t).inDays;
    String two(int n) => n.toString().padLeft(2, '0');
    if (diff <= 0) return '${two(time.hour)}:${two(time.minute)}';
    if (diff == 1) return '昨天';
    if (diff < 7) {
      const wd = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      return wd[time.weekday - 1];
    }
    return '${time.month}/${time.day}';
  }

  /// 分组渲染历史列表
  Widget _buildGroupedHistory(ThemeData theme, List<Task> tasks) {
    // 按时间分组 (保持已排序顺序, 分桶)
    final groups = <String, List<Task>>{};
    for (final t in tasks) {
      final label = _timeGroupLabel(t.updatedAt);
      (groups[label] ??= []).add(t);
    }
    // 固定分组顺序
    const order = ['今天', '昨天', '本周', '更早'];
    final ordered = order.where(groups.containsKey);

    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      children: [
        for (final g in ordered) ...[
          AppSectionHeader(title: g),
          for (final task in groups[g]!) _buildHistoryItem(theme, task),
        ],
      ],
    );
  }

  /// 单个对话项 (圆角图标块 + 标题 + mono 时间/状态)
  Widget _buildHistoryItem(ThemeData theme, Task task) {
    final isActive = task.id == widget.currentTaskId;
    final isRunning = task.status == TaskStatus.running;
    final isArchived = task.archived;

    return Opacity(
      opacity: isArchived ? 0.5 : 1.0,
      child: InkWell(
        onTap: () {
          Navigator.pop(context);
          widget.onSelected(task.id);
        },
        onLongPress: () => _showTaskActions(context, task),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 1,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: isActive ? AppColors.accentContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 图标块
              Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: isActive
                      ? AppColors.accent
                      : theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  isRunning
                      ? Icons.autorenew_rounded
                      : Icons.chat_bubble_outline_rounded,
                  size: 14,
                  color: isActive
                      ? Colors.white
                      : (isRunning
                            ? AppColors.warning
                            : theme.colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 标题 + 元信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: AppTextSizes.bodySm,
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (isRunning) ...[
                          _RunningDot(),
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            '运行中',
                            style: AppText.mono(
                              context,
                              size: AppTextSizes.monoXs,
                              color: AppColors.warning,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            '·',
                            style: AppText.mono(
                              context,
                              size: AppTextSizes.monoXs,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.4),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                        ],
                        Text(
                          _formatHistTime(task.updatedAt),
                          style: AppText.mono(
                            context,
                            size: AppTextSizes.monoXs,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 抽屉快捷入口行 (新建任务 / 搜索 / 自动化 / 技能)
  Widget _buildNavItem(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 19,
              color: accent
                  ? AppColors.accent
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.md),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: accent ? AppColors.accent : theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allTasks = ref.watch(allTasksProvider);
    // 根据 _showArchived 过滤任务 (标题搜索已移至全屏搜索页)
    final tasks = allTasks
        .where(
          (t) =>
              t.workspaceKey == widget.workspacePath &&
              t.archived == _showArchived,
        )
        .toList();
    tasks.sort(
      (a, b) => (b.updatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
        a.updatedAt?.millisecondsSinceEpoch ?? 0,
      ),
    );

    return Drawer(
      backgroundColor: theme.brightness == Brightness.dark
          ? AppColors.darkSurfaceElevated
          : AppColors.lightSurface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部: ZCode + 搜索按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Text(
                    'ZCode',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const Spacer(),
                  // 搜索按钮 (跳转全屏搜索页)
                  IconButton(
                    icon: const Icon(Icons.search_rounded, size: 22),
                    tooltip: '搜索',
                    color: theme.colorScheme.onSurfaceVariant,
                    onPressed: () {
                      Navigator.pop(context); // 关抽屉
                      widget.onOpenSearch();
                    },
                  ),
                ],
              ),
            ),
            // 快捷入口: 新建任务 / 搜索 / 自动化 / 技能
            _buildNavItem(
              theme,
              icon: Icons.add_rounded,
              label: '新建任务',
              accent: true,
              onTap: () {
                Navigator.pop(context); // 关抽屉
                widget.onNewChat();
              },
            ),
            _buildNavItem(
              theme,
              icon: Icons.search_rounded,
              label: '搜索',
              onTap: () {
                Navigator.pop(context);
                widget.onOpenSearch();
              },
            ),
            _buildNavItem(
              theme,
              icon: Icons.auto_awesome_rounded,
              label: '技能',
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      SkillsPage(onNewSkill: widget.onNewSkill),
                ));
              },
            ),
            // 对话历史区标题 + 归档切换
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  Text(
                    '对话历史',
                    style: TextStyle(
                      fontSize: AppTextSizes.label,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _showArchived = !_showArchived),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _showArchived
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _showArchived
                                ? Icons.archive
                                : Icons.archive_outlined,
                            size: 13,
                            color: _showArchived
                                ? AppColors.accent
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _showArchived ? '已归档' : '归档',
                            style: TextStyle(
                              fontSize: AppTextSizes.label,
                              color: _showArchived
                                  ? AppColors.accent
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 历史列表 (时间分组, 可滚动)
            Expanded(
              child: tasks.isEmpty
                  ? AppEmptyState(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: _showArchived ? '暂无已归档对话' : '暂无历史对话',
                    )
                  : _buildGroupedHistory(theme, tasks),
            ),
            // 底部固定: 项目切换 + 设置 (对齐网页手机端)
            _buildDrawerBottomBar(theme),
          ],
        ),
      ),
    );
  }

  /// 抽屉底部栏: 左侧项目名 (点击向上弹窗切换项目) + 右侧设置按钮
  Widget _buildDrawerBottomBar(ThemeData theme) {
    final workspaces =
        ref.watch(workspaceListProvider).valueOrNull ?? const <Workspace>[];
    final current = workspaces
        .where((w) => w.workspaceKey == widget.workspacePath)
        .firstOrNull;
    final isDefault = current != null && _isDefaultWorkspace(current);
    final label = current == null
        ? '选择项目'
        : (isDefault ? '不在项目中工作' : current.name);

    return Container(
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? AppColors.darkSurfaceElevated
            : AppColors.lightSurface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          // 项目名 + 切换提示图标
          Expanded(
            child: InkWell(
              onTap: () => _openProjectSwitcher(context, workspaces),
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      isDefault
                          ? Icons.home_work_outlined
                          : Icons.folder_outlined,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: AppTextSizes.bodySm,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    // 向上延伸图标: 提示点击后弹窗向上展开
                    Icon(
                      Icons.keyboard_double_arrow_up_rounded,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 设置按钮
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: '设置',
            style: IconButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: () {
              Navigator.pop(context); // 关抽屉
              context.push('/settings');
            },
          ),
        ],
      ),
    );
  }

  /// 项目切换弹窗 (从抽屉底部向上延伸): 项目列表 + "不在项目中工作"
  void _openProjectSwitcher(BuildContext context, List<Workspace> workspaces) {
    final theme = Theme.of(context);
    // 默认工作区固定最上, 其余按名称排序
    final sorted = [...workspaces]
      ..sort((a, b) {
        final d = (_isDefaultWorkspace(b) ? 1 : 0).compareTo(
          _isDefaultWorkspace(a) ? 1 : 0,
        );
        if (d != 0) return d;
        return a.name.compareTo(b.name);
      });

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Color.alphaBlend(
        theme.colorScheme.surfaceContainerHigh,
        theme.colorScheme.surfaceContainerLowest,
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Text('切换项目', style: theme.textTheme.titleMedium),
              ),
              for (final w in sorted)
                ListTile(
                  dense: true,
                  leading: Icon(
                    _isDefaultWorkspace(w)
                        ? Icons.home_work_outlined
                        : Icons.folder_outlined,
                    size: 20,
                    color: w.workspaceKey == widget.workspacePath
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    _isDefaultWorkspace(w) ? '不在项目中工作' : w.name,
                    style: TextStyle(
                      fontSize: AppTextSizes.bodyMd,
                      fontWeight: w.workspaceKey == widget.workspacePath
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  subtitle: Text(
                    w.workspacePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTextSizes.caption,
                      fontFamily: kMonoFont,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: w.workspaceKey == widget.workspacePath
                      ? Icon(
                          Icons.check_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    Navigator.pop(ctx); // 关切换弹窗
                    Navigator.pop(context); // 关抽屉
                    if (w.workspaceKey != widget.workspacePath) {
                      widget.onSwitchWorkspace(w);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 运行中脉动小点 (历史列表元信息用)
class _RunningDot extends StatefulWidget {
  @override
  State<_RunningDot> createState() => _RunningDotState();
}

class _RunningDotState extends State<_RunningDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: AppDur.slow)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Opacity(
        opacity: 0.3 + 0.7 * _c.value,
        child: Container(
          width: 5,
          height: 5,
          decoration: const BoxDecoration(
            color: AppColors.warning,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
