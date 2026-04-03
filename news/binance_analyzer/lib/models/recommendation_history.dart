import 'dart:convert';

/// 单次推荐记录（存入 SharedPreferences）
class PickRecord {
  final String symbol;
  final double entryPrice; // 推荐时价格
  final DateTime date; // 推荐日期
  final double score;
  final double entryScore;
  final String recommendation;
  final String timingLabel;
  double? exitPrice; // 次日检测价格
  bool? isWin; // 是否盈利

  PickRecord({
    required this.symbol,
    required this.entryPrice,
    required this.date,
    this.score = 0,
    this.entryScore = 0,
    this.recommendation = '',
    this.timingLabel = '',
    this.exitPrice,
    this.isWin,
  });

  double get changePercent {
    if (exitPrice == null || entryPrice == 0) return 0;
    return (exitPrice! - entryPrice) / entryPrice * 100;
  }

  bool get isPending => exitPrice == null;

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'entryPrice': entryPrice,
        'date': date.toIso8601String(),
        'score': score,
        'entryScore': entryScore,
        'recommendation': recommendation,
        'timingLabel': timingLabel,
        'exitPrice': exitPrice,
        'isWin': isWin,
      };

  factory PickRecord.fromJson(Map<String, dynamic> json) => PickRecord(
        symbol: json['symbol'] as String,
        entryPrice: (json['entryPrice'] as num).toDouble(),
        date: DateTime.parse(json['date'] as String),
        score: (json['score'] as num?)?.toDouble() ?? 0,
        entryScore: (json['entryScore'] as num?)?.toDouble() ?? 0,
        recommendation: json['recommendation'] as String? ?? '',
        timingLabel: json['timingLabel'] as String? ?? '',
        exitPrice: json['exitPrice'] != null
            ? (json['exitPrice'] as num).toDouble()
            : null,
        isWin: json['isWin'] as bool?,
      );
}

/// 某一天的推荐集合
class DailyRecommendation {
  final DateTime date;
  final List<PickRecord> picks; // 最多3个

  DailyRecommendation({required this.date, required this.picks});

  /// 已结算的胜率
  double get winRate {
    final settled = picks.where((p) => p.isWin != null).toList();
    if (settled.isEmpty) return 0;
    final wins = settled.where((p) => p.isWin == true).length;
    return wins / settled.length;
  }

  bool get isPending => picks.any((p) => p.isPending);

  String get dateLabel {
    final now = DateTime.now();
    final diff = now.difference(date).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${date.month}月${date.day}日';
  }

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'picks': picks.map((p) => p.toJson()).toList(),
      };

  factory DailyRecommendation.fromJson(Map<String, dynamic> json) =>
      DailyRecommendation(
        date: DateTime.parse(json['date'] as String),
        picks: (json['picks'] as List<dynamic>)
            .map((p) => PickRecord.fromJson(p as Map<String, dynamic>))
            .toList(),
      );

  static String encodeList(List<DailyRecommendation> list) =>
      jsonEncode(list.map((d) => d.toJson()).toList());

  static List<DailyRecommendation> decodeList(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((d) => DailyRecommendation.fromJson(d as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
