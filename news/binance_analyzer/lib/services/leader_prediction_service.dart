import 'dart:math';

import '../models/coin_data.dart';
import '../models/news_item.dart';
import 'binance_service.dart';

class LeaderPredictionExperimentConfig {
  final String id;
  final String label;
  final String family;
  final int round;
  final int corePoolSize;
  final double rotationWeight;
  final double trendWeight;
  final double compressionWeight;
  final double volumeWeight;
  final double lowVolWeight;
  final double marketWeight;
  final double newsWeight;
  final double heatPenaltyWeight;
  final double recommendThreshold;
  final double watchThreshold;
  final bool requireRotationConfirmation;

  const LeaderPredictionExperimentConfig({
    required this.id,
    required this.label,
    required this.family,
    required this.round,
    required this.corePoolSize,
    required this.rotationWeight,
    required this.trendWeight,
    required this.compressionWeight,
    required this.volumeWeight,
    required this.lowVolWeight,
    required this.marketWeight,
    required this.newsWeight,
    required this.heatPenaltyWeight,
    required this.recommendThreshold,
    required this.watchThreshold,
    this.requireRotationConfirmation = true,
  });
}

class LeaderPredictionResult {
  final DateTime generatedAt;
  final List<CoinData> rankedCoins;
  final List<CoinData> top3;
  final String regimeStatus;
  final String regimeReason;
  final double marketBreadth;
  final double medianSevenDayReturn;
  final double btcDistanceToSma20;
  final String modelVersion;
  final String confidence;
  final bool rotationConfirmed;
  final List<String> corePoolSymbols;
  final String selectedExperimentId;
  final String selectedExperimentLabel;
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
    required this.modelVersion,
    required this.confidence,
    required this.rotationConfirmed,
    required this.corePoolSymbols,
    required this.selectedExperimentId,
    required this.selectedExperimentLabel,
    required this.summary,
  });
}

class LeaderPredictionService {
  static const double minMedianQuoteVolume = 250000;
  static const String modelVersion = 'rotation_top1_v2';

  static const LeaderPredictionExperimentConfig defaultExperimentConfig =
      LeaderPredictionExperimentConfig(
    id: 'cooldown_pool6',
    label: 'Cooldown Re-entry / Pool 6',
    family: 'cooldown_reentry',
    round: 2,
    corePoolSize: 6,
    rotationWeight: 0.34,
    trendWeight: 0.20,
    compressionWeight: 0.14,
    volumeWeight: 0.10,
    lowVolWeight: 0.10,
    marketWeight: 0.08,
    newsWeight: 0.04,
    heatPenaltyWeight: 0.20,
    recommendThreshold: 0.62,
    watchThreshold: 0.52,
  );

  static const List<LeaderPredictionExperimentConfig> experimentConfigs = [
    LeaderPredictionExperimentConfig(
      id: 'cooldown_pool4',
      label: 'Cooldown Re-entry / Pool 4',
      family: 'cooldown_reentry',
      round: 1,
      corePoolSize: 4,
      rotationWeight: 0.36,
      trendWeight: 0.18,
      compressionWeight: 0.14,
      volumeWeight: 0.10,
      lowVolWeight: 0.10,
      marketWeight: 0.08,
      newsWeight: 0.04,
      heatPenaltyWeight: 0.20,
      recommendThreshold: 0.63,
      watchThreshold: 0.53,
    ),
    defaultExperimentConfig,
    LeaderPredictionExperimentConfig(
      id: 'cooldown_pool8',
      label: 'Cooldown Re-entry / Pool 8',
      family: 'cooldown_reentry',
      round: 3,
      corePoolSize: 8,
      rotationWeight: 0.33,
      trendWeight: 0.18,
      compressionWeight: 0.16,
      volumeWeight: 0.10,
      lowVolWeight: 0.11,
      marketWeight: 0.08,
      newsWeight: 0.04,
      heatPenaltyWeight: 0.19,
      recommendThreshold: 0.61,
      watchThreshold: 0.51,
    ),
    LeaderPredictionExperimentConfig(
      id: 'shorttrend_pool4',
      label: 'Short Trend Rotation / Pool 4',
      family: 'short_trend_rotation',
      round: 4,
      corePoolSize: 4,
      rotationWeight: 0.10,
      trendWeight: 0.52,
      compressionWeight: 0.06,
      volumeWeight: 0.10,
      lowVolWeight: 0.05,
      marketWeight: 0.12,
      newsWeight: 0.05,
      heatPenaltyWeight: 0.08,
      recommendThreshold: 0.60,
      watchThreshold: 0.50,
    ),
    LeaderPredictionExperimentConfig(
      id: 'shorttrend_pool6',
      label: 'Short Trend Rotation / Pool 6',
      family: 'short_trend_rotation',
      round: 5,
      corePoolSize: 6,
      rotationWeight: 0.12,
      trendWeight: 0.48,
      compressionWeight: 0.07,
      volumeWeight: 0.10,
      lowVolWeight: 0.06,
      marketWeight: 0.12,
      newsWeight: 0.05,
      heatPenaltyWeight: 0.08,
      recommendThreshold: 0.59,
      watchThreshold: 0.49,
    ),
    LeaderPredictionExperimentConfig(
      id: 'shorttrend_pool8',
      label: 'Short Trend Rotation / Pool 8',
      family: 'short_trend_rotation',
      round: 6,
      corePoolSize: 8,
      rotationWeight: 0.13,
      trendWeight: 0.44,
      compressionWeight: 0.08,
      volumeWeight: 0.10,
      lowVolWeight: 0.07,
      marketWeight: 0.12,
      newsWeight: 0.06,
      heatPenaltyWeight: 0.08,
      recommendThreshold: 0.58,
      watchThreshold: 0.48,
    ),
    LeaderPredictionExperimentConfig(
      id: 'compression_pool4',
      label: 'Compression Break Candidate / Pool 4',
      family: 'compression_break_candidate',
      round: 7,
      corePoolSize: 4,
      rotationWeight: 0.19,
      trendWeight: 0.19,
      compressionWeight: 0.29,
      volumeWeight: 0.12,
      lowVolWeight: 0.12,
      marketWeight: 0.07,
      newsWeight: 0.02,
      heatPenaltyWeight: 0.18,
      recommendThreshold: 0.63,
      watchThreshold: 0.53,
    ),
    LeaderPredictionExperimentConfig(
      id: 'compression_pool6',
      label: 'Compression Break Candidate / Pool 6',
      family: 'compression_break_candidate',
      round: 8,
      corePoolSize: 6,
      rotationWeight: 0.18,
      trendWeight: 0.19,
      compressionWeight: 0.30,
      volumeWeight: 0.12,
      lowVolWeight: 0.12,
      marketWeight: 0.07,
      newsWeight: 0.02,
      heatPenaltyWeight: 0.18,
      recommendThreshold: 0.62,
      watchThreshold: 0.52,
    ),
    LeaderPredictionExperimentConfig(
      id: 'compression_pool8',
      label: 'Compression Break Candidate / Pool 8',
      family: 'compression_break_candidate',
      round: 9,
      corePoolSize: 8,
      rotationWeight: 0.17,
      trendWeight: 0.18,
      compressionWeight: 0.30,
      volumeWeight: 0.12,
      lowVolWeight: 0.13,
      marketWeight: 0.08,
      newsWeight: 0.02,
      heatPenaltyWeight: 0.18,
      recommendThreshold: 0.61,
      watchThreshold: 0.51,
    ),
    LeaderPredictionExperimentConfig(
      id: 'newsbias_pool4',
      label: 'News-biased Rotation / Pool 4',
      family: 'news_biased_rotation',
      round: 10,
      corePoolSize: 4,
      rotationWeight: 0.22,
      trendWeight: 0.23,
      compressionWeight: 0.13,
      volumeWeight: 0.12,
      lowVolWeight: 0.08,
      marketWeight: 0.08,
      newsWeight: 0.14,
      heatPenaltyWeight: 0.20,
      recommendThreshold: 0.63,
      watchThreshold: 0.53,
    ),
    LeaderPredictionExperimentConfig(
      id: 'newsbias_pool6',
      label: 'News-biased Rotation / Pool 6',
      family: 'news_biased_rotation',
      round: 11,
      corePoolSize: 6,
      rotationWeight: 0.21,
      trendWeight: 0.23,
      compressionWeight: 0.14,
      volumeWeight: 0.12,
      lowVolWeight: 0.08,
      marketWeight: 0.08,
      newsWeight: 0.14,
      heatPenaltyWeight: 0.20,
      recommendThreshold: 0.62,
      watchThreshold: 0.52,
    ),
    LeaderPredictionExperimentConfig(
      id: 'newsbias_pool8',
      label: 'News-biased Rotation / Pool 8',
      family: 'news_biased_rotation',
      round: 12,
      corePoolSize: 8,
      rotationWeight: 0.19,
      trendWeight: 0.22,
      compressionWeight: 0.15,
      volumeWeight: 0.12,
      lowVolWeight: 0.08,
      marketWeight: 0.08,
      newsWeight: 0.16,
      heatPenaltyWeight: 0.20,
      recommendThreshold: 0.61,
      watchThreshold: 0.51,
    ),
  ];

  LeaderPredictionExperimentConfig configById(String id) {
    return experimentConfigs.firstWhere(
      (item) => item.id == id,
      orElse: () => defaultExperimentConfig,
    );
  }

  LeaderPredictionResult analyze({
    required List<CoinData> currentCoins,
    required Map<String, List<dynamic>> dailyHistory,
    required List<dynamic> btcDailyHistory,
    List<NewsItem> recentNews = const [],
    LeaderPredictionExperimentConfig? experimentConfig,
    List<String>? forcedCorePoolSymbols,
  }) {
    final generatedAt = DateTime.now();
    final normalizedHistory = <String, List<dynamic>>{
      for (final entry in dailyHistory.entries)
        BinanceService.toSymbol(entry.key): _completeDailyBars(entry.value),
    };
    final profiles = <_LeaderProfile>[];

    for (final coin in currentCoins) {
      final symbol = BinanceService.toSymbol(coin.symbol);
      final bars = normalizedHistory[symbol] ?? const [];
      if (bars.length < 45) {
        profiles.add(
          _LeaderProfile.skipped(
            coin: coin,
            reason: '日线样本不足 45 天，暂不参与轮动 Top1 预测。',
          ),
        );
        continue;
      }

      final closes = bars.map(_closeOf).toList();
      final opens = bars.map(_openOf).toList();
      final highs = bars.map(_highOf).toList();
      final lows = bars.map(_lowOf).toList();
      final quotes = bars.map(_quoteVolumeOf).toList();
      final bodyReturns = List<double>.generate(
        closes.length,
        (index) => _returnOf(opens[index], closes[index]),
      );
      final closeReturns = _closeToCloseReturns(closes);
      final sma5 = _average(closes.sublist(max(0, closes.length - 5)));
      final sma10 = _average(closes.sublist(max(0, closes.length - 10)));
      final sma20 = _average(closes.sublist(max(0, closes.length - 20)));
      final sma30 = _average(closes.sublist(max(0, closes.length - 30)));
      final vol5 = _realizedVolatility(
        closeReturns.sublist(max(0, closeReturns.length - 5)),
      );
      final vol10 = _realizedVolatility(
        closeReturns.sublist(max(0, closeReturns.length - 10)),
      );
      final vol20 = _realizedVolatility(
        closeReturns.sublist(max(0, closeReturns.length - 20)),
      );
      final high10 = highs.sublist(max(0, highs.length - 10)).reduce(max);
      final low10 = lows.sublist(max(0, lows.length - 10)).reduce(min);
      final recent3Volume = _average(quotes.sublist(max(0, quotes.length - 3)));
      final recent10Volume =
          _average(quotes.sublist(max(0, quotes.length - 10)));
      final volumeRatio = recent3Volume / max(recent10Volume, 1);
      final medianQuote20 = _median(quotes.sublist(max(0, quotes.length - 20)));
      final distanceToHigh10 = high10 <= 0
          ? 0.0
          : (((closes.last - high10) / high10) * 100).toDouble();
      final distanceToLow10 = low10 <= 0
          ? 0.0
          : (((closes.last - low10) / low10) * 100).toDouble();
      final trendAlignment = _trendAlignmentScore(
        close: closes.last,
        sma5: sma5,
        sma10: sma10,
        sma20: sma20,
      );
      final newsBias = _newsBiasForSymbol(
        symbol: symbol,
        news: recentNews,
      );
      final skipped = medianQuote20 < minMedianQuoteVolume ||
          _periodReturn(closes, 1) > 9.5 ||
          _periodReturn(closes, 3) > 16 ||
          _countConsecutiveLargeBodies(bodyReturns) >= 2;

      profiles.add(
        _LeaderProfile(
          coin: coin,
          close: closes.last,
          ret1: _periodReturn(closes, 1),
          body1: bodyReturns.last,
          ret3: _periodReturn(closes, 3),
          ret5: _periodReturn(closes, 5),
          ret7: _periodReturn(closes, 7),
          ret14: _periodReturn(closes, 14),
          ret21: _periodReturn(closes, 21),
          sma5: sma5,
          sma10: sma10,
          sma20: sma20,
          sma30: sma30,
          trendAlignment: trendAlignment,
          volatility5: vol5,
          volatility10: vol10,
          volatility20: vol20,
          compressionRatio: vol20 <= 0 ? 1.0 : vol5 / max(vol20, 0.0001),
          volumeRatio: volumeRatio,
          medianQuote20: medianQuote20,
          distanceToHigh10: distanceToHigh10,
          distanceToLow10: distanceToLow10,
          newsBias: newsBias,
          skipped: skipped,
          skipReason: skipped
              ? _skipReason(
                  medianQuote20: medianQuote20,
                  ret1: _periodReturn(closes, 1),
                  ret3: _periodReturn(closes, 3),
                  consecutiveLargeBodies:
                      _countConsecutiveLargeBodies(bodyReturns),
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
        modelVersion: modelVersion,
        confidence: 'low',
        rotationConfirmed: false,
        corePoolSymbols: const [],
        selectedExperimentId: defaultExperimentConfig.id,
        selectedExperimentLabel: defaultExperimentConfig.label,
        summary: {
          'mode': 'leader_prediction',
          'modelVersion': modelVersion,
          'regimeStatus': 'stand_aside',
          'reason': '当前没有可参与预测的币种',
          'confidence': 'low',
          'rotationConfirmed': false,
          'corePoolSymbols': const <String>[],
          'selectedExperimentId': defaultExperimentConfig.id,
          'selectedExperimentLabel': defaultExperimentConfig.label,
          'top1Symbol': null,
          'top1Score': 0.0,
          'top1ComponentScores': const <String, double>{},
          'top3Symbols': const <String>[],
        },
      );
    }

    final leaderStats = _buildLeaderStats(
      dailyHistory: normalizedHistory,
      tradableSymbols: tradable.map((item) => item.coin.symbol).toSet(),
    );
    final rotationSummary = _buildRotationSummary(leaderStats.timeline);
    for (final profile in tradable) {
      final stats = leaderStats.bySymbol[profile.coin.symbol] ??
          const _LeaderHistorySnapshot.empty();
      profile
        ..daysSinceLeader = stats.daysSinceLeader
        ..leaderCount60 = stats.leaderCount60
        ..leaderCount20 = stats.leaderCount20
        ..leaderCount10 = stats.leaderCount10;
    }

    final corePoolScores = _buildCorePoolScores(tradable);
    for (final profile in tradable) {
      profile.corePoolScore = corePoolScores[profile.coin.symbol] ?? 0.0;
    }

    final resolvedConfig = experimentConfig ?? defaultExperimentConfig;
    final corePoolSymbols = _resolveCorePoolSymbols(
      tradable: tradable,
      config: resolvedConfig,
      forcedCorePoolSymbols: forcedCorePoolSymbols,
    );
    final corePoolSet = corePoolSymbols.toSet();
    for (final profile in tradable) {
      profile.inCorePool = corePoolSet.contains(profile.coin.displayName);
    }

    final baseRegime = _buildRegime(
      currentCoins: currentCoins,
      tradable: tradable,
      btcDailyHistory: btcDailyHistory,
      rotationSummary: rotationSummary,
    );
    _applyExperimentScores(
      profiles: tradable,
      config: resolvedConfig,
      regime: baseRegime,
      rotationSummary: rotationSummary,
    );

    final rankedProfiles = [...profiles]
      ..sort((a, b) {
        final byScore = b.totalScore.compareTo(a.totalScore);
        if (byScore != 0) return byScore;
        final byCorePool = (b.inCorePool ? 1 : 0).compareTo(a.inCorePool ? 1 : 0);
        if (byCorePool != 0) return byCorePool;
        final byPoolScore = b.corePoolScore.compareTo(a.corePoolScore);
        if (byPoolScore != 0) return byPoolScore;
        return b.coin.quoteVolume.compareTo(a.coin.quoteVolume);
      });
    final topProfiles = rankedProfiles.where((item) => !item.skipped).take(3).toList();
    final confidence = _confidenceFor(topProfiles);
    final regime = _finalizeRegime(
      baseRegime: baseRegime,
      topProfiles: topProfiles,
      confidence: confidence,
      config: resolvedConfig,
      rotationConfirmed: rotationSummary.confirmed,
    );

    final rankedCoins = rankedProfiles
        .map((profile) => _decorateCoin(
              profile,
              regime,
              resolvedConfig,
            ))
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
      modelVersion: modelVersion,
      confidence: confidence,
      rotationConfirmed: rotationSummary.confirmed,
      corePoolSymbols: corePoolSymbols,
      selectedExperimentId: resolvedConfig.id,
      selectedExperimentLabel: resolvedConfig.label,
      summary: {
        'mode': 'leader_prediction',
        'modelVersion': modelVersion,
        'regimeStatus': regime.status,
        'reason': regime.reason,
        'confidence': confidence,
        'marketBreadth': regime.marketBreadth,
        'medianSevenDayReturn': regime.medianSevenDayReturn,
        'btcDistanceToSma20': regime.btcDistanceToSma20,
        'rotationConfirmed': rotationSummary.confirmed,
        'rotationSummary': rotationSummary.toJson(),
        'corePoolSymbols': corePoolSymbols,
        'selectedExperimentId': resolvedConfig.id,
        'selectedExperimentLabel': resolvedConfig.label,
        'selectedExperimentFamily': resolvedConfig.family,
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

  List<String> _resolveCorePoolSymbols({
    required List<_LeaderProfile> tradable,
    required LeaderPredictionExperimentConfig config,
    required List<String>? forcedCorePoolSymbols,
  }) {
    if (forcedCorePoolSymbols != null && forcedCorePoolSymbols.isNotEmpty) {
      final normalized = forcedCorePoolSymbols
          .map((item) => item.trim().toUpperCase())
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (normalized.isNotEmpty) return normalized;
    }

    final ordered = [...tradable]
      ..sort((a, b) {
        final byPool = b.corePoolScore.compareTo(a.corePoolScore);
        if (byPool != 0) return byPool;
        return b.coin.quoteVolume.compareTo(a.coin.quoteVolume);
      });
    final size = min(config.corePoolSize, max(4, ordered.length));
    return ordered.take(size).map((item) => item.coin.displayName).toList();
  }

  Map<String, double> _buildCorePoolScores(List<_LeaderProfile> tradable) {
    final leader60Ranks =
        _rankMap(tradable, (item) => item.leaderCount60.toDouble(), descending: true);
    final leader20Ranks =
        _rankMap(tradable, (item) => item.leaderCount20.toDouble(), descending: true);
    final liquidityRanks =
        _rankMap(tradable, (item) => item.medianQuote20, descending: true);
    final heatRanks = _rankMap(
      tradable,
      (item) => _corePoolHeat(item),
      descending: false,
    );
    final recentActiveRanks = _rankMap(
      tradable,
      (item) => (item.leaderCount10 * 2 + item.leaderCount20).toDouble(),
      descending: true,
    );

    return {
      for (final profile in tradable)
        profile.coin.symbol:
            ((leader60Ranks[profile.coin.symbol] ?? 0.0) * 0.40) +
                ((leader20Ranks[profile.coin.symbol] ?? 0.0) * 0.20) +
                ((liquidityRanks[profile.coin.symbol] ?? 0.0) * 0.15) +
                ((heatRanks[profile.coin.symbol] ?? 0.0) * 0.15) +
                ((recentActiveRanks[profile.coin.symbol] ?? 0.0) * 0.10),
    };
  }

  void _applyExperimentScores({
    required List<_LeaderProfile> profiles,
    required LeaderPredictionExperimentConfig config,
    required _MarketRegime regime,
    required _RotationSummary rotationSummary,
  }) {
    final coreProfiles = profiles.where((item) => item.inCorePool).toList();
    final rankedUniverse = coreProfiles.isEmpty ? profiles : coreProfiles;
    final rotationRanks =
        _rankMap(rankedUniverse, (item) => _rotationBase(item), descending: true);
    final trendRanks =
        _rankMap(rankedUniverse, (item) => _trendBase(item), descending: true);
    final compressionRanks = _rankMap(
      rankedUniverse,
      (item) => _compressionBase(item),
      descending: true,
    );
    final lowVolRanks =
        _rankMap(rankedUniverse, (item) => item.volatility20, descending: false);
    final marketScore = _marketScore(regime, rotationSummary.confirmed);

    for (final profile in profiles) {
      final symbol = profile.coin.symbol;
      final rotationScore = (((rotationRanks[symbol] ?? 0.0) * 0.72) +
              (profile.corePoolScore * 0.28))
          .clamp(0.0, 1.0);
      final trendScore = (((trendRanks[symbol] ?? 0.0) * 0.70) +
              (_trendAlignmentStrength(profile) * 0.30))
          .clamp(0.0, 1.0);
      final compressionScore = (((compressionRanks[symbol] ?? 0.0) * 0.72) +
              ((lowVolRanks[symbol] ?? 0.0) * 0.28))
          .clamp(0.0, 1.0);
      final volumeScore = _volumeHealthScore(profile.volumeRatio);
      final lowVolScore = (lowVolRanks[symbol] ?? 0.0).clamp(0.0, 1.0);
      final newsScore =
          _normalize(profile.newsBias, -1.0, 1.0).clamp(0.0, 1.0);
      final heatPenalty = _heatPenalty(profile);
      final positiveWeight = config.rotationWeight +
          config.trendWeight +
          config.compressionWeight +
          config.volumeWeight +
          config.lowVolWeight +
          config.marketWeight +
          config.newsWeight;
      var rawScore = (rotationScore * config.rotationWeight) +
          (trendScore * config.trendWeight) +
          (compressionScore * config.compressionWeight) +
          (volumeScore * config.volumeWeight) +
          (lowVolScore * config.lowVolWeight) +
          (marketScore * config.marketWeight) +
          (newsScore * config.newsWeight) -
          (heatPenalty * config.heatPenaltyWeight);
      if (!profile.inCorePool) {
        rawScore -= 0.24;
      }
      if (config.requireRotationConfirmation && !rotationSummary.confirmed) {
        rawScore -= 0.08;
      }
      final totalScore =
          positiveWeight <= 0 ? 0.0 : (rawScore / positiveWeight).clamp(0.0, 1.0);

      profile
        ..rotationScore = rotationScore
        ..trendScore = trendScore
        ..compressionScore = compressionScore
        ..volumeHealthScore = volumeScore
        ..lowVolScore = lowVolScore
        ..marketScore = marketScore
        ..newsScore = newsScore
        ..overheatPenaltyScore = (1 - heatPenalty).clamp(0.0, 1.0)
        ..rawSignalScore = rawScore
        ..totalScore = totalScore;
    }
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

  double _rotationBase(_LeaderProfile profile) {
    final cooldown = _rotationWindowScore(profile.daysSinceLeader);
    final knownLeader = profile.leaderCount60 > 0 ? 1.0 : 0.24;
    final recentOverusePenalty = profile.leaderCount10 >= 2 ? 0.16 : 0.0;
    return ((cooldown * 0.62) +
            (profile.corePoolScore * 0.26) +
            (knownLeader * 0.12) -
            recentOverusePenalty)
        .clamp(0.0, 1.0);
  }

  double _trendBase(_LeaderProfile profile) {
    final mildMomentum = _normalize(profile.ret5, -8.0, 10.0);
    final weeklyMomentum = _normalize(profile.ret7, -10.0, 16.0);
    final biWeeklyMomentum = _normalize(profile.ret14, -15.0, 22.0);
    return ((weeklyMomentum * 0.42) +
            (biWeeklyMomentum * 0.28) +
            (mildMomentum * 0.20) +
            (_trendAlignmentStrength(profile) * 0.10))
        .clamp(0.0, 1.0);
  }

  double _compressionBase(_LeaderProfile profile) {
    final compression = (1 -
            _normalize(profile.compressionRatio, 0.65, 1.55).clamp(0.0, 1.0))
        .clamp(0.0, 1.0);
    final highProximity = (1 -
            _normalize((profile.distanceToHigh10 + 1.8).abs(), 0.0, 8.0)
                .clamp(0.0, 1.0))
        .clamp(0.0, 1.0);
    final notTooLow = _normalize(profile.distanceToLow10, 1.0, 18.0);
    return ((compression * 0.55) +
            (highProximity * 0.30) +
            (notTooLow * 0.15))
        .clamp(0.0, 1.0);
  }

  double _corePoolHeat(_LeaderProfile profile) {
    return (max(profile.body1, 0) * 0.6) +
        (max(profile.ret3, 0) * 0.25) +
        (max(profile.ret7, 0) * 0.15);
  }

  double _rotationWindowScore(int daysSinceLeader) {
    if (daysSinceLeader <= 0) return 0.02;
    if (daysSinceLeader == 1) return 0.08;
    if (daysSinceLeader == 2) return 0.34;
    if (daysSinceLeader <= 4) return 0.74;
    if (daysSinceLeader <= 8) return 1.0;
    if (daysSinceLeader <= 14) return 0.82;
    if (daysSinceLeader <= 21) return 0.58;
    return 0.36;
  }

  double _trendAlignmentStrength(_LeaderProfile profile) {
    if (profile.close > profile.sma5 &&
        profile.sma5 > profile.sma10 &&
        profile.sma10 > profile.sma20) {
      return 1.0;
    }
    if (profile.close > profile.sma5 && profile.sma5 > profile.sma10) {
      return 0.74;
    }
    if (profile.close > profile.sma10) {
      return 0.48;
    }
    if (profile.close > profile.sma20) {
      return 0.32;
    }
    return 0.12;
  }

  double _volumeHealthScore(double ratio) {
    if (ratio < 0.70) return 0.10;
    if (ratio < 0.95) return 0.44;
    if (ratio <= 1.60) return 1.0;
    if (ratio <= 2.20) return 0.48;
    return 0.16;
  }

  double _heatPenalty(_LeaderProfile profile) {
    var penalty = 0.0;
    if (profile.ret1 > 8) {
      penalty += 0.48;
    } else if (profile.ret1 > 5.5) {
      penalty += 0.24;
    }
    if (profile.ret3 > 14) {
      penalty += 0.44;
    } else if (profile.ret3 > 9) {
      penalty += 0.18;
    }
    if (profile.volumeRatio > 2.2) penalty += 0.14;
    if (profile.distanceToHigh10 > 1.2) penalty += 0.12;
    if (profile.ret7 > 18) penalty += 0.12;
    return penalty.clamp(0.0, 1.0);
  }

  Map<String, double> _componentScores(_LeaderProfile profile) {
    return {
      'rotation': profile.rotationScore,
      'trend': profile.trendScore,
      'compression': profile.compressionScore,
      'volume': profile.volumeHealthScore,
      'lowVol': profile.lowVolScore,
      'market': profile.marketScore,
      'newsBias': profile.newsScore,
      'risk': profile.overheatPenaltyScore,
      'corePool': profile.corePoolScore,
      'total': profile.totalScore,
      'ret1': profile.ret1,
      'ret3': profile.ret3,
      'ret5': profile.ret5,
      'ret7': profile.ret7,
      'ret14': profile.ret14,
      'ret21': profile.ret21,
      'volumeRatio': profile.volumeRatio,
      'compressionRatio': profile.compressionRatio,
      'distanceToHigh10': profile.distanceToHigh10,
      'distanceToLow10': profile.distanceToLow10,
      'daysSinceLeader': profile.daysSinceLeader.toDouble(),
      'leaderCount60': profile.leaderCount60.toDouble(),
      'leaderCount20': profile.leaderCount20.toDouble(),
      'leaderCount10': profile.leaderCount10.toDouble(),
      'newsBiasRaw': profile.newsBias,
      'medianQuote20': profile.medianQuote20,
    };
  }

  _MarketRegime _buildRegime({
    required List<CoinData> currentCoins,
    required List<_LeaderProfile> tradable,
    required List<dynamic> btcDailyHistory,
    required _RotationSummary rotationSummary,
  }) {
    final breadth = currentCoins.isEmpty
        ? 0.0
        : currentCoins.where((item) => item.priceChangePercent > 0).length /
            currentCoins.length;
    final sevenDayValues = tradable.map((item) => item.ret7).toList();
    final medianSevenDayReturn =
        sevenDayValues.isEmpty ? 0.0 : _median(sevenDayValues);
    final btcBars = _completeDailyBars(btcDailyHistory);
    final btcCloses = btcBars.map(_closeOf).toList();
    final btcLast = btcCloses.isEmpty ? 0.0 : btcCloses.last;
    final btcSma20 = btcCloses.length < 20
        ? btcLast
        : _average(btcCloses.sublist(btcCloses.length - 20));
    final btcDistanceToSma20 =
        btcSma20 <= 0 ? 0.0 : ((btcLast - btcSma20) / btcSma20) * 100;

    if (btcDistanceToSma20 <= -9 ||
        (breadth < 0.15 && medianSevenDayReturn < -10)) {
      return _MarketRegime(
        status: 'stand_aside',
        reason: 'BTC 明显弱于 20 日均线，市场广度不足，先暂停明日 Top1 推送。',
        marketBreadth: breadth,
        medianSevenDayReturn: medianSevenDayReturn,
        btcDistanceToSma20: btcDistanceToSma20,
      );
    }
    if (!rotationSummary.confirmed) {
      return _MarketRegime(
        status: 'watch_only',
        reason: '最近样本还不够稳定，轮动特征暂未完全确认，先观察不强推。',
        marketBreadth: breadth,
        medianSevenDayReturn: medianSevenDayReturn,
        btcDistanceToSma20: btcDistanceToSma20,
      );
    }
    if (breadth >= 0.52 && medianSevenDayReturn >= -1 && btcDistanceToSma20 >= -1.2) {
      return _MarketRegime(
        status: 'recommend',
        reason: '市场广度尚可，BTC 没有明显走弱，可执行轮动 Top1 预测。',
        marketBreadth: breadth,
        medianSevenDayReturn: medianSevenDayReturn,
        btcDistanceToSma20: btcDistanceToSma20,
      );
    }
    return _MarketRegime(
      status: 'watch_only',
      reason: '市场偏震荡，继续给出轮动排序，但只做观察不宜激进追单。',
      marketBreadth: breadth,
      medianSevenDayReturn: medianSevenDayReturn,
      btcDistanceToSma20: btcDistanceToSma20,
    );
  }

  double _marketScore(_MarketRegime regime, bool rotationConfirmed) {
    if (!rotationConfirmed) return 0.36;
    if (regime.status == 'recommend') return 0.92;
    if (regime.status == 'watch_only') return 0.58;
    return 0.18;
  }

  _MarketRegime _finalizeRegime({
    required _MarketRegime baseRegime,
    required List<_LeaderProfile> topProfiles,
    required String confidence,
    required LeaderPredictionExperimentConfig config,
    required bool rotationConfirmed,
  }) {
    if (baseRegime.status == 'stand_aside' || topProfiles.isEmpty) {
      return baseRegime;
    }

    final top1 = topProfiles.first;
    if (confidence == 'high' &&
        top1.totalScore >= config.recommendThreshold &&
        rotationConfirmed) {
      return baseRegime.copyWith(
        status: 'recommend',
        reason: '${baseRegime.reason} 当前第一候选优势清晰，可发送 Top1 轮动预测。',
      );
    }
    if (confidence == 'medium' &&
        top1.totalScore >= config.watchThreshold &&
        rotationConfirmed) {
      return baseRegime.copyWith(
        status: 'recommend',
        reason: '${baseRegime.reason} 当前第一候选具备中等把握，允许轻量推送。',
      );
    }
    return baseRegime.copyWith(
      status: 'watch_only',
      reason: '${baseRegime.reason} 当前第一候选仍有不确定性，先记录预测不强推。',
    );
  }

  String _confidenceFor(List<_LeaderProfile> topProfiles) {
    if (topProfiles.isEmpty) return 'low';
    final top1 = topProfiles.first;
    final top2 = topProfiles.length > 1 ? topProfiles[1].totalScore : 0.0;
    final gap = top1.totalScore - top2;
    if (top1.totalScore >= 0.72 && gap >= 0.08) return 'high';
    if (top1.totalScore >= 0.60 && gap >= 0.04) return 'medium';
    return 'low';
  }

  CoinData _decorateCoin(
    _LeaderProfile profile,
    _MarketRegime regime,
    LeaderPredictionExperimentConfig config,
  ) {
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
      'recommend' => '可出手',
      'watch_only' => '仅观察',
      _ => '只记录',
    };
    final poolText = profile.inCorePool ? '核心池内' : '池外降权';
    coin
      ..score = profile.totalScore
      ..historicalScore = profile.rotationScore
      ..entryScore = profile.trendScore
      ..expectedEdge = profile.totalScore - 0.5
      ..recommendation = regimeLabel
      ..reason =
          '轮动冷却 ${profile.daysSinceLeader} 天 | 5日 ${profile.ret5 >= 0 ? '+' : ''}${profile.ret5.toStringAsFixed(1)}% | 压缩 ${profile.compressionRatio.toStringAsFixed(2)} | $poolText'
      ..timingLabel = '明日轮动预测'
      ..timingReason =
          '模型 ${config.round} · ${config.label} · 核心池 ${profile.inCorePool ? '是' : '否'} · 上次领涨距今 ${profile.daysSinceLeader} 天 · 量比 ${profile.volumeRatio.toStringAsFixed(2)}x · ${regime.reason}';
    return coin;
  }

  CoinData _decorateSkipped(_LeaderProfile profile) {
    return _decorateCoin(
      profile,
      const _MarketRegime(
        status: 'stand_aside',
        reason: '当前币种不满足轮动预测参与条件。',
        marketBreadth: 0,
        medianSevenDayReturn: 0,
        btcDistanceToSma20: 0,
      ),
      defaultExperimentConfig,
    );
  }

  String _skipReason({
    required double medianQuote20,
    required double ret1,
    required double ret3,
    required int consecutiveLargeBodies,
  }) {
    if (medianQuote20 < minMedianQuoteVolume) {
      return '近 20 天成交额中位数偏低，流动性不足。';
    }
    if (ret1 > 9.5) {
      return '单日涨幅过热，不纳入明日轮动 Top1 候选。';
    }
    if (ret3 > 16) {
      return '近 3 日累计涨幅过大，避免末端追高。';
    }
    if (consecutiveLargeBodies >= 2) {
      return '已连续大阳线拉升，先等待轮动冷却。';
    }
    return '当前不满足轮动预测过滤条件。';
  }

  _LeaderHistoryState _buildLeaderStats({
    required Map<String, List<dynamic>> dailyHistory,
    required Set<String> tradableSymbols,
  }) {
    final returnByDate = <int, Map<String, double>>{};
    for (final entry in dailyHistory.entries) {
      final symbol = BinanceService.toSymbol(entry.key);
      if (!tradableSymbols.contains(symbol)) continue;
      final bars = entry.value;
      for (var i = 1; i < bars.length; i += 1) {
        final previousClose = _closeOf(bars[i - 1]);
        final close = _closeOf(bars[i]);
        if (previousClose <= 0) continue;
        returnByDate.putIfAbsent(_openTimeOf(bars[i]), () => <String, double>{})[symbol] =
            ((close - previousClose) / previousClose) * 100;
      }
    }

    final timeline = <_LeaderTimelineEntry>[];
    final orderedDates = returnByDate.keys.toList()..sort();
    for (final date in orderedDates) {
      final values = returnByDate[date]!;
      if (values.length < 2) continue;
      final ordered = values.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      timeline.add(
        _LeaderTimelineEntry(
          openTime: date,
          leaderSymbol: ordered.first.key,
          leaderReturn: ordered.first.value,
        ),
      );
    }

    final bySymbol = <String, _LeaderHistorySnapshot>{};
    final total = timeline.length;
    final last20 = timeline.length <= 20 ? timeline : timeline.sublist(total - 20);
    final last10 = timeline.length <= 10 ? timeline : timeline.sublist(total - 10);
    for (final symbol in tradableSymbols) {
      final indices = <int>[];
      for (var i = 0; i < timeline.length; i += 1) {
        if (timeline[i].leaderSymbol == symbol) {
          indices.add(i);
        }
      }
      final daysSinceLeader =
          indices.isEmpty ? 999 : max(0, timeline.length - 1 - indices.last);
      bySymbol[symbol] = _LeaderHistorySnapshot(
        daysSinceLeader: daysSinceLeader,
        leaderCount60: indices.length,
        leaderCount20: last20.where((item) => item.leaderSymbol == symbol).length,
        leaderCount10: last10.where((item) => item.leaderSymbol == symbol).length,
      );
    }
    return _LeaderHistoryState(
      timeline: timeline,
      bySymbol: bySymbol,
    );
  }

  _RotationSummary _buildRotationSummary(List<_LeaderTimelineEntry> timeline) {
    if (timeline.isEmpty) {
      return const _RotationSummary.empty();
    }

    final leaders = timeline.map((item) => item.leaderSymbol).toList();
    final counts = <String, int>{};
    for (final leader in leaders) {
      counts[leader] = (counts[leader] ?? 0) + 1;
    }
    var continuation = 0;
    for (var i = 1; i < leaders.length; i += 1) {
      if (leaders[i] == leaders[i - 1]) continuation += 1;
    }
    final continuationRate =
        leaders.length <= 1 ? 0.0 : continuation / (leaders.length - 1);
    final rollingUnique = <int>[];
    if (leaders.length < 10) {
      rollingUnique.add(leaders.toSet().length);
    } else {
      for (var i = 9; i < leaders.length; i += 1) {
        rollingUnique.add(leaders.sublist(i - 9, i + 1).toSet().length);
      }
    }
    final rollingAverage = rollingUnique.isEmpty
        ? 0.0
        : rollingUnique.reduce((a, b) => a + b) / rollingUnique.length;
    final maxShare = counts.values.isEmpty
        ? 0.0
        : counts.values.reduce(max) / max(1, leaders.length);
    final confirmed = leaders.length >= 20 &&
        counts.length >= min(6, max(4, leaders.length ~/ 8)) &&
        continuationRate <= 0.45 &&
        rollingAverage >= 4.0 &&
        maxShare <= 0.28;

    return _RotationSummary(
      confirmed: confirmed,
      totalDays: leaders.length,
      uniqueLeaders: counts.length,
      continuationRate: continuationRate,
      rolling10UniqueAverage: rollingAverage,
      maxLeaderShare: maxShare,
      latestLeader: leaders.last.replaceAll('USDT', ''),
    );
  }

  double _newsBiasForSymbol({
    required String symbol,
    required List<NewsItem> news,
  }) {
    if (news.isEmpty) return 0.0;
    final shortSymbol = symbol.replaceAll('USDT', '').toUpperCase();
    final now = DateTime.now();
    var total = 0.0;
    for (final item in news) {
      final related = item.relatedSymbols
          .map((entry) => entry.trim().toUpperCase())
          .toSet();
      if (!related.contains(shortSymbol)) continue;
      final ageHours = now.difference(item.publishedAt).inMinutes / 60;
      final recencyFactor = ageHours <= 6
          ? 1.0
          : ageHours <= 12
              ? 0.78
              : ageHours <= 24
                  ? 0.55
                  : 0.28;
      final signed = switch (item.impactDirection) {
        'bullish' => item.impactScore,
        'bearish' => -item.impactScore,
        _ => 0.0,
      };
      total += signed * recencyFactor;
    }
    return total.clamp(-1.0, 1.0);
  }

  static List<dynamic> _completeDailyBars(List<dynamic> bars) {
    if (bars.isEmpty) return const <dynamic>[];
    final ordered = [...bars]..sort((a, b) => _openTimeOf(a).compareTo(_openTimeOf(b)));
    final last = ordered.last;
    if (_isCurrentUtcDailyBar(_openTimeOf(last))) {
      return ordered.sublist(0, max(0, ordered.length - 1));
    }
    return ordered;
  }

  static bool _isCurrentUtcDailyBar(int openTime) {
    final nowUtc = DateTime.now().toUtc();
    final todayUtcStart = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    return openTime >= todayUtcStart.millisecondsSinceEpoch;
  }

  static int _openTimeOf(dynamic item) {
    if (item is Kline) return item.openTime;
    if (item is List && item.isNotEmpty) return _asInt(item[0]);
    if (item is Map) return _asInt(item['openTime']);
    return 0;
  }

  static double _periodReturn(List<double> closes, int period) {
    if (closes.length <= period) return 0;
    final start = closes[closes.length - period - 1];
    if (start <= 0) return 0;
    final end = closes.last;
    return ((end - start) / start) * 100;
  }

  static List<double> _closeToCloseReturns(List<double> closes) {
    if (closes.length <= 1) return const <double>[];
    final returns = <double>[];
    for (var i = 1; i < closes.length; i += 1) {
      final previous = closes[i - 1];
      if (previous <= 0) {
        returns.add(0);
        continue;
      }
      returns.add(((closes[i] - previous) / previous) * 100);
    }
    return returns;
  }

  static double _trendAlignmentScore({
    required double close,
    required double sma5,
    required double sma10,
    required double sma20,
  }) {
    if (close > sma5 && sma5 > sma10 && sma10 > sma20) return 1.0;
    if (close > sma5 && sma5 > sma10) return 0.74;
    if (close > sma10) return 0.48;
    if (close > sma20) return 0.32;
    return 0.12;
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
    if (item is Kline) return item.open;
    if (item is List && item.length > 1) return _asDouble(item[1]);
    if (item is Map) return _asDouble(item['open']);
    return 0;
  }

  static double _closeOf(dynamic item) {
    if (item is Kline) return item.close;
    if (item is List && item.length > 4) return _asDouble(item[4]);
    if (item is Map) return _asDouble(item['close']);
    return 0;
  }

  static double _highOf(dynamic item) {
    if (item is Kline) return item.high;
    if (item is List && item.length > 2) return _asDouble(item[2]);
    if (item is Map) return _asDouble(item['high']);
    return 0;
  }

  static double _lowOf(dynamic item) {
    if (item is Kline) return item.low;
    if (item is List && item.length > 3) return _asDouble(item[3]);
    if (item is Map) return _asDouble(item['low']);
    return 0;
  }

  static double _quoteVolumeOf(dynamic item) {
    if (item is Kline) return item.quoteVolume;
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

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value == null) return 0;
    return int.tryParse(value.toString()) ?? 0;
  }

  static double _normalize(double value, double minValue, double maxValue) {
    if (maxValue <= minValue) return 0;
    return ((value - minValue) / (maxValue - minValue)).clamp(0.0, 1.0);
  }
}

class _LeaderProfile {
  final CoinData coin;
  final double close;
  final double ret1;
  final double body1;
  final double ret3;
  final double ret5;
  final double ret7;
  final double ret14;
  final double ret21;
  final double sma5;
  final double sma10;
  final double sma20;
  final double sma30;
  final double trendAlignment;
  final double volatility5;
  final double volatility10;
  final double volatility20;
  final double compressionRatio;
  final double volumeRatio;
  final double medianQuote20;
  final double distanceToHigh10;
  final double distanceToLow10;
  final double newsBias;
  final bool skipped;
  final String skipReason;
  int daysSinceLeader = 999;
  int leaderCount60 = 0;
  int leaderCount20 = 0;
  int leaderCount10 = 0;
  bool inCorePool = false;
  double corePoolScore = 0;
  double rotationScore = 0;
  double trendScore = 0;
  double compressionScore = 0;
  double volumeHealthScore = 0;
  double lowVolScore = 0;
  double marketScore = 0;
  double newsScore = 0;
  double overheatPenaltyScore = 0;
  double rawSignalScore = 0;
  double totalScore = 0;

  _LeaderProfile({
    required this.coin,
    required this.close,
    required this.ret1,
    required this.body1,
    required this.ret3,
    required this.ret5,
    required this.ret7,
    required this.ret14,
    required this.ret21,
    required this.sma5,
    required this.sma10,
    required this.sma20,
    required this.sma30,
    required this.trendAlignment,
    required this.volatility5,
    required this.volatility10,
    required this.volatility20,
    required this.compressionRatio,
    required this.volumeRatio,
    required this.medianQuote20,
    required this.distanceToHigh10,
    required this.distanceToLow10,
    required this.newsBias,
    required this.skipped,
    required this.skipReason,
  });

  factory _LeaderProfile.skipped({
    required CoinData coin,
    required String reason,
  }) {
    return _LeaderProfile(
      coin: coin,
      close: 0,
      ret1: 0,
      body1: 0,
      ret3: 0,
      ret5: 0,
      ret7: 0,
      ret14: 0,
      ret21: 0,
      sma5: 0,
      sma10: 0,
      sma20: 0,
      sma30: 0,
      trendAlignment: 0,
      volatility5: 0,
      volatility10: 0,
      volatility20: 0,
      compressionRatio: 0,
      volumeRatio: 0,
      medianQuote20: 0,
      distanceToHigh10: 0,
      distanceToLow10: 0,
      newsBias: 0,
      skipped: true,
      skipReason: reason,
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

  _MarketRegime copyWith({
    String? status,
    String? reason,
  }) {
    return _MarketRegime(
      status: status ?? this.status,
      reason: reason ?? this.reason,
      marketBreadth: marketBreadth,
      medianSevenDayReturn: medianSevenDayReturn,
      btcDistanceToSma20: btcDistanceToSma20,
    );
  }
}

class _LeaderHistorySnapshot {
  final int daysSinceLeader;
  final int leaderCount60;
  final int leaderCount20;
  final int leaderCount10;

  const _LeaderHistorySnapshot({
    required this.daysSinceLeader,
    required this.leaderCount60,
    required this.leaderCount20,
    required this.leaderCount10,
  });

  const _LeaderHistorySnapshot.empty()
      : daysSinceLeader = 999,
        leaderCount60 = 0,
        leaderCount20 = 0,
        leaderCount10 = 0;
}

class _LeaderTimelineEntry {
  final int openTime;
  final String leaderSymbol;
  final double leaderReturn;

  const _LeaderTimelineEntry({
    required this.openTime,
    required this.leaderSymbol,
    required this.leaderReturn,
  });
}

class _LeaderHistoryState {
  final List<_LeaderTimelineEntry> timeline;
  final Map<String, _LeaderHistorySnapshot> bySymbol;

  const _LeaderHistoryState({
    required this.timeline,
    required this.bySymbol,
  });
}

class _RotationSummary {
  final bool confirmed;
  final int totalDays;
  final int uniqueLeaders;
  final double continuationRate;
  final double rolling10UniqueAverage;
  final double maxLeaderShare;
  final String latestLeader;

  const _RotationSummary({
    required this.confirmed,
    required this.totalDays,
    required this.uniqueLeaders,
    required this.continuationRate,
    required this.rolling10UniqueAverage,
    required this.maxLeaderShare,
    required this.latestLeader,
  });

  const _RotationSummary.empty()
      : confirmed = false,
        totalDays = 0,
        uniqueLeaders = 0,
        continuationRate = 0,
        rolling10UniqueAverage = 0,
        maxLeaderShare = 0,
        latestLeader = '';

  Map<String, dynamic> toJson() => {
        'confirmed': confirmed,
        'totalDays': totalDays,
        'uniqueLeaders': uniqueLeaders,
        'continuationRate': continuationRate,
        'rolling10UniqueAverage': rolling10UniqueAverage,
        'maxLeaderShare': maxLeaderShare,
        'latestLeader': latestLeader,
      };
}
