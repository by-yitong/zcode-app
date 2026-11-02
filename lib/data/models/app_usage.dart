/// 应用用量统计模型 — 对应桌面端 / 网页端「使用统计」页 (应用用量)。
///
/// 数据来源: relay `usage-stats.getAppUsageSnapshot({range, timeZone})`
/// (方法与参数见 docs/v4-API协议规格.md usage-stats channel)。
///
/// 注意: 该方法的响应字段在仓库文档里没有记载 (只登记了方法名与参数),
/// 因此解析刻意做得宽容: 汇总字段接受多个别名, 日序列接受 list / map
/// 两种形态, 缺失的汇总项 (累计/峰值/连续天数) 从日序列里推算,
/// 只有最长聊天时长推算不出来 (日序列没有单次聊天时长), 缺失时为空。
/// 首次在真机上跑通后, 应按实际响应把这里的别名收敛为实测字段。
library;

/// 单日 Token 用量。
class DailyTokenUsage {
  /// 当天 (本地日期, 已去掉时分秒)。
  final DateTime date;

  /// 当天 Token 总数。
  final int total;

  /// 按模型分的日用量 (模型名 → Token 数), 无分模型数据时为空。
  final Map<String, int> byModel;

  const DailyTokenUsage({
    required this.date,
    required this.total,
    this.byModel = const {},
  });
}

/// 应用用量统计快照。
class AppUsage {
  /// 累计 Token 数 (API 原值, null = 响应里没有, 调用方用 [effectiveTotal])。
  final int? totalTokens;

  /// 峰值 Token 数: 单日最高 Token (API 原值, null 时从日序列推算)。
  final int? peakTokens;

  /// 最长单次聊天时长 (API 原值, 推算不出来, 缺失时为 null)。
  final Duration? longestChat;

  /// 预格式化的最长聊天时长文本 (响应直接给文本时用, 优先于 Duration 换算)。
  final String? longestChatText;

  /// 当前连续使用天数 (API 原值, null 时从日序列推算)。
  final int? currentStreakDays;

  /// 最长连续使用天数 (API 原值, null 时从日序列推算)。
  final int? longestStreakDays;

  /// 日序列 (按日期升序)。
  final List<DailyTokenUsage> daily;

  const AppUsage({
    this.totalTokens,
    this.peakTokens,
    this.longestChat,
    this.longestChatText,
    this.currentStreakDays,
    this.longestStreakDays,
    this.daily = const [],
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
      if (!active.contains(cursor)) cursor = cursor.subtract(const Duration(days: 1));
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
  // 宽容解析
  // ---------------------------------------------------------------

  /// 从 getAppUsageSnapshot 的响应 body 解析。
  /// 顶层可能包一层 data, 汇总可能在 summary 对象里, 都兼容。
  factory AppUsage.fromJson(Map<String, dynamic> body) {
    final root = body['data'] is Map<String, dynamic>
        ? body['data'] as Map<String, dynamic>
        : body;
    final summary = root['summary'] is Map<String, dynamic>
        ? root['summary'] as Map<String, dynamic>
        : root;

    final daily = _parseDaily(
      root['daily'] ?? root['activity'] ?? root['days'] ?? root['series'],
    );

    return AppUsage(
      totalTokens: _asInt(
        summary['totalTokens'] ??
            summary['total'] ??
            summary['cumulativeTokens'],
      ),
      peakTokens: _asInt(
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
    );
  }

  static Duration? _parseDuration(Map<String, dynamic> summary) {
    // 带单位的显式字段优先。
    final ms = _asInt(
      summary['longestChatDurationMs'] ?? summary['longestChatMs'],
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
      // map 形态: { '2026-10-01': 123 } 或 { '2026-10-01': {total, models} }
      raw.forEach((key, value) {
        final date = _parseDate(key);
        if (date == null) return;
        if (value is num) {
          entries.add(
            DailyTokenUsage(date: date, total: value.toInt()),
          );
        } else if (value is Map) {
          final m = Map<String, dynamic>.from(value);
          m['date'] ??= key;
          final d = _parseDay(m);
          if (d != null) entries.add(d);
        }
      });
    }
    entries.sort((a, b) => a.date.compareTo(b.date));
    // 同一天多条时合并 (取和, 分模型也合并)。
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
        final ms = v.abs() < 100000000000
            ? v.toInt() * 1000
            : v.toInt();
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
