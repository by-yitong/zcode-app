/// 使用统计页 — 桌面端 / 网页端「使用统计」(应用用量) 的移动端呈现。
///
/// 对照参考面 (2026-11-03 用户截图的桌面端页面, 自上而下):
/// 1. 5 张汇总卡: 累计 Token 数 / 峰值 Token 数 / 最长聊天时长 /
///    当前连续天数 / 最长连续天数
/// 2. Token 活动热力图 (GitHub 贡献格样式) + 每日 / 每周 / 累计切换
/// 3. 时间范围: 近 7 日 / 近 30 日
/// 4. 每日 Token 趋势图: 按模型分线 (图例 + 平滑曲线)
///
/// 数据 (2026-11-02 网页端抓包实测, 照网页端两条调用办理):
/// - 汇总 + 热力图: `getAppUsageSnapshot({range: "all"})`
/// - 趋势图: `getAppUsageSnapshot({range: "7d"/"30d"})`, 切换时只重拉这条
/// - 热力周块为服务端 weeks 原样 (从 startDate 起连续 7 天一切块,
///   非自然周; 未来日期为 null 占位); 每日模式颜色直接用服务端 level 0-4
///
/// 移动端适配说明:
/// - 桌面端左侧边栏导航不要, 只取主内容区; 5 卡横排改 2 列网格;
/// - 新 UI 不用分割线与边框, 卡片只靠填充色区分。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/services/app_usage_service.dart';
import '../../../data/models/app_usage.dart';
import '../../../providers/app_providers.dart';
import '../../../shared/theme/app_design_tokens.dart';
import '../../agent/widgets/caps_page_chrome.dart';

/// 趋势图配色: 前三色与参考面图例一致
/// (GLM-5.3 蓝 / GLM-5.3-Flash 绿 / deepseek-v4.1-flash 紫)。
const _trendPalette = <Color>[
  Color(0xFF2196F3),
  Color(0xFF4CAF50),
  Color(0xFF9C27B0),
  Color(0xFFFB8C00),
  Color(0xFF00ACC1),
  Color(0xFFE53935),
];

/// 热力图强度色 (浅 → 深, level 0 用填充色最浅档)。
const _heatEmpty = Color(0xFFECEFF1);
const _heatLevels = <Color>[
  Color(0xFFBBDEFB),
  Color(0xFF64B5F6),
  Color(0xFF1E88E5),
  Color(0xFF0D47A1),
];

class UsageStatsPage extends ConsumerStatefulWidget {
  const UsageStatsPage({super.key});

  @override
  ConsumerState<UsageStatsPage> createState() => _UsageStatsPageState();
}

class _UsageStatsPageState extends ConsumerState<UsageStatsPage> {
  /// 汇总 + 热力图 (range 'all')。
  AppUsage? _allUsage;

  /// 趋势图 (range _trendRange)。
  AppUsage? _trendUsage;

  String? _error;
  bool _loading = true;

  /// 热力图模式: 'daily' 每日 / 'weekly' 每周 / 'cumulative' 累计。
  String _heatmapMode = 'daily';

  /// 趋势图范围: '7d' 近 7 日 / '30d' 近 30 日 (切换时只重拉趋势)。
  String _trendRange = '7d';
  bool _trendLoading = false;
  String? _trendError;

  /// 热力图点选的日期 (点格子后下方显示该天数值)。
  DateTime? _selectedHeatDay;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = ref.read(relayClientProvider);
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '未连接设备, 连接设备后可查看使用统计';
      });
      return;
    }
    try {
      final service = AppUsageService();
      final results = await Future.wait([
        service.fetch(client, range: 'all'),
        service.fetch(client, range: _trendRange),
      ]);
      if (!mounted) return;
      setState(() {
        _allUsage = results[0];
        _trendUsage = results[1];
        _loading = false;
      });
    } catch (e) {
      appLog.w('[UsageStats] 加载失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '加载失败，请检查设备连接后重试';
        _loading = false;
      });
    }
  }

  /// 时间范围切换时只重拉趋势那条 (旧图保留到新数据到达, 失败则留错)。
  Future<void> _loadTrend() async {
    final client = ref.read(relayClientProvider);
    if (client == null) return;
    setState(() {
      _trendLoading = true;
      _trendError = null;
    });
    try {
      final usage = await AppUsageService().fetch(
        client,
        range: _trendRange,
      );
      if (!mounted) return;
      setState(() {
        _trendUsage = usage;
        _trendLoading = false;
      });
    } catch (e) {
      appLog.w('[UsageStats] 趋势加载失败: $e');
      if (!mounted) return;
      setState(() {
        _trendLoading = false;
        _trendError = '趋势数据加载失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: CapsPageHeader.overlayStyle(context),
      child: Scaffold(
        appBar: const CapsPageHeader(title: '使用统计'),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('加载失败', style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.sm),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                      ),
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    FilledButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  children: [
                    _buildScopeCapsule(theme),
                    const SizedBox(height: AppSpacing.md),
                    _buildSummaryGrid(theme),
                    const SizedBox(height: AppSpacing.lg),
                    _buildActivityCard(theme),
                    const SizedBox(height: AppSpacing.lg),
                    _buildRangeRow(theme),
                    const SizedBox(height: AppSpacing.md),
                    _buildTrendCard(theme),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      '数据来自所连设备的应用用量统计',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                ),
              ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // 汇总卡 (range 'all' 的 summary)
  // ---------------------------------------------------------------

  Widget _buildScopeCapsule(ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '应用用量',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryGrid(ThemeData theme) {
    final usage = _allUsage!;
    final longest = usage.longestChatText ?? _fmtDuration(usage.longestChat);
    final cards = <({String value, String label})>[
      (value: _fmtTokens(usage.effectiveTotal), label: '累计 Token 数'),
      (value: _fmtTokens(usage.effectivePeak), label: '峰值 Token 数'),
      (value: longest, label: '最长聊天时长'),
      (value: '${usage.effectiveCurrentStreak}天', label: '当前连续天数'),
      (value: '${usage.effectiveLongestStreak}天', label: '最长连续天数'),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppSpacing.sm,
      crossAxisSpacing: AppSpacing.sm,
      childAspectRatio: 1.55,
      children: cards.map((c) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                c.value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                c.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ---------------------------------------------------------------
  // Token 活动热力图 (服务端周块原样渲染)
  // ---------------------------------------------------------------

  Widget _buildActivityCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Token 活动', style: theme.textTheme.titleMedium),
              const Spacer(),
              _CapsuleToggle(
                options: const ['每日', '每周', '累计'],
                selected: switch (_heatmapMode) {
                  'weekly' => '每周',
                  'cumulative' => '累计',
                  _ => '每日',
                },
                onChanged: (label) {
                  setState(() {
                    _heatmapMode = switch (label) {
                      '每周' => 'weekly',
                      '累计' => 'cumulative',
                      _ => 'daily',
                    };
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (_allUsage!.heatWeeks.isEmpty)
            Text(
              '暂无活动数据',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            _buildHeatmap(theme),
            const SizedBox(height: 8),
            _buildHeatLegend(theme),
            if (_selectedHeatDay != null) ...[
              const SizedBox(height: 6),
              Text(
                _heatDetailText(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// 热力图“少 → 多”图例 (与格子用同一套强度色)。
  Widget _buildHeatLegend(ThemeData theme) {
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 10,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      children: [
        Text('少', style: labelStyle),
        const SizedBox(width: 4),
        for (final c in [_heatEmpty, ..._heatLevels])
          Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: 4),
        Text('多', style: labelStyle),
      ],
    );
  }

  /// 点选格子的数值说明 (按当前模式: 当日/当周/累计)。
  String _heatDetailText() {
    final day = _selectedHeatDay!;
    final value = _heatmapCells()[day]?.value ?? 0;
    final scope = switch (_heatmapMode) {
      'weekly' => '当周',
      'cumulative' => '累计',
      _ => '当日',
    };
    return '${day.month}月${day.day}日 · $scope $value Tokens';
  }

  /// 按当前模式算出的 每日 → (展示值, 颜色)。
  /// 每日模式颜色直接用服务端 level; 每周/累计模式按值四分位算色。
  Map<DateTime, ({int value, Color color})> _heatmapCells() {
    final weeks = _allUsage!.heatWeeks;
    if (_heatmapMode == 'daily') {
      var maxVal = 0;
      for (final week in weeks) {
        for (final d in week) {
          if (d != null && d.total > maxVal) maxVal = d.total;
        }
      }
      final map = <DateTime, ({int value, Color color})>{};
      for (final week in weeks) {
        for (final d in week) {
          if (d == null) continue;
          final color = d.level != null
              ? _levelColor(d.level!)
              : _quartileColor(d.total, maxVal);
          map[d.date] = (value: d.total, color: color);
        }
      }
      return map;
    }
    if (_heatmapMode == 'weekly') {
      final weekTotals = <int>[];
      for (final week in weeks) {
        var sum = 0;
        for (final d in week) {
          if (d != null) sum += d.total;
        }
        weekTotals.add(sum);
      }
      var maxVal = 0;
      for (final t in weekTotals) {
        if (t > maxVal) maxVal = t;
      }
      final map = <DateTime, ({int value, Color color})>{};
      for (var w = 0; w < weeks.length; w++) {
        for (final d in weeks[w]) {
          if (d == null) continue;
          map[d.date] = (
            value: weekTotals[w],
            color: _quartileColor(weekTotals[w], maxVal),
          );
        }
      }
      return map;
    }
    // 累计: 按日期顺序累计 (周块本身已按日期升序)。
    var acc = 0;
    final ordered = <DailyTokenUsage>[];
    for (final week in weeks) {
      for (final d in week) {
        if (d != null) ordered.add(d);
      }
    }
    var maxVal = 0;
    final accValues = <DateTime, int>{};
    for (final d in ordered) {
      acc += d.total;
      accValues[d.date] = acc;
      if (acc > maxVal) maxVal = acc;
    }
    return {
      for (final e in accValues.entries)
        e.key: (value: e.value, color: _quartileColor(e.value, maxVal)),
    };
  }

  Color _levelColor(int level) {
    if (level <= 0) return _heatEmpty;
    if (level >= _heatLevels.length) return _heatLevels.last;
    return _heatLevels[level - 1];
  }

  Color _quartileColor(int value, int maxVal) {
    if (value <= 0 || maxVal <= 0) return _heatEmpty;
    final ratio = value / maxVal;
    if (ratio <= 0.25) return _heatLevels[0];
    if (ratio <= 0.5) return _heatLevels[1];
    if (ratio <= 0.75) return _heatLevels[2];
    return _heatLevels[3];
  }

  Widget _buildHeatmap(ThemeData theme) {
    const cell = 12.0;
    const gap = 3.0;
    final weeks = _allUsage!.heatWeeks;
    final cells = _heatmapCells();
    final columns = <Widget>[];
    DateTime? prevMonth;
    for (var w = 0; w < weeks.length; w++) {
      final week = weeks[w];
      DateTime? firstDay;
      for (final d in week) {
        if (d != null) {
          firstDay = d.date;
          break;
        }
      }
      final showMonth =
          firstDay != null &&
          (prevMonth == null ||
              prevMonth.month != firstDay.month ||
              prevMonth.year != firstDay.year);
      if (firstDay != null) prevMonth = firstDay;
      final monthLabel =
          showMonth && firstDay != null ? '${firstDay.month}月' : '';
      final children = <Widget>[
        SizedBox(
          height: 14,
          child: Text(
            monthLabel,
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 6),
      ];
      for (var i = 0; i < week.length; i++) {
        final d = week[i];
        if (d == null) {
          // 服务端 null 占位 (未来日期): 占位保持对齐。
          children.add(const SizedBox(width: cell, height: cell));
        } else {
          final c = cells[d.date];
          children.add(
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _selectedHeatDay = d.date),
              child: Container(
                width: cell,
                height: cell,
                decoration: BoxDecoration(
                  color: c?.color ?? _heatEmpty,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          );
        }
        if (i < week.length - 1) children.add(const SizedBox(height: gap));
      }
      columns.add(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
      if (w < weeks.length - 1) columns.add(const SizedBox(width: gap));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: columns,
      ),
    );
  }

  // ---------------------------------------------------------------
  // 时间范围 + 趋势图 (range _trendRange 的快照, 不再页内过滤)
  // ---------------------------------------------------------------

  Widget _buildRangeRow(ThemeData theme) {
    return Row(
      children: [
        Text('时间范围', style: theme.textTheme.titleMedium),
        const Spacer(),
        _CapsuleToggle(
          options: const ['近 7 日', '近 30 日'],
          selected: _trendRange == '7d' ? '近 7 日' : '近 30 日',
          onChanged: (label) {
            final next = label == '近 7 日' ? '7d' : '30d';
            if (next == _trendRange) return;
            setState(() => _trendRange = next);
            _loadTrend();
          },
        ),
      ],
    );
  }

  Widget _buildTrendCard(ThemeData theme) {
    final days = _trendUsage?.daily ?? const <DailyTokenUsage>[];
    final models = _trendUsage?.models ?? const <String>[];
    final hasModels = models.isNotEmpty;
    final seriesNames = hasModels ? models : const ['全部'];
    final seriesValues = <List<double>>[];
    var maxVal = 0.0;
    for (final name in seriesNames) {
      final values = days.map((d) {
        final v = hasModels ? (d.byModel[name] ?? 0) : d.total;
        return v.toDouble();
      }).toList();
      for (final v in values) {
        if (v > maxVal) maxVal = v;
      }
      seriesValues.add(values);
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('每日 Token 趋势图', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (var i = 0; i < seriesNames.length; i++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _trendPalette[i % _trendPalette.length],
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(seriesNames[i], style: theme.textTheme.bodySmall),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (_trendLoading)
            const SizedBox(
              height: 200,
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_trendError != null)
            SizedBox(
              height: 200,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '趋势数据加载失败',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _loadTrend,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          else if (days.isEmpty)
            Text(
              '暂无趋势数据',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            SizedBox(
              height: 200,
              width: double.infinity,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 纵轴刻度 (最大值/一半/0, 与 25%/50%/75% 网格线对齐)。
                  SizedBox(
                    width: 40,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final v in <double>[maxVal, maxVal / 2, 0])
                          Text(
                            _fmtTokens(v.toInt()),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: CustomPaint(
                      painter: _TrendChartPainter(
                        series: seriesValues,
                        colors: [
                          for (var i = 0; i < seriesNames.length; i++)
                            _trendPalette[i % _trendPalette.length],
                        ],
                        maxValue: maxVal,
                        gridColor: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmtDay(days.first.date),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  _fmtDay(days.last.date),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------
  // 格式化
  // ---------------------------------------------------------------

  /// Token 紧凑显示, 与参考面一致: 50.4亿 / 6.8亿 / 1.2万。
  String _fmtTokens(int v) {
    if (v >= 100000000) return '${(v / 1e8).toStringAsFixed(1)}亿';
    if (v >= 10000) return '${(v / 1e4).toStringAsFixed(1)}万';
    return '$v';
  }

  String _fmtDuration(Duration? d) {
    if (d == null) return '—';
    final days = d.inDays;
    final hours = d.inHours % 24;
    final minutes = d.inMinutes % 60;
    if (days > 0) return '$days天$hours小时';
    if (hours > 0) return '$hours小时$minutes分钟';
    if (minutes > 0) return '$minutes分钟';
    return '${d.inSeconds}秒';
  }

  String _fmtDay(DateTime d) => '${d.month}/${d.day}';
}

/// 胶囊切换 (模型渠道胶囊同款语言: 选中 primary 底白字,
/// 未选填充色, 无边框)。
class _CapsuleToggle extends StatelessWidget {
  final List<String> options;
  final String selected;
  final ValueChanged<String> onChanged;

  const _CapsuleToggle({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: options.map((o) {
          final isSelected = o == selected;
          return GestureDetector(
            onTap: () => onChanged(o),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                o,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// 每日趋势平滑折线 (Catmull-Rom 转三次贝塞尔, 与参考面的圆滑曲线同款)。
class _TrendChartPainter extends CustomPainter {
  final List<List<double>> series;
  final List<Color> colors;
  final double maxValue;
  final Color gridColor;

  const _TrendChartPainter({
    required this.series,
    required this.colors,
    required this.maxValue,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final f in <double>[0.25, 0.5, 0.75]) {
      final y = size.height * (1 - f);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    for (var s = 0; s < series.length; s++) {
      final values = series[s];
      if (values.isEmpty) continue;
      final color = colors[s % colors.length];
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      double yOf(double v) =>
          size.height * (1 - (maxValue > 0 ? v / maxValue : 0));
      if (values.length == 1) {
        canvas.drawCircle(
          Offset(size.width / 2, yOf(values[0])),
          3,
          paint..style = PaintingStyle.fill,
        );
        continue;
      }
      final points = <Offset>[];
      for (var i = 0; i < values.length; i++) {
        final x = size.width * i / (values.length - 1);
        points.add(Offset(x, yOf(values[i])));
      }
      final path = Path()..moveTo(points[0].dx, points[0].dy);
      for (var i = 0; i < points.length - 1; i++) {
        final p0 = i > 0 ? points[i - 1] : points[i];
        final p1 = points[i];
        final p2 = points[i + 1];
        final p3 = i + 2 < points.length ? points[i + 2] : p2;
        path.cubicTo(
          p1.dx + (p2.dx - p0.dx) / 6,
          p1.dy + (p2.dy - p0.dy) / 6,
          p2.dx - (p3.dx - p1.dx) / 6,
          p2.dy - (p3.dy - p1.dy) / 6,
          p2.dx,
          p2.dy,
        );
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendChartPainter old) =>
      old.series != series || old.maxValue != maxValue;
}
