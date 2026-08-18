import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/relay/relay_events.dart';
import '../../../core/logging/app_logger.dart';
import '../../../data/models/glm_quota.dart' as glm;
import '../../../data/models/workspace.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../../shared/theme/chat_markdown_style.dart';
import 'usage_detail_sheet.dart';

class PlusMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const PlusMenuItem({
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

class SlashCommand {
  final String name;
  final String desc;
  const SlashCommand(this.name, this.desc);
}

const slashCommands = <SlashCommand>[
  SlashCommand('/compact', '压缩对话历史'),
  SlashCommand('/model', '切换模型'),
  SlashCommand('/agents', '子代理'),
  SlashCommand('/help', '查看帮助'),
];

class CommandPalette extends StatelessWidget {
  final String query;
  final ValueChanged<SlashCommand> onSelected;
  const CommandPalette({required this.query, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = slashCommands
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

class MentionOverlay extends ConsumerWidget {
  final String trigger; // @ # $ /
  final String query;
  final String workspacePath;
  final ChatRef chatRef;
  final ValueChanged<String> onSelected; // 传入要插入的完整文本

  const MentionOverlay({
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

  List<MentionItem> _buildItems(WidgetRef ref) {
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
  List<MentionItem> _buildCommands(WidgetRef ref, String q) {
    final builtinNames = slashCommands.map((c) => c.name.substring(1)).toSet();
    final skills = ref.watch(skillsProvider).valueOrNull ?? const <SkillItem>[];
    final server =
        (ref.watch(serverSlashCommandsProvider).valueOrNull ?? const <String>[])
            .where((s) => !builtinNames.contains(s))
            .map((s) {
              final skill = skills.where((sk) => sk.name == s).firstOrNull;
              return SlashCommand('/$s', skill?.description ?? '服务端命令');
            })
            .toList();
    final all = [...slashCommands, ...server];
    final matches = all
        .where((c) => c.name.toLowerCase().contains(q.isEmpty ? '/' : q))
        .toList();
    return matches
        .map(
          (c) => MentionItem(
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
  List<MentionItem> _buildFiles(WidgetRef ref, String q) {
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
        MentionItem(
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
      return MentionItem(
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
  List<MentionItem> _buildSessions(WidgetRef ref, String q) {
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
      return MentionItem(
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
  List<MentionItem> _buildSkills(WidgetRef ref, String q) {
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
      return MentionItem(
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

class MentionItem {
  final IconData icon;
  final Color color;
  final String label;
  final String subtitle;
  final String insertText;
  const MentionItem({
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
/// 点击弹出用量详情底部表 (usage_detail_sheet.dart)。
class UsagePill extends StatelessWidget {
  final ({int input, int output, int max})? tokenUsage;
  final AsyncValue<glm.GlmQuota?> glmQuotaAsync;
  final VoidCallback? onRefreshQuota;

  const UsagePill({
    this.tokenUsage,
    required this.glmQuotaAsync,
    this.onRefreshQuota,
  });

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
    final quota = glmQuotaAsync.valueOrNull;
    // 未配置 GLM API Key (无配额数据) 时整个隐藏, 让标题垂直居中
    if (quota == null || !quota.hasData) return const SizedBox.shrink();
    // 只展示 5 小时窗口配额 (上下文用量底部输入栏已有, 不重复展示;
    // 完整明细 (token/周窗口/MCP) 在点击后的详情弹窗里)
    final tier = quota.fiveHourTier;
    final parts = <UsagePart>[
      if (tier != null)
        UsagePart(
          icon: Icons.local_fire_department_outlined,
          text: _fmtPct(tier.utilization),
          color: _pctColor(tier.utilization, context),
        ),
    ];

    if (parts.isEmpty) return const SizedBox.shrink();

    // 点击 → 用量详情底部表 (token 上下文 + GLM 两窗口 + MCP 月度)
    return InkWell(
      onTap: () => UsageDetailSheet.show(
        context,
        tokenUsage: tokenUsage,
        quotaAsync: glmQuotaAsync,
        onRefresh: onRefreshQuota,
      ),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Wrap(
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
        ),
      ),
    );
  }
}

class UsagePart {
  final IconData icon;
  final String text;
  final Color color;
  const UsagePart({
    required this.icon,
    required this.text,
    required this.color,
  });
}

/// Token 用量 badge (输入栏内显示)
///
/// AI 每轮回复完成后由 ChatNotifier 刷新 state.tokenUsage (累计 input/output)。
/// composer 圆形发送按钮 (上箭头/停止)
class ComposerSendButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool enabled;
  final bool isStop;

  const ComposerSendButton({
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
class ToolbarChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const ToolbarChip({required this.icon, required this.label, this.onTap});

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
class TokenUsageBadge extends StatelessWidget {
  final ({int input, int output})? usage;

  const TokenUsageBadge({this.usage});

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
class ComposerIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  const ComposerIconBtn({
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
class ContextLengthIndicator extends StatelessWidget {
  final ({int input, int output, int max})? usage;

  const ContextLengthIndicator({this.usage});

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
class ModeSelector extends StatelessWidget {
  final String mode; // 'build' | 'edit' | 'plan' | 'yolo' (wire 值, 与后端一致)
  final ValueChanged<String> onChanged;

  const ModeSelector({required this.mode, required this.onChanged});

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
                ModeOptionTile(
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
    // 完全访问 (yolo) 少确认有风险, 常驻 warn 色提示
    return ComposerIconBtn(
      icon: _current.$2,
      tooltip: '执行模式: ${_current.$3}',
      color: mode == 'yolo' ? AppColors.warning : null,
      onTap: () => _open(context),
    );
  }
}

/// 模式选项 tile (图标 + 标题/描述 + 对勾)
class ModeOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  final bool selected;
  final VoidCallback onTap;

  const ModeOptionTile({
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
class ThoughtLevelSelector extends StatelessWidget {
  final String level; // 'max' | 'medium' | 'nothink'
  final ValueChanged<String> onChanged;

  const ThoughtLevelSelector({required this.level, required this.onChanged});

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
                ModeOptionTile(
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
    return ComposerIconBtn(
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
    builder: (ctx) => ModelPickerSheet(
      models: models,
      current: current,
      onSelected: onSelected,
      providerNames: providerNames,
    ),
  );
}

class ModelPickerSheet extends StatefulWidget {
  final List<String> models;
  final String? current;
  final ValueChanged<String> onSelected;
  final Map<String, String> providerNames;

  const ModelPickerSheet({
    required this.models,
    required this.current,
    required this.onSelected,
    required this.providerNames,
  });

  @override
  State<ModelPickerSheet> createState() => ModelPickerSheetState();
}

class ModelPickerSheetState extends State<ModelPickerSheet> {
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
class ModelSelector extends StatelessWidget {
  final List<String> models;
  final String? current;
  final ValueChanged<String> onSelected;
  final Map<String, String> providerNames;
  final bool isLoading;

  const ModelSelector({
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
/// 排队消息行 (输入框上方; 单行文字 + 立即/编辑/删除)
class QueuedMessageRow extends StatelessWidget {
  final String text;
  final VoidCallback onSendNow;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const QueuedMessageRow({
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
            QueueAction(
              icon: Icons.play_arrow_rounded,
              tooltip: '立即发送',
              onTap: onSendNow,
            ),
            QueueAction(
              icon: Icons.edit_outlined,
              tooltip: '编辑',
              onTap: onEdit,
            ),
            QueueAction(
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

class QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const QueueAction({
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
          child: Icon(
            icon,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 压缩标记 (居中药丸形; running 态转圈)
