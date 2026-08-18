import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/logging/app_logger.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../core/relay/relay_events.dart';
import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/chat_markdown_style.dart';
import 'agent_card.dart';
import 'chat_helpers.dart';
import 'execution_trace.dart';
import 'code_block.dart';
import 'plan_card.dart';
import 'thought_block.dart';
import 'tool_activity.dart';
import 'work_history.dart';

class MarkdownSegment {
  final String text;
  final bool isTable;
  const MarkdownSegment(this.text, this.isTable);
}

/// 将 markdown 文本按 GFM 表格块拆分。
/// 表格块: 连续以 `|` 开头的行, 且第二行是分隔符 (|---|---|)
/// 其余为普通文本段。
List<MarkdownSegment> splitMarkdownByTables(String text) {
  final lines = text.split('\n');
  final segments = <MarkdownSegment>[];
  final buf = StringBuffer();
  int i = 0;

  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trimLeft();

    // 检测表格起始: 当前行以 | 开头, 且下一行是分隔符
    if (trimmed.startsWith('|') &&
        i + 1 < lines.length &&
        isTableSeparator(lines[i + 1])) {
      // flush 文本缓冲
      if (buf.isNotEmpty) {
        segments.add(MarkdownSegment(buf.toString(), false));
        buf.clear();
      }
      // 收集所有表格行
      final tableLines = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
        tableLines.add(lines[i]);
        i++;
      }
      segments.add(MarkdownSegment(tableLines.join('\n'), true));
    } else {
      buf.writeln(line);
      i++;
    }
  }
  if (buf.isNotEmpty) {
    segments.add(MarkdownSegment(buf.toString(), false));
  }
  return segments;
}

/// 判断是否是 GFM 表格分隔行: |---|:---:|---|
bool isTableSeparator(String line) {
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
class MessageBubble extends StatefulWidget {
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

  /// ★ ExitPlanMode 权限 (传给 PlanCard 内嵌按钮, null=无待确认权限)
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

  /// ★ 子代理子会话懒加载器 (AgentCard 展开时拉嵌套内容, null=无下钻)
  final Future<List<MessagePart>> Function(String childSessionId)?
      subagentLoader;

  const MessageBubble({
    required this.message,
    required this.theme,
    this.isLastUserMessage = false,
    this.isResponding = false,
    this.onEdit,
    this.onRewind,
    this.planPermission,
    this.onRespondPermission,
    this.subagentLoader,
  });

  @override
  State<MessageBubble> createState() => MessageBubbleState();
}

class MessageBubbleState extends State<MessageBubble> {
  // ── Markdown 样式记忆化 ──
  // flutter_markdown 以 styleSheet 引用相等 (无 == 重载) 判断是否重解析;
  // 每次 build 新建实例会让流式消息里早已写完的正文段也每帧全量重解析。
  ThemeData? _mdStyleTheme;
  Color? _mdStyleInk;
  Color? _mdStyleCodeBg;
  MarkdownStyleSheet? _mdStyle;
  Map<String, MarkdownElementBuilder>? _mdBuilders;
  ThemeData? _mdBuildersTheme;

  /// AI 正文样式 (同一 theme/ink/codeBg 下复用同一实例)
  MarkdownStyleSheet _assistantStyle(ThemeData theme, Color ink, Color codeBg) {
    if (_mdStyle == null ||
        !identical(_mdStyleTheme, theme) ||
        _mdStyleInk != ink ||
        _mdStyleCodeBg != codeBg) {
      _mdStyleTheme = theme;
      _mdStyleInk = ink;
      _mdStyleCodeBg = codeBg;
      _mdStyle = chatMarkdownStyleSheet(theme, ink: ink, codeBg: codeBg);
    }
    return _mdStyle!;
  }

  /// 'pre' 构建器 (代码块), 按 theme 复用
  Map<String, MarkdownElementBuilder> _preBuilders(ThemeData theme) {
    if (_mdBuilders == null || !identical(_mdBuildersTheme, theme)) {
      _mdBuildersTheme = theme;
      _mdBuilders = {'pre': CodeBlockBuilder(theme: theme)};
    }
    return _mdBuilders!;
  }

  /// 用户气泡样式 (颜色全部固定, 整个 State 生命周期只建一份)
  late final MarkdownStyleSheet _userStyle = MarkdownStyleSheet(
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
  );

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
                            child: DataImage(dataUri: dataUri),
                          ),
                        ),
                      // 文本 (有图片或有文字时才显示)
                      if (text.isNotEmpty)
                        MarkdownBody(data: text, styleSheet: _userStyle),
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
    final segments = splitMarkdownByTables(cleanText);
    final styleSheet = _assistantStyle(theme, aiInk, aiCodeBg);
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
            builders: _preBuilders(theme),
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
              child: DataImage(dataUri: dataUri),
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
  ///   - ThoughtPart → ThoughtBlock
  ///   - TextPart    → MarkdownBody 正文
  ///   - ToolPart    → ExitPlanMode 渲染 PlanCard; 其余连续工具合并成
  ///                   一个 ToolActivityCards (避免碎片化)
  /// 否则回退旧的固定顺序 (思考 → 正文 → 计划卡 → 文件摘要 → 工具卡)。
  ///
  /// ChangedFilesSummary 与赞/踩按钮始终在末尾 (两种路径共享)。
  List<Widget> _buildAssistantContent(
    DisplayMessage message,
    ThemeData theme,
    Color aiInk,
    Color aiCodeBg,
  ) {
    final children = <Widget>[];

    // ★ 查找 ExitPlanMode 权限 (如果有, 传给 PlanCard 内嵌按钮)
    final planPerm = widget.planPermission;
    final respondPermission = widget.onRespondPermission;

    if (message.parts.isNotEmpty) {
      // ── parts 路径: 按 parts[] 顺序交错渲染 ──
      // 执行类 part (思考/工具/MCP/子代理) 连续累积, 遇到正文/计划卡时
      // flush 成一段 Execution Trace (无边框 Activity List, 点击弹详情)。
      final pendingParts = <MessagePart>[];
      List<Widget> buildRange(List<MessagePart> range) {
        final out = <Widget>[];
        void flushTrace() {
          if (pendingParts.isEmpty) return;
          final nodes = buildExecutionNodes(pendingParts);
          pendingParts.clear();
          if (nodes.isEmpty) return;
          out.add(
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: ExecutionNodeList(
                nodes: nodes,
                theme: theme,
                inkColor: aiInk,
                onLoadChildren: widget.subagentLoader,
              ),
            ),
          );
        }

        for (final part in range) {
          switch (part) {
            case TextPart(:final text):
              flushTrace();
              out.add(_buildMarkdown(text, theme, aiInk, aiCodeBg));
            case StepPart():
              flushTrace();
              // 只在 step-finish 后插入分隔线 (表示一个步骤完成)
              if (!part.isStart && out.isNotEmpty) {
                out.add(
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                    child: Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.12,
                      ),
                    ),
                  ),
                );
              }
            case SubagentPart():
              pendingParts.add(part);
            case ToolPart(:final activity):
              if (isPlanTool(activity)) {
                flushTrace();
                out.add(
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: PlanCard(
                      activity: activity,
                      theme: theme,
                      inkColor: aiInk,
                      permission: planPerm,
                      onRespondPermission: respondPermission,
                    ),
                  ),
                );
              } else {
                pendingParts.add(part);
              }
            case ThoughtPart():
              pendingParts.add(part);
          }
        }
        flushTrace();
        return out;
      }

      // ★ 历史/尾段拆分 (对齐桌面端 f5e): 以「最后一个正文 part」为界 —
      //   尾段 = 最后的正文 + 其后的工具调用 (保持可见);
      //   之前的全部内容 (思考/工具/早期正文) 折叠进 "已工作 X" 状态行后面。
      //   无正文 / 运行中 / 被打断 (completedInterrupted) → 整轮锁定展开
      //   (桌面端 wG: streaming || settling || 无尾段, interrupted→无尾段)。
      var splitIdx = -1;
      for (var i = message.parts.length - 1; i >= 0; i--) {
        if (message.parts[i] is TextPart) {
          splitIdx = i;
          break;
        }
      }
      final hasText = splitIdx >= 0;
      final historyParts = hasText
          ? message.parts.sublist(0, splitIdx)
          : message.parts;
      final tailParts = hasText
          ? message.parts.sublist(splitIdx)
          : const <MessagePart>[];

      if (historyParts.isNotEmpty) {
        children.add(
          WorkHistory(
            message: message,
            theme: theme,
            // 无正文/运行中/被打断的轮次锁定展开 (ZCode 同款);
            // 正常完成且带正文 → 过程折叠, 只露尾段 (最终回答)
            defaultOpen: message.isStreaming || message.interrupted || !hasText,
            // 大轮次跳过折叠动画 (见 WorkHistory.animate)
            animate: historyParts.length <= 40,
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
            child: TypingCursor(color: AppColors.accent),
          ),
        );
      }
      // 变更文件摘要 (始终在末尾; 优先 turnHeader.fileChanges 权威数据)
      final hasFileData =
          message.fileChanges != null && message.fileChanges!.files > 0;
      if ((hasFileData || message.activities.any(isFileActivity)) &&
          !message.isStreaming) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: ChangedFilesSummary(
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
          TurnStatusLine(
            running: message.isStreaming,
            workedMs: message.workedMs,
            startedAt: message.turnStartedAt,
            theme: theme,
          ),
        );
      }
      // 思考过程 (折叠)
      if (message.thought != null && message.thought!.isNotEmpty) {
        children.add(ThoughtBlock(thought: message.thought!, theme: theme));
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
            child: TypingCursor(color: AppColors.accent),
          ),
        );
      }
      // 计划卡片 (ExitPlanMode 工具产出, 网页端 g3e 同款)
      children.addAll(
        message.activities
            .where(isPlanTool)
            .map(
              (a) => Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: PlanCard(
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
      if ((hasFileData || message.activities.any(isFileActivity)) &&
          !message.isStreaming) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: ChangedFilesSummary(
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
            child: ToolActivityCards(
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
