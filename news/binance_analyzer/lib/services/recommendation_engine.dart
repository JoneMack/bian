import 'dart:math';

import '../models/coin_data.dart';
import '../models/strategy_snapshot.dart';
import '../utils/technical_indicators.dart';
import 'binance_service.dart';

class RecommendationEngineResult {
  final List<CoinData> rankedCoins;
  final List<CoinData> top3;
  final StrategyBacktestReport report;
  final List<EntryAlertSignal> entryAlerts;
  final List<EntryAlertSignal> exitAlerts;

  const RecommendationEngineResult({
    required this.rankedCoins,
    required this.top3,
    required this.report,
    required this.entryAlerts,
    required this.exitAlerts,
  });
}

class RecommendationEngine {
  static const int historicalLookbackDays = 45;
  static const int minimumDailyBars = historicalLookbackDays + 7;

  static const List<_StrategyPreset> _presets = [
    _StrategyPreset(
      id: 'balanced',
      label: '平衡轮动',
      rotationWeight: 0.26,
      trendWeight: 0.22,
      compressionWeight: 0.16,
      triggerWeight: 0.22,
      liquidityWeight: 0.14,
    ),
    _StrategyPreset(
      id: 'rotation',
      label: '轮动优先',
      rotationWeight: 0.34,
      trendWeight: 0.18,
      compressionWeight: 0.16,
      triggerWeight: 0.18,
      liquidityWeight: 0.14,
    ),
    _StrategyPreset(
      id: 'trend',
      label: '趋势延续',
      rotationWeight: 0.18,
      trendWeight: 0.32,
      compressionWeight: 0.14,
      triggerWeight: 0.22,
      liquidityWeight: 0.14,
    ),
    _StrategyPreset(
      id: 'squeeze',
      label: '蓄势突破',
      rotationWeight: 0.22,
      trendWeight: 0.16,
      compressionWeight: 0.28,
      triggerWeight: 0.20,
      liquidityWeight: 0.14,
    ),
    _StrategyPreset(
      id: 'liquidity',
      label: '流动性优先',
      rotationWeight: 0.18,
      trendWeight: 0.18,
      compressionWeight: 0.14,
      triggerWeight: 0.18,
      liquidityWeight: 0.32,
    ),
  ];

  static RecommendationEngineResult analyze({
    required List<CoinData> currentCoins,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    EntrySignalPolicy policy = EntrySignalPolicy.defaultPolicy,
  }) {
    if (currentCoins.isEmpty) {
      return RecommendationEngineResult(
        rankedCoins: const [],
        top3: const [],
        report: StrategyBacktestReport(
          presetId: 'empty',
          presetLabel: '暂无数据',
          testDays: 0,
          avgTop3Return: 0,
          benchmarkReturn: 0,
          winRate: 0,
          positiveDaysRate: 0,
          generatedAt: DateTime.now(),
        ),
        entryAlerts: const [],
        exitAlerts: const [],
      );
    }

    final dailyClosed = <String, List<Kline>>{};
    for (final coin in currentCoins) {
      final bars = _closedBars(dailyHistory[coin.symbol] ?? const []);
      if (bars.length >= minimumDailyBars) {
        dailyClosed[coin.symbol] = bars;
      }
    }

    final preset = _pickBestPreset(dailyClosed);
    final profiles = _buildCurrentProfiles(currentCoins, dailyClosed);
    final scored = _scoreCoins(currentCoins, profiles, preset.preset);
    final alerts = _buildEntrySignals(
      scored,
      hourlyHistory,
      policy: policy,
    );
    final exits = _buildExitSignals(scored, hourlyHistory);

    scored.sort((a, b) {
      final primary = b.score.compareTo(a.score);
      if (primary != 0) return primary;
      return b.entryScore.compareTo(a.entryScore);
    });

    final top3 = scored.take(3).toList();
    return RecommendationEngineResult(
      rankedCoins: scored,
      top3: top3,
      report: preset.report,
      entryAlerts: alerts,
      exitAlerts: exits,
    );
  }

  static _BacktestSelection _pickBestPreset(Map<String, List<Kline>> history) {
    if (history.length < 5) {
      final preset = _presets.first;
      return _BacktestSelection(
        preset: preset,
        report: StrategyBacktestReport(
          presetId: preset.id,
          presetLabel: preset.label,
          testDays: 0,
          avgTop3Return: 0,
          benchmarkReturn: 0,
          winRate: 0,
          positiveDaysRate: 0,
          generatedAt: DateTime.now(),
        ),
      );
    }

    _BacktestSelection? best;
    for (final preset in _presets) {
      final metrics = _simulatePreset(history, preset);
      final report = StrategyBacktestReport(
        presetId: preset.id,
        presetLabel: preset.label,
        testDays: metrics.testDays,
        avgTop3Return: metrics.avgTop3Return,
        benchmarkReturn: metrics.benchmarkReturn,
        winRate: metrics.winRate,
        positiveDaysRate: metrics.positiveDaysRate,
        generatedAt: DateTime.now(),
      );
      final candidate = _BacktestSelection(
        preset: preset,
        report: report,
        objective: metrics.objective,
      );
      if (best == null || candidate.objective > best.objective) {
        best = candidate;
      }
    }

    return best!;
  }

  static _BacktestMetrics _simulatePreset(
    Map<String, List<Kline>> history,
    _StrategyPreset preset,
  ) {
    final symbols = history.entries
        .where((entry) => entry.value.length >= minimumDailyBars)
        .map((entry) => entry.key)
        .toList();

    if (symbols.length < 5) {
      return const _BacktestMetrics();
    }

    final minLength =
        symbols.map((symbol) => history[symbol]!.length).reduce(min);
    const startIndex = historicalLookbackDays;
    final endIndex = minLength - 2;

    if (endIndex <= startIndex) {
      return const _BacktestMetrics();
    }

    var testDays = 0;
    var wins = 0;
    var totalPicks = 0;
    var totalReturn = 0.0;
    var totalBenchmark = 0.0;
    var positiveDays = 0;

    for (var dayIndex = startIndex; dayIndex <= endIndex; dayIndex++) {
      final profiles = <String, _HistoricalProfile>{};

      for (final symbol in symbols) {
        final profile = _buildHistoricalProfile(
          symbol,
          history[symbol]!,
          dayIndex,
        );
        if (profile != null) {
          profiles[symbol] = profile;
        }
      }

      if (profiles.length < 5) continue;

      final coinScores = _scoreProfiles(profiles, preset);
      final ranked = coinScores.entries.toList()
        ..sort((a, b) => b.value.total.compareTo(a.value.total));
      final selected = ranked.take(3).toList();

      if (selected.isEmpty) continue;

      var dayReturn = 0.0;
      var benchmark = 0.0;
      for (final symbol in profiles.keys) {
        final bars = history[symbol]!;
        benchmark += _nextDayReturnPercent(bars, dayIndex);
      }
      benchmark /= profiles.length;

      for (final item in selected) {
        final nextReturn = _nextDayReturnPercent(history[item.key]!, dayIndex);
        dayReturn += nextReturn;
        totalPicks += 1;
        totalReturn += nextReturn;
        if (nextReturn > 0) wins += 1;
      }

      dayReturn /= selected.length;
      if (dayReturn > 0) positiveDays += 1;
      totalBenchmark += benchmark;
      testDays += 1;
    }

    if (testDays == 0 || totalPicks == 0) {
      return const _BacktestMetrics();
    }

    final avgTop3Return = totalReturn / totalPicks;
    final benchmarkReturn = totalBenchmark / testDays;
    final winRate = wins / totalPicks;
    final positiveDaysRate = positiveDays / testDays;
    final objective = (avgTop3Return - benchmarkReturn) * 7 +
        winRate * 100 +
        positiveDaysRate * 45;

    return _BacktestMetrics(
      testDays: testDays,
      avgTop3Return: avgTop3Return,
      benchmarkReturn: benchmarkReturn,
      winRate: winRate,
      positiveDaysRate: positiveDaysRate,
      objective: objective,
    );
  }

  static Map<String, _HistoricalProfile> _buildCurrentProfiles(
    List<CoinData> currentCoins,
    Map<String, List<Kline>> dailyClosed,
  ) {
    final profiles = <String, _HistoricalProfile>{};
    for (final coin in currentCoins) {
      final bars = dailyClosed[coin.symbol];
      if (bars == null || bars.length < historicalLookbackDays + 1) continue;

      final profile = _buildHistoricalProfile(
        coin.symbol,
        bars,
        bars.length - 1,
        liveChangePercent: coin.priceChangePercent,
        liveRangePosition: coin.rangePosition,
        liveQuoteVolume: coin.quoteVolume,
        liveTradeCount: coin.count,
      );

      if (profile != null) {
        profiles[coin.symbol] = profile;
      }
    }
    return profiles;
  }

  static List<CoinData> _scoreCoins(
    List<CoinData> currentCoins,
    Map<String, _HistoricalProfile> profiles,
    _StrategyPreset preset,
  ) {
    final profileScores = _scoreProfiles(profiles, preset);
    final bySymbol = {for (final coin in currentCoins) coin.symbol: coin};

    for (final coin in currentCoins) {
      final profile = profiles[coin.symbol];
      final score = profileScores[coin.symbol];
      if (profile == null || score == null) {
        coin.historicalScore = 0;
        coin.entryScore = 0;
        coin.expectedEdge = 0;
        coin.thirtyDayChange = 0;
        coin.sevenDayChange = 0;
        coin.daysSinceSurge = 0;
        coin.score = 0.28;
        coin.level = RecommendationLevel.avoid;
        coin.recommendation = '观察数据';
        coin.reason = '45天历史数据不足，暂时只保留观察状态';
        continue;
      }

      final total = score.total.clamp(0.0, 1.0);
      coin.historicalScore = ((score.rotation +
                  score.trend +
                  score.compression +
                  score.liquidity) /
              4)
          .clamp(0.0, 1.0);
      coin.entryScore = 0;
      coin.expectedEdge = total - 0.5;
      coin.thirtyDayChange = profile.thirtyDayReturn * 100;
      coin.sevenDayChange = profile.sevenDayReturn * 100;
      coin.daysSinceSurge = profile.daysSinceSurge;
      coin.score = total;
      coin.level = _level(total);
      coin.recommendation = _label(coin.level);
      coin.reason = _buildReason(
        profile: profile,
        score: score,
        preset: preset,
      );

      bySymbol[coin.symbol] = coin;
    }

    return bySymbol.values.toList();
  }

  static Map<String, _ComponentScore> _scoreProfiles(
    Map<String, _HistoricalProfile> profiles,
    _StrategyPreset preset,
  ) {
    final ret30Rank = _percentileRank({
      for (final entry in profiles.entries)
        entry.key: entry.value.thirtyDayReturn,
    });
    final lag7Rank = _percentileRank({
      for (final entry in profiles.entries)
        entry.key: -entry.value.sevenDayReturn,
    });
    final volCompressionRank = _percentileRank({
      for (final entry in profiles.entries)
        entry.key:
            -(entry.value.volatility7 / max(entry.value.volatility30, 0.0001)),
    });
    final rangeCompressionRank = _percentileRank({
      for (final entry in profiles.entries)
        entry.key: -(entry.value.range7 / max(entry.value.range30, 0.0001)),
    });
    final quoteVolumeRank = _percentileRank({
      for (final entry in profiles.entries)
        entry.key: entry.value.liquidityVolume,
    });
    final tradeCountRank = _percentileRank({
      for (final entry in profiles.entries)
        entry.key: entry.value.tradeCount.toDouble(),
    });

    final result = <String, _ComponentScore>{};
    for (final entry in profiles.entries) {
      final key = entry.key;
      final profile = entry.value;

      final rotation = (lag7Rank[key]! * 0.45 +
              _sweetSpot(profile.daysSinceSurge.toDouble(), 7, 8) * 0.35 +
              _sweetSpot(profile.drawdownFrom30High, 0.12, 0.12) * 0.20)
          .clamp(0.0, 1.0);

      final trend = (ret30Rank[key]! * 0.60 +
              _clamp01((profile.upRatio30 - 0.35) / 0.35) * 0.25 +
              _clamp01((profile.threeDayReturn + 0.02) / 0.08) * 0.15)
          .clamp(0.0, 1.0);

      final compression =
          (volCompressionRank[key]! * 0.55 + rangeCompressionRank[key]! * 0.45)
              .clamp(0.0, 1.0);

      final trigger =
          (_sweetSpot(profile.triggerChangePercent, 2.2, 3.6) * 0.45 +
                  _sweetSpot(profile.triggerRangePosition, 0.35, 0.35) * 0.25 +
                  _clamp01((profile.turnStrength + 0.04) / 0.10) * 0.30)
              .clamp(0.0, 1.0);

      final liquidity =
          (quoteVolumeRank[key]! * 0.70 + tradeCountRank[key]! * 0.30)
              .clamp(0.0, 1.0);

      final trendGuard =
          (_clamp01((profile.thirtyDayReturn + 0.04) / 0.22) * 0.50 +
                  _clamp01((profile.upRatio30 - 0.38) / 0.26) * 0.25 +
                  _clamp01((0.26 - profile.drawdownFrom30High) / 0.26) * 0.25)
              .clamp(0.0, 1.0);

      // 原始五维度评分（保持100%权重，不稀释）
      var total = preset.rotationWeight * rotation +
          preset.trendWeight * trend +
          preset.compressionWeight * compression +
          preset.triggerWeight * trigger +
          preset.liquidityWeight * liquidity;

      total *= 0.78 + trendGuard * 0.22;

      // ─── 技术指标作为乘数调整（确认/惩罚机制）───

      // 1. MACD 金叉 → 加分 8%；MACD 死叉 + 空头趋势 → 惩罚 6%
      if (profile.macdCrossover) {
        total *= 1.08;
      } else if (profile.macdHistogram < 0 && profile.emaTrendScore < 0.4) {
        total *= 0.94;
      }

      // 2. EMA 多头排列 → 加分 6%；EMA 空头排列 → 惩罚 8%
      if (profile.emaTrendScore >= 0.75) {
        total *= 1.06;
      } else if (profile.emaTrendScore <= 0.25) {
        total *= 0.92;
      }

      // 3. RSI 超买(>78) → 惩罚 10%；RSI 极低(<25) → 惩罚（币种可能在死亡螺旋）
      if (profile.rsi14 > 78) {
        total *= 0.90;
      } else if (profile.rsi14 < 25 && profile.emaTrendScore < 0.4) {
        total *= 0.92;
      }

      // 4. 布林带收窄 + 价格在中轨附近 → 蓄势突破加分 5%
      if (profile.bollingerBandwidth < 0.04 &&
          profile.bollingerPercentB >= 0.3 &&
          profile.bollingerPercentB <= 0.7) {
        total *= 1.05;
      }

      // 5. OBV 量价背离（价格涨但OBV弱）→ 惩罚 4%
      if (profile.obvTrend < 0.3 && profile.sevenDayReturn > 0.03) {
        total *= 0.96;
      }
      // OBV 确认（量价齐升）→ 加分 4%
      if (profile.obvTrend > 0.7 && profile.emaTrendScore >= 0.55) {
        total *= 1.04;
      }

      // 6. RSI 看涨背离 → 加分 6%
      if (profile.bullishDivergence > 0.3) {
        total *= 1.06;
      }

      // 7. 强趋势(ADX>30) + 方向正确 → 加分 4%
      if (profile.adx14 > 30 && profile.emaTrendScore >= 0.55) {
        total *= 1.04;
      }

      if (profile.thirtyDayReturn < -0.12) {
        total *= 0.82;
      }
      if (profile.thirtyDayReturn < -0.05 && profile.sevenDayReturn < -0.10) {
        total *= 0.78;
      }
      if (profile.drawdownFrom30High > 0.24 &&
          profile.triggerChangePercent < 0) {
        total *= 0.84;
      }
      if (profile.triggerChangePercent < -6) {
        total *= 0.88;
      }

      result[key] = _ComponentScore(
        rotation: rotation,
        trend: trend,
        compression: compression,
        trigger: trigger,
        liquidity: liquidity,
        total: total,
      );
    }

    return result;
  }

  static List<EntryAlertSignal> _buildEntrySignals(
    List<CoinData> scoredCoins,
    Map<String, List<Kline>> hourlyHistory, {
    required EntrySignalPolicy policy,
  }) {
    final alerts = <EntryAlertSignal>[];

    for (final coin in scoredCoins) {
      final bars = _closedBars(hourlyHistory[coin.symbol] ?? const []);
      final timing = _buildTimingSignal(
        coin,
        bars,
        policy: policy,
      );
      coin.entryScore = timing.entryScore;
      coin.timingLabel = timing.timingLabel;
      coin.timingReason = timing.timingReason;

      alerts.add(timing);
    }

    alerts.sort((a, b) {
      if (a.shouldNotify != b.shouldNotify) {
        return b.shouldNotify ? 1 : -1;
      }
      final byTotal = b.totalScore.compareTo(a.totalScore);
      if (byTotal != 0) return byTotal;
      return b.entryScore.compareTo(a.entryScore);
    });

    return alerts;
  }

  static List<EntryAlertSignal> _buildExitSignals(
    List<CoinData> scoredCoins,
    Map<String, List<Kline>> hourlyHistory,
  ) {
    final alerts = <EntryAlertSignal>[];

    for (final coin in scoredCoins) {
      final bars = _closedBars(hourlyHistory[coin.symbol] ?? const []);
      alerts.add(_buildExitSignal(coin, bars));
    }

    alerts.sort((a, b) {
      if (a.shouldNotify != b.shouldNotify) {
        return b.shouldNotify ? 1 : -1;
      }
      final byExit = b.entryScore.compareTo(a.entryScore);
      if (byExit != 0) return byExit;
      return b.totalScore.compareTo(a.totalScore);
    });

    return alerts;
  }

  static EntryAlertSignal _buildTimingSignal(
    CoinData coin,
    List<Kline> bars, {
    required EntrySignalPolicy policy,
  }) {
    if (bars.length < 24) {
      return EntryAlertSignal(
        symbol: coin.displayName,
        timingLabel: '等待数据',
        timingReason: '小时级样本不足，先继续观察。',
        currentPrice: coin.lastPrice,
        dayChangePercent: coin.priceChangePercent,
        totalScore: coin.score,
        entryScore: 0,
        volumeRatio: 0,
        breakoutDistance: 0,
        pullbackPercent: 0,
        shouldNotify: false,
      );
    }

    final closes = bars.map((bar) => bar.close).toList();
    final ma8 = _average(closes.sublist(max(0, closes.length - 8)));
    final ma21 = _average(closes.sublist(max(0, closes.length - 21)));
    final recentHigh12 = bars
        .sublist(max(0, bars.length - 13), bars.length - 1)
        .map((bar) => bar.high)
        .reduce(max);
    final recentHigh8 = bars
        .sublist(max(0, bars.length - 8))
        .map((bar) => bar.high)
        .reduce(max);
    final lastClose = bars.last.close;
    final breakoutDistance = recentHigh12 > 0
        ? ((lastClose - recentHigh12) / recentHigh12) * 100
        : 0.0;
    final pullback =
        recentHigh8 > 0 ? ((recentHigh8 - lastClose) / recentHigh8) * 100 : 0.0;

    final recent6AvgVolume = _average(
      bars
          .sublist(max(0, bars.length - 6))
          .map((bar) => bar.quoteVolume)
          .toList(),
    );
    final previousWindowStart = max(0, bars.length - 30);
    final previousWindowEnd = max(previousWindowStart + 1, bars.length - 6);
    final previous24AvgVolume = _average(
      bars
          .sublist(previousWindowStart, previousWindowEnd)
          .map((bar) => bar.quoteVolume)
          .toList(),
    );
    final volumeRatio =
        previous24AvgVolume > 0 ? recent6AvgVolume / previous24AvgVolume : 1.0;

    final trendScore = lastClose > ma8 && ma8 > ma21
        ? 1.0
        : lastClose > ma21
            ? 0.55
            : 0.15;

    // 基础入场评分（保持原始权重结构）
    var entryScore = (trendScore * 0.35 +
            _clamp01((volumeRatio - 0.8) / 0.8) * 0.25 +
            _sweetSpot(breakoutDistance, 0.6, 1.4) * 0.20 +
            _clamp01((coin.priceChangePercent + 1.5) / 6.5) * 0.20)
        .clamp(0.0, 1.0);

    // 技术指标作为乘数微调
    final hourlyRsi = TechnicalIndicators.rsiLatest(closes);
    final hourlyMacd = TechnicalIndicators.macdLatest(closes);
    final hourlyBB = TechnicalIndicators.bollingerLatest(closes);

    // MACD 金叉 → 入场信心加成
    if (hourlyMacd.crossover) {
      entryScore = (entryScore * 1.12).clamp(0.0, 1.0);
    } else if (hourlyMacd.histogram > 0 && hourlyMacd.histogram > hourlyMacd.prevHistogram) {
      entryScore = (entryScore * 1.05).clamp(0.0, 1.0);
    }
    // RSI 超买 → 惩罚入场
    if (hourlyRsi > 75) {
      entryScore *= 0.85;
    }
    // 布林带上轨 → 追高风险
    if (hourlyBB.percentB > 0.9) {
      entryScore *= 0.90;
    }

    final label = entryScore >= 0.76 && volumeRatio >= 1.05
        ? '可入场'
        : entryScore >= 0.60
            ? '临近买点'
            : lastClose > ma21 && pullback <= 2
                ? '等回踩'
                : '继续等待';

    final reason =
        'RSI${hourlyRsi.toStringAsFixed(0)} ${hourlyMacd.crossover ? "MACD金叉 " : hourlyMacd.histogram > 0 ? "MACD+ " : ""}1h MA8${ma8 >= ma21 ? '↑' : '↓'}MA21 量比${volumeRatio.toStringAsFixed(2)}x 距突破${breakoutDistance >= 0 ? '+' : ''}${breakoutDistance.toStringAsFixed(1)}%';

    final signal = EntryAlertSignal(
      symbol: coin.displayName,
      timingLabel: label,
      timingReason: reason,
      currentPrice: coin.lastPrice,
      dayChangePercent: coin.priceChangePercent,
      totalScore: coin.score,
      entryScore: entryScore,
      volumeRatio: volumeRatio,
      breakoutDistance: breakoutDistance,
      pullbackPercent: pullback,
      shouldNotify: false,
    );

    return signal.copyWith(shouldNotify: policy.matches(signal));
  }

  static EntryAlertSignal _buildExitSignal(
    CoinData coin,
    List<Kline> bars,
  ) {
    if (bars.length < 24) {
      return EntryAlertSignal(
        symbol: coin.displayName,
        timingLabel: '继续持有',
        timingReason: '小时级样本不足，先继续观察。',
        currentPrice: coin.lastPrice,
        dayChangePercent: coin.priceChangePercent,
        totalScore: coin.score,
        entryScore: 0,
        volumeRatio: 0,
        breakoutDistance: 0,
        pullbackPercent: 0,
        shouldNotify: false,
      );
    }

    final closes = bars.map((bar) => bar.close).toList();
    final ma8 = _average(closes.sublist(max(0, closes.length - 8)));
    final ma21 = _average(closes.sublist(max(0, closes.length - 21)));
    final recentHigh18 = bars
        .sublist(max(0, bars.length - 19), bars.length - 1)
        .map((bar) => bar.high)
        .reduce(max);
    final lastClose = bars.last.close;
    final drawdown = recentHigh18 > 0
        ? ((recentHigh18 - lastClose) / recentHigh18) * 100
        : 0.0;
    final maGapPercent =
        ma21 > 0 ? ((lastClose - ma21) / ma21) * 100 : 0.0;
    final weaknessScore = (_clamp01((drawdown - 1.4) / 4.4) * 0.35 +
            _clamp01((-maGapPercent + 0.6) / 4.4) * 0.25 +
            _clamp01((-coin.priceChangePercent - 0.8) / 5.2) * 0.20 +
            _clamp01((coin.thirtyDayChange - 8) / 26) * 0.20)
        .clamp(0.0, 1.0);

    final trendBroken = lastClose < ma21 && ma8 < ma21;
    final label = trendBroken && drawdown >= 3.2
        ? coin.thirtyDayChange >= 12
            ? '止盈减仓'
            : '止损离场'
        : drawdown >= 6 || coin.priceChangePercent <= -6
            ? '止损离场'
            : weaknessScore >= 0.58 && coin.thirtyDayChange >= 10
                ? '观察止盈'
                : '继续持有';

    final reason =
        '1h MA8 ${ma8 < ma21 ? '跌破' : '仍高于'} MA21；距18h高点回撤 ${drawdown.toStringAsFixed(2)}%；相对MA21 ${maGapPercent >= 0 ? '+' : ''}${maGapPercent.toStringAsFixed(2)}%';

    return EntryAlertSignal(
      symbol: coin.displayName,
      timingLabel: label,
      timingReason: reason,
      currentPrice: coin.lastPrice,
      dayChangePercent: coin.priceChangePercent,
      totalScore: coin.score,
      entryScore: weaknessScore,
      volumeRatio: 0,
      breakoutDistance: maGapPercent,
      pullbackPercent: drawdown,
      shouldNotify:
          (label == '止盈减仓' || label == '止损离场') && weaknessScore >= 0.62,
    );
  }

  static _HistoricalProfile? _buildHistoricalProfile(
    String symbol,
    List<Kline> bars,
    int endIndex, {
    double? liveChangePercent,
    double? liveRangePosition,
    double? liveQuoteVolume,
    int? liveTradeCount,
  }) {
    if (endIndex < historicalLookbackDays || bars.length <= endIndex) {
      return null;
    }

    final window30 =
        bars.sublist(endIndex - historicalLookbackDays, endIndex + 1);
    final window7 = bars.sublist(endIndex - 7, endIndex + 1);
    final latest = bars[endIndex];
    final prev = bars[endIndex - 1];

    final returns30 = <double>[];
    for (var i = endIndex - (historicalLookbackDays - 1); i <= endIndex; i++) {
      final close = bars[i].close;
      final prevClose = bars[i - 1].close;
      if (prevClose <= 0) continue;
      returns30.add((close - prevClose) / prevClose);
    }
    final returns7 = returns30.sublist(max(0, returns30.length - 7));

    final thirtyDayReturn = (latest.close - window30.first.close) /
        max(window30.first.close, 0.000001);
    final sevenDayReturn = (latest.close - window7.first.close) /
        max(window7.first.close, 0.000001);
    final threeReference = bars[endIndex - 3].close;
    final threeDayReturn =
        (latest.close - threeReference) / max(threeReference, 0.000001);
    final triggerChangePercent = liveChangePercent ??
        ((latest.close - prev.close) / max(prev.close, 0.000001)) * 100;
    final triggerRangePosition = liveRangePosition ??
        _rangePosition(latest.close, latest.low, latest.high);

    final maxHigh30 = window30.map((bar) => bar.high).reduce(max);
    final minLow30 = window30.map((bar) => bar.low).reduce(min);
    final maxHigh7 = window7.map((bar) => bar.high).reduce(max);
    final minLow7 = window7.map((bar) => bar.low).reduce(min);

    // 计算技术指标（使用 endIndex 之前的数据）
    final indicatorBars = bars.sublist(0, endIndex + 1);
    final indicatorCloses = indicatorBars.map((b) => b.close).toList();
    final indicatorHighs = indicatorBars.map((b) => b.high).toList();
    final indicatorLows = indicatorBars.map((b) => b.low).toList();
    final indicatorVolumes = indicatorBars.map((b) => b.quoteVolume).toList();

    final rsi14 = TechnicalIndicators.rsiLatest(indicatorCloses);
    final macdSnap = TechnicalIndicators.macdLatest(indicatorCloses);
    final bb = TechnicalIndicators.bollingerLatest(indicatorCloses);
    final adx14 = indicatorHighs.length >= 30
        ? TechnicalIndicators.adxLatest(
            indicatorHighs, indicatorLows, indicatorCloses)
        : 25.0;
    final ema8 = TechnicalIndicators.emaLatest(indicatorCloses, 8);
    final ema21 = TechnicalIndicators.emaLatest(indicatorCloses, 21);
    final ema55 = indicatorCloses.length >= 55
        ? TechnicalIndicators.emaLatest(indicatorCloses, 55)
        : ema21;
    final price = indicatorCloses.last;
    double emaTrend;
    if (price > ema8 && ema8 > ema21 && ema21 > ema55) {
      emaTrend = 1.0;
    } else if (price > ema21 && ema8 > ema21) {
      emaTrend = 0.75;
    } else if (price > ema21) {
      emaTrend = 0.55;
    } else if (price > ema55) {
      emaTrend = 0.35;
    } else {
      emaTrend = 0.15;
    }
    final obvTrend =
        TechnicalIndicators.obvTrendScore(indicatorCloses, indicatorVolumes);
    final divScore =
        TechnicalIndicators.bullishDivergenceScore(indicatorCloses);

    return _HistoricalProfile(
      symbol: symbol,
      thirtyDayReturn: thirtyDayReturn,
      sevenDayReturn: sevenDayReturn,
      threeDayReturn: threeDayReturn,
      upRatio30:
          returns30.where((item) => item > 0).length / max(returns30.length, 1),
      volatility30: _stdDev(returns30),
      volatility7: _stdDev(returns7),
      range30: (maxHigh30 - minLow30) / max(latest.close, 0.000001),
      range7: (maxHigh7 - minLow7) / max(latest.close, 0.000001),
      drawdownFrom30High: (maxHigh30 - latest.close) / max(maxHigh30, 0.000001),
      daysSinceSurge: _daysSinceSurge(bars, endIndex),
      triggerChangePercent: triggerChangePercent,
      triggerRangePosition: triggerRangePosition,
      liquidityVolume: liveQuoteVolume ??
          _average(window30.map((bar) => bar.quoteVolume).toList()),
      tradeCount: liveTradeCount ?? latest.tradeCount,
      turnStrength: threeDayReturn - sevenDayReturn,
      rsi14: rsi14,
      macdHistogram: macdSnap.histogram,
      macdCrossover: macdSnap.crossover,
      bollingerPercentB: bb.percentB,
      bollingerBandwidth: bb.bandwidth,
      adx14: adx14,
      emaTrendScore: emaTrend,
      obvTrend: obvTrend,
      bullishDivergence: divScore,
    );
  }

  static List<Kline> _closedBars(List<Kline> bars) {
    if (bars.isEmpty) return const [];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final filtered =
        bars.where((bar) => bar.closeTime < nowMs - 60 * 1000).toList();
    return filtered.isNotEmpty ? filtered : bars;
  }

  static double _nextDayReturnPercent(List<Kline> bars, int index) {
    if (index + 1 >= bars.length) return 0;
    final current = bars[index].close;
    final next = bars[index + 1].close;
    if (current <= 0) return 0;
    return ((next - current) / current) * 100;
  }

  static RecommendationLevel _level(double score) {
    if (score >= 0.76) return RecommendationLevel.strongBuy;
    if (score >= 0.62) return RecommendationLevel.buy;
    if (score >= 0.46) return RecommendationLevel.hold;
    return RecommendationLevel.avoid;
  }

  static String _label(RecommendationLevel level) {
    switch (level) {
      case RecommendationLevel.strongBuy:
        return '轮动首选';
      case RecommendationLevel.buy:
        return '建议关注';
      case RecommendationLevel.hold:
        return '等待确认';
      case RecommendationLevel.avoid:
        return '暂缓出手';
    }
  }

  static String _buildReason({
    required _HistoricalProfile profile,
    required _ComponentScore score,
    required _StrategyPreset preset,
  }) {
    final parts = <String>[
      '45天${profile.thirtyDayReturn >= 0 ? '+' : ''}${(profile.thirtyDayReturn * 100).toStringAsFixed(1)}%',
      '近7天${profile.sevenDayReturn >= 0 ? '+' : ''}${(profile.sevenDayReturn * 100).toStringAsFixed(1)}%',
      'RSI ${profile.rsi14.toStringAsFixed(0)}',
    ];

    if (profile.macdCrossover) {
      parts.add('MACD金叉');
    } else if (profile.macdHistogram > 0) {
      parts.add('MACD柱正向');
    }

    if (profile.emaTrendScore >= 0.75) {
      parts.add('EMA多头排列');
    } else if (profile.emaTrendScore <= 0.35) {
      parts.add('EMA空头');
    }

    if (profile.bollingerBandwidth < 0.04) {
      parts.add('布林收窄蓄势');
    }

    if (profile.bullishDivergence > 0.3) {
      parts.add('RSI看涨背离');
    }

    if (profile.adx14 > 30) {
      parts.add('趋势强(ADX${profile.adx14.toStringAsFixed(0)})');
    }

    if (score.rotation >= 0.65) {
      parts.add('轮动补涨分高');
    }
    if (score.compression >= 0.65) {
      parts.add('波动压缩');
    }
    if (profile.thirtyDayReturn < 0 && profile.sevenDayReturn < 0) {
      parts.add('趋势仍弱');
    }

    parts.add(preset.label);
    return parts.join('；');
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

  static int _daysSinceSurge(List<Kline> bars, int endIndex) {
    for (var offset = 0; offset < min(15, endIndex); offset++) {
      final idx = endIndex - offset;
      final prev = bars[idx - 1].close;
      if (prev <= 0) continue;
      final change = ((bars[idx].close - prev) / prev) * 100;
      if (change >= 8) return offset;
    }
    return 15;
  }

  static double _stdDev(List<double> values) {
    if (values.length < 2) return 0;
    final avg = _average(values);
    final variance = values
            .map((value) => pow(value - avg, 2).toDouble())
            .reduce((a, b) => a + b) /
        values.length;
    return sqrt(variance);
  }

  static double _rangePosition(double close, double low, double high) {
    final range = high - low;
    if (range <= 0) return 0.5;
    return (close - low) / range;
  }

  static double _clamp01(double value) => value.clamp(0.0, 1.0);

  static double _sweetSpot(double value, double center, double width) {
    if (width <= 0) return 0;
    return (1 - ((value - center).abs() / width)).clamp(0.0, 1.0);
  }
}

class _StrategyPreset {
  final String id;
  final String label;
  final double rotationWeight;
  final double trendWeight;
  final double compressionWeight;
  final double triggerWeight;
  final double liquidityWeight;

  const _StrategyPreset({
    required this.id,
    required this.label,
    required this.rotationWeight,
    required this.trendWeight,
    required this.compressionWeight,
    required this.triggerWeight,
    required this.liquidityWeight,
  });
}

class _BacktestSelection {
  final _StrategyPreset preset;
  final StrategyBacktestReport report;
  final double objective;

  const _BacktestSelection({
    required this.preset,
    required this.report,
    this.objective = 0,
  });
}

class _BacktestMetrics {
  final int testDays;
  final double avgTop3Return;
  final double benchmarkReturn;
  final double winRate;
  final double positiveDaysRate;
  final double objective;

  const _BacktestMetrics({
    this.testDays = 0,
    this.avgTop3Return = 0,
    this.benchmarkReturn = 0,
    this.winRate = 0,
    this.positiveDaysRate = 0,
    this.objective = 0,
  });
}

class _HistoricalProfile {
  final String symbol;
  final double thirtyDayReturn;
  final double sevenDayReturn;
  final double threeDayReturn;
  final double upRatio30;
  final double volatility30;
  final double volatility7;
  final double range30;
  final double range7;
  final double drawdownFrom30High;
  final int daysSinceSurge;
  final double triggerChangePercent;
  final double triggerRangePosition;
  final double liquidityVolume;
  final int tradeCount;
  final double turnStrength;
  // 新增技术指标
  final double rsi14;
  final double macdHistogram;
  final bool macdCrossover;
  final double bollingerPercentB;
  final double bollingerBandwidth;
  final double adx14;
  final double emaTrendScore;
  final double obvTrend;
  final double bullishDivergence;

  const _HistoricalProfile({
    required this.symbol,
    required this.thirtyDayReturn,
    required this.sevenDayReturn,
    required this.threeDayReturn,
    required this.upRatio30,
    required this.volatility30,
    required this.volatility7,
    required this.range30,
    required this.range7,
    required this.drawdownFrom30High,
    required this.daysSinceSurge,
    required this.triggerChangePercent,
    required this.triggerRangePosition,
    required this.liquidityVolume,
    required this.tradeCount,
    required this.turnStrength,
    this.rsi14 = 50,
    this.macdHistogram = 0,
    this.macdCrossover = false,
    this.bollingerPercentB = 0.5,
    this.bollingerBandwidth = 0.05,
    this.adx14 = 25,
    this.emaTrendScore = 0.5,
    this.obvTrend = 0.5,
    this.bullishDivergence = 0,
  });
}

class _ComponentScore {
  final double rotation;
  final double trend;
  final double compression;
  final double trigger;
  final double liquidity;
  final double total;

  const _ComponentScore({
    required this.rotation,
    required this.trend,
    required this.compression,
    required this.trigger,
    required this.liquidity,
    required this.total,
  });
}
