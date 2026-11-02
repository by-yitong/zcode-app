/// 使用统计页 — 桌面端 / 网页端「使用统计」(应用用量) 的移动端呈现。
///
/// 对照参考面 (2026-11-03 用户截图的桌面端页面, 自上而下):
/// 1. 5 张汇总卡: 累计 Token 数 / 峰值 Token 数 / 最长聊天时长 /
///    当前连续天数 / 最长连续天数
/// 2. Token 活动热力图 (GitHub 贡献格样式) + 每日 / 每周 / 累计切换
/// 3. 时间范围: 近 7 日 / 近 30 日
/// 4. 每日 Token 趋势图: 按模型分线 (图例 + 平滑曲线)
///
/// 移动端适配说明:
/// - 桌面端左侧边栏导航不要, 只取主内容区; 5 卡横排改 2 列网格;
/// - 新 UI 不用分割线与边框, 卡片只靠填充色区分;
/// - 数据一次拉取 (range '30d'), 近 7 日在页内过滤, 不重复调接口;
/// - 热力图「每周」= 该周总量映射到周内每一天, 「累计」= 截止当天的累计值。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// 热力图强度色 (浅 → 深, 0 值用填充色最浅档)。
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
  AppUsage? _usage;
  String? _error;
  bool _loading = true;

  /// 热力图模式: 'daily' 每日 / 'weekly' 每周 / 'cumulative' 累计。
  String _heatmapMode = 'daily';

  /// 趋势图范围: '7d' 近 7 日 / '30d' 近 30 日 (页内过滤, 不重调接口)。
  String _trendRange = '7d';

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
      final usage = await AppUsageService().fetch(client);
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
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
  // 汇总卡
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
    final usage = _usage!;
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
  // Token 活动热力图
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
          if (_usage!.daily.isEmpty)
            Text(
              '暂无活动数据',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            _buildHeatmap(theme),
        ],
      ),
    );
  }

  /// 按当前模式算出的 每日 → 展示值。
  Map<DateTime, int> _heatmapValues() {
    final days = _usage!.daily;
    if (_heatmapMode == 'weekly') {
      final weekTotals = <DateTime, int>{};
      for (final d in days) {
        final monday = d.date.subtract(Duration(days: d.date.weekday - 1));
        weekTotals[monday] = (weekTotals[monday] ?? 0) + d.total;
      }
      return {
        for (final d in days)
          d.date:
              weekTotals[d.date.subtract(
                Duration(days: d.date.weekday - 1),
              )] ??
              0,
      };
    }
    if (_heatmapMode == 'cumulative') {
      var acc = 0;
      final map = <DateTime, int>{};
      for (final d in days) {
        acc += d.total;
        map[d.date] = acc;
      }
      return map;
    }
    return {for (final d in days) d.date: d.total};
  }

  Widget _buildHeatmap(ThemeData theme) {
    const cell = 12.0;
    const gap = 3.0;
    final values = _heatmapValues();
    final dates = values.keys.toList()..sort();
    final first = dates.first;
    final last = dates.last;
    final startMonday = first.subtract(Duration(days: first.weekday - 1));
    final endSunday = last.add(Duration(days: 7 - last.weekday));
    final weekCount = endSunday.difference(startMonday).inDays ~/ 7 + 1;
    var maxVal = 0;
    for (final v in values.values) {
      if (v > maxVal) maxVal = v;
    }

    final columns = <Widget>[];
    DateTime? prevMonth;
    for (var w = 0; w < weekCount; w++) {
      final weekStart = startMonday.add(Duration(days: w * 7));
      final showMonth =
          prevMonth == null ||
          prevMonth.month != weekStart.month ||
          prevMonth.year != weekStart.year;
      prevMonth = weekStart;
      final cells = <Widget>[
        SizedBox(
          height: 14,
          child: Text(
            showMonth ? '${weekStart.month}月' : '',
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 6),
      ];
      for (var d = 0; d < 7; d++) {
        final day = weekStart.add(Duration(days: d));
        final v = values[day];
        if (v == null) {
          // 序列外的日期 (首尾不完整周): 占位保持对齐。
          cells.add(const SizedBox(width: cell, height: cell));
        } else {
          cells.add(
            Container(
              width: cell,
              height: cell,
              decoration: BoxDecoration(
                color: _heatColor(v, maxVal),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          );
        }
        if (d < 6) cells.add(const SizedBox(height: gap));
      }
      columns.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: cells));
      if (w < weekCount - 1) columns.add(const SizedBox(width: gap));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: columns),
    );
  }

  Color _heatColor(int value, int maxVal) {
    if (value <= 0 || maxVal <= 0) return _heatEmpty;
    final ratio = value / maxVal;
    if (ratio <= 0.25) return _heatLevels[0];
    if (ratio <= 0.5) return _heatLevels[1];
    if (ratio <= 0.75) return _heatLevels[2];
    return _heatLevels[3];
  }

  // ---------------------------------------------------------------
  // 时间范围 + 趋势图
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
            setState(() {
              _trendRange = label == '近 7 日' ? '7d' : '30d';
            });
          },
        ),
      ],
    );
  }

  /// 趋势图取的日子: 近 7 日 = 以序列最后一天为锚的最近 7 天, 近 30 日 = 全量。
  List<DailyTokenUsage> _trendDays() {
    final days = _usage!.daily;
    if (_trendRange != '7d' || days.isEmpty) return days;
    final anchor = days.last.date;
    final cutoff = anchor.subtract(const Duration(days: 6));
    return days.where((d) => !d.date.isBefore(cutoff)).toList();
  }

  Widget _buildTrendCard(ThemeData theme) {
    final days = _trendDays();
    final models = _usage!.models;
    final hasModels = models.isNotEmpty;
    final seriesNames = hasModels ? models : const ['全部'];
    final seriesValues = <List<double>>[];
    var maxVal = 0.0;
    for (final name in seriesNames) {
      final values = days.map((d) {
        final v = hasModels
            ? (d.byModel[name] ?? 0)
            : d.total;
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
                    Text(
                      seriesNames[i],
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (days.isEmpty)
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
