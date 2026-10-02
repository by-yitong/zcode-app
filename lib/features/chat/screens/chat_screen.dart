import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../../agent/screens/cap_pages.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

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
import '../../../providers/pip_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/app_router.dart';
import '../../../shared/widgets/code_highlight.dart';
import '../../../shared/widgets/update_dialog.dart';
import '../../../shared/widgets/app_empty_state.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../search/screens/search_screen.dart';
import '../widgets/chat_floating_header.dart';
import '../widgets/code_block.dart';
import '../widgets/thought_block.dart';
import '../widgets/approval_cards.dart';
import '../widgets/chat_helpers.dart';
import '../widgets/plan_card.dart';
import '../widgets/plan_list.dart';
import '../widgets/tool_activity.dart';
import '../widgets/work_history.dart';
import '../widgets/composer.dart';
import '../widgets/question_sheet.dart';
import '../widgets/execution_trace.dart';
import '../widgets/running_works.dart';
import '../widgets/message_bubble.dart';
import '../widgets/history_drawer.dart';
import '../../../shared/widgets/reveal_drawer.dart';
import '../../git/screens/git_screen.dart';
import '../../../providers/git_provider.dart' show GitRef;

/// AI 对话页 — 核心交互界面 (实测对接 2026-06-15)
///
/// 数据流: chatProvider(ChatNotifier)
///   - init: 加载历史 (getTaskSnapshot) + 订阅 session 事件
///   - sendMessage: enqueueTaskCommand 入队, AI 回复走 session 事件
///   - session.event: tool.updated = AI 在调工具; 文本流 = 追加到 AI 消息
class ChatScreen extends ConsumerStatefulWidget {
  final String workspaceKey;
  final String? taskId;

  /// 切换项目 (context.replace 重建本页) 后, 新页面首帧自动恢复抽屉 —
  /// 文件级旗标跨路由传递, 用后即清。产品要求: 切项目抽屉不关, 方便选会话。
  static bool keepDrawerOpenOnNextInit = false;

  const ChatScreen({super.key, required this.workspaceKey, this.taskId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  // ⚠️ GlobalKey 必须在 state 里持有 (跨帧稳定), 不能在 build 里 new。
  // 推开式抽屉控制柄 (open/close/isOpen, 见 RevealDrawer)
  final GlobalKey<RevealDrawerState> _revealKey =
      GlobalKey<RevealDrawerState>();
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

  @override
  void initState() {
    super.initState();
    // 切项目 (replace 重建本页) 后首帧直接跳到抽屉全开 — 无动画,
    // 避免"先看到关着再弹开"的闪动; 旗标用后即清
    if (ChatScreen.keepDrawerOpenOnNextInit) {
      ChatScreen.keepDrawerOpenOnNextInit = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealKey.currentState?.openImmediately();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(selectedWorkspaceProvider);
    final title = workspace?.name ?? '对话';
    // 抽屉背景色: HistoryDrawer 与 RevealDrawer.backdropColor 共用同一色,
    // 页面推开后四周露出的底才与抽屉浑然一体 (不出现黑边)
    final drawerBg = Theme.of(context).brightness == Brightness.dark
        ? AppColors.darkSurfaceElevated
        : AppColors.lightSurface;
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
        // 抽屉开着 → 返回键先关抽屉 (不触发双击退出)
        if (_revealKey.currentState?.isOpen == true) {
          _revealKey.currentState?.close();
          return;
        }
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
        // 抽屉改为推开式 reveal (RevealDrawer): 抽屉垫底层从左滑入,
        // 页面被推开缩小; 全屏右滑跟手开 / 点页面关 / 页面左拖跟手关,
        // 消息里表格/代码块横向滚动不受影响 (让路逻辑见 RevealDrawer 注释)。
        body: RevealDrawer(
          key: _revealKey,
          backdropColor: drawerBg,
          drawer: HistoryDrawer(
            backgroundColor: drawerBg,
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
              // 切换项目: 更新选中工作区 + 跳转新工作区聊天页 (新会话)。
              // 抽屉保持打开 (见 keepDrawerOpenOnNextInit), 方便继续选会话
              if (ws.workspaceKey != widget.workspaceKey) {
                ChatScreen.keepDrawerOpenOnNextInit = true;
              }
              ref.read(selectedWorkspaceProvider.notifier).state = ws;
              context.replace(
                '${AppRoutes.chat}?workspace=${Uri.encodeComponent(ws.workspaceKey)}',
              );
            },
            onOpenSearch: _openSearchFromDrawer,
            onClose: () => _revealKey.currentState?.close(),
          ),
          child: _ChatScaffold(
            key: _chatScaffoldKey,
            title: title,
            workspacePath: widget.workspaceKey,
            chatRef: chatRef,
            state: chatState,
            onMenuTap: () {
              FocusManager.instance.primaryFocus?.unfocus();
              _revealKey.currentState?.open();
            },
          ),
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

  // ── 待发送附件 (V4 分片上传, 对齐网页端图片发送) ──
  // 选图后挂 composer 附件条, 发送时逐张上传后随 sendText 引用发出,
  // 不再 base64 嵌入文本。chips 是纯 UI 状态; 上传成功 ref 回填到
  // PendingAttachment.uploadedRef, 失败重试复用不重复上传。
  final List<PendingAttachment> _pendingAttachments = [];
  bool _isUploadingAttachments = false;

  /// 用户是否在底部附近 (= 自动跟随中; 控制"回到底部"悬浮按钮显隐,
  /// 也是流式增长补偿的下限 — 贴底区间交给 reverse 列表天然跟随)。
  bool _isAtBottom = true;

  /// 上一次构建时挂起的权限数 (新增权限 → 自动滚底露出内联审批卡)
  int _lastPendingPermCount = 0;

  /// AI 提问答题弹窗是否打开 (防重复弹出)
  bool _questionSheetOpen = false;

  /// 上一帧是否有挂起的 AI 提问 (null→非空跳变 → 自动弹答题弹窗)
  bool _hadPendingQuestion = false;

  // ── center 锚定双 sliver 列表 ──
  // 消息列表拆成两块: live 块 (center 之前, 最新消息+审批卡, 持续增长) 和
  // older 块 (center sliver, 历史消息, 翻页在尾部追加)。滚动坐标从锚点
  // (两块边界) 向两侧计算: live 增长向负向扩展、翻页向正向扩展 — 已有内容
  // 的坐标永远不变, 用户上翻阅读时流式输出零位移、零补偿、零竞态
  // (反向 ListView 锚定的是列表末端, 底部增长会把阅读内容顶上去, 事后
  // 校正永远慢一帧且要与框架内部重锚定赛跑 — 已废弃)。
  /// center sliver (older 块) 的 key
  final GlobalKey _centerSliverKey = GlobalKey();

  /// older 块最后一条消息 (紧邻锚点) 的 id — 边界一经确定不再移动,
  /// 新消息只进 live 块; 翻页/刷新后按 id 重新解析下标
  String? _boundaryMsgId;

  /// 当前按在列表上的指针数 — 手指未离开时不做贴底跟随
  /// (Hold 窗口/按住不动时 jumpTo 会打断手势起点)
  int _pointerArmed = 0;

  /// 贴底判定阈值: 距底部小于该值视为"跟随中" (悬浮按钮显隐 + 跟随下限)
  static const double _kBottomFollowPx = 60;

  // ── 消息项 widget 缓存 ──
  // provider 每次通知都会重建整个列表; 流式期间未变化的历史消息
  // 若复用同一 widget 实例, Element 会直接跳过该子树 rebuild
  // (含 Markdown 重解析/图片正则提取, 长会话下的主要卡顿来源)。
  final Map<String, Widget> _itemWidgetCache = {};
  final Map<String, String> _itemSigCache = {};

  /// 解析 older 块大小 (bEnd): older = messages[0..bEnd-1], live = 其后。
  /// 边界首次定为"最后一条消息之外的全部" (最后一条通常正在流式);
  /// 边界消息找不到 (rewind/刷新整体替换) 时重置。
  int _resolveBoundaryEnd(int msgCount, List<DisplayMessage> messages) {
    if (msgCount == 0) return 0;
    if (_boundaryMsgId != null) {
      final idx = messages.lastIndexWhere((m) => m.id == _boundaryMsgId);
      if (idx >= 0) return idx + 1;
    }
    // 首次/边界失效: 仅一条消息时全归 live 块 (可能在流式, 增长必须在
    // center 之前才零位移); 两条以上时最后一条归 live, 其余归 older
    if (msgCount == 1) {
      _boundaryMsgId = null;
      return 0;
    }
    _boundaryMsgId = messages[msgCount - 2].id;
    return msgCount - 1;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrollChanged);
    // center 锚定下 offset 0 = 锚点 (列表中部), 不是视觉底部;
    // 缓存会话首帧就有消息 (不触发 didUpdateWidget 的加载完成分支),
    // 首帧后跳到底部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) _jumpToBottom();
    });
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

  /// ★ center 锚定滚动语义: offset 从锚点 (live/older 边界) 起算,
  ///   minScrollExtent (负) = 最新消息端 (视觉底部), max = 最旧消息端。
  ///   - live 块增长只扩展负向, older 块翻页只扩展正向 — 已有内容坐标
  ///     不变, 上翻阅读零位移 (无补偿)
  ///   - 贴底跟随: 内容增长后 min 变小, 跟随中的视口需 jumpTo 新 min
  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final current = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final minScroll = _scrollController.position.minScrollExtent;
    final nearBottom = current - minScroll < _kBottomFollowPx;
    if (nearBottom != _isAtBottom) {
      setState(() => _isAtBottom = nearBottom);
    }
    // 上翻接近最旧一端 → 预载更早历史 (loadOlder 自带并发/hasMore 守卫)
    if (maxScroll - current < 400 && !widget.state.isLoadingHistory) {
      unawaited(ref.read(chatProvider(widget.chatRef).notifier).loadOlder());
    }
  }

  /// extent 变化帧的唯一动作: 贴底跟随。
  /// 内容增长后 minScrollExtent 变小, 视口与新底的距離被拉开 — 不能用
  /// "当前距底 <60px" 判断 (增长后必然超阈值), 要用增长前的跟随状态
  /// (_isAtBottom 由滚动监听维护, 只在用户主动滚动时翻转)。
  /// ★ 只在完全静止时跟随: jumpTo 会杀掉进行中的拖拽/惯性活动 —
  /// 流式期间若在用户上滑时跳底, 手势每 125ms 被拽回一次, 列表等于锁死。
  bool _handleMetricsChanged(ScrollMetricsNotification n) {
    if (!mounted || !_scrollController.hasClients) return false;
    if (_pointerArmed > 0) return false; // 手指按住 (含 Hold 窗口)
    if (_scrollController.position.isScrollingNotifier.value) return false;
    if (!_isAtBottom) return false;
    final pos = _scrollController.position;
    if (pos.minScrollExtent.isFinite) {
      pos.jumpTo(pos.minScrollExtent);
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant _ChatScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换会话: 消息列表整体替换, 边界重置
    if (oldWidget.chatRef != widget.chatRef) {
      _boundaryMsgId = null;
    }
    final newCount = widget.state.messages.length;
    final oldCount = oldWidget.state.messages.length;

    // 历史加载完成 / 消息从空变非空: 首次进入确保在底部
    // (center 锚定初始 offset 0 = 锚点边界, 需跳到 min 才是视觉底部)
    if ((oldWidget.state.isLoadingHistory && !widget.state.isLoadingHistory) ||
        (oldCount == 0 && newCount > 0)) {
      if (oldCount == 0 || _isAtBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
      }
      _continueIfNoScrollSpace();
    }
  }

  /// 打开悬浮窗进度监视器 (画中画, 仅 Android):
  /// 主体抽到 pip_providers.openPipOverlay (进后台自动打开同源复用);
  /// 打开成功后 app 自动退到后台 — 用户开小窗就是为了在其他 app 上用。
  /// 权限被拒 → 跳系统设置引导 (仅手动路径; 自动打开路径静默跳过)。
  Future<void> _openPipOverlay() async {
    if (!Platform.isAndroid) return;
    final pip = ref.read(pipServiceProvider);
    final result = await ref.read(
      pipOpenOverlayProvider,
    )(pinTaskId: widget.chatRef.taskId);
    switch (result) {
      case PipOpenResult.permissionDenied:
        appLog.d('[Pip] 无悬浮窗权限 → 跳系统设置');
        await pip.requestPermission();
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('请先在 系统设置 → 应用 → ZCode → 显示其他应用上层 开启悬浮窗权限后重试'),
              duration: Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
            ),
          );
      case PipOpenResult.failed:
        appLog.w('[Pip] showOverlay 失败');
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('悬浮窗启动失败'),
              behavior: SnackBarBehavior.floating,
            ),
          );
      case PipOpenResult.opened:
      case PipOpenResult.alreadyActive:
        // 已打开时 openPipOverlay 内部已恢复展开 — 用户点按钮的意图就是
        // "要小窗去别处用", 两种结果都退后台
        await pip.moveToBackground();
    }
  }

  /// 打开 AI 提问答题弹窗 (已打开或无挂起问题时直接返回)。
  /// 关闭后仅复位标志, 不自动重弹 (由状态跳变或用户点提示条重新触发)。
  void _openQuestionSheet(ThemeData theme) {
    if (!mounted || _questionSheetOpen) return;
    final q = widget.state.pendingQuestion;
    if (q == null) return;
    _questionSheetOpen = true;
    showQuestionSheet(
      context,
      question: q,
      theme: theme,
      onAnswer:
          ({
            decline = false,
            selectedValues = const {},
            customAnswers = const {},
          }) {
            ref
                .read(chatProvider(widget.chatRef).notifier)
                .answerQuestion(
                  decline: decline,
                  selectedValues: selectedValues,
                  customAnswers: customAnswers,
                );
          },
    ).whenComplete(() {
      _questionSheetOpen = false;
    });
  }

  /// 翻页死区兜底: 一页内容不足一屏时 maxScrollExtent==0, 永远产生不了
  /// 滚动事件 → 渐进模式卡在第一页。布局后检查, 无滚动空间就主动续拉
  /// (loadOlder 自带 hasMore/并发守卫, 拉完自然停止)。
  void _continueIfNoScrollSpace() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent <= 0 &&
          !widget.state.isLoadingHistory &&
          widget.state.messages.isNotEmpty) {
        unawaited(ref.read(chatProvider(widget.chatRef).notifier).loadOlder());
      }
    });
  }

  void _sendMessage() {
    if (_isUploadingAttachments) return; // 上传中禁发 (composer 已禁用)
    final text = _messageController.text.trim();
    if (text.isEmpty && _pendingAttachments.isEmpty) return;
    // 任务运行中不禁发 — followupMode=queue, 服务端会排队 (队列条可管理)

    // 不 await, 让 UI 立即响应; 错误由 chatProvider 状态反映
    if (_pendingAttachments.isEmpty) {
      // 无附件: 走原路径, payload 与现状完全一致
      ref.read(chatProvider(widget.chatRef).notifier).sendMessage(text);
      _messageController.clear();
      _scrollToBottom();
      return;
    }
    // 带附件: composer 立即清空并禁用, chips 进度态; 上传中乐观回显
    // (文本立即显示, 图片位置显示本地缩略图) 由 provider 侧处理
    final attachments = List<PendingAttachment>.of(_pendingAttachments);
    setState(() {
      _isUploadingAttachments = true;
      _messageController.clear();
    });
    _scrollToBottom();
    unawaited(_sendWithAttachments(text, attachments));
  }

  /// 逐张上传后一条 sendText 发出; 失败 → SnackBar + chips 保留
  /// (已上传 ref 回填复用), 用户可重试或移除, 不降级 base64
  Future<void> _sendWithAttachments(
    String text,
    List<PendingAttachment> attachments,
  ) async {
    var sent = false;
    var refs = const <String?>[];
    try {
      (sent, refs) = await ref
          .read(chatProvider(widget.chatRef).notifier)
          .sendMessageWithAttachments(text, attachments);
    } catch (e) {
      // notifier 已销毁等极端场景 (上传中途离开会话页): 静默, 不再回填
      appLog.w('[Chat] 附件发送流程异常: $e');
    }
    if (!mounted) return;
    setState(() {
      _isUploadingAttachments = false;
      if (sent) {
        _pendingAttachments.clear();
      } else {
        // 回填已成功上传的 ref (失败重试免重复上传)
        for (var i = 0; i < attachments.length && i < refs.length; i++) {
          final ref = refs[i];
          if (ref == null || ref.isEmpty) continue;
          _pendingAttachments[i] = _pendingAttachments[i].copyWith(
            uploadedRef: ref,
          );
        }
      }
    });
    if (!sent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('图片上传失败'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 底部 = minScrollExtent (center 锚定下为负值, 随 live 块增长而变)
  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.minScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.minScrollExtent);
  }

  /// 构建单个消息项 — 稳定项复用缓存 widget 实例。
  ///
  /// provider 每次通知都会重跑整个 build; 若消息未变 (签名一致) 直接返回
  /// 上次的 widget 实例, Element 判定 identical 后会整棵跳过 rebuild
  /// (省掉 Markdown 重解析 + data-URI 图片正则提取, 这是长会话的主要开销)。
  /// 流式中的消息内容持续变化, 不走缓存。
  Widget _buildMessageItem(
    ChatState state,
    int index,
    ThemeData theme,
    int lastUserIndex,
  ) {
    final msg = state.messages[index];
    // 压缩标记: 居中药丸, 不走消息气泡
    if (msg.role == 'marker') {
      // ★ 稳定 Key: 头部插入 (翻页) / 尾部增删 (占位) 时防止 index 错位
      //   导致 Element 复用错对象 (折叠 State 串位 → 高度突变 → 滚动抽搐)
      return KeyedSubtree(
        key: ValueKey('marker_${msg.id}'),
        child: CompactMarkerPill(label: msg.content, running: msg.isStreaming),
      );
    }
    // 日期分组: 第一条(视觉最顶)或日期变化时插入分隔线
    final showDateSeparator =
        index == 0 ||
        !isSameDay(state.messages[index - 1].createdAt, msg.createdAt);
    final isLastUserMessage = msg.role == 'user' && index == lastUserIndex;
    final planPermission = state.pendingPermissions
        .where(
          (p) => p.toolName == 'ExitPlanMode' || p.toolName == 'switch_mode',
        )
        .firstOrNull;

    Widget build() => Column(
      key: ValueKey('msg_${msg.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showDateSeparator) DateSeparator(date: msg.createdAt),
        MessageBubble(
          message: msg,
          theme: theme,
          isLastUserMessage: isLastUserMessage,
          isResponding: state.isResponding,
          planPermission: planPermission,
          subagentLoader: (childSessionId) => ref
              .read(chatProvider(widget.chatRef).notifier)
              .loadSubagentChildren(childSessionId),
          // 子代理详情弹窗实时刷新 (强刷 children + 权威行状态)
          subagentLiveRefresh: (childSessionId) => ref
              .read(chatProvider(widget.chatRef).notifier)
              .refreshSubagentDetail(childSessionId),
          // 附件图片读回 (V4 ref → bytes, provider 侧 32MB 缓存)
          attachmentLoader: (attachmentRef) => ref
              .read(chatProvider(widget.chatRef).notifier)
              .loadAttachmentBytes(attachmentRef),
          onRespondPermission:
              (permissionId, optionId, decision, options, traceId) {
                ref
                    .read(chatProvider(widget.chatRef).notifier)
                    .answerPermission(
                      permissionId,
                      optionId,
                      decision,
                      permOptions: options,
                      permTraceId: traceId,
                    );
              },
          // ★ 编辑只给最后一条用户消息 (对齐网页端
          //   actions.canEdit 的行为, 历史消息不可编辑)
          onEdit: isLastUserMessage
              ? (text) => ref
                    .read(chatProvider(widget.chatRef).notifier)
                    .editLastUserMessage(text)
              : null,
          onRewind: () =>
              ref.read(chatProvider(widget.chatRef).notifier).rewindLastTurn(),
          // ★ 工作区路径 (markdown 文件链接 / 变更文件条目 → 预览页)
          workspacePath: widget.workspacePath,
        ),
      ],
    );

    if (msg.isStreaming) return build();

    // 签名只纳入该消息真正消费的字段:
    // - isResponding 只有最后一条用户消息消费 (撤销按钮显示);
    // - planPermission 只有含 plan 工具的消息渲染。
    // 否则发送/完成/权限出现瞬间, 视口内所有消息签名同时失效, 整屏重建。
    final hasPlanContent =
        msg.role == 'assistant' &&
        (msg.activities.any(isPlanTool) ||
            msg.parts.any((p) => p is ToolPart && isPlanTool(p.activity)));
    final sig = _msgSig(
      msg,
      showDate: showDateSeparator,
      isLastUser: isLastUserMessage,
      isResponding: isLastUserMessage && state.isResponding,
      permId: hasPlanContent ? planPermission?.id ?? '' : '',
      vpW: MediaQuery.sizeOf(context).width,
    );
    if (_itemSigCache[msg.id] == sig && _itemWidgetCache.containsKey(msg.id)) {
      return _itemWidgetCache[msg.id]!;
    }
    final w = build();
    // 缓存膨胀 (rewind 删除/长会话) → 剔除已不在列表里的条目。
    // 不整体 clear: 那会让视口内全部 item 同帧重建, 造成偶发卡顿尖峰。
    if (_itemWidgetCache.length > state.messages.length + 80) {
      final live = state.messages.map((m) => m.id).toSet();
      _itemWidgetCache.removeWhere((k, _) => !live.contains(k));
      _itemSigCache.removeWhere((k, _) => !live.contains(k));
    }
    _itemWidgetCache[msg.id] = w;
    _itemSigCache[msg.id] = sig;
    return w;
  }

  /// 消息项缓存的轻量签名: 覆盖所有影响渲染的字段。
  /// 文本用 length 代替全文比较 — 只变内容不变长度的情况仅存在于流式
  /// 追加过程中, 而流式消息不入缓存, 因此安全。
  String _msgSig(
    DisplayMessage m, {
    required bool showDate,
    required bool isLastUser,
    required bool isResponding,
    required String permId,
    required double vpW,
  }) {
    final b = StringBuffer(
      '${m.role}|${m.content.length}|'
      '${m.thought?.length ?? -1}|${m.model ?? ''}|'
      '${m.isStreaming ? 1 : 0}${m.interrupted ? 'i' : ''}|'
      '${m.workedMs ?? -1}|${m.turnStartedAt?.millisecondsSinceEpoch ?? -1}|'
      '${m.createdAt.millisecondsSinceEpoch}|'
      '${m.fileChanges?.files ?? -1},${m.fileChanges?.additions ?? -1},'
      '${m.fileChanges?.deletions ?? -1}|$showDate|$isLastUser|'
      '$isResponding|$permId|${vpW.round()}',
    );
    // 附件 (ref 变化 = 读回数据源变化; localBytes 有无决定乐观/读回渲染)
    for (final a in m.attachments) {
      b.write(
        '|img${a.ref.length}:${a.localBytes != null ? 1 : 0}'
        ':${a.bytes}:${a.fileName.length}',
      );
    }
    for (final p in m.parts) {
      switch (p) {
        case TextPart(:final text):
          b.write('|t${text.length}');
        case ThoughtPart(:final text, :final durationMs):
          b.write('|h${text.length}d$durationMs');
        case ToolPart(:final activity):
          b.write(
            '|w${activity.status},${activity.result?.length ?? -1},'
            '${activity.elapsedMs ?? -1},${activity.input?.length ?? -1}',
          );
        case StepPart(:final isStart):
          b.write('|s$isStart');
        case SubagentPart(:final status, :final summaryText):
          b.write('|a$status,${summaryText.length}');
      }
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;

    // 最后一条用户消息位置: build 里算一次。
    // (原实现每条消息都向后扫描剩余列表判断, O(n²), 长会话明显卡顿)
    final lastUserIndex = state.messages.lastIndexWhere(
      (m) => m.role == 'user',
    );

    // 非 plan 权限 (ExitPlanMode/switch_mode 的按钮在 plan 卡片里) → 列表尾内联审批卡
    final nonPlanPerms = state.pendingPermissions
        .where(
          (p) => p.toolName != 'ExitPlanMode' && p.toolName != 'switch_mode',
        )
        .toList();

    // center 锚定边界: older 块 = messages[0..bEnd-1], live 块 = 其后
    final bEnd = _resolveBoundaryEnd(state.messages.length, state.messages);

    // ★ 权限挂起 → 内联审批卡出现在列表尾部 (非 plan) / plan 卡片内 (ExitPlanMode)
    // 新权限到来时自动滚到底部露出审批卡, 不再弹模态弹窗遮挡聊天上下文
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final n = state.pendingPermissions.length;
      if (n > _lastPendingPermCount && _scrollController.hasClients) {
        _scrollToBottom();
      }
      _lastPendingPermCount = n;
      // AI 提问: null→非空自动弹答题弹窗; 变 null 且弹窗开着 → 关闭
      final hasQ = state.pendingQuestion != null;
      if (hasQ && !_hadPendingQuestion) {
        _openQuestionSheet(Theme.of(context));
      } else if (!hasQ && _questionSheetOpen) {
        Navigator.of(context).maybePop();
      }
      _hadPendingQuestion = hasQ;
    });

    return Scaffold(
      extendBodyBehindAppBar: true,
      // 三段式悬浮胶囊 Header: [返回=抽屉] [标题+状态行] [更多]
      appBar: ChatFloatingHeader(
        title: widget.title,
        // 上下文环移入中间胶囊 (新对话还没有内容时不显示)
        contextIndicator: state.messages.isNotEmpty
            ? ContextLengthIndicator(
                usage: state.tokenUsage,
                onCompact: () =>
                    ref.read(chatProvider(widget.chatRef).notifier).compact(),
              )
            : null,
        // 状态行: 常驻用量统计 (AI 工作中状态在消息流里已有体现)
        // 点击 → 用量详情底部表
        usagePill: UsagePill(
          tokenUsage: state.tokenUsage,
          glmQuotaAsync: ref.watch(glmQuotaProvider),
          onRefreshQuota: () => ref.read(glmQuotaProvider.notifier).refresh(),
        ),
        onMenuTap: widget.onMenuTap,
        onNewChat: () {
          // 跳回不带 task 的聊天页 (replace: 原地替换, 保持返回栈)
          context.replace(
            '${AppRoutes.chat}?workspace=${Uri.encodeComponent(widget.workspacePath)}',
          );
        },
        // 悬浮窗进度监视器 (画中画; flutter_overlay_window 仅 Android)
        onOpenPip: Platform.isAndroid ? _openPipOverlay : null,
        // Git 工具全屏页 (查看更改/分支/历史/提交/推送)
        onOpenGit: () {
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => GitScreen(
                gitRef: GitRef(
                  workspacePath: widget.workspacePath,
                  workspaceIdentity: widget.chatRef.workspaceIdentity,
                ),
              ),
            ),
          );
        },
        onOpenSettings: () => context.push(AppRoutes.settings),
      ),
      // 内容可穿过顶部: 无占位块, 消息列表从 y=0 起滚, 从三枚胶囊的空隙
      // 与毛玻璃后穿过; 顶部渐变把穿过内容淡出 (胶囊由 appBar 层盖在渐变上)。
      body: Stack(
        children: [
          Column(
            children: [
              // 连接状态条 (非 ready 时显示) — 显示时下移到胶囊栏之下
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
                return Padding(
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 64,
                  ),
                  child: Container(
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
              return Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 64,
                ),
                child: Container(
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
                ),
              );
            },
          ),
              if (state.error != null)
                Padding(
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 64,
                  ),
                  child: ErrorBanner(
                    message: state.error!,
                    theme: theme,
                    onRetry: () => ref
                        .read(chatProvider(widget.chatRef).notifier)
                        .reloadHistory(),
                  ),
                ),
              // plan 提议批准卡 (AI 调 ExitPlanMode, 等用户批准/拒绝)
              if (state.pendingPlan != null)
                Padding(
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 64,
                  ),
                  child: PlanApprovalCard(
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
                ),
          // 工具执行前确认 → 列表尾部内联审批卡 (聊天上下文全程可见, 不再模态遮挡)
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
                            Positioned(
                              top: MediaQuery.of(context).padding.top + 64,
                              left: 0,
                              right: 0,
                              child: LinearProgressIndicator(
                                minHeight: 2,
                                backgroundColor: Colors.transparent,
                              ),
                            ),
                          NotificationListener<ScrollMetricsNotification>(
                            onNotification: _handleMetricsChanged,
                            child: Listener(
                              // 手指按下期间不做贴底跟随 (jumpTo 会打断手势)
                              onPointerDown: (_) => _pointerArmed++,
                              onPointerUp: (_) => _pointerArmed =
                                  _pointerArmed > 0 ? _pointerArmed - 1 : 0,
                              onPointerCancel: (_) => _pointerArmed =
                                  _pointerArmed > 0 ? _pointerArmed - 1 : 0,
                              child: CustomScrollView(
                                controller: _scrollController,
                                // ★ center 锚定双 sliver (见字段组注释):
                                // reverse 下 sliver 顺序 视觉底帽 → live 块 →
                                // center(older 块) → 视觉顶帽。live 增长向负向
                                // (视觉下方) 扩展坐标, older 翻页向正向扩展 —
                                // 已有内容坐标永不变化, 上翻阅读时流式输出零位移;
                                // 贴底跟随由 metrics 通知 jumpTo min。
                                reverse: true,
                                center: _centerSliverKey,
                                slivers: [
                                  // 视觉最底留白 (负向末端)
                                  const SliverToBoxAdapter(
                                    child: SizedBox(height: AppSpacing.sm),
                                  ),
                                  // live 块: index 0 = 边界消息 (块顶, 紧邻锚点),
                                  // 递增到最新消息, 审批卡在块尾 (视觉最底)
                                  SliverPadding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    sliver: SliverList(
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                          final liveCount =
                                              state.messages.length - bEnd;
                                          if (index < liveCount) {
                                            final msgIndex = bEnd + index;
                                            final msg =
                                                state.messages[msgIndex];
                                            return KeyedSubtree(
                                              key: ValueKey(msg.id),
                                              child: _buildMessageItem(
                                                state,
                                                msgIndex,
                                                theme,
                                                lastUserIndex,
                                              ),
                                            );
                                          }
                                          final perm =
                                              nonPlanPerms[index - liveCount];
                                          return KeyedSubtree(
                                            key: ValueKey('perm_${perm.id}'),
                                            child: ApprovalCard(
                                              perm: perm,
                                              theme: theme,
                                              onAnswer: (optionId, decision) =>
                                                  ref
                                                      .read(
                                                        chatProvider(
                                                          widget.chatRef,
                                                        ).notifier,
                                                      )
                                                      .answerPermission(
                                                        perm.id,
                                                        optionId,
                                                        decision,
                                                        permOptions:
                                                            perm.options,
                                                        permTraceId:
                                                            perm.traceId,
                                                      ),
                                            ),
                                          );
                                        },
                                        childCount:
                                            state.messages.length -
                                            bEnd +
                                            nonPlanPerms.length,
                                        addAutomaticKeepAlives: false,
                                      ),
                                    ),
                                  ),
                                  // older 块 = center: index 0 = 最新的老消息
                                  // (紧邻锚点), 递增到最旧; 翻页在尾部追加
                                  SliverPadding(
                                    key: _centerSliverKey,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    sliver: SliverList(
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                          final msgIndex = bEnd - 1 - index;
                                          final msg = state.messages[msgIndex];
                                          return KeyedSubtree(
                                            key: ValueKey(msg.id),
                                            child: _buildMessageItem(
                                              state,
                                              msgIndex,
                                              theme,
                                              lastUserIndex,
                                            ),
                                          );
                                        },
                                        childCount: bEnd,
                                        addAutomaticKeepAlives: false,
                                      ),
                                    ),
                                  ),
                                  // 视觉最顶留白 (正向末端) — 加高到胶囊栏下,
                                  // 翻到最旧消息时第一条不被悬浮头部遮挡
                                  SliverToBoxAdapter(
                                    child: SizedBox(
                                      height:
                                          AppSpacing.sm +
                                          MediaQuery.of(context).padding.top +
                                          64,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // 滚动到底部悬浮按钮: 不在底部时显示
                          if (!_isAtBottom)
                            Positioned(
                              bottom: AppSpacing.sm,
                              right: 12,
                              child: ScrollToBottomButton(
                                onPressed: _scrollToBottom,
                                hasNewContent: state.isResponding,
                              ),
                            ),
                        ],
                      ),
                // 浮动: Todo 计划面板 (叠加在消息列表上方, 展开/收起不影响列表滚动)
                // 内容可穿过顶部: 面板下移到胶囊栏之下
                if (state.plan.isNotEmpty)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 64,
                    left: 0,
                    right: 0,
                    child: PlanList(
                      plan: state.plan,
                      theme: theme,
                      isResponding: state.isResponding,
                    ),
                  ),
              ],
            ),
          ),
          // 待确认提示条: 用户滚走后仍固定可见, 点击定位回审批卡
          if (nonPlanPerms.isNotEmpty)
            PendingApprovalBar(
              count: nonPlanPerms.length,
              onTap: _scrollToBottom,
            ),
          // AI 提问提示条: 挂起时常驻输入栏上方, 点击弹出答题弹窗
          if (state.pendingQuestion != null)
            QuestionPendingBar(onTap: () => _openQuestionSheet(theme)),
          // 后台运行指示条: 运行中子智能体 / 后台终端 >0 时常驻输入栏上方,
          // 点击弹清单面板 (子智能体进详情, 后台终端可取消)
          Builder(
            builder: (context) {
              final runningSubs = runningSubagentsIn(state.messages);
              final bashWorks = state.backgroundWorks
                  .where((w) => w.kind == 'bash' && w.status == 'running')
                  .toList();
              if (runningSubs.isEmpty && bashWorks.isEmpty) {
                return const SizedBox.shrink();
              }
              // 胶囊自带入场动画, 常驻与消失由这里直接增删 (短内容, 无需 AnimatedSize)
              return Padding(
                padding: const EdgeInsets.only(
                  bottom: AppSpacing.sm - 2,
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                ),
                child: RunningWorkBar(
                  subagentCount: runningSubs.length,
                  bashCount: bashWorks.length,
                  onTap: () => showRunningWorksSheet(
                    context,
                    theme: theme,
                    subagents: runningSubs,
                    bashWorks: bashWorks,
                    onOpenSubagent: (part) {
                      if (!mounted) return;
                      // 先关清单弹窗, 再从该 SubagentPart 构建详情弹窗
                      Navigator.of(context).pop();
                      final nodes = buildExecutionNodes([part]);
                      if (nodes.isEmpty) return;
                      showExecutionDetail(
                        context,
                        nodes.first,
                        theme,
                        onLoadChildren: (childSessionId) => ref
                            .read(chatProvider(widget.chatRef).notifier)
                            .loadSubagentChildren(childSessionId),
                        onLiveRefresh: (childSessionId) => ref
                            .read(chatProvider(widget.chatRef).notifier)
                            .refreshSubagentDetail(childSessionId),
                      );
                    },
                    onCancelBash: (work) => ref
                        .read(chatProvider(widget.chatRef).notifier)
                        .cancelBackgroundWork(work.workId),
                  ),
                ),
              );
            },
          ),
          _buildInputArea(theme),
        ],
      ),
          // 顶部渐变: 穿过胶囊区的内容淡出到背景色 (IgnorePointer 放行点击)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).padding.top + 76,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Theme.of(context).scaffoldBackgroundColor,
                      Theme.of(
                        context,
                      ).scaffoldBackgroundColor.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 消息加载骨架屏
  Widget _buildSkeleton(ThemeData theme) {
    final shimmerColor = theme.colorScheme.surfaceContainerHighest;
    // 内容可穿过顶部: 骨架从胶囊栏下开始
    final topInset =
        AppSpacing.sm + MediaQuery.of(context).padding.top + 64;
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
    // 内容可穿过顶部: 空态垂直居中时避开胶囊栏
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 64),
      child: Center(
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
        // 整个 composer 是一个圆角卡片 (深灰填充, 无边框)
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.lg),
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
              // 待发送附件条 (选图后累积, 发送时 V4 分片上传)
              if (_pendingAttachments.isNotEmpty) _buildAttachmentStrip(),
              // 排队消息 (任务运行中发送 → 服务端排队): 立即/编辑/删除
              if (widget.state.queuedMessages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final q in widget.state.queuedMessages)
                        QueuedMessageRow(
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
                    child: MentionOverlay(
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
                  // 输入框 (无边框, 透明, 自适应高度); 附件上传中禁用 composer
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      focusNode: _inputFocusNode,
                      enabled: !_isUploadingAttachments,
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
                      final canSend =
                          (hasText || _pendingAttachments.isNotEmpty) &&
                          !_isUploadingAttachments;
                      // 有文字或挂了附件 = 发送 (任务运行中发送会进入服务端队列);
                      // 无内容且任务运行中 = 暂停
                      final showStop =
                          widget.state.isResponding &&
                          !hasText &&
                          _pendingAttachments.isEmpty &&
                          !_isUploadingAttachments;
                      return showStop
                          ? ComposerSendButton(
                              icon: Icons.stop_rounded,
                              onPressed: () => notifier.stopResponding(),
                              enabled: true,
                              isStop: true,
                            )
                          : ComposerSendButton(
                              icon: Icons.arrow_upward_rounded,
                              onPressed: canSend ? _sendMessage : null,
                              enabled: canSend,
                            );
                    },
                  ),
                ],
              ),
              // 工具栏 (输入框内底部一行, 对齐网页端):
              // 左: + 功能 | 执行模式        右: 思考级别 | 模型
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Row(
                  children: [
                    // + 功能菜单 (附件/提及/指令)
                    ComposerIconBtn(
                      icon: Icons.add_rounded,
                      tooltip: '附件 / 功能',
                      onTap: _showPlusMenu,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    // 模式选择器 (变更前确认/计划模式/自动编辑) — 图标随模式变化
                    ModeSelector(
                      mode: widget.state.mode,
                      onChanged: (m) => notifier.setMode(m),
                    ),
                    const Spacer(),
                    // 思考级别选择器 — 级别中文名 chip (上下文环已移至顶部 Header)
                    ThoughtLevelSelector(
                      level: widget.state.thoughtLevel,
                      onChanged: (l) => notifier.setThoughtLevel(l),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    // 模型选择器 — 模型名文本 chip
                    ModelSelector(
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
      TextPosition(offset: _messageController.text.length),
    );
  }

  void openSearch() {
    // 收起键盘: 避免从搜索页/弹层返回时, 输入框残留焦点导致键盘再次自动弹起
    FocusManager.instance.primaryFocus?.unfocus();
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
  void _runCommand(SlashCommand cmd) {
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
    FocusManager.instance.primaryFocus?.unfocus();
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
                    PlusMenuItem(
                      icon: Icons.image_outlined,
                      label: '图片',
                      color: AppColors.accent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertImage();
                      },
                    ),
                    PlusMenuItem(
                      icon: Icons.description_outlined,
                      label: '文件',
                      color: AppColors.success,
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertFileMention();
                      },
                    ),
                    PlusMenuItem(
                      icon: Icons.alternate_email,
                      label: '@文件',
                      color: const Color(0xFFF59E0B),
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertAtCursor('@');
                      },
                    ),
                    PlusMenuItem(
                      icon: Icons.tag,
                      label: '#会话',
                      color: const Color(0xFF8B5CF6),
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertAtCursor('#');
                      },
                    ),
                    PlusMenuItem(
                      icon: Icons.bolt_outlined,
                      label: r'$技能',
                      color: const Color(0xFFFBBF24),
                      onTap: () {
                        Navigator.pop(ctx);
                        _insertAtCursor(r'$');
                      },
                    ),
                    PlusMenuItem(
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
      final cmd = slashCommands.where((c) => c.name == insertText).firstOrNull;
      if (cmd != null) {
        _messageController.clear();
        _runCommand(cmd);
      }
    }
  }

  /// 内置 + 服务端命令合并表 (供面板过滤/选中分发)
  List<SlashCommand> get _mergedSlashCommands {
    final builtinNames = slashCommands.map((c) => c.name.substring(1)).toSet();
    final skills = ref.read(skillsProvider).valueOrNull ?? const <SkillItem>[];
    final server =
        (ref.read(serverSlashCommandsProvider).valueOrNull ?? const <String>[])
            .where((s) => !builtinNames.contains(s))
            .map((s) {
              final skill = skills.where((sk) => sk.name == s).firstOrNull;
              return SlashCommand('/$s', skill?.description ?? '服务端命令');
            })
            .toList();
    return [...slashCommands, ...server];
  }

  /// 选图 → 压缩 (1920px/75%) → 挂 composer 待发送附件条。
  /// 不再 base64 嵌入文本: 发送时走 V4 分片上传 (对齐网页端),
  /// sendText 只带 ref 引用。
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
    // 检查大小 (> 2MB 压缩后仍太大 → 拒绝, 避免分片上传拖慢发送)
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

    final ext = xfile.name.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    setState(() {
      _pendingAttachments.add(
        PendingAttachment(fileName: xfile.name, mime: mime, bytes: bytes),
      );
    });
  }

  /// composer 上方附件条: 横向缩略图 chip (缩略图 + 文件名 + × 移除),
  /// 可连续选多张累积; 上传中整条转进度态且禁移除
  Widget _buildAttachmentStrip() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pendingAttachments.length,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.xs),
          itemBuilder: (context, i) {
            final a = _pendingAttachments[i];
            return _AttachmentChip(
              attachment: a,
              uploading: _isUploadingAttachments,
              onRemove: _isUploadingAttachments
                  ? null
                  : () => setState(() => _pendingAttachments.removeAt(i)),
            );
          },
        ),
      ),
    );
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
    FocusManager.instance.primaryFocus?.unfocus();
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
    FocusManager.instance.primaryFocus?.unfocus();
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
    FocusManager.instance.primaryFocus?.unfocus();
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
                  itemCount: slashCommands.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.3,
                    ),
                  ),
                  itemBuilder: (ctx, index) {
                    final cmd = slashCommands[index];
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

/// 附件条缩略图 chip (56px 高, 圆角): 缩略图 + 文件名省略号 + 右上角 × 移除;
/// 上传中转进度态 (半透明 + 转圈), 禁移除
class _AttachmentChip extends StatelessWidget {
  final PendingAttachment attachment;
  final bool uploading;
  final VoidCallback? onRemove;

  const _AttachmentChip({
    required this.attachment,
    required this.uploading,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 168,
          height: 56,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            children: [
              // 缩略图 (选图时内存里已有 bytes)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xs),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Image.memory(
                    attachment.bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Opacity(
                  opacity: uploading ? 0.55 : 1,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attachment.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTextSizes.label,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (uploading)
                            const SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                              ),
                            )
                          else
                            Icon(
                              attachment.uploadedRef != null
                                  ? Icons.check_circle_outline
                                  : Icons.image_outlined,
                              size: 11,
                              color: attachment.uploadedRef != null
                                  ? AppColors.accent
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          const SizedBox(width: 4),
                          Text(
                            uploading
                                ? '上传中'
                                : (attachment.uploadedRef != null
                                      ? '已就绪'
                                      : _fmtBytes(attachment.bytes.length)),
                            style: TextStyle(
                              fontSize: AppTextSizes.caption,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // 右上角 × 移除
        if (onRemove != null)
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant,
                    width: 0.8,
                  ),
                ),
                child: Icon(
                  Icons.close,
                  size: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// + 菜单项 (图标 + 文字, 网格布局)
