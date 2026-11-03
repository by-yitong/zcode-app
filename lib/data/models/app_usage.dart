/// 应用用量统计模型 — 对应桌面端 / 网页端「使用统计」页 (应用用量)。
///
/// 数据来源: relay `usage-stats.getAppUsageSnapshot({range, timeZone})`。
///
/// 响应结构 (2026-11-02 网页端抓包实测, rpcId 295/296, 非文档推测):
/// - 顶层: `{range, generatedAt, timeZone, source, summary, heatmap,
///   dailyModelUsage, models}`
/// - summary: `totalTokens` (累计) / `peakDayTokens` (峰值, 单日最高) /
///   `longestSessionMs` (最长单次聊天, 毫秒) / `currentStreakDays` /
///   `longestStreakDays` / `totalSessions` / `favoriteModel` 等
/// - heatmap: `{startDate, endDate, maxTokens, weeks}`; weeks 为从 startDate
///   起连续 7 天一切块 (非自然周), 每块 days 7 项, 未来日期为 null 占位;
///   每项 `{date, level(0-4), totalTokens, turnCount, toolCallCount}`
/// - dailyModelUsage: `[{date, models: [{modelId, totalTokens}]}]` (趋势图分线用)
/// - models: 各模型汇总 (已按 share 降序)
///
/// 网页端一次拉两条: `range: "all"` (汇总 + 热力图) 与 `range: "7d"/"30d"`
/// (趋势图); 时间范围切换时只重拉趋势那条。本页照此办理。
///
/// 旧别名兜底保留 (响应缺字段时从日序列推算累计/峰值/连续天数),
/// 只有最长聊天时长推算不出来, 缺失时为空。
library;

/// 单日 Token 用量。
class DailyTokenUsage {
  /// 当天 (本地日期, 已去掉时分秒)。
  final DateTime date;

  /// 当天 Token 总数。
  final int total;

  /// 按模型分的日用量 (模型名 → Token 数), 无分模型数据时为空。
  final Map<String, int> byModel;

  /// 服务端热力强度 0-4 (heatmap.days[].level), 非 heatmap 来源时为 null。
  final int? level;

  const DailyTokenUsage({
    required this.date,
    required this.total,
    this.byModel = const {},
    this.level,
  });
}

/// 应用用量统计快照 (一次 getAppUsageSnapshot 调用的解析结果)。
class AppUsage {
  /// 累计 Token 数 (summary.totalTokens)。
  final int? totalTokens;

  /// 峰值 Token 数 (summary.peakDayTokens, 单日最高)。
  final int? peakTokens;

  /// 最长单次聊天时长 (summary.longestSessionMs, 毫秒)。
  final Duration? longestChat;

  /// 预格式化的最长聊天时长文本 (响应直接给文本时用, 优先于 Duration 换算)。
  final String? longestChatText;

  /// 当前连续使用天数 (summary.currentStreakDays)。
  final int? currentStreakDays;

  /// 最长连续使用天数 (summary.longestStreakDays)。
  final int? longestStreakDays;

  /// 日序列 (按日期升序, heatmap 与 dailyModelUsage 合并后)。
  final List<DailyTokenUsage> daily;

  /// 热力周块 (服务端 weeks 原样: 每块 7 项, null = 未来日期占位)。
  /// 无服务端周块时由 daily 每 7 天切块兜底 (无 null 项)。
  final List<List<DailyTokenUsage?>> heatWeeks;

  const AppUsage({
    this.totalTokens,
    this.peakTokens,
    this.longestChat,
    this.longestChatText,
    this.currentStreakDays,
    this.longestStreakDays,
    this.daily = const [],
    this.heatWeeks = const [],
  });

  /// 日序列求和得到的累计 (API 没给累计时用它)。
  int get computedTotal => daily.fold(0, (sum, d) => sum + d.total);

  /// 展示用累计 Token: API 原值优先, 否则日序列求和。
  int get effectiveTotal => totalTokens ?? computedTotal;

  /// 展示用峰值 Token: API 原值优先, 否则日序列单日最高。
  int get effectivePeak {
    if (peakTokens != null) return peakTokens!;
    var peak = 0;
    for (final d in daily) {
      if (d.total > peak) peak = d.total;
    }
    return peak;
  }

  /// 展示用当前连续天数: API 原值优先, 否则从日序列推算
  /// (从今天 (或昨天, 当今天暂无数据时) 往回数连续有用的天数)。
  int get effectiveCurrentStreak =>
      currentStreakDays ?? _streakFromSeries(current: true);

  /// 展示用最长连续天数: API 原值优先, 否则从日序列推算最长连续段。
  int get effectiveLongestStreak =>
      longestStreakDays ?? _streakFromSeries(current: false);

  /// 日序列里出现过的模型, 按总量降序 (趋势图图例与配色顺序用它)。
  List<String> get models {
    final totals = <String, int>{};
    for (final d in daily) {
      d.byModel.forEach((name, v) {
        totals[name] = (totals[name] ?? 0) + v;
      });
    }
    final names = totals.keys.toList()
      ..sort((a, b) => totals[b]!.compareTo(totals[a]!));
    return names;
  }

  int _streakFromSeries({required bool current}) {
    if (daily.isEmpty) return 0;
    final active = <DateTime>{};
    for (final d in daily) {
      if (d.total > 0) active.add(d.date);
    }
    if (active.isEmpty) return 0;
    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    if (current) {
      var cursor = day(DateTime.now());
      if (!active.contains(cursor)) {
        cursor = cursor.subtract(const Duration(days: 1));
      }
      if (!active.contains(cursor)) return 0;
      var streak = 0;
      while (active.contains(cursor)) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
      }
      return streak;
    }
    var longest = 0;
    var run = 0;
    DateTime? prev;
    final sorted = active.toList()..sort();
    for (final d in sorted) {
      if (prev != null && d.difference(prev).inDays == 1) {
        run++;
      } else {
        run = 1;
      }
      if (run > longest) longest = run;
      prev = d;
    }
    return longest;
  }

  // ---------------------------------------------------------------
  // 解析 (实测结构优先, 旧别名兜底)
  // ---------------------------------------------------------------

  factory AppUsage.fromJson(Map<String, dynamic> body) {
    final root = body['data'] is Map<String, dynamic>
        ? body['data'] as Map<String, dynamic>
        : body;
    final summary = root['summary'] is Map<String, dynamic>
        ? root['summary'] as Map<String, dynamic>
        : root;

    // 1. heatmap 周块 (实测结构, null = 未来占位)。
    final weeks = <List<DailyTokenUsage?>>[];
    final byDate = <DateTime, DailyTokenUsage>{};
    final heat = root['heatmap'];
    if (heat is Map) {
      final weekList = heat['weeks'];
      if (weekList is List) {
        for (final w in weekList) {
          if (w is! Map) continue;
          final days = w['days'];
          if (days is! List) continue;
          final week = <DailyTokenUsage?>[];
          for (final d in days) {
            if (d is! Map) {
              week.add(null);
              continue;
            }
            final dm = Map<String, dynamic>.from(d);
            final date = _parseDate(dm['date']);
            final total = _asInt(dm['totalTokens'] ?? dm['tokens']);
            if (date == null || total == null) {
              week.add(null);
              continue;
            }
            final entry = DailyTokenUsage(
              date: date,
              total: total,
              level: _asInt(dm['level']),
            );
            week.add(entry);
            byDate[date] = entry;
          }
          weeks.add(week);
        }
      }
    }

    // 2. dailyModelUsage 合并分模型 (同步回周块, 趋势图分线用)。
    final dmu = root['dailyModelUsage'];
    if (dmu is List) {
      for (final e in dmu) {
        if (e is! Map) continue;
        final em = Map<String, dynamic>.from(e);
        final date = _parseDate(em['date']);
        if (date == null) continue;
        final byModel = <String, int>{};
        final models = em['models'];
        if (models is List) {
          for (final m in models) {
            if (m is! Map) continue;
            final mm = Map<String, dynamic>.from(m);
            final id = mm['modelId']?.toString();
            final v = _asInt(mm['totalTokens']);
            if (id != null && v != null) byModel[id] = v;
          }
        }
        final existing = byDate[date];
        if (existing != null) {
          final merged = DailyTokenUsage(
            date: date,
            total: existing.total,
            byModel: byModel,
            level: existing.level,
          );
          byDate[date] = merged;
          for (final week in weeks) {
            for (var i = 0; i < week.length; i++) {
              if (week[i]?.date == date) week[i] = merged;
            }
          }
        } else {
          final total = byModel.values.fold<int>(0, (a, b) => a + b);
          byDate[date] = DailyTokenUsage(
            date: date,
            total: total,
            byModel: byModel,
          );
        }
      }
    }

    // 3. 日序列 (排序); 两路都空时走旧别名兜底。
    var daily = byDate.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    if (daily.isEmpty) {
      daily = _parseDaily(
        root['daily'] ?? root['activity'] ?? root['days'] ?? root['series'],
      );
    }

    // 4. 周块兜底: 无服务端周块时按首日起点每 7 天切块 (无 null 项)。
    var heatWeeks = weeks;
    if (heatWeeks.isEmpty && daily.isNotEmpty) {
      heatWeeks = [];
      for (var i = 0; i < daily.length; i += 7) {
        final end = (i + 7).clamp(0, daily.length);
        heatWeeks.add(
          daily.sublist(i, end).map((d) => d as DailyTokenUsage?).toList(),
        );
      }
    }

    return AppUsage(
      totalTokens: _asInt(
        summary['totalTokens'] ??
            summary['total'] ??
            summary['cumulativeTokens'],
      ),
      peakTokens: _asInt(
        summary['peakDayTokens'] ??
            summary['peakTokens'] ??
            summary['peakDailyTokens'] ??
            summary['maxDailyTokens'],
      ),
      longestChat: _parseDuration(summary),
      longestChatText: () {
        final v =
            summary['longestChatDurationText'] ?? summary['longestChatText'];
        return v is String && v.isNotEmpty ? v : null;
      }(),
      currentStreakDays: _asInt(
        summary['currentStreakDays'] ??
            summary['currentStreak'] ??
            summary['currentConsecutiveDays'],
      ),
      longestStreakDays: _asInt(
        summary['longestStreakDays'] ??
            summary['longestStreak'] ??
            summary['maxConsecutiveDays'],
      ),
      daily: daily,
      heatWeeks: heatWeeks,
    );
  }

  static Duration? _parseDuration(Map<String, dynamic> summary) {
    // 带单位的显式字段优先 (实测: longestSessionMs, 毫秒)。
    final ms = _asInt(
      summary['longestSessionMs'] ??
          summary['longestChatDurationMs'] ??
          summary['longestChatMs'],
    );
    if (ms != null) return Duration(milliseconds: ms);
    final seconds = _asInt(
      summary['longestChatDurationSeconds'] ?? summary['longestChatSeconds'],
    );
    if (seconds != null) return Duration(seconds: seconds);
    final minutes = _asInt(
      summary['longestChatDurationMinutes'] ?? summary['longestChatMinutes'],
    );
    if (minutes != null) return Duration(minutes: minutes);
    // 无单位的裸数字: 只有大到不可能是秒/分钟时才当毫秒 (≥1 小时毫秒数),
    // 否则宁可缺失也不猜错单位。
    final bare = _asInt(
      summary['longestChatDuration'] ?? summary['longestChat'],
    );
    if (bare != null && bare >= 3600000) {
      return Duration(milliseconds: bare);
    }
    return null;
  }

  /// 旧形态日序列兜底 (list / map, 字段别名)。
  static List<DailyTokenUsage> _parseDaily(dynamic raw) {
    final entries = <DailyTokenUsage>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          final d = _parseDay(e);
          if (d != null) entries.add(d);
        } else if (e is Map) {
          final d = _parseDay(Map<String, dynamic>.from(e));
          if (d != null) entries.add(d);
        }
      }
    } else if (raw is Map) {
      raw.forEach((key, value) {
        final date = _parseDate(key);
        if (date == null) return;
        if (value is num) {
          entries.add(DailyTokenUsage(date: date, total: value.toInt()));
        } else if (value is Map) {
          final m = Map<String, dynamic>.from(value);
          m['date'] ??= key;
          final d = _parseDay(m);
          if (d != null) entries.add(d);
        }
      });
    }
    entries.sort((a, b) => a.date.compareTo(b.date));
    final merged = <DailyTokenUsage>[];
    for (final e in entries) {
      if (merged.isNotEmpty && merged.last.date == e.date) {
        final last = merged.removeLast();
        final byModel = Map<String, int>.from(last.byModel);
        e.byModel.forEach((k, v) => byModel[k] = (byModel[k] ?? 0) + v);
        merged.add(
          DailyTokenUsage(
            date: e.date,
            total: last.total + e.total,
            byModel: byModel,
          ),
        );
      } else {
        merged.add(e);
      }
    }
    return merged;
  }

  static DailyTokenUsage? _parseDay(Map<String, dynamic> e) {
    final date = _parseDate(e['date'] ?? e['day'] ?? e['timestamp']);
    if (date == null) return null;
    final byModel = <String, int>{};
    final modelMap =
        e['models'] ?? e['byModel'] ?? e['tokensByModel'] ?? e['perModel'];
    if (modelMap is Map) {
      modelMap.forEach((key, value) {
        final v = _asInt(value);
        if (v != null) byModel[key.toString()] = v;
      });
    }
    var total = _asInt(
      e['tokens'] ?? e['total'] ?? e['totalTokens'] ?? e['value'],
    );
    total ??= byModel.values.fold<int>(0, (sum, v) => sum + v);
    return DailyTokenUsage(date: date, total: total, byModel: byModel);
  }

  static DateTime? _parseDate(dynamic v) {
    try {
      if (v is num) {
        // 毫秒时间戳 (秒级时间戳 < 1e11, 毫秒级 ≥ 1e11, 粗分即可)。
        final ms =
            v.abs() < 100000000000 ? v.toInt() * 1000 : v.toInt();
        final d = DateTime.fromMillisecondsSinceEpoch(ms);
        return DateTime(d.year, d.month, d.day);
      }
      if (v is String) {
        if (v.isEmpty) return null;
        final d = DateTime.tryParse(v);
        if (d == null) return null;
        return DateTime(d.year, d.month, d.day);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    if (v is num) return v.toInt();
    return null;
  }
}
