import 'dart:math';

import '../models/coin_data.dart';

class LeaderPredictionResult {
  final DateTime generatedAt;
  final List<CoinData> rankedCoins;
  final List<CoinData> top3;
  final String regimeStatus;
  final String regimeReason;
  final double marketBreadth;
  final double medianSevenDayReturn;
  final double btcDistanceToSma20;
  final Map<String, dynamic> summary;

  const LeaderPredictionResult({
    required this.generatedAt,
    required this.rankedCoins,
    required this.top3,
    required this.regimeStatus,
    required this.regimeReason,
    required this.marketBreadth,
    required this.medianSevenDayReturn,
    required this.btcDistanceToSma20,
    required this.summary,
  });
}

class LeaderPredictionService {
  static const double minMedianQuoteVolume = 1500000;

  LeaderPredictionResult analyze({
    required List<CoinData> currentCoins,
    required Map<String, List<dynamic>> dailyHistory,
    required List<dynamic> btcDailyHistory,
  }) {
    final generatedAt = DateTime.now();
    final profiles = <_LeaderProfile>[];

    for (final coin in currentCoins) {
      final bars = dailyHistory[coin.symbol] ?? const [];
      if (bars.length < 30) {
        profiles.add(
          _LeaderProfile.skipped(
            coin: coin,
            reason: '日线样本不足 30 天，无法参与领涨预测。',
          ),
        );
        continue;
      }

      final closes = bars.map(_closeOf).toList();
      final highs = bars.map(_highOf).toList();
      final opens = bars.map(_openOf).toList();
      final quotes = bars.map(_quoteVolumeOf).toList();
      final returns = List<double>.generate(
        closes.length,
        (index) => _returnOf(opens[index], closes[index]),
      );

      final ret7 = _periodReturn(closes, 7);
      final ret14 = _periodReturn(closes, 14);
      final ret21 = _periodReturn(closes, 21);
      final sma10 = _average(closes.sublist(max(0, closes.length - 10)));
      final sma20 = _average(closes.sublist(max(0, closes.length - 20)));
      final sma30 = _average(closes.sublist(max(0, closes.length - 30)));
      final vol20 =
          _realizedVolatility(returns.sublist(max(0, returns.length - 20)));
      final recent3Volume = _average(quotes.sublist(max(0, quotes.length - 3)));
      final recent10Volume =
          _average(quotes.sublist(max(0, quotes.length - 10)));
      final volumeRatio = recent3Volume / max(recent10Volume, 1);
      final medianQuote20 = _median(quotes.sublist(max(0, quotes.length - 20)));
      final daily1 = returns.last;
      final daily3 = returns
          .sublist(max(0, returns.length - 3))
          .fold<double>(0, (sum, item) => sum + item);
      final consecutiveLargeBodies = _countConsecutiveLargeBodies(returns);
      final high10 = highs.sublist(max(0, highs.length - 10)).reduce(max);
      final distanceToHigh10 = high10 <= 0
          ? 0.0
          : (((closes.last - high10) / high10) * 100).toDouble();

      final skipped = medianQuote20 < minMedianQuoteVolume ||
          daily1 > 10 ||
          daily3 > 18 ||
          consecutiveLargeBodies >= 3;

      profiles.add(
        _LeaderProfile(
          coin: coin,
          ret7: ret7,
          ret14: ret14,
          ret21: ret21,
          sma10: sma10,
          sma20: sma20,
          sma30: sma30,
          volatility20: vol20,
          volumeRatio: volumeRatio,
          medianQuote20: medianQuote20,
          daily1: daily1,
          daily3: daily3,
          distanceToHigh10: distanceToHigh10,
          skipped: skipped,
          skipReason: skipped
              ? _skipReason(
                  medianQuote20: medianQuote20,
                  daily1: daily1,
                  daily3: daily3,
                  consecutiveLargeBodies: consecutiveLargeBodies,
                )
              : '',
        ),
      );
    }

    final tradable = profiles.where((item) => !item.skipped).toList();
    if (tradable.isEmpty) {
      final ranked = profiles.map(_decorateSkipped).toList()
        ..sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
      return LeaderPredictionResult(
        generatedAt: generatedAt,
        rankedCoins: ranked,
        top3: ranked.take(3).toList(),
        regimeStatus: 'stand_aside',
        regimeReason: '当前自选池没有满足基础流动性和热度过滤的币。',
        marketBreadth: 0,
        medianSevenDayReturn: 0,
        btcDistanceToSma20: 0,
        summary: {
          'mode': 'leader_prediction',
          'regimeStatus': 'stand_aside',
          'reason': '当前没有可参与预测的币种',
          'top1Symbol': null,
          'top1Score': 0.0,
          'top1ComponentScores': const <String, double>{},
          'top3Symbols': const <String>[],
        },
      );
    }

    _applyCrossSectionScores(tradable);
    final regime = _buildRegime(
      currentCoins: currentCoins,
      tradable: tradable,
      btcDailyHistory: btcDailyHistory,
    );

    final rankedProfiles = profiles
        .map((profile) => _applyRegime(profile, regime.status))
        .toList()
      ..sort((a, b) => b.totalScore.compareTo(a.totalScore));
    final topProfiles = rankedProfiles.take(3).toList();

    final rankedCoins = rankedProfiles
        .map((profile) => _decorateCoin(profile, regime))
        .toList();
    final top3 = rankedCoins.take(3).toList();
    final top1 = top3.isEmpty ? null : top3.first;

    return LeaderPredictionResult(
      generatedAt: generatedAt,
      rankedCoins: rankedCoins,
      top3: top3,
      regimeStatus: regime.status,
      regimeReason: regime.reason,
      marketBreadth: regime.marketBreadth,
      medianSevenDayReturn: regime.medianSevenDayReturn,
      btcDistanceToSma20: regime.btcDistanceToSma20,
      summary: {
        'mode': 'leader_prediction',
        'regimeStatus': regime.status,
        'reason': regime.reason,
        'marketBreadth': regime.marketBreadth,
        'medianSevenDayReturn': regime.medianSevenDayReturn,
        'btcDistanceToSma20': regime.btcDistanceToSma20,
        'top1Symbol': top1?.displayName,
        'top1Score': top1?.score ?? 0.0,
        'top1ComponentScores': topProfiles.isEmpty
            ? const <String, double>{}
            : _componentScores(topProfiles.first),
        'top3Symbols': top3.map((item) => item.displayName).toList(),
        'top3ComponentScores': {
          for (final profile in topProfiles)
            profile.coin.displayName: _componentScores(profile),
        },
      },
    );
  }

  void _applyCrossSectionScores(List<_LeaderProfile> profiles) {
    final ret7Ranks = _rankMap(profiles, (item) => item.ret7, descending: true);
    final ret14Ranks =
        _rankMap(profiles, (item) => item.ret14, descending: true);
    final ret21Ranks =
        _rankMap(profiles, (item) => item.ret21, descending: true);
    final volRanks = _rankMap(
      profiles,
      (item) => item.volatility20,
      descending: false,
    );

    for (final profile in profiles) {
      final symbol = profile.coin.symbol;
      final momentumScore = ((ret7Ranks[symbol] ?? 0) * 0.30 +
              (ret14Ranks[symbol] ?? 0) * 0.50 +
              (ret21Ranks[symbol] ?? 0) * 0.20)
          .clamp(0.0, 1.0);
      final trendScore = _trendScore(profile);
      final lowVolScore = (volRanks[symbol] ?? 0).clamp(0.0, 1.0);
      final volumeHealthScore = _volumeHealthScore(profile.volumeRatio);
      final overheatPenalty = _overheatPenalty(profile);
      final totalScore = (momentumScore * 0.35 +
              trendScore * 0.20 +
              lowVolScore * 0.18 +
              volumeHealthScore * 0.15 +
              overheatPenalty * 0.12)
          .clamp(0.0, 1.0);

      profile
        ..momentumScore = momentumScore
        ..trendScore = trendScore
        ..lowVolScore = lowVolScore
        ..volumeHealthScore = volumeHealthScore
        ..overheatPenaltyScore = overheatPenalty
        ..totalScore = totalScore;
    }
  }

  _LeaderProfile _applyRegime(_LeaderProfile profile, String regimeStatus) {
    if (profile.skipped) return profile.copyWith(totalScore: 0);
    var adjustedScore = profile.totalScore;
    if (regimeStatus == 'watch_only') {
      adjustedScore *= 0.82;
    } else if (regimeStatus == 'stand_aside') {
      adjustedScore *= 0.55;
    }
    return profile.copyWith(totalScore: adjustedScore);
  }

  Map<String, double> _rankMap(
    List<_LeaderProfile> profiles,
    double Function(_LeaderProfile item) selector, {
    required bool descending,
  }) {
    final ordered = [...profiles]..sort((a, b) {
        final comparison = selector(a).compareTo(selector(b));
        return descending ? -comparison : comparison;
      });
    final total = max(ordered.length - 1, 1);
    final scores = <String, double>{};
    for (var i = 0; i < ordered.length; i += 1) {
      scores[ordered[i].coin.symbol] = 1 - (i / total);
    }
    return scores;
  }

  double _trendScore(_LeaderProfile profile) {
    final price = profile.coin.lastPrice;
    if (price > profile.sma10 &&
        profile.sma10 > profile.sma20 &&
        profile.sma20 > profile.sma30) {
      return 1.0;
    }
    if (price > profile.sma10 && profile.sma10 > profile.sma20) {
      return 0.82;
    }
    if (price > profile.sma20) {
      return 0.56;
    }
    if (price > profile.sma30) {
      return 0.34;
    }
    return 0.08;
  }

  double _volumeHealthScore(double ratio) {
    if (ratio < 0.75) return 0.12;
    if (ratio <= 1.05) return 0.55;
    if (ratio <= 1.50) return 1.0;
    if (ratio <= 2.0) return 0.58;
    return 0.18;
  }

  double _overheatPenalty(_LeaderProfile profile) {
    var score = 1.0;
    if (profile.daily1 > 8) score -= 0.55;
    if (profile.daily3 > 15) score -= 0.55;
    if (profile.distanceToHigh10 > -0.2) score -= 0.18;
    if (profile.distanceToHigh10 < -6) score -= 0.12;
    return score.clamp(0.0, 1.0);
  }

  Map<String, double> _componentScores(_LeaderProfile profile) {
    return {
      'momentum': profile.momentumScore,
      'trend': profile.trendScore,
      'lowVol': profile.lowVolScore,
      'volumeHealth': profile.volumeHealthScore,
      'overheatPenalty': profile.overheatPenaltyScore,
      'total': profile.totalScore,
      'ret7': profile.ret7,
      'ret14': profile.ret14,
      'ret21': profile.ret21,
      'volumeRatio': profile.volumeRatio,
      'distanceToHigh10': profile.distanceToHigh10,
      'medianQuote20': profile.medianQuote20,
    };
  }

  _MarketRegime _buildRegime({
    required List<CoinData> currentCoins,
    required List<_LeaderProfile> tradable,
    required List<dynamic> btcDailyHistory,
  }) {
    final breadth = currentCoins.isEmpty
        ? 0.0
        : currentCoins.where((item) => item.priceChangePercent > 0).length /
            currentCoins.length;
    final sevenDayValues = tradable.map((item) => item.ret7).toList();
    final medianSevenDayReturn =
        sevenDayValues.isEmpty ? 0.0 : _median(sevenDayValues);
    final btcCloses = btcDailyHistory.map(_closeOf).toList();
    final btcLast = btcCloses.isEmpty ? 0.0 : btcCloses.last;
    final btcSma20 = btcCloses.length < 20
        ? btcLast
        : _average(btcCloses.sublist(btcCloses.length - 20));
    final btcDistanceToSma20 =
        btcSma20 <= 0 ? 0.0 : ((btcLast - btcSma20) / btcSma20) * 100;

    if (btcDistanceToSma20 <= -2 ||
        breadth < 0.42 ||
        medianSevenDayReturn < -4) {
      return _MarketRegime(
        status: 'stand_aside',
        reason: 'BTC 跌破 20 日线或自选池整体偏弱，当前不建议主动追逐领涨。',
        marketBreadth: breadth,
        medianSevenDayReturn: medianSevenDayReturn,
        btcDistanceToSma20: btcDistanceToSma20,
      );
    }
    if (btcDistanceToSma20 < 0 || breadth < 0.52 || medianSevenDayReturn < -1) {
      return _MarketRegime(
        status: 'watch_only',
        reason: '市场环境一般，可观察但不建议高频出手。',
        marketBreadth: breadth,
        medianSevenDayReturn: medianSevenDayReturn,
        btcDistanceToSma20: btcDistanceToSma20,
      );
    }
    return _MarketRegime(
      status: 'recommend',
      reason: '市场状态配合，允许输出下一根日线领涨预测。',
      marketBreadth: breadth,
      medianSevenDayReturn: medianSevenDayReturn,
      btcDistanceToSma20: btcDistanceToSma20,
    );
  }

  CoinData _decorateCoin(_LeaderProfile profile, _MarketRegime regime) {
    final coin = CoinData(
      symbol: profile.coin.symbol,
      lastPrice: profile.coin.lastPrice,
      priceChange: profile.coin.priceChange,
      priceChangePercent: profile.coin.priceChangePercent,
      highPrice: profile.coin.highPrice,
      lowPrice: profile.coin.lowPrice,
      openPrice: profile.coin.openPrice,
      quoteVolume: profile.coin.quoteVolume,
      volume: profile.coin.volume,
      count: profile.coin.count,
      thirtyDayChange: profile.coin.thirtyDayChange,
      sevenDayChange: profile.coin.sevenDayChange,
      daysSinceSurge: profile.coin.daysSinceSurge,
    );

    if (profile.skipped) {
      coin
        ..score = 0
        ..historicalScore = 0
        ..entryScore = 0
        ..expectedEdge = 0
        ..recommendation = '跳过'
        ..reason = profile.skipReason
        ..timingLabel = '不参与'
        ..timingReason = profile.skipReason;
      return coin;
    }

    final regimeLabel = switch (regime.status) {
      'recommend' => '可推荐',
      'watch_only' => '仅观察',
      _ => '不出手',
    };
    coin
      ..score = profile.totalScore
      ..historicalScore = profile.momentumScore
      ..entryScore = profile.trendScore
      ..expectedEdge = profile.totalScore - 0.5
      ..recommendation = regimeLabel
      ..reason =
          '动量 ${(profile.momentumScore * 100).round()} | 趋势 ${(profile.trendScore * 100).round()} | 低波动 ${(profile.lowVolScore * 100).round()} | 量能 ${(profile.volumeHealthScore * 100).round()}'
      ..timingLabel = '下一根日线领涨预测'
      ..timingReason =
          '14d ${profile.ret14 >= 0 ? '+' : ''}${profile.ret14.toStringAsFixed(1)}% · 7d ${profile.ret7 >= 0 ? '+' : ''}${profile.ret7.toStringAsFixed(1)}% · 量比 ${profile.volumeRatio.toStringAsFixed(2)}x · 距10日高点 ${profile.distanceToHigh10.toStringAsFixed(2)}% · ${regime.reason}';
    return coin;
  }

  CoinData _decorateSkipped(_LeaderProfile profile) {
    return _decorateCoin(
      profile,
      const _MarketRegime(
        status: 'stand_aside',
        reason: '当前币种不满足参与预测条件。',
        marketBreadth: 0,
        medianSevenDayReturn: 0,
        btcDistanceToSma20: 0,
      ),
    );
  }

  String _skipReason({
    required double medianQuote20,
    required double daily1,
    required double daily3,
    required int consecutiveLargeBodies,
  }) {
    if (medianQuote20 < minMedianQuoteVolume) {
      return '近 20 天成交额中位数偏低，流动性不足。';
    }
    if (daily1 > 10) {
      return '单日涨幅过大，视为过热，不纳入领涨预测。';
    }
    if (daily3 > 18) {
      return '近 3 日累计涨幅过大，避免追涨末端。';
    }
    if (consecutiveLargeBodies >= 3) {
      return '已连续强拉升，当前阶段不做默认推荐。';
    }
    return '当前不满足领涨预测过滤条件。';
  }

  static double _periodReturn(List<double> closes, int period) {
    if (closes.length <= period) return 0;
    final start = closes[closes.length - period - 1];
    if (start <= 0) return 0;
    final end = closes.last;
    return ((end - start) / start) * 100;
  }

  static double _realizedVolatility(List<double> values) {
    if (values.length <= 1) return 0;
    final mean = _average(values);
    final variance = values.fold<double>(
          0,
          (sum, item) => sum + pow(item - mean, 2),
        ) /
        values.length;
    return sqrt(variance);
  }

  static int _countConsecutiveLargeBodies(List<double> returns) {
    var count = 0;
    for (var i = returns.length - 1; i >= 0; i -= 1) {
      if (returns[i] > 5.2) {
        count += 1;
      } else {
        break;
      }
    }
    return count;
  }

  static double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static double _average(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double _openOf(dynamic item) {
    if (item is List && item.length > 1) return _asDouble(item[1]);
    if (item is Map) return _asDouble(item['open']);
    return 0;
  }

  static double _closeOf(dynamic item) {
    if (item is List && item.length > 4) return _asDouble(item[4]);
    if (item is Map) return _asDouble(item['close']);
    return 0;
  }

  static double _highOf(dynamic item) {
    if (item is List && item.length > 2) return _asDouble(item[2]);
    if (item is Map) return _asDouble(item['high']);
    return 0;
  }

  static double _quoteVolumeOf(dynamic item) {
    if (item is List && item.length > 7) return _asDouble(item[7]);
    if (item is Map) return _asDouble(item['quoteVolume']);
    return 0;
  }

  static double _returnOf(double open, double close) {
    if (open <= 0) return 0;
    return ((close - open) / open) * 100;
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value == null) return 0;
    return double.tryParse(value.toString()) ?? 0;
  }
}

class _LeaderProfile {
  final CoinData coin;
  final double ret7;
  final double ret14;
  final double ret21;
  final double sma10;
  final double sma20;
  final double sma30;
  final double volatility20;
  final double volumeRatio;
  final double medianQuote20;
  final double daily1;
  final double daily3;
  final double distanceToHigh10;
  final bool skipped;
  final String skipReason;
  double momentumScore;
  double trendScore;
  double lowVolScore;
  double volumeHealthScore;
  double overheatPenaltyScore;
  double totalScore;

  _LeaderProfile({
    required this.coin,
    required this.ret7,
    required this.ret14,
    required this.ret21,
    required this.sma10,
    required this.sma20,
    required this.sma30,
    required this.volatility20,
    required this.volumeRatio,
    required this.medianQuote20,
    required this.daily1,
    required this.daily3,
    required this.distanceToHigh10,
    required this.skipped,
    required this.skipReason,
    this.momentumScore = 0,
    this.trendScore = 0,
    this.lowVolScore = 0,
    this.volumeHealthScore = 0,
    this.overheatPenaltyScore = 0,
    this.totalScore = 0,
  });

  factory _LeaderProfile.skipped({
    required CoinData coin,
    required String reason,
  }) {
    return _LeaderProfile(
      coin: coin,
      ret7: 0,
      ret14: 0,
      ret21: 0,
      sma10: 0,
      sma20: 0,
      sma30: 0,
      volatility20: 0,
      volumeRatio: 0,
      medianQuote20: 0,
      daily1: 0,
      daily3: 0,
      distanceToHigh10: 0,
      skipped: true,
      skipReason: reason,
    );
  }

  _LeaderProfile copyWith({double? totalScore}) {
    return _LeaderProfile(
      coin: coin,
      ret7: ret7,
      ret14: ret14,
      ret21: ret21,
      sma10: sma10,
      sma20: sma20,
      sma30: sma30,
      volatility20: volatility20,
      volumeRatio: volumeRatio,
      medianQuote20: medianQuote20,
      daily1: daily1,
      daily3: daily3,
      distanceToHigh10: distanceToHigh10,
      skipped: skipped,
      skipReason: skipReason,
      momentumScore: momentumScore,
      trendScore: trendScore,
      lowVolScore: lowVolScore,
      volumeHealthScore: volumeHealthScore,
      overheatPenaltyScore: overheatPenaltyScore,
      totalScore: totalScore ?? this.totalScore,
    );
  }
}

class _MarketRegime {
  final String status;
  final String reason;
  final double marketBreadth;
  final double medianSevenDayReturn;
  final double btcDistanceToSma20;

  const _MarketRegime({
    required this.status,
    required this.reason,
    required this.marketBreadth,
    required this.medianSevenDayReturn,
    required this.btcDistanceToSma20,
  });
}
