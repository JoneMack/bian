import 'dart:math';

import '../models/coin_data.dart';
import 'binance_service.dart';

class MarketBottomDetectorService {
  static const int minimumDailyBars = 50;
  static const int minimumHourlyBars = 32;

  MarketBottomAlert analyzeMarket({
    required List<CoinData> currentCoins,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    MarketBottomPolicy policy = MarketBottomPolicy.defaultPolicy,
  }) {
    final closedDaily = {
      for (final entry in dailyHistory.entries)
        entry.key: _closedBars(entry.value),
    };
    final closedHourly = {
      for (final entry in hourlyHistory.entries)
        entry.key: _closedBars(entry.value),
    };

    final profiles = <_RawBottomProfile>[];
    for (final coin in currentCoins) {
      final dailyBars = _sorted(closedDaily[coin.symbol] ?? const []);
      final hourlyBars = _sorted(closedHourly[coin.symbol] ?? const []);
      if (dailyBars.length < minimumDailyBars ||
          hourlyBars.length < minimumHourlyBars) {
        continue;
      }

      final profile = _buildProfile(
        coin: coin,
        dailyBars: dailyBars,
        hourlyBars: hourlyBars,
      );
      if (profile != null) {
        profiles.add(profile);
      }
    }

    if (profiles.length < policy.minAnalyzedSymbols) {
      return MarketBottomAlert(
        generatedAt: DateTime.now(),
        universeSize: currentCoins.length,
        analyzedSymbols: profiles.length,
        strategyLabel: policy.label,
        alertScore: 0,
        fearScore: 0,
        stabilizationScore: 0,
        redBreadth: 0,
        downBreadth: 0,
        capitulationBreadth: 0,
        nearLowBreadth: 0,
        reboundBreadth: 0,
        recoveryBreadth: 0,
        volumeBreadth: 0,
        avg24hChange: 0,
        avg7dChange: 0,
        shouldNotify: false,
        notes: '可用于恐慌见底检测的币种不足，暂不触发底部提醒。',
        candidates: const [],
      );
    }

    final liquidityRanks = _percentileRank({
      for (final profile in profiles)
        profile.symbol: log(profile.coin.quoteVolume + 1) +
            log(profile.coin.count + 1) * 0.35,
    });

    final redBreadth = profiles
            .where((profile) => profile.coin.priceChangePercent < 0)
            .length /
        profiles.length;
    final downBreadth = profiles
            .where((profile) => profile.coin.priceChangePercent <= -3.5)
            .length /
        profiles.length;
    final capitulationBreadth = profiles
            .where((profile) =>
                profile.coin.priceChangePercent <= -5.5 ||
                profile.sevenDayChange <= -12 ||
                profile.drawdownFrom30dHigh >= 18)
            .length /
        profiles.length;
    final nearLowBreadth = profiles
            .where((profile) =>
                profile.distanceTo45dLow <= policy.maxDistanceTo45dLow)
            .length /
        profiles.length;
    final reboundBreadth = profiles
            .where((profile) =>
                profile.bounceFrom12hLow >= policy.minBounceFrom12hLow &&
                profile.hourlyTrendScore >= 0.52)
            .length /
        profiles.length;
    final recoveryBreadth =
        profiles.where((profile) => profile.hourlyTrendScore >= 0.62).length /
            profiles.length;
    final volumeBreadth = profiles
            .where((profile) => profile.volumeRatio >= policy.minVolumeRatio)
            .length /
        profiles.length;

    final avg24hChange = _average(
      profiles.map((profile) => profile.coin.priceChangePercent).toList(),
    );
    final avg7dChange = _average(
      profiles.map((profile) => profile.sevenDayChange).toList(),
    );
    final medianBounce = _median(
      profiles.map((profile) => profile.bounceFrom12hLow).toList(),
    );

    final fearScore = (redBreadth * 0.24 +
            downBreadth * 0.24 +
            capitulationBreadth * 0.24 +
            nearLowBreadth * 0.16 +
            _clamp01((-avg24hChange - 2.0) / 6.5) * 0.06 +
            _clamp01((-avg7dChange - 6.0) / 16.0) * 0.06)
        .clamp(0.0, 1.0);
    final stabilizationScore = (reboundBreadth * 0.38 +
            recoveryBreadth * 0.28 +
            volumeBreadth * 0.16 +
            _clamp01((medianBounce - 1.2) / 3.2) * 0.18)
        .clamp(0.0, 1.0);
    final alertScore =
        (fearScore * 0.58 + stabilizationScore * 0.42).clamp(0.0, 1.0);

    final candidates = profiles
        .map(
          (profile) => _toCandidate(
            profile,
            policy: policy,
            liquidityRank: liquidityRanks[profile.symbol] ?? 0,
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

    final actionable = candidates
        .where((candidate) => candidate.shouldNotify)
        .take(policy.maxPushCandidates)
        .toList();

    final shouldNotify = alertScore >= policy.minAlertScore &&
        redBreadth >= policy.minRedBreadth &&
        downBreadth >= policy.minDownBreadth &&
        capitulationBreadth >= policy.minCapitulationBreadth &&
        nearLowBreadth >= policy.minNearLowBreadth &&
        reboundBreadth >= policy.minReboundBreadth &&
        recoveryBreadth >= policy.minRecoveryBreadth &&
        volumeBreadth >= policy.minVolumeBreadth &&
        actionable.isNotEmpty;

    final notes = shouldNotify
        ? '全市场已出现普跌后的止跌回抽，适合关注高流动性币的底部反转。'
        : '当前更像下跌中的波动，尚未满足全市场见底确认。';

    return MarketBottomAlert(
      generatedAt: DateTime.now(),
      universeSize: currentCoins.length,
      analyzedSymbols: profiles.length,
      strategyLabel: policy.label,
      alertScore: alertScore,
      fearScore: fearScore,
      stabilizationScore: stabilizationScore,
      redBreadth: redBreadth,
      downBreadth: downBreadth,
      capitulationBreadth: capitulationBreadth,
      nearLowBreadth: nearLowBreadth,
      reboundBreadth: reboundBreadth,
      recoveryBreadth: recoveryBreadth,
      volumeBreadth: volumeBreadth,
      avg24hChange: avg24hChange,
      avg7dChange: avg7dChange,
      shouldNotify: shouldNotify,
      notes: notes,
      candidates: candidates,
    );
  }

  _RawBottomProfile? _buildProfile({
    required CoinData coin,
    required List<Kline> dailyBars,
    required List<Kline> hourlyBars,
  }) {
    final currentPrice = coin.lastPrice;
    if (currentPrice <= 0) return null;

    final recent45 = dailyBars.sublist(dailyBars.length - 45);
    final recent30 = dailyBars.sublist(dailyBars.length - 30);
    final recent12h = hourlyBars.sublist(hourlyBars.length - 12);

    final low45 = recent45.map((bar) => bar.low).reduce(min);
    final high30 = recent30.map((bar) => bar.high).reduce(max);
    if (low45 <= 0 || high30 <= 0) return null;

    final base7 = dailyBars[dailyBars.length - 8].close;
    final base30 = dailyBars[dailyBars.length - 31].close;
    final sevenDayChange =
        ((currentPrice - base7) / max(base7, 0.000001)) * 100;
    final thirtyDayChange =
        ((currentPrice - base30) / max(base30, 0.000001)) * 100;

    final bounceLow = recent12h.map((bar) => bar.low).reduce(min);
    final bounceFrom12hLow =
        ((currentPrice - bounceLow) / max(bounceLow, 0.000001)) * 100;
    final distanceTo45dLow =
        ((currentPrice - low45) / max(low45, 0.000001)) * 100;
    final drawdownFrom30dHigh =
        ((high30 - currentPrice) / max(high30, 0.000001)) * 100;

    final hourlyCloses = hourlyBars.map((bar) => bar.close).toList();
    final hourlySma8 = _average(hourlyCloses.sublist(hourlyCloses.length - 8));
    final hourlySma21 =
        _average(hourlyCloses.sublist(hourlyCloses.length - 21));
    final impulseBase = hourlyBars[hourlyBars.length - 4].close;
    final hourlyImpulsePercent =
        ((currentPrice - impulseBase) / max(impulseBase, 0.000001)) * 100;
    final hourlyTrendScore = ((currentPrice > hourlySma8 ? 1.0 : 0.18) * 0.46 +
            (hourlySma8 > hourlySma21 ? 1.0 : 0.2) * 0.34 +
            _clamp01((hourlyImpulsePercent + 0.8) / 3.5) * 0.20)
        .clamp(0.0, 1.0);

    final recentVolume = _average(
      hourlyBars
          .sublist(hourlyBars.length - 3)
          .map((bar) => bar.quoteVolume)
          .toList(),
    );
    final baselineVolume = _average(
      hourlyBars
          .sublist(hourlyBars.length - 24, hourlyBars.length - 3)
          .map((bar) => bar.quoteVolume)
          .toList(),
    );
    final volumeRatio = recentVolume / max(baselineVolume, 0.000001);

    return _RawBottomProfile(
      coin: coin,
      symbol: coin.displayName,
      drawdownFrom30dHigh: drawdownFrom30dHigh,
      distanceTo45dLow: distanceTo45dLow,
      bounceFrom12hLow: bounceFrom12hLow,
      volumeRatio: volumeRatio,
      hourlyTrendScore: hourlyTrendScore,
      hourlyImpulsePercent: hourlyImpulsePercent,
      sevenDayChange: sevenDayChange,
      thirtyDayChange: thirtyDayChange,
    );
  }

  MarketBottomCandidate _toCandidate(
    _RawBottomProfile profile, {
    required MarketBottomPolicy policy,
    required double liquidityRank,
  }) {
    final oversoldScore =
        (_sweetSpot(profile.drawdownFrom30dHigh, 20, 18) * 0.42 +
                _sweetSpot(profile.distanceTo45dLow, 2.5, 5.2) * 0.26 +
                _sweetSpot(-profile.sevenDayChange, 12, 12) * 0.20 +
                _sweetSpot(profile.coin.rangePosition, 0.18, 0.28) * 0.12)
            .clamp(0.0, 1.0);

    final reboundScore =
        (_sweetSpot(profile.bounceFrom12hLow, 2.8, 3.8) * 0.34 +
                profile.hourlyTrendScore * 0.32 +
                _clamp01((profile.volumeRatio - 0.9) / 0.9) * 0.20 +
                _clamp01((profile.hourlyImpulsePercent + 0.5) / 3.0) * 0.14)
            .clamp(0.0, 1.0);

    final score =
        (oversoldScore * 0.44 + reboundScore * 0.40 + liquidityRank * 0.16)
            .clamp(0.0, 1.0);

    final shouldNotify = score >= policy.minCandidateScore &&
        liquidityRank >= policy.minCandidateLiquidityScore &&
        profile.drawdownFrom30dHigh >= policy.minCandidateDrawdownPercent &&
        profile.distanceTo45dLow <= policy.maxCandidateDistanceTo45dLow &&
        profile.bounceFrom12hLow >= policy.minBounceFrom12hLow &&
        profile.bounceFrom12hLow <= policy.maxCandidateBounceFrom12hLow &&
        profile.volumeRatio >= policy.minVolumeRatio * 0.9 &&
        profile.hourlyTrendScore >= 0.56;

    final reasonParts = <String>[
      '24h额 ${_compactUsd(profile.coin.quoteVolume)}',
      '30日回撤 ${profile.drawdownFrom30dHigh.toStringAsFixed(1)}%',
      '距45日低点 ${profile.distanceTo45dLow.toStringAsFixed(1)}%',
      '12h反弹 ${profile.bounceFrom12hLow.toStringAsFixed(1)}%',
      '量比 ${profile.volumeRatio.toStringAsFixed(2)}x',
      '近7天 ${profile.sevenDayChange >= 0 ? '+' : ''}${profile.sevenDayChange.toStringAsFixed(1)}%',
    ];
    if (profile.hourlyTrendScore >= 0.65) {
      reasonParts.add('1h结构转强');
    }
    if (profile.coin.rangePosition <= 0.35) {
      reasonParts.add('仍贴近日内低位');
    }

    return MarketBottomCandidate(
      symbol: profile.symbol,
      currentPrice: profile.coin.lastPrice,
      score: score,
      oversoldScore: oversoldScore,
      reboundScore: reboundScore,
      liquidityScore: liquidityRank,
      drawdownFrom30dHigh: profile.drawdownFrom30dHigh,
      distanceTo45dLow: profile.distanceTo45dLow,
      bounceFrom12hLow: profile.bounceFrom12hLow,
      volumeRatio: profile.volumeRatio,
      hourlyTrendScore: profile.hourlyTrendScore,
      sevenDayChange: profile.sevenDayChange,
      thirtyDayChange: profile.thirtyDayChange,
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

  static double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[middle];
    }
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  static double _clamp01(double value) => value.clamp(0.0, 1.0);

  static double _sweetSpot(double value, double center, double width) {
    if (width <= 0) return 0;
    return (1 - ((value - center).abs() / width)).clamp(0.0, 1.0);
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

class MarketBottomPolicy {
  final String label;
  final int minAnalyzedSymbols;
  final double minRedBreadth;
  final double minDownBreadth;
  final double minCapitulationBreadth;
  final double minNearLowBreadth;
  final double minReboundBreadth;
  final double minRecoveryBreadth;
  final double minVolumeBreadth;
  final double minAlertScore;
  final double maxDistanceTo45dLow;
  final double minBounceFrom12hLow;
  final double minVolumeRatio;
  final double minCandidateScore;
  final double minCandidateLiquidityScore;
  final double minCandidateDrawdownPercent;
  final double maxCandidateDistanceTo45dLow;
  final double maxCandidateBounceFrom12hLow;
  final int maxPushCandidates;
  final int cooldownHours;

  static const MarketBottomPolicy defaultPolicy = MarketBottomPolicy(
    label: '全市场恐慌见底',
    minAnalyzedSymbols: 25,
    minRedBreadth: 0.74,
    minDownBreadth: 0.40,
    minCapitulationBreadth: 0.24,
    minNearLowBreadth: 0.18,
    minReboundBreadth: 0.14,
    minRecoveryBreadth: 0.11,
    minVolumeBreadth: 0.14,
    minAlertScore: 0.68,
    maxDistanceTo45dLow: 7.0,
    minBounceFrom12hLow: 1.6,
    minVolumeRatio: 1.10,
    minCandidateScore: 0.66,
    minCandidateLiquidityScore: 0.20,
    minCandidateDrawdownPercent: 12.0,
    maxCandidateDistanceTo45dLow: 8.0,
    maxCandidateBounceFrom12hLow: 8.5,
    maxPushCandidates: 3,
    cooldownHours: 14,
  );

  const MarketBottomPolicy({
    required this.label,
    required this.minAnalyzedSymbols,
    required this.minRedBreadth,
    required this.minDownBreadth,
    required this.minCapitulationBreadth,
    required this.minNearLowBreadth,
    required this.minReboundBreadth,
    required this.minRecoveryBreadth,
    required this.minVolumeBreadth,
    required this.minAlertScore,
    required this.maxDistanceTo45dLow,
    required this.minBounceFrom12hLow,
    required this.minVolumeRatio,
    required this.minCandidateScore,
    required this.minCandidateLiquidityScore,
    required this.minCandidateDrawdownPercent,
    required this.maxCandidateDistanceTo45dLow,
    required this.maxCandidateBounceFrom12hLow,
    required this.maxPushCandidates,
    required this.cooldownHours,
  });

  String get summary => 'alert>=${(minAlertScore * 100).round()} '
      '| red>=${(minRedBreadth * 100).round()} '
      '| down>=${(minDownBreadth * 100).round()} '
      '| panic>=${(minCapitulationBreadth * 100).round()} '
      '| rebound>=${(minReboundBreadth * 100).round()} '
      '| volume>=${(minVolumeBreadth * 100).round()} '
      '| candidate>=${(minCandidateScore * 100).round()} '
      '| cooldown=${cooldownHours}h';

  Map<String, dynamic> toJson() => {
        'label': label,
        'minAnalyzedSymbols': minAnalyzedSymbols,
        'minRedBreadth': minRedBreadth,
        'minDownBreadth': minDownBreadth,
        'minCapitulationBreadth': minCapitulationBreadth,
        'minNearLowBreadth': minNearLowBreadth,
        'minReboundBreadth': minReboundBreadth,
        'minRecoveryBreadth': minRecoveryBreadth,
        'minVolumeBreadth': minVolumeBreadth,
        'minAlertScore': minAlertScore,
        'maxDistanceTo45dLow': maxDistanceTo45dLow,
        'minBounceFrom12hLow': minBounceFrom12hLow,
        'minVolumeRatio': minVolumeRatio,
        'minCandidateScore': minCandidateScore,
        'minCandidateLiquidityScore': minCandidateLiquidityScore,
        'minCandidateDrawdownPercent': minCandidateDrawdownPercent,
        'maxCandidateDistanceTo45dLow': maxCandidateDistanceTo45dLow,
        'maxCandidateBounceFrom12hLow': maxCandidateBounceFrom12hLow,
        'maxPushCandidates': maxPushCandidates,
        'cooldownHours': cooldownHours,
        'summary': summary,
      };
}

class MarketBottomCandidate {
  final String symbol;
  final double currentPrice;
  final double score;
  final double oversoldScore;
  final double reboundScore;
  final double liquidityScore;
  final double drawdownFrom30dHigh;
  final double distanceTo45dLow;
  final double bounceFrom12hLow;
  final double volumeRatio;
  final double hourlyTrendScore;
  final double sevenDayChange;
  final double thirtyDayChange;
  final String reason;
  final bool shouldNotify;

  const MarketBottomCandidate({
    required this.symbol,
    required this.currentPrice,
    required this.score,
    required this.oversoldScore,
    required this.reboundScore,
    required this.liquidityScore,
    required this.drawdownFrom30dHigh,
    required this.distanceTo45dLow,
    required this.bounceFrom12hLow,
    required this.volumeRatio,
    required this.hourlyTrendScore,
    required this.sevenDayChange,
    required this.thirtyDayChange,
    required this.reason,
    required this.shouldNotify,
  });

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'currentPrice': currentPrice,
        'score': score,
        'oversoldScore': oversoldScore,
        'reboundScore': reboundScore,
        'liquidityScore': liquidityScore,
        'drawdownFrom30dHigh': drawdownFrom30dHigh,
        'distanceTo45dLow': distanceTo45dLow,
        'bounceFrom12hLow': bounceFrom12hLow,
        'volumeRatio': volumeRatio,
        'hourlyTrendScore': hourlyTrendScore,
        'sevenDayChange': sevenDayChange,
        'thirtyDayChange': thirtyDayChange,
        'reason': reason,
        'shouldNotify': shouldNotify,
      };
}

class MarketBottomAlert {
  final DateTime generatedAt;
  final int universeSize;
  final int analyzedSymbols;
  final String strategyLabel;
  final double alertScore;
  final double fearScore;
  final double stabilizationScore;
  final double redBreadth;
  final double downBreadth;
  final double capitulationBreadth;
  final double nearLowBreadth;
  final double reboundBreadth;
  final double recoveryBreadth;
  final double volumeBreadth;
  final double avg24hChange;
  final double avg7dChange;
  final bool shouldNotify;
  final String notes;
  final List<MarketBottomCandidate> candidates;

  const MarketBottomAlert({
    required this.generatedAt,
    required this.universeSize,
    required this.analyzedSymbols,
    required this.strategyLabel,
    required this.alertScore,
    required this.fearScore,
    required this.stabilizationScore,
    required this.redBreadth,
    required this.downBreadth,
    required this.capitulationBreadth,
    required this.nearLowBreadth,
    required this.reboundBreadth,
    required this.recoveryBreadth,
    required this.volumeBreadth,
    required this.avg24hChange,
    required this.avg7dChange,
    required this.shouldNotify,
    required this.notes,
    required this.candidates,
  });

  List<MarketBottomCandidate> get actionableCandidates =>
      candidates.where((item) => item.shouldNotify).toList();

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'universeSize': universeSize,
        'analyzedSymbols': analyzedSymbols,
        'strategyLabel': strategyLabel,
        'alertScore': alertScore,
        'fearScore': fearScore,
        'stabilizationScore': stabilizationScore,
        'redBreadth': redBreadth,
        'downBreadth': downBreadth,
        'capitulationBreadth': capitulationBreadth,
        'nearLowBreadth': nearLowBreadth,
        'reboundBreadth': reboundBreadth,
        'recoveryBreadth': recoveryBreadth,
        'volumeBreadth': volumeBreadth,
        'avg24hChange': avg24hChange,
        'avg7dChange': avg7dChange,
        'shouldNotify': shouldNotify,
        'notes': notes,
        'candidates': candidates.map((item) => item.toJson()).toList(),
      };
}

class _RawBottomProfile {
  final CoinData coin;
  final String symbol;
  final double drawdownFrom30dHigh;
  final double distanceTo45dLow;
  final double bounceFrom12hLow;
  final double volumeRatio;
  final double hourlyTrendScore;
  final double hourlyImpulsePercent;
  final double sevenDayChange;
  final double thirtyDayChange;

  const _RawBottomProfile({
    required this.coin,
    required this.symbol,
    required this.drawdownFrom30dHigh,
    required this.distanceTo45dLow,
    required this.bounceFrom12hLow,
    required this.volumeRatio,
    required this.hourlyTrendScore,
    required this.hourlyImpulsePercent,
    required this.sevenDayChange,
    required this.thirtyDayChange,
  });
}
