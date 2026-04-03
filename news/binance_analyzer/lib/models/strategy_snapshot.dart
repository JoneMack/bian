import 'dart:convert';

class StrategyBacktestReport {
  final String presetId;
  final String presetLabel;
  final int testDays;
  final double avgTop3Return;
  final double benchmarkReturn;
  final double winRate;
  final double positiveDaysRate;
  final DateTime generatedAt;

  const StrategyBacktestReport({
    required this.presetId,
    required this.presetLabel,
    required this.testDays,
    required this.avgTop3Return,
    required this.benchmarkReturn,
    required this.winRate,
    required this.positiveDaysRate,
    required this.generatedAt,
  });

  double get edgeVsBenchmark => avgTop3Return - benchmarkReturn;

  Map<String, dynamic> toJson() => {
        'presetId': presetId,
        'presetLabel': presetLabel,
        'testDays': testDays,
        'avgTop3Return': avgTop3Return,
        'benchmarkReturn': benchmarkReturn,
        'winRate': winRate,
        'positiveDaysRate': positiveDaysRate,
        'generatedAt': generatedAt.toIso8601String(),
      };

  factory StrategyBacktestReport.fromJson(Map<String, dynamic> json) {
    return StrategyBacktestReport(
      presetId: json['presetId'] as String? ?? '',
      presetLabel: json['presetLabel'] as String? ?? '',
      testDays: json['testDays'] as int? ?? 0,
      avgTop3Return: (json['avgTop3Return'] as num?)?.toDouble() ?? 0,
      benchmarkReturn: (json['benchmarkReturn'] as num?)?.toDouble() ?? 0,
      winRate: (json['winRate'] as num?)?.toDouble() ?? 0,
      positiveDaysRate: (json['positiveDaysRate'] as num?)?.toDouble() ?? 0,
      generatedAt: DateTime.tryParse(json['generatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static String encode(StrategyBacktestReport report) =>
      jsonEncode(report.toJson());
}

class EntrySignalPolicy {
  final String id;
  final String label;
  final double minTotalScore;
  final double minEntryScore;
  final double minVolumeRatio;
  final double maxBreakoutDistance;
  final int maxSignalsPerHour;
  final int cooldownHours;
  final List<String> allowedLabels;

  static const EntrySignalPolicy defaultPolicy = EntrySignalPolicy(
    id: 'default-v1',
    label: '默认提醒',
    minTotalScore: 0.62,
    minEntryScore: 0.60,
    minVolumeRatio: 1.0,
    maxBreakoutDistance: 3.2,
    maxSignalsPerHour: 1,
    cooldownHours: 6,
    allowedLabels: ['可入场', '临近买点'],
  );

  const EntrySignalPolicy({
    required this.id,
    required this.label,
    required this.minTotalScore,
    required this.minEntryScore,
    required this.minVolumeRatio,
    required this.maxBreakoutDistance,
    required this.maxSignalsPerHour,
    required this.cooldownHours,
    required this.allowedLabels,
  });

  bool matches(EntryAlertSignal signal) {
    return allowedLabels.contains(signal.timingLabel) &&
        signal.totalScore >= minTotalScore &&
        signal.entryScore >= minEntryScore &&
        signal.volumeRatio >= minVolumeRatio &&
        signal.breakoutDistance <= maxBreakoutDistance;
  }

  String get summary =>
      '${allowedLabels.join('/')} | 总分>=${(minTotalScore * 100).round()} '
      '| 时机>=${(minEntryScore * 100).round()} '
      '| 量比>=${minVolumeRatio.toStringAsFixed(2)}x '
      '| 突破<=${maxBreakoutDistance.toStringAsFixed(1)}% '
      '| 冷却${cooldownHours}h';

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'minTotalScore': minTotalScore,
        'minEntryScore': minEntryScore,
        'minVolumeRatio': minVolumeRatio,
        'maxBreakoutDistance': maxBreakoutDistance,
        'maxSignalsPerHour': maxSignalsPerHour,
        'cooldownHours': cooldownHours,
        'allowedLabels': allowedLabels,
      };

  factory EntrySignalPolicy.fromJson(Map<String, dynamic> json) {
    return EntrySignalPolicy(
      id: json['id'] as String? ?? defaultPolicy.id,
      label: json['label'] as String? ?? defaultPolicy.label,
      minTotalScore: (json['minTotalScore'] as num?)?.toDouble() ??
          defaultPolicy.minTotalScore,
      minEntryScore: (json['minEntryScore'] as num?)?.toDouble() ??
          defaultPolicy.minEntryScore,
      minVolumeRatio: (json['minVolumeRatio'] as num?)?.toDouble() ??
          defaultPolicy.minVolumeRatio,
      maxBreakoutDistance: (json['maxBreakoutDistance'] as num?)?.toDouble() ??
          defaultPolicy.maxBreakoutDistance,
      maxSignalsPerHour:
          json['maxSignalsPerHour'] as int? ?? defaultPolicy.maxSignalsPerHour,
      cooldownHours:
          json['cooldownHours'] as int? ?? defaultPolicy.cooldownHours,
      allowedLabels: (json['allowedLabels'] as List<dynamic>? ??
              defaultPolicy.allowedLabels)
          .map((item) => item.toString())
          .toList(),
    );
  }

  static String encode(EntrySignalPolicy policy) => jsonEncode(policy.toJson());
}

class EntryAlertSignal {
  final String symbol;
  final String timingLabel;
  final String timingReason;
  final double currentPrice;
  final double dayChangePercent;
  final double totalScore;
  final double entryScore;
  final double volumeRatio;
  final double breakoutDistance;
  final double pullbackPercent;
  final bool shouldNotify;

  const EntryAlertSignal({
    required this.symbol,
    required this.timingLabel,
    required this.timingReason,
    required this.currentPrice,
    required this.dayChangePercent,
    required this.totalScore,
    required this.entryScore,
    required this.volumeRatio,
    required this.breakoutDistance,
    required this.pullbackPercent,
    required this.shouldNotify,
  });

  EntryAlertSignal copyWith({
    String? symbol,
    String? timingLabel,
    String? timingReason,
    double? currentPrice,
    double? dayChangePercent,
    double? totalScore,
    double? entryScore,
    double? volumeRatio,
    double? breakoutDistance,
    double? pullbackPercent,
    bool? shouldNotify,
  }) {
    return EntryAlertSignal(
      symbol: symbol ?? this.symbol,
      timingLabel: timingLabel ?? this.timingLabel,
      timingReason: timingReason ?? this.timingReason,
      currentPrice: currentPrice ?? this.currentPrice,
      dayChangePercent: dayChangePercent ?? this.dayChangePercent,
      totalScore: totalScore ?? this.totalScore,
      entryScore: entryScore ?? this.entryScore,
      volumeRatio: volumeRatio ?? this.volumeRatio,
      breakoutDistance: breakoutDistance ?? this.breakoutDistance,
      pullbackPercent: pullbackPercent ?? this.pullbackPercent,
      shouldNotify: shouldNotify ?? this.shouldNotify,
    );
  }

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'timingLabel': timingLabel,
        'timingReason': timingReason,
        'currentPrice': currentPrice,
        'dayChangePercent': dayChangePercent,
        'totalScore': totalScore,
        'entryScore': entryScore,
        'volumeRatio': volumeRatio,
        'breakoutDistance': breakoutDistance,
        'pullbackPercent': pullbackPercent,
        'shouldNotify': shouldNotify,
      };

  factory EntryAlertSignal.fromJson(Map<String, dynamic> json) {
    return EntryAlertSignal(
      symbol: json['symbol'] as String? ?? '',
      timingLabel: json['timingLabel'] as String? ?? '',
      timingReason: json['timingReason'] as String? ?? '',
      currentPrice: (json['currentPrice'] as num?)?.toDouble() ?? 0,
      dayChangePercent: (json['dayChangePercent'] as num?)?.toDouble() ?? 0,
      totalScore: (json['totalScore'] as num?)?.toDouble() ?? 0,
      entryScore: (json['entryScore'] as num?)?.toDouble() ?? 0,
      volumeRatio: (json['volumeRatio'] as num?)?.toDouble() ?? 0,
      breakoutDistance: (json['breakoutDistance'] as num?)?.toDouble() ?? 0,
      pullbackPercent: (json['pullbackPercent'] as num?)?.toDouble() ?? 0,
      shouldNotify: json['shouldNotify'] as bool? ?? false,
    );
  }

  static String encodeList(List<EntryAlertSignal> list) =>
      jsonEncode(list.map((item) => item.toJson()).toList());

  static List<EntryAlertSignal> decodeList(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
              (item) => EntryAlertSignal.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

class ReplayAlertOutcome {
  final DateTime triggeredAt;
  final String symbol;
  final String timingLabel;
  final double totalScore;
  final double entryScore;
  final double entryPrice;
  final double next24hCloseReturn;
  final double next24hBestReturn;
  final bool isWin;

  const ReplayAlertOutcome({
    required this.triggeredAt,
    required this.symbol,
    required this.timingLabel,
    required this.totalScore,
    required this.entryScore,
    required this.entryPrice,
    required this.next24hCloseReturn,
    required this.next24hBestReturn,
    required this.isWin,
  });

  Map<String, dynamic> toJson() => {
        'triggeredAt': triggeredAt.toIso8601String(),
        'symbol': symbol,
        'timingLabel': timingLabel,
        'totalScore': totalScore,
        'entryScore': entryScore,
        'entryPrice': entryPrice,
        'next24hCloseReturn': next24hCloseReturn,
        'next24hBestReturn': next24hBestReturn,
        'isWin': isWin,
      };

  factory ReplayAlertOutcome.fromJson(Map<String, dynamic> json) {
    return ReplayAlertOutcome(
      triggeredAt: DateTime.tryParse(json['triggeredAt'] as String? ?? '') ??
          DateTime.now(),
      symbol: json['symbol'] as String? ?? '',
      timingLabel: json['timingLabel'] as String? ?? '',
      totalScore: (json['totalScore'] as num?)?.toDouble() ?? 0,
      entryScore: (json['entryScore'] as num?)?.toDouble() ?? 0,
      entryPrice: (json['entryPrice'] as num?)?.toDouble() ?? 0,
      next24hCloseReturn: (json['next24hCloseReturn'] as num?)?.toDouble() ?? 0,
      next24hBestReturn: (json['next24hBestReturn'] as num?)?.toDouble() ?? 0,
      isWin: json['isWin'] as bool? ?? false,
    );
  }
}

class HourlyReplayReport {
  final DateTime generatedAt;
  final DateTime windowStart;
  final DateTime windowEnd;
  final int simulatedHours;
  final int silentHours;
  final int top3SampleCount;
  final double top3WinRate;
  final double top3AvgReturn;
  final int alertSampleCount;
  final double alertWinRate;
  final double alertAvgReturn;
  final double alertBestReturn;
  final int validationHours;
  final int validationSilentHours;
  final int validationAlertSampleCount;
  final double validationAlertWinRate;
  final double validationAlertAvgReturn;
  final double targetWinRate;
  final bool targetMet;
  final EntrySignalPolicy optimizedPolicy;
  final String notes;
  final List<ReplayAlertOutcome> recentAlerts;

  const HourlyReplayReport({
    required this.generatedAt,
    required this.windowStart,
    required this.windowEnd,
    required this.simulatedHours,
    required this.silentHours,
    required this.top3SampleCount,
    required this.top3WinRate,
    required this.top3AvgReturn,
    required this.alertSampleCount,
    required this.alertWinRate,
    required this.alertAvgReturn,
    required this.alertBestReturn,
    required this.validationHours,
    required this.validationSilentHours,
    required this.validationAlertSampleCount,
    required this.validationAlertWinRate,
    required this.validationAlertAvgReturn,
    required this.targetWinRate,
    required this.targetMet,
    required this.optimizedPolicy,
    required this.notes,
    required this.recentAlerts,
  });

  double get silentRate =>
      simulatedHours == 0 ? 0 : silentHours / simulatedHours;

  double get validationSilentRate =>
      validationHours == 0 ? 0 : validationSilentHours / validationHours;

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'windowStart': windowStart.toIso8601String(),
        'windowEnd': windowEnd.toIso8601String(),
        'simulatedHours': simulatedHours,
        'silentHours': silentHours,
        'top3SampleCount': top3SampleCount,
        'top3WinRate': top3WinRate,
        'top3AvgReturn': top3AvgReturn,
        'alertSampleCount': alertSampleCount,
        'alertWinRate': alertWinRate,
        'alertAvgReturn': alertAvgReturn,
        'alertBestReturn': alertBestReturn,
        'validationHours': validationHours,
        'validationSilentHours': validationSilentHours,
        'validationAlertSampleCount': validationAlertSampleCount,
        'validationAlertWinRate': validationAlertWinRate,
        'validationAlertAvgReturn': validationAlertAvgReturn,
        'targetWinRate': targetWinRate,
        'targetMet': targetMet,
        'optimizedPolicy': optimizedPolicy.toJson(),
        'notes': notes,
        'recentAlerts': recentAlerts.map((item) => item.toJson()).toList(),
      };

  factory HourlyReplayReport.fromJson(Map<String, dynamic> json) {
    return HourlyReplayReport(
      generatedAt: DateTime.tryParse(json['generatedAt'] as String? ?? '') ??
          DateTime.now(),
      windowStart: DateTime.tryParse(json['windowStart'] as String? ?? '') ??
          DateTime.now(),
      windowEnd: DateTime.tryParse(json['windowEnd'] as String? ?? '') ??
          DateTime.now(),
      simulatedHours: json['simulatedHours'] as int? ?? 0,
      silentHours: json['silentHours'] as int? ?? 0,
      top3SampleCount: json['top3SampleCount'] as int? ?? 0,
      top3WinRate: (json['top3WinRate'] as num?)?.toDouble() ?? 0,
      top3AvgReturn: (json['top3AvgReturn'] as num?)?.toDouble() ?? 0,
      alertSampleCount: json['alertSampleCount'] as int? ?? 0,
      alertWinRate: (json['alertWinRate'] as num?)?.toDouble() ?? 0,
      alertAvgReturn: (json['alertAvgReturn'] as num?)?.toDouble() ?? 0,
      alertBestReturn: (json['alertBestReturn'] as num?)?.toDouble() ?? 0,
      validationHours: json['validationHours'] as int? ?? 0,
      validationSilentHours: json['validationSilentHours'] as int? ?? 0,
      validationAlertSampleCount:
          json['validationAlertSampleCount'] as int? ?? 0,
      validationAlertWinRate:
          (json['validationAlertWinRate'] as num?)?.toDouble() ?? 0,
      validationAlertAvgReturn:
          (json['validationAlertAvgReturn'] as num?)?.toDouble() ?? 0,
      targetWinRate: (json['targetWinRate'] as num?)?.toDouble() ?? 0.8,
      targetMet: json['targetMet'] as bool? ?? false,
      optimizedPolicy: EntrySignalPolicy.fromJson(
        json['optimizedPolicy'] is Map
            ? Map<String, dynamic>.from(json['optimizedPolicy'] as Map)
            : const <String, dynamic>{},
      ),
      notes: json['notes'] as String? ?? '',
      recentAlerts: (json['recentAlerts'] as List<dynamic>? ?? [])
          .map((item) =>
              ReplayAlertOutcome.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  static String encode(HourlyReplayReport report) =>
      jsonEncode(report.toJson());
}
