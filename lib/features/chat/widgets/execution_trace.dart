import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/chat_markdown_style.dart';
import 'chat_helpers.dart';
import 'thought_block.dart';
import 'tool_activity.dart';

/// Agent 执行过程树 (渲染层视图模型)。
///
/// ExecutionNode 不进 provider — 从 DisplayMessage.parts 投影而来:
/// parts 平铺承载交错顺序, 树形 (子代理 children) 在视图层组装。
/// 消息未变时整个 MessageBubble 走签名缓存整棵跳过, 投影天然不重跑。
///
/// 视觉: 无边框轻量 Activity List (深色开发者工具风), 点击节点弹
/// DraggableScrollableSheet 查看详情; 子代理节点点击展开 children。

enum ExecutionStatus { pending, running, success, error, cancelled }

enum ExecutionNodeKind { thinking, tool, mcp, subagent, explore }

class ExecutionNode {
  final ExecutionNodeKind kind;
  final String id; // 稳定 key: toolCallId / rowIdKey / thought 序号
  final String title; // mono 名 (server · method / 思考过程 / 子代理类型)
  final String? subtitle; // 摘要 (命令/路径/搜索词/子代理摘要)
  final ExecutionStatus status;
  final int? durationMs;
  final ToolActivity? activity; // tool/mcp 详情数据
  final SubagentPart? subagent; // 子代理 (children 懒加载句柄)
  final String? thoughtText; // thinking 详情文本
  final List<ExecutionNode> children; // 子代理已加载的嵌套节点

  const ExecutionNode({
    required this.kind,
    required this.id,
    required this.title,
    required this.status,
    this.subtitle,
    this.durationMs,
    this.activity,
    this.subagent,
    this.thoughtText,
    this.children = const [],
  });
}

ExecutionStatus _toolStatus(String s) => switch (s) {
      'error' || 'failed' => ExecutionStatus.error,
      'cancelled' => ExecutionStatus.cancelled,
      'inputStreaming' ||
      'pendingApproval' ||
      'running' ||
      'scheduled' ||
      'started' ||
      'progress' => ExecutionStatus.running,
      _ => ExecutionStatus.success,
    };

/// 执行类 part → node (TextPart 不进 trace, 由调用方渲染正文)
ExecutionNode? _partToNode(MessagePart p, int seq) {
  switch (p) {
    case ThoughtPart(:final text, :final durationMs):
      return ExecutionNode(
        kind: ExecutionNodeKind.thinking,
        id: 'think_$seq',
        title: '思考过程',
        subtitle: durationMs != null
            ? '持续了 ${formatWorkDuration(durationMs)}'
            : null,
        status: ExecutionStatus.success,
        durationMs: durationMs,
        thoughtText: text,
      );
    case SubagentPart():
      return ExecutionNode(
        kind: ExecutionNodeKind.subagent,
        id: p.rowIdKey,
        title: p.subagentType.isEmpty ? '子智能体' : p.subagentType,
        subtitle: p.summaryText.isEmpty ? null : p.summaryText,
        status: switch (p.status) {
          'running' => ExecutionStatus.running,
          'failed' => ExecutionStatus.error,
          'cancelled' => ExecutionStatus.cancelled,
          _ => ExecutionStatus.success,
        },
        subagent: p,
        children: [
          for (final c in p.children)
            if (_partToNode(c, seq) != null) _partToNode(c, seq)!,
        ],
      );
    case ToolPart(:final activity):
      final isMcp = activity.toolName.startsWith('mcp__');
      return ExecutionNode(
        kind: isMcp ? ExecutionNodeKind.mcp : ExecutionNodeKind.tool,
        id: activity.toolCallId,
        title: formatToolName(activity.toolName),
        subtitle: toolTarget(activity),
        status: _toolStatus(activity.status),
        durationMs: activity.elapsedMs,
        activity: activity,
      );
    default:
      return null;
  }
}

// ── 探索折叠组 (桌面端/网页端同款, 渲染层聚合) ──
// 来源: 桌面端 app.asar 渲染 bundle 逆向 (VB/S2e/V6e/H6e 函数族)。
// 机制: 连续的只读工具调用吸收成一张"探索"卡, 子项按 搜索/列表/文件
// 分桶计数 ("2 搜索, 1 文件"); 遇正文/思考/不可进组工具即断开。
// 协议上无分组概念 — 纯视图层投影, 不进 provider。

/// 工具名 → 家族 (桌面端 VB 正则链, 名字归一化小写后匹配)
String? toolFamily(String name) {
  final n = name.toLowerCase();
  if (RegExp(
    r'^(?:read|view|open|cat|head|tail|read_file)(?:_|$)',
  ).hasMatch(n)) {
    return 'file-read';
  }
  if (RegExp(
    r'(?:^|_)(?:edit|patch|replace|multi_edit|multiedit|write|create|save|apply_patch)(?:_|$)',
  ).hasMatch(n)) {
    return 'file-write';
  }
  if (RegExp(
    r'^(?:execute|run|exec|bash|shell|command|terminal)(?:_|$)',
  ).hasMatch(n)) {
    return 'shell';
  }
  if (RegExp(
    r'^(?:search|grep|find|fetch|web_search|web_fetch|webfetch|query|lookup|glob|list|ls|dir|tree)(?:_|$)',
  ).hasMatch(n)) {
    return 'search';
  }
  if (RegExp(r'^(?:explore|inspect)(?:_|$)').hasMatch(n)) {
    return 'explore';
  }
  return null;
}

// shell 家族进组的命令白/黑名单 (桌面端 NV/y2e/b2e)
final RegExp _shellReadonly = RegExp(
  r'\b(rg|grep|find|ls|cat|head|tail|wc|stat|pwd|which|readlink|tree|sed\s+-n)\b'
  r'|^git\s+(status|log|show|diff)\b',
);
final RegExp _shellMutator = RegExp(
  r'\b(sed\s+-i|perl\s+-pi|tee|mv|cp|rm|mkdir|rmdir|touch|truncate|chmod|chown)\b'
  r'|^git\s+(add|commit|rm|mv|checkout|switch|restore|reset|clean|revert|cherry-pick|merge|rebase)\b',
);
// 输出重定向 (>> > &>) → 有副作用, 不进组
final RegExp _shellRedirect = RegExp(r'(^|[^\d<])>>?\s*\S|&>\s*\S');

/// 是否可进"探索"折叠组 (桌面端 S2e):
/// file-read/search/explore 家族直接可进; shell 逐条命令检查
/// (不含写操作黑名单、无输出重定向、至少一条只读白名单命令);
/// file-write 与 MCP/子代理等无家族工具永不进组。
bool exploreEligible(ToolActivity a) {
  final name = a.toolName.toLowerCase();
  if (name.startsWith('mcp__') || name.startsWith('subagent')) return false;
  final family = toolFamily(name);
  if (family == 'file-read' || family == 'search' || family == 'explore') {
    return true;
  }
  if (family != 'shell') return false;
  final cmd = a.input?['command'] ?? a.input?['cmd'];
  if (cmd is! String || cmd.isEmpty) return false;
  final parts = cmd
      .split(RegExp(r'\s*(?:&&|\|\||;|\||\n)\s*'))
      .where((s) => s.trim().isNotEmpty)
      .toList();
  if (parts.isEmpty) return false;
  if (parts.any((p) => _shellMutator.hasMatch(p))) return false;
  if (parts.any((p) => _shellRedirect.hasMatch(p))) return false;
  return parts.any((p) => _shellReadonly.hasMatch(p));
}

/// 子项分桶 (桌面端 V6e): kind/名字含关键词或 input 命中命令名 →
/// search(搜索) / list(列表), 其余 file(文件)
String exploreBucket(ToolActivity a) {
  final r = a.toolName.toLowerCase();
  final inputVals =
      (a.input?.values ?? const [])
          .whereType<String>()
          .join(' ; ')
          .toLowerCase();
  if (RegExp(
    r'(\bgrep\b|\bsearch\b|\bfetch\b|\bweb.?search\b|\bweb.?fetch\b)',
  ).hasMatch(r) ||
      RegExp(r'(^|\s)(rg|grep|ripgrep|git\s+grep)(\s|$)').hasMatch(
        inputVals,
      )) {
    return 'search';
  }
  if (RegExp(
    r'(\bglob\b|\bfind\b|\blist\b|\btree\b|\bdir\b|\bls\b)',
  ).hasMatch(r) ||
      RegExp(r'(^|\s)(ls|find|tree|dir)(\s|$)').hasMatch(inputVals)) {
    return 'list';
  }
  return 'file';
}

/// 桶计数摘要 (桌面端 H6e): "2 搜索, 1 列表, 3 文件", 每桶 >0 才显示
String exploreSummary(List<ToolActivity> activities) {
  var search = 0, list = 0, file = 0;
  for (final a in activities) {
    switch (exploreBucket(a)) {
      case 'search':
        search++;
      case 'list':
        list++;
      default:
        file++;
    }
  }
  final out = <String>[];
  if (search > 0) out.add('$search 搜索');
  if (list > 0) out.add('$list 列表');
  if (file > 0) out.add('$file 文件');
  return out.isEmpty ? '0 个文件' : out.join(', ');
}

/// parts 片段 → 执行节点列表 (跳过 plan/todo 等特殊工具)。
/// 连续可进组的 tool 节点吸收成一张"探索"卡 (≥2 才合组, 单个保持独立);
/// 思考/子代理/MCP/不可进组工具都会断开吸收。
List<ExecutionNode> buildExecutionNodes(List<MessagePart> parts) {
  final nodes = <ExecutionNode>[];
  var seq = 0;
  for (final p in parts) {
    if (p is ToolPart && (isPlanTool(p.activity) || isTodoTool(p.activity))) {
      continue;
    }
    final n = _partToNode(p, seq++);
    if (n != null) nodes.add(n);
  }
  return _absorbExploreRuns(nodes);
}

/// 连续吸收: 相邻的合格 tool 节点合成 explore 组节点
List<ExecutionNode> _absorbExploreRuns(List<ExecutionNode> nodes) {
  final out = <ExecutionNode>[];
  var run = <ExecutionNode>[];
  void flush() {
    if (run.length >= 2) {
      final activities = [
        for (final n in run) n.activity!,
      ];
      final running = run.any(
        (n) => n.status == ExecutionStatus.running,
      );
      out.add(
        ExecutionNode(
          kind: ExecutionNodeKind.explore,
          id: 'explore_${run.first.id}',
          title: '探索',
          subtitle: exploreSummary(activities),
          status: running
              ? ExecutionStatus.running
              : run.last.status,
          durationMs: null,
          children: run,
        ),
      );
    } else {
      out.addAll(run);
    }
    run = [];
  }

  for (final n in nodes) {
    if (n.kind == ExecutionNodeKind.tool &&
        n.activity != null &&
        exploreEligible(n.activity!)) {
      run.add(n);
    } else {
      flush();
      out.add(n);
    }
  }
  flush();
  return out;
}

/// ── 一级节点列表: 无边框轻量 Activity List ──
/// [onLoadChildren]: 子代理 children 懒加载器 (可空 = 无下钻)
class ExecutionNodeList extends StatelessWidget {
  final List<ExecutionNode> nodes;
  final ThemeData theme;
  final Color inkColor;
  final Future<List<MessagePart>> Function(String childSessionId)?
      onLoadChildren;

  const ExecutionNodeList({
    super.key,
    required this.nodes,
    required this.theme,
    required this.inkColor,
    this.onLoadChildren,
  });

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final n in nodes)
          ExecutionNodeWidget(
            node: n,
            theme: theme,
            inkColor: inkColor,
            onLoadChildren: onLoadChildren,
          ),
      ],
    );
  }
}

/// 单个执行节点行 (递归: 子代理 children 缩进渲染)
class ExecutionNodeWidget extends StatefulWidget {
  final ExecutionNode node;
  final ThemeData theme;
  final Color inkColor;
  final Future<List<MessagePart>> Function(String childSessionId)?
      onLoadChildren;
  final int depth;

  const ExecutionNodeWidget({
    super.key,
    required this.node,
    required this.theme,
    required this.inkColor,
    this.onLoadChildren,
    this.depth = 0,
  });

  @override
  State<ExecutionNodeWidget> createState() => _ExecutionNodeWidgetState();
}

class _ExecutionNodeWidgetState extends State<ExecutionNodeWidget> {
  bool _childrenExpanded = false;
  List<ExecutionNode>? _children;
  bool _loading = false;
  String? _error;

  Future<void> _ensureChildren() async {
    final loader = widget.onLoadChildren;
    final sid = widget.node.subagent?.childSessionId;
    if (loader == null || sid == null || _children != null || _loading) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final parts = await loader(sid);
      if (!mounted) return;
      setState(() => _children = buildExecutionNodes(parts));
    } catch (_) {
      if (mounted) setState(() => _error = '子任务详情加载失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onTap() {
    final n = widget.node;
    if (n.kind == ExecutionNodeKind.subagent) {
      // 子代理: 点击 = 展开/收起 children (完整 input/output 走详情入口)
      setState(() => _childrenExpanded = !_childrenExpanded);
      if (_childrenExpanded) _ensureChildren();
      return;
    }
    if (n.kind == ExecutionNodeKind.explore && n.children.isNotEmpty) {
      // 探索组: 点击 = 展开/收起子工具行 (children 已内联)
      setState(() => _childrenExpanded = !_childrenExpanded);
      return;
    }
    showExecutionDetail(context, n, widget.theme);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final n = widget.node;
    final statusColor = switch (n.status) {
      ExecutionStatus.running => AppColors.accent,
      ExecutionStatus.error => AppColors.danger,
      ExecutionStatus.cancelled => theme.colorScheme.onSurfaceVariant,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    final hasChildrenHandle =
        n.kind == ExecutionNodeKind.subagent &&
        n.subagent?.childSessionId != null &&
        widget.onLoadChildren != null;
    // 探索组: 子工具行已内联, 直接可展开
    final expandableExplore =
        n.kind == ExecutionNodeKind.explore && n.children.isNotEmpty;
    final expandable = hasChildrenHandle || expandableExplore;

    // 新节点出现: 轻微淡入 (一次性, 不抢戏)
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: Padding(
        padding: EdgeInsets.only(
          left: widget.depth > 0 ? AppSpacing.md : 0,
          bottom: AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: _onTap,
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: 1,
                ),
                child: Row(
                  children: [
                    Icon(_iconFor(n.kind), size: 14, color: statusColor),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  n.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppTextSizes.label,
                                    fontFamily: kMonoFont,
                                    // 元信息降一档: 比正文 inkColor 浅,
                                    // 仍略高于 subtitle, 保持层级
                                    color: widget.inkColor.withValues(
                                      alpha: 0.65,
                                    ),
                                  ),
                                ),
                              ),
                              if (n.subtitle != null &&
                                  n.subtitle!.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    n.subtitle!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: AppTextSizes.label,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildStatus(statusColor),
                    if (expandable) ...[
                      const SizedBox(width: 2),
                      Icon(
                        _childrenExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 子代理 children / 探索组子工具行 (递归, 轻微缩进)
            if (expandable && _childrenExpanded)
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
              child: Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.xs,
                  left: AppSpacing.md,
                ),
                  child: _loading
                      ? Row(
                          children: [
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '加载子任务…',
                              style: TextStyle(
                                fontSize: AppTextSizes.label,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        )
                      : _error != null
                          ? Text(
                              _error!,
                              style: TextStyle(
                                fontSize: AppTextSizes.label,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          : ExecutionNodeList(
                              nodes: _children ?? n.children,
                              theme: theme,
                              inkColor: widget.inkColor,
                              onLoadChildren: widget.onLoadChildren,
                            ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(Color color) {
    if (widget.node.status == ExecutionStatus.running) {
      return const RunningDot(size: 5);
    }
    final err = widget.node.status == ExecutionStatus.error;
    return Icon(
      err ? Icons.error_outline : Icons.check,
      size: 13,
      color: err ? AppColors.danger : color,
    );
  }

}

IconData _iconFor(ExecutionNodeKind k) => switch (k) {
      ExecutionNodeKind.thinking => Icons.psychology_outlined,
      ExecutionNodeKind.tool => Icons.build_outlined,
      ExecutionNodeKind.mcp => Icons.extension,
      ExecutionNodeKind.subagent => Icons.account_tree_outlined,
      ExecutionNodeKind.explore => Icons.travel_explore,
    };

/// ── 详情 Bottom Sheet (DraggableScrollableSheet) ──
void showExecutionDetail(BuildContext context, ExecutionNode node, ThemeData theme) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _ExecutionDetailSheet(node: node, theme: theme),
  );
}

class _ExecutionDetailSheet extends StatefulWidget {
  final ExecutionNode node;
  final ThemeData theme;

  const _ExecutionDetailSheet({required this.node, required this.theme});

  @override
  State<_ExecutionDetailSheet> createState() => _ExecutionDetailSheetState();
}

class _ExecutionDetailSheetState extends State<_ExecutionDetailSheet> {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  static const double _minSize = 0.3;
  static const double _maxSize = 0.92;

  // 拖拽条在 Sheet 结构中固定于顶部 (不随内容滚动);
  // 由于它不在 scrollController 驱动的 Scrollable 内,
  // 手动把竖向拖拽映射到 DraggableScrollableController。
  void _onHandleDrag(DragUpdateDetails details) {
    if (!_sheetController.isAttached) return;
    final box = context.findRenderObject() as RenderBox?;
    final available = (box?.size.height ?? 0) / _maxSize;
    if (available <= 0) return;
    final sizeDelta = -(details.primaryDelta ?? 0) / available;
    final target = (_sheetController.size + sizeDelta).clamp(
      _minSize,
      _maxSize,
    );
    _sheetController.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return DraggableScrollableSheet(
      expand: false,
      controller: _sheetController,
      initialChildSize: 0.5,
      minChildSize: _minSize,
      maxChildSize: _maxSize,
      snap: true,
      snapSizes: const [0.5, 0.92],
      builder: (ctx, scrollController) {
        return Container(
          decoration: BoxDecoration(
            // 与全 app 底部弹层一致的不透明提升面 (composer 模型选择等同款)
            color: Color.alphaBlend(
              theme.colorScheme.surfaceContainerHigh,
              theme.colorScheme.surfaceContainerLowest,
            ),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.lg),
            ),
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: Column(
            children: [
              // drag handle — 固定在 Sheet 顶部, 不参与内容滚动
              GestureDetector(
                onVerticalDragUpdate: _onHandleDrag,
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Expanded(
                // scrollController 必须传给内部 Scrollable,
                // 这样内容滚到顶后继续下拉仍会带动 Sheet 收起
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    0,
                    AppSpacing.md,
                    AppSpacing.xl,
                  ),
                  child: _buildContent(context, theme),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context, ThemeData theme) {
    final n = widget.node;
    final typeLabel = switch (n.kind) {
      ExecutionNodeKind.thinking => '思考过程',
      ExecutionNodeKind.tool => 'Tool Call',
      ExecutionNodeKind.mcp => 'MCP',
      ExecutionNodeKind.subagent => '子智能体',
      ExecutionNodeKind.explore => '探索',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          typeLabel,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          n.title,
          style: TextStyle(
            fontSize: AppTextSizes.titleSm,
            fontFamily: kMonoFont,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        // Status + Duration 行
        Row(
          children: [
            Icon(
              n.status == ExecutionStatus.error
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              size: 14,
              color: n.status == ExecutionStatus.error
                  ? AppColors.danger
                  : AppColors.success,
            ),
            const SizedBox(width: 5),
            Text(
              switch (n.status) {
                ExecutionStatus.running => '执行中',
                ExecutionStatus.error => '执行失败',
                ExecutionStatus.cancelled => '已取消',
                ExecutionStatus.pending => '等待中',
                _ => '已完成',
              },
              style: TextStyle(
                fontSize: AppTextSizes.bodySm,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (n.durationMs != null) ...[
              const SizedBox(width: 8),
              Text(
                '· ${formatWorkDuration(n.durationMs!)}',
                style: TextStyle(
                  fontSize: AppTextSizes.bodySm,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        if (n.kind == ExecutionNodeKind.mcp) ...[
          const SizedBox(height: AppSpacing.md),
          _kv(theme, 'Server', n.activity!.toolName.split('__')[1]),
          _kv(theme, 'Tool', n.title),
        ],
        if (n.kind == ExecutionNodeKind.subagent) ...[
          const SizedBox(height: AppSpacing.md),
          _kv(theme, '类型', n.subagent?.subagentType ?? ''),
          if (n.subtitle != null && n.subtitle!.isNotEmpty)
            _kv(theme, '摘要', n.subtitle!),
        ],
        // Arguments
        if (n.activity?.input != null && n.activity!.input!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _sectionLabel(theme, 'Arguments'),
          _codeBlock(theme, _prettyJson(n.activity!.input!)),
        ],
        // Result
        if (n.activity?.result != null &&
            n.activity!.result!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _sectionLabel(theme, 'Result'),
          _codeBlock(theme, _clip(n.activity!.result!, 8000)),
        ],
        // Thinking 正文
        if (n.thoughtText != null && n.thoughtText!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _sectionLabel(theme, '思考内容'),
          _codeBlock(theme, _clip(n.thoughtText!, 8000)),
        ],
      ],
    );
  }

  Widget _sectionLabel(ThemeData theme, String s) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text(
          s,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _kv(ThemeData theme, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(
                k,
                style: TextStyle(
                  fontSize: AppTextSizes.label,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Text(
                v,
                style: TextStyle(
                  fontSize: AppTextSizes.label,
                  fontFamily: kMonoFont,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _codeBlock(ThemeData theme, String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppTextSizes.label,
            fontFamily: kMonoFont,
            height: 1.5,
          ),
        ),
      );

  static String _prettyJson(Map<String, dynamic> m) {
    try {
      return const JsonEncoder.withIndent('  ').convert(m);
    } catch (_) {
      return m.toString();
    }
  }

  static String _clip(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}…(${s.length} 字符)' : s;
}
