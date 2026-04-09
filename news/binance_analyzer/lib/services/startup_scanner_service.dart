import 'dart:math';

import '../models/coin_data.dart';
import 'binance_service.dart';

class StartupScannerService {
  static const int minimumDailyBars = 55;
  static const int minimumHourlyBars = 30;

  StartupScanReport analyzeMarket({
    required List<CoinData> currentCoins,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    StartupScanPolicy policy = StartupScanPolicy.defaultPolicy,
  }) {
    final closedDaily = {
      for (final entry in dailyHistory.entries)
        entry.key: _closedBars(entry.value),
    };
    final closedHourly = {
      for (final entry in hourlyHistory.entries)
        entry.key: _closedBars(entry.value),
    };

    final profiles = <_RawStartupProfile>[];
    for (final coin in currentCoins) {
      final dailyBars = _sorted(closedDaily[coin.symbol] ?? const []);
      final hourlyBars = _sorted(closedHourly[coin.symbol] ?? const []);
      if (dailyBars.length < minimumDailyBars ||
          hourlyBars.length < minimumHourlyBars) {
        continue;
      }

      final profile = _buildRawProfile(
        coin: coin,
        dailyBars: dailyBars,
        hourlyBars: hourlyBars,
      );
      if (profile != null) {
        profiles.add(profile);
      }
    }

    if (profiles.isEmpty) {
      return StartupScanReport(
        generatedAt: DateTime.now(),
        universeSize: currentCoins.length,
        analyzedSymbols: 0,
        strategyLabel: policy.label,
        candidates: const [],
        notes: '可用于启动扫描的币种不足，可能是历史 K 线样本不够。',
      );
    }

    final liquidityRanks = _percentileRank({
      for (final profile in profiles)
        profile.symbol: log(profile.coin.quoteVolume + 1) +
            log(profile.coin.count + 1) * 0.35,
    });
    final momentumRanks = _percentileRank({
      for (final profile in profiles)
        profile.symbol: profile.momentum7 * 0.7 + profile.momentum30 * 0.3,
    });
    final marketTrendBreadth = profiles
            .where((profile) => profile.coin.lastPrice > profile.sma20)
            .length /
        profiles.length;
    final marketMomentumBreadth =
        profiles.where((profile) => profile.momentum7 > 0).length /
            profiles.length;

    final candidates = profiles
        .map(
          (profile) => _toCandidate(
            profile,
            liquidityRank: liquidityRanks[profile.symbol] ?? 0,
            momentumRank: momentumRanks[profile.symbol] ?? 0,
            marketTrendBreadth: marketTrendBreadth,
            marketMomentumBreadth: marketMomentumBreadth,
            policy: policy,
          ),
        )
        .toList()
      ..sort((a, b) {
        final byNotify =
            (b.shouldNotify ? 1 : 0).compareTo(a.shouldNotify ? 1 : 0);
        if (byNotify != 0) return byNotify;
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return b.volumeRatio.compareTo(a.volumeRatio);
      });

    final actionable = candidates.where((item) => item.shouldNotify).length;
    final notes = actionable > 0
        ? '当前共发现 $actionable 个满足启动阈值的币，已按总分和量能排序。'
        : '当前没有满足启动阈值的币，建议继续等待放量突破。';

    return StartupScanReport(
      generatedAt: DateTime.now(),
      universeSize: currentCoins.length,
      analyzedSymbols: profiles.length,
      strategyLabel: policy.label,
      candidates: candidates,
      notes: notes,
    );
  }

  _RawStartupProfile? _buildRawProfile({
    required CoinData coin,
    required List<Kline> dailyBars,
    required List<Kline> hourlyBars,
  }) {
    final dailyCloses = dailyBars.map((bar) => bar.close).toList();
    final hourlyCloses = hourlyBars.map((bar) => bar.close).toList();
    final latestDailyClose = dailyCloses.last;
    final latestHourlyClose = hourlyCloses.last;
    if (latestDailyClose <= 0 || latestHourlyClose <= 0) return null;

    final dailyWindow30 = dailyBars.sublist(dailyBars.length - 30);
    final dailyWindow7 = dailyBars.sublist(dailyBars.length - 7);
    final priorDaily20 =
        dailyBars.sublist(dailyBars.length - 21, dailyBars.length - 1);
    final priorHourly24 =
        hourlyBars.sublist(hourlyBars.length - 25, hourlyBars.length - 1);

    final sma20 = _average(dailyCloses.sublist(dailyCloses.length - 20));
    final sma50 = _average(dailyCloses.sublist(dailyCloses.length - 50));
    final hourlySma8 = _average(hourlyCloses.sublist(hourlyCloses.length - 8));
    final hourlySma21 =
        _average(hourlyCloses.sublist(hourlyCloses.length - 21));

    final high20 = priorDaily20.map((bar) => bar.high).reduce(max);
    final high10 = dailyBars
        .sublist(dailyBars.length - 11, dailyBars.length - 1)
        .map((bar) => bar.high)
        .reduce(max);
    final high24h = priorHourly24.map((bar) => bar.high).reduce(max);
    final low30 = dailyWindow30.map((bar) => bar.low).reduce(min);
    final high30 = dailyWindow30.map((bar) => bar.high).reduce(max);
    final low7 = dailyWindow7.map((bar) => bar.low).reduce(min);
    final high7 = dailyWindow7.map((bar) => bar.high).reduce(max);

    final dailyBreakoutDistance =
        high20 <= 0 ? 0 : ((coin.lastPrice - high20) / high20) * 100;
    final hourlyBreakoutDistance =
        high24h <= 0 ? 0 : ((coin.lastPrice - high24h) / high24h) * 100;
    final momentum7 =
        ((latestDailyClose - dailyBars[dailyBars.length - 8].close) /
                max(dailyBars[dailyBars.length - 8].close, 0.000001)) *
            100;
    final momentum30 =
        ((latestDailyClose - dailyBars[dailyBars.length - 31].close) /
                max(dailyBars[dailyBars.length - 31].close, 0.000001)) *
            100;
    final dailyRange30 = (high30 - low30) / max(latestDailyClose, 0.000001);
    final dailyRange7 = (high7 - low7) / max(latestDailyClose, 0.000001);
    final volumeRatio = _average(
          hourlyBars
              .sublist(hourlyBars.length - 3)
              .map((bar) => bar.quoteVolume)
              .toList(),
        ) /
        max(
          _average(
            hourlyBars
                .sublist(hourlyBars.length - 27, hourlyBars.length - 3)
                .map((bar) => bar.quoteVolume)
                .toList(),
          ),
          0.000001,
        );

    return _RawStartupProfile(
      coin: coin,
      symbol: coin.displayName,
      sma20: sma20,
      sma50: sma50,
      hourlySma8: hourlySma8,
      hourlySma21: hourlySma21,
      dailyBreakoutDistance: dailyBreakoutDistance.toDouble(),
      hourlyBreakoutDistance: hourlyBreakoutDistance.toDouble(),
      momentum7: momentum7,
      momentum30: momentum30,
      dailyRange30: dailyRange30,
      dailyRange7: dailyRange7,
      nearTermPivotDistance:
          high10 <= 0 ? 0 : ((coin.lastPrice - high10) / high10) * 100,
      volumeRatio: volumeRatio,
    );
  }

  StartupScanCandidate _toCandidate(
    _RawStartupProfile profile, {
    required double liquidityRank,
    required double momentumRank,
    required double marketTrendBreadth,
    required double marketMomentumBreadth,
    required StartupScanPolicy policy,
  }) {
    final price = profile.coin.lastPrice;
    final trendScore = ((price > profile.sma20 ? 1.0 : 0.15) * 0.4 +
            (profile.sma20 > profile.sma50 ? 1.0 : 0.15) * 0.35 +
            (profile.hourlySma8 > profile.hourlySma21 ? 1.0 : 0.2) * 0.25)
        .clamp(0.0, 1.0);

    final compressionScore =
        (1 - (profile.dailyRange7 / max(profile.dailyRange30, 0.000001)))
            .clamp(0.0, 1.0);
    final pivotScore =
        _sweetSpot(profile.nearTermPivotDistance, 0.35, 1.6).clamp(0.0, 1.0);
    final breakoutScore =
        (_breakoutProximityScore(profile.dailyBreakoutDistance) * 0.65 +
                _breakoutProximityScore(profile.hourlyBreakoutDistance) * 0.35)
            .clamp(0.0, 1.0);
    final volumeScore = _clamp01((profile.volumeRatio - 1.0) / 1.05);
    final dailyChangeScore = _sweetSpot(
      profile.coin.priceChangePercent,
      3.2,
      4.8,
    );
    final marketScore = (marketTrendBreadth * 0.6 + marketMomentumBreadth * 0.4)
        .clamp(0.0, 1.0);
    final momentumScore = (momentumRank * 0.45 +
            _sweetSpot(profile.momentum7, 5.5, 6.0) * 0.25 +
            _sweetSpot(profile.momentum30, 10, 16) * 0.2 +
            dailyChangeScore * 0.1)
        .clamp(0.0, 1.0);

    final overextendedPenalty = profile.momentum30 > 36 ||
            profile.coin.priceChangePercent > 8.6 ||
            profile.dailyBreakoutDistance > 2.8 ||
            profile.nearTermPivotDistance > 2.2
        ? 0.14
        : 0.0;
    final weakLiquidityPenalty = liquidityRank < 0.18 ? 0.04 : 0.0;

    final score = (trendScore * 0.22 +
            compressionScore * 0.20 +
            breakoutScore * 0.22 +
            volumeScore * 0.15 +
            pivotScore * 0.11 +
            momentumScore * 0.06 +
            liquidityRank * 0.03 +
            marketScore * 0.01 -
            weakLiquidityPenalty -
            overextendedPenalty)
        .clamp(0.0, 1.0);

    final shouldNotify = score >= policy.minScore &&
        trendScore >= policy.minTrendScore &&
        compressionScore >= policy.minCompressionScore &&
        liquidityRank >= policy.minLiquidityScore &&
        momentumScore >= policy.minMomentumScore &&
        marketTrendBreadth >= policy.minMarketTrendBreadth &&
        marketMomentumBreadth >= policy.minMarketMomentumBreadth &&
        profile.volumeRatio >= policy.minVolumeRatio &&
        profile.coin.quoteVolume >= policy.minQuoteVolume &&
        profile.coin.count >= policy.minTradeCount &&
        profile.coin.priceChangePercent >= policy.minDailyChangePercent &&
        profile.dailyBreakoutDistance >= policy.minBreakoutDistance &&
        profile.dailyBreakoutDistance <= policy.maxBreakoutDistance &&
        profile.hourlyBreakoutDistance >= policy.minHourlyBreakoutDistance &&
        profile.hourlyBreakoutDistance <= policy.maxHourlyBreakoutDistance &&
        profile.nearTermPivotDistance >= policy.minNearTermPivotDistance &&
        profile.nearTermPivotDistance <= policy.maxNearTermPivotDistance &&
        profile.momentum30 <= policy.maxThirtyDayMomentum &&
        profile.coin.priceChangePercent <= policy.maxDailyChangePercent;

    final reasonParts = <String>[
      '24h额 ${_compactUsd(profile.coin.quoteVolume)}',
      '量比 ${profile.volumeRatio.toStringAsFixed(2)}x',
      '距20日突破位 ${profile.dailyBreakoutDistance >= 0 ? '+' : ''}${profile.dailyBreakoutDistance.toStringAsFixed(2)}%',
      '距10日枢轴 ${profile.nearTermPivotDistance >= 0 ? '+' : ''}${profile.nearTermPivotDistance.toStringAsFixed(2)}%',
      '7日动量 ${profile.momentum7 >= 0 ? '+' : ''}${profile.momentum7.toStringAsFixed(1)}%',
      '30日动量 ${profile.momentum30 >= 0 ? '+' : ''}${profile.momentum30.toStringAsFixed(1)}%',
    ];

    if (compressionScore >= 0.55) {
      reasonParts.add('波动收缩明显');
    }
    if (trendScore >= 0.7) {
      reasonParts.add('日线/小时线趋势同步');
    }
    if (profile.nearTermPivotDistance >= -0.8 &&
        profile.nearTermPivotDistance <= 1.6) {
      reasonParts.add('临近短线突破位');
    }
    if (marketTrendBreadth >= 0.55) {
      reasonParts.add('市场趋势配合');
    }

    return StartupScanCandidate(
      symbol: profile.symbol,
      currentPrice: profile.coin.lastPrice,
      score: score,
      trendScore: trendScore,
      compressionScore: compressionScore,
      momentumScore: momentumScore,
      liquidityScore: liquidityRank,
      volumeRatio: profile.volumeRatio,
      dailyBreakoutDistance: profile.dailyBreakoutDistance,
      hourlyBreakoutDistance: profile.hourlyBreakoutDistance,
      nearTermPivotDistance: profile.nearTermPivotDistance,
      marketTrendBreadth: marketTrendBreadth,
      marketMomentumBreadth: marketMomentumBreadth,
      sevenDayMomentum: profile.momentum7,
      thirtyDayMomentum: profile.momentum30,
      reason: reasonParts.join('；'),
      shouldNotify: shouldNotify,
    );
  }

  static List<Kline> _closedBars(List<Kline> bars) {
    if (bars.isEmpty) return const [];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final filtered =
        bars.where((bar) => bar.closeTime < nowMs - 60 * 1000).toList();
    return filtered.isNotEmpty ? filtered : bars;
  }

  static List<Kline> _sorted(List<Kline> bars) {
    final copy = [...bars];
    copy.sort((a, b) => a.closeTime.compareTo(b.closeTime));
    return copy;
  }

  static Map<String, double> _percentileRank(Map<String, double> values) {
    if (values.isEmpty) return const {};
    final entries = values.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (entries.length == 1) {
      return {entries.first.key: 1};
    }

    final result = <String, double>{};
    for (var i = 0; i < entries.length; i++) {
      result[entries[i].key] = i / (entries.length - 1);
    }
    return result;
  }

  static double _average(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double _clamp01(double value) => value.clamp(0.0, 1.0);

  static double _sweetSpot(double value, double center, double width) {
    if (width <= 0) return 0;
    return (1 - ((value - center).abs() / width)).clamp(0.0, 1.0);
  }

  static double _breakoutProximityScore(double distancePercent) {
    if (distancePercent < -4.5 || distancePercent > 4.5) return 0;
    if (distancePercent <= 1.4) {
      return _sweetSpot(distancePercent, 0.4, 2.0);
    }
    return _sweetSpot(distancePercent, 1.6, 2.8);
  }

  static String _compactUsd(double value) {
    if (value >= 1000000000) {
      return '${(value / 1000000000).toStringAsFixed(2)}B';
    }
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(0)}K';
    }
    return value.toStringAsFixed(0);
  }
}

class StartupScanPolicy {
  final String label;
  final double minScore;
  final double minTrendScore;
  final double minCompressionScore;
  final double minLiquidityScore;
  final double minMomentumScore;
  final double minMarketTrendBreadth;
  final double minMarketMomentumBreadth;
  final double minVolumeRatio;
  final double minDailyChangePercent;
  final double minBreakoutDistance;
  final double maxBreakoutDistance;
  final double minHourlyBreakoutDistance;
  final double maxHourlyBreakoutDistance;
  final double minNearTermPivotDistance;
  final double maxNearTermPivotDistance;
  final double maxThirtyDayMomentum;
  final double maxDailyChangePercent;
  final double minQuoteVolume;
  final int minTradeCount;
  final int maxPushCandidates;
  final int cooldownHours;

  static const StartupScanPolicy defaultPolicy = StartupScanPolicy(
    label: '全市场启动扫描',
    minScore: 0.74,
    minTrendScore: 0.66,
    minCompressionScore: 0.24,
    minLiquidityScore: 0.18,
    minMomentumScore: 0.26,
    minMarketTrendBreadth: 0.54,
    minMarketMomentumBreadth: 0.48,
    minVolumeRatio: 1.42,
    minDailyChangePercent: 1.8,
    minBreakoutDistance: -1.4,
    maxBreakoutDistance: 2.4,
    minHourlyBreakoutDistance: -1.2,
    maxHourlyBreakoutDistance: 2.2,
    minNearTermPivotDistance: -1.0,
    maxNearTermPivotDistance: 1.8,
    maxThirtyDayMomentum: 42,
    maxDailyChangePercent: 9,
    minQuoteVolume: 3000000,
    minTradeCount: 6000,
    maxPushCandidates: 2,
    cooldownHours: 10,
  );

  const StartupScanPolicy({
    required this.label,
    required this.minScore,
    required this.minTrendScore,
    required this.minCompressionScore,
    required this.minLiquidityScore,
    required this.minMomentumScore,
    required this.minMarketTrendBreadth,
    required this.minMarketMomentumBreadth,
    required this.minVolumeRatio,
    required this.minDailyChangePercent,
    required this.minBreakoutDistance,
    required this.maxBreakoutDistance,
    required this.minHourlyBreakoutDistance,
    required this.maxHourlyBreakoutDistance,
    required this.minNearTermPivotDistance,
    required this.maxNearTermPivotDistance,
    required this.maxThirtyDayMomentum,
    required this.maxDailyChangePercent,
    required this.minQuoteVolume,
    required this.minTradeCount,
    required this.maxPushCandidates,
    required this.cooldownHours,
  });

  String get summary => 'score>=${(minScore * 100).round()} '
      '| trend>=${(minTrendScore * 100).round()} '
      '| compression>=${(minCompressionScore * 100).round()} '
      '| liquidity>=${(minLiquidityScore * 100).round()} '
      '| momentum>=${(minMomentumScore * 100).round()} '
      '| marketTrend>=${(minMarketTrendBreadth * 100).round()} '
      '| marketMomentum>=${(minMarketMomentumBreadth * 100).round()} '
      '| volume>=${minVolumeRatio.toStringAsFixed(2)}x '
      '| cooldown=${cooldownHours}h';

  StartupScanPolicy copyWith({
    String? label,
    double? minScore,
    double? minTrendScore,
    double? minCompressionScore,
    double? minLiquidityScore,
    double? minMomentumScore,
    double? minMarketTrendBreadth,
    double? minMarketMomentumBreadth,
    double? minVolumeRatio,
    double? minDailyChangePercent,
    double? minBreakoutDistance,
    double? maxBreakoutDistance,
    double? minHourlyBreakoutDistance,
    double? maxHourlyBreakoutDistance,
    double? minNearTermPivotDistance,
    double? maxNearTermPivotDistance,
    double? maxThirtyDayMomentum,
    double? maxDailyChangePercent,
    double? minQuoteVolume,
    int? minTradeCount,
    int? maxPushCandidates,
    int? cooldownHours,
  }) {
    return StartupScanPolicy(
      label: label ?? this.label,
      minScore: minScore ?? this.minScore,
      minTrendScore: minTrendScore ?? this.minTrendScore,
      minCompressionScore: minCompressionScore ?? this.minCompressionScore,
      minLiquidityScore: minLiquidityScore ?? this.minLiquidityScore,
      minMomentumScore: minMomentumScore ?? this.minMomentumScore,
      minMarketTrendBreadth:
          minMarketTrendBreadth ?? this.minMarketTrendBreadth,
      minMarketMomentumBreadth:
          minMarketMomentumBreadth ?? this.minMarketMomentumBreadth,
      minVolumeRatio: minVolumeRatio ?? this.minVolumeRatio,
      minDailyChangePercent:
          minDailyChangePercent ?? this.minDailyChangePercent,
      minBreakoutDistance: minBreakoutDistance ?? this.minBreakoutDistance,
      maxBreakoutDistance: maxBreakoutDistance ?? this.maxBreakoutDistance,
      minHourlyBreakoutDistance:
          minHourlyBreakoutDistance ?? this.minHourlyBreakoutDistance,
      maxHourlyBreakoutDistance:
          maxHourlyBreakoutDistance ?? this.maxHourlyBreakoutDistance,
      minNearTermPivotDistance:
          minNearTermPivotDistance ?? this.minNearTermPivotDistance,
      maxNearTermPivotDistance:
          maxNearTermPivotDistance ?? this.maxNearTermPivotDistance,
      maxThirtyDayMomentum: maxThirtyDayMomentum ?? this.maxThirtyDayMomentum,
      maxDailyChangePercent:
          maxDailyChangePercent ?? this.maxDailyChangePercent,
      minQuoteVolume: minQuoteVolume ?? this.minQuoteVolume,
      minTradeCount: minTradeCount ?? this.minTradeCount,
      maxPushCandidates: maxPushCandidates ?? this.maxPushCandidates,
      cooldownHours: cooldownHours ?? this.cooldownHours,
    );
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'minScore': minScore,
        'minTrendScore': minTrendScore,
        'minCompressionScore': minCompressionScore,
        'minLiquidityScore': minLiquidityScore,
        'minMomentumScore': minMomentumScore,
        'minMarketTrendBreadth': minMarketTrendBreadth,
        'minMarketMomentumBreadth': minMarketMomentumBreadth,
        'minVolumeRatio': minVolumeRatio,
        'minDailyChangePercent': minDailyChangePercent,
        'minBreakoutDistance': minBreakoutDistance,
        'maxBreakoutDistance': maxBreakoutDistance,
        'minHourlyBreakoutDistance': minHourlyBreakoutDistance,
        'maxHourlyBreakoutDistance': maxHourlyBreakoutDistance,
        'minNearTermPivotDistance': minNearTermPivotDistance,
        'maxNearTermPivotDistance': maxNearTermPivotDistance,
        'maxThirtyDayMomentum': maxThirtyDayMomentum,
        'maxDailyChangePercent': maxDailyChangePercent,
        'minQuoteVolume': minQuoteVolume,
        'minTradeCount': minTradeCount,
        'maxPushCandidates': maxPushCandidates,
        'cooldownHours': cooldownHours,
        'summary': summary,
      };
}

class StartupScanCandidate {
  final String symbol;
  final double currentPrice;
  final double score;
  final double trendScore;
  final double compressionScore;
  final double momentumScore;
  final double liquidityScore;
  final double volumeRatio;
  final double dailyBreakoutDistance;
  final double hourlyBreakoutDistance;
  final double nearTermPivotDistance;
  final double marketTrendBreadth;
  final double marketMomentumBreadth;
  final double sevenDayMomentum;
  final double thirtyDayMomentum;
  final String reason;
  final bool shouldNotify;

  const StartupScanCandidate({
    required this.symbol,
    required this.currentPrice,
    required this.score,
    required this.trendScore,
    required this.compressionScore,
    required this.momentumScore,
    required this.liquidityScore,
    required this.volumeRatio,
    required this.dailyBreakoutDistance,
    required this.hourlyBreakoutDistance,
    required this.nearTermPivotDistance,
    required this.marketTrendBreadth,
    required this.marketMomentumBreadth,
    required this.sevenDayMomentum,
    required this.thirtyDayMomentum,
    required this.reason,
    required this.shouldNotify,
  });

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'currentPrice': currentPrice,
        'score': score,
        'trendScore': trendScore,
        'compressionScore': compressionScore,
        'momentumScore': momentumScore,
        'liquidityScore': liquidityScore,
        'volumeRatio': volumeRatio,
        'dailyBreakoutDistance': dailyBreakoutDistance,
        'hourlyBreakoutDistance': hourlyBreakoutDistance,
        'nearTermPivotDistance': nearTermPivotDistance,
        'marketTrendBreadth': marketTrendBreadth,
        'marketMomentumBreadth': marketMomentumBreadth,
        'sevenDayMomentum': sevenDayMomentum,
        'thirtyDayMomentum': thirtyDayMomentum,
        'reason': reason,
        'shouldNotify': shouldNotify,
      };
}

class StartupScanReport {
  final DateTime generatedAt;
  final int universeSize;
  final int analyzedSymbols;
  final String strategyLabel;
  final List<StartupScanCandidate> candidates;
  final String notes;

  const StartupScanReport({
    required this.generatedAt,
    required this.universeSize,
    required this.analyzedSymbols,
    required this.strategyLabel,
    required this.candidates,
    required this.notes,
  });

  List<StartupScanCandidate> get actionableCandidates =>
      candidates.where((item) => item.shouldNotify).toList();

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'universeSize': universeSize,
        'analyzedSymbols': analyzedSymbols,
        'strategyLabel': strategyLabel,
        'notes': notes,
        'candidates': candidates.map((item) => item.toJson()).toList(),
      };
}

class _RawStartupProfile {
  final CoinData coin;
  final String symbol;
  final double sma20;
  final double sma50;
  final double hourlySma8;
  final double hourlySma21;
  final double dailyBreakoutDistance;
  final double hourlyBreakoutDistance;
  final double nearTermPivotDistance;
  final double momentum7;
  final double momentum30;
  final double dailyRange30;
  final double dailyRange7;
  final double volumeRatio;

  const _RawStartupProfile({
    required this.coin,
    required this.symbol,
    required this.sma20,
    required this.sma50,
    required this.hourlySma8,
    required this.hourlySma21,
    required this.dailyBreakoutDistance,
    required this.hourlyBreakoutDistance,
    required this.nearTermPivotDistance,
    required this.momentum7,
    required this.momentum30,
    required this.dailyRange30,
    required this.dailyRange7,
    required this.volumeRatio,
  });
}
