import 'dart:math';

import '../models/coin_data.dart';
import 'binance_service.dart';
import 'startup_scanner_service.dart';

class StartupStrategyBacktestService {
  static const int replayLookbackHours = 96;
  static const int evaluationHours = 24;

  final StartupScannerService _scanner;

  StartupStrategyBacktestService({
    StartupScannerService? scanner,
  }) : _scanner = scanner ?? StartupScannerService();

  List<StartupPolicyRound> buildDefaultPolicyRounds() {
    const base = StartupScanPolicy.defaultPolicy;
    return [
      StartupPolicyRound(
        id: 'round_01_baseline',
        label: 'Baseline',
        policy: base.copyWith(label: 'Baseline'),
      ),
      StartupPolicyRound(
        id: 'round_02_quality',
        label: 'Quality',
        policy: base.copyWith(
          label: '质量收紧',
          minScore: 0.74,
          minCompressionScore: 0.24,
          minMomentumScore: 0.30,
          maxPushCandidates: 2,
        ),
      ),
      StartupPolicyRound(
        id: 'round_03_volume',
        label: 'Volume',
        policy: base.copyWith(
          label: '量能优先',
          minScore: 0.73,
          minMarketTrendBreadth: 0.50,
          minMarketMomentumBreadth: 0.44,
          minVolumeRatio: 1.48,
          minQuoteVolume: 5000000,
          minTradeCount: 8000,
        ),
      ),
      StartupPolicyRound(
        id: 'round_04_breakout',
        label: 'Breakout',
        policy: base.copyWith(
          label: '突破贴近',
          minScore: 0.73,
          minMarketTrendBreadth: 0.52,
          minMarketMomentumBreadth: 0.46,
          minBreakoutDistance: -0.8,
          maxBreakoutDistance: 1.6,
          minHourlyBreakoutDistance: -0.7,
          maxHourlyBreakoutDistance: 1.5,
          minNearTermPivotDistance: -0.5,
          maxNearTermPivotDistance: 1.2,
        ),
      ),
      StartupPolicyRound(
        id: 'round_05_compression',
        label: 'Compression',
        policy: base.copyWith(
          label: '压缩优先',
          minCompressionScore: 0.30,
          minScore: 0.73,
          minMomentumScore: 0.28,
          minMarketTrendBreadth: 0.50,
          minMarketMomentumBreadth: 0.44,
        ),
      ),
      StartupPolicyRound(
        id: 'round_06_liquidity',
        label: 'Liquidity',
        policy: base.copyWith(
          label: '流动性优先',
          minLiquidityScore: 0.22,
          minMarketTrendBreadth: 0.48,
          minMarketMomentumBreadth: 0.42,
          minQuoteVolume: 7000000,
          minTradeCount: 10000,
        ),
      ),
      StartupPolicyRound(
        id: 'round_07_conservative',
        label: 'Conservative',
        policy: base.copyWith(
          label: '保守信号',
          minScore: 0.76,
          minTrendScore: 0.68,
          minCompressionScore: 0.26,
          minVolumeRatio: 1.55,
          maxPushCandidates: 1,
          cooldownHours: 12,
        ),
      ),
      StartupPolicyRound(
        id: 'round_08_balanced_2',
        label: 'Balanced 2',
        policy: base.copyWith(
          label: '均衡二号',
          minScore: 0.74,
          minTrendScore: 0.66,
          minCompressionScore: 0.24,
          minLiquidityScore: 0.18,
          minVolumeRatio: 1.42,
          minDailyChangePercent: 1.8,
          minMarketTrendBreadth: 0.54,
          minMarketMomentumBreadth: 0.48,
          maxPushCandidates: 2,
          cooldownHours: 10,
        ),
      ),
      StartupPolicyRound(
        id: 'round_09_momentum_cap',
        label: 'Momentum Cap',
        policy: base.copyWith(
          label: '动量上限',
          minMomentumScore: 0.29,
          minMarketTrendBreadth: 0.50,
          minMarketMomentumBreadth: 0.44,
          maxThirtyDayMomentum: 28,
          maxDailyChangePercent: 7.2,
          minNearTermPivotDistance: -0.6,
          maxNearTermPivotDistance: 1.3,
        ),
      ),
      StartupPolicyRound(
        id: 'round_10_rotation',
        label: 'Rotation',
        policy: base.copyWith(
          label: '轮动启动',
          minCompressionScore: 0.28,
          minLiquidityScore: 0.16,
          minMomentumScore: 0.27,
          minDailyChangePercent: 0.8,
          minMarketTrendBreadth: 0.52,
          minMarketMomentumBreadth: 0.46,
          minBreakoutDistance: -0.9,
          maxBreakoutDistance: 1.7,
          maxPushCandidates: 2,
          cooldownHours: 8,
        ),
      ),
      StartupPolicyRound(
        id: 'round_11_tight_pivot',
        label: 'Tight Pivot',
        policy: base.copyWith(
          label: '贴轴启动',
          minCompressionScore: 0.22,
          minVolumeRatio: 1.45,
          minMarketTrendBreadth: 0.56,
          minMarketMomentumBreadth: 0.50,
          minNearTermPivotDistance: -0.25,
          maxNearTermPivotDistance: 0.85,
          maxBreakoutDistance: 1.35,
          maxHourlyBreakoutDistance: 1.2,
        ),
      ),
      StartupPolicyRound(
        id: 'round_12_high_conviction',
        label: 'High Conviction',
        policy: base.copyWith(
          label: '高确信度',
          minScore: 0.78,
          minTrendScore: 0.70,
          minCompressionScore: 0.32,
          minLiquidityScore: 0.24,
          minMomentumScore: 0.31,
          minMarketTrendBreadth: 0.58,
          minMarketMomentumBreadth: 0.52,
          minVolumeRatio: 1.60,
          minQuoteVolume: 8000000,
          minTradeCount: 12000,
          maxPushCandidates: 1,
          cooldownHours: 12,
        ),
      ),
      StartupPolicyRound(
        id: 'round_13_balanced_3',
        label: 'Balanced 3',
        policy: base.copyWith(
          label: '均衡三号',
          minScore: 0.73,
          minTrendScore: 0.64,
          minCompressionScore: 0.22,
          minLiquidityScore: 0.16,
          minMomentumScore: 0.28,
          minMarketTrendBreadth: 0.52,
          minMarketMomentumBreadth: 0.46,
          minVolumeRatio: 1.40,
          minDailyChangePercent: 1.5,
          maxPushCandidates: 2,
          cooldownHours: 8,
        ),
      ),
      StartupPolicyRound(
        id: 'round_14_rotation_2',
        label: 'Rotation 2',
        policy: base.copyWith(
          label: '轮动二号',
          minScore: 0.74,
          minTrendScore: 0.64,
          minCompressionScore: 0.26,
          minLiquidityScore: 0.15,
          minMomentumScore: 0.28,
          minMarketTrendBreadth: 0.50,
          minMarketMomentumBreadth: 0.44,
          minBreakoutDistance: -0.7,
          maxBreakoutDistance: 1.5,
          minHourlyBreakoutDistance: -0.5,
          maxHourlyBreakoutDistance: 1.4,
          maxPushCandidates: 2,
          cooldownHours: 10,
        ),
      ),
      StartupPolicyRound(
        id: 'round_15_selective',
        label: 'Selective',
        policy: base.copyWith(
          label: '精选单发',
          minScore: 0.75,
          minTrendScore: 0.66,
          minCompressionScore: 0.24,
          minLiquidityScore: 0.18,
          minMomentumScore: 0.30,
          minMarketTrendBreadth: 0.54,
          minMarketMomentumBreadth: 0.48,
          minVolumeRatio: 1.48,
          maxPushCandidates: 1,
          cooldownHours: 10,
        ),
      ),
      StartupPolicyRound(
        id: 'round_16_regime_guard',
        label: 'Regime Guard',
        policy: base.copyWith(
          label: '行情过滤',
          minScore: 0.72,
          minTrendScore: 0.62,
          minCompressionScore: 0.20,
          minLiquidityScore: 0.14,
          minMomentumScore: 0.27,
          minMarketTrendBreadth: 0.60,
          minMarketMomentumBreadth: 0.54,
          minVolumeRatio: 1.38,
          maxPushCandidates: 2,
          cooldownHours: 8,
        ),
      ),
    ];
  }

  StartupStrategyOptimizationResult optimize({
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    List<StartupPolicyRound>? rounds,
  }) {
    final candidates = rounds ?? buildDefaultPolicyRounds();
    final results = candidates
        .map(
          (round) => StartupPolicyRoundResult(
            id: round.id,
            label: round.label,
            policy: round.policy,
            report: analyze(
              dailyHistory: dailyHistory,
              hourlyHistory: hourlyHistory,
              policy: round.policy,
            ),
          ),
        )
        .map((item) => item.copyWith(score: _optimizationScore(item.report)))
        .toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byWin = b.report.winRate.compareTo(a.report.winRate);
        if (byWin != 0) return byWin;
        return b.report.sampleCount.compareTo(a.report.sampleCount);
      });

    final best = results.first;
    final baseline = results.firstWhere(
      (item) => item.id == 'round_01_baseline',
      orElse: () => best,
    );

    return StartupStrategyOptimizationResult(
      generatedAt: DateTime.now(),
      rounds: results,
      bestRound: best,
      baselineRound: baseline,
    );
  }

  StartupStrategyBacktestReport analyze({
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    required StartupScanPolicy policy,
  }) {
    final normalizedDaily = {
      for (final entry in dailyHistory.entries) entry.key: _sorted(entry.value),
    };
    final normalizedHourly = {
      for (final entry in hourlyHistory.entries)
        entry.key: _sorted(entry.value),
    };

    final eligibleSymbols = normalizedHourly.keys
        .where(
          (symbol) =>
              (normalizedDaily[symbol]?.length ?? 0) >=
                  StartupScannerService.minimumDailyBars &&
              (normalizedHourly[symbol]?.length ?? 0) >=
                  replayLookbackHours + evaluationHours,
        )
        .toList()
      ..sort();

    if (eligibleSymbols.length < 10) {
      return StartupStrategyBacktestReport.empty(
        generatedAt: DateTime.now(),
        policy: policy,
        eligibleSymbols: eligibleSymbols,
      );
    }

    final timelineBars = normalizedHourly[eligibleSymbols.first]!;
    final states = <_StartupReplayState>[];
    for (var index = replayLookbackHours - 1;
        index + evaluationHours < timelineBars.length;
        index++) {
      final state = _buildReplayState(
        replayIndex: index,
        symbols: eligibleSymbols,
        dailyHistory: normalizedDaily,
        hourlyHistory: normalizedHourly,
        policy: policy,
      );
      if (state != null) {
        states.add(state);
      }
    }

    return _evaluate(states, policy);
  }

  _StartupReplayState? _buildReplayState({
    required int replayIndex,
    required List<String> symbols,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    required StartupScanPolicy policy,
  }) {
    final currentCoins = <CoinData>[];
    final dailySlices = <String, List<Kline>>{};
    final hourlySlices = <String, List<Kline>>{};
    final nextCloseReturns = <String, double>{};
    final nextBestReturns = <String, double>{};

    DateTime? replayAt;

    for (final symbol in symbols) {
      final hourlyBars = hourlyHistory[symbol] ?? const [];
      if (replayIndex >= hourlyBars.length ||
          replayIndex < replayLookbackHours - 1 ||
          replayIndex + evaluationHours >= hourlyBars.length) {
        continue;
      }

      final at = DateTime.fromMillisecondsSinceEpoch(
          hourlyBars[replayIndex].closeTime);
      replayAt ??= at;

      final dailyBars =
          _dailyClosedBefore(dailyHistory[symbol] ?? const [], at);
      if (dailyBars.length < StartupScannerService.minimumDailyBars) {
        continue;
      }

      final recent24 = hourlyBars.sublist(replayIndex - 23, replayIndex + 1);
      final recent96 = hourlyBars.sublist(
        replayIndex - (replayLookbackHours - 1),
        replayIndex + 1,
      );
      final currentClose = hourlyBars[replayIndex].close;
      if (currentClose <= 0) continue;

      final next24 = hourlyBars.sublist(
          replayIndex + 1, replayIndex + evaluationHours + 1);
      final next24Close = hourlyBars[replayIndex + evaluationHours].close;
      final next24High = next24.map((bar) => bar.high).reduce(max);
      final displayName = _displayName(symbol);

      currentCoins.add(_snapshotCoin(symbol, recent24));
      dailySlices[symbol] = dailyBars;
      hourlySlices[symbol] = recent96;
      nextCloseReturns[displayName] =
          (next24Close - currentClose) / currentClose;
      nextBestReturns[displayName] = (next24High - currentClose) / currentClose;
    }

    final at = replayAt;
    if (currentCoins.length < 20 || at == null) return null;

    final report = _scanner.analyzeMarket(
      currentCoins: currentCoins,
      dailyHistory: dailySlices,
      hourlyHistory: hourlySlices,
      policy: policy,
    );

    return _StartupReplayState(
      at: at,
      actionableCandidates:
          report.actionableCandidates.take(policy.maxPushCandidates).toList(),
      nextCloseReturns: nextCloseReturns,
      nextBestReturns: nextBestReturns,
    );
  }

  StartupStrategyBacktestReport _evaluate(
    List<_StartupReplayState> states,
    StartupScanPolicy policy,
  ) {
    if (states.isEmpty) {
      return StartupStrategyBacktestReport.empty(
        generatedAt: DateTime.now(),
        policy: policy,
        eligibleSymbols: const [],
      );
    }

    var samples = 0;
    var wins = 0;
    var silentHours = 0;
    var totalSignalReturn = 0.0;
    var totalBestReturn = 0.0;
    final lastTriggeredAtBySymbol = <String, DateTime>{};
    final bySymbol = <String, _MutableSignalBucket>{};

    for (final state in states) {
      var triggeredThisHour = 0;

      for (final candidate in state.actionableCandidates) {
        final lastTriggeredAt = lastTriggeredAtBySymbol[candidate.symbol];
        if (lastTriggeredAt != null &&
            state.at.difference(lastTriggeredAt).inHours <
                policy.cooldownHours) {
          continue;
        }

        final nextReturn = state.nextCloseReturns[candidate.symbol];
        final bestReturn = state.nextBestReturns[candidate.symbol];
        if (nextReturn == null || bestReturn == null) {
          continue;
        }

        final isWin = nextReturn > 0;
        samples += 1;
        triggeredThisHour += 1;
        totalSignalReturn += nextReturn;
        totalBestReturn += bestReturn;
        if (isWin) {
          wins += 1;
        }
        lastTriggeredAtBySymbol[candidate.symbol] = state.at;
        bySymbol.putIfAbsent(candidate.symbol, _MutableSignalBucket.new).add(
              nextReturn,
              isWin,
            );
      }

      if (triggeredThisHour == 0) {
        silentHours += 1;
      }
    }

    final topSymbols = bySymbol.entries
        .map(
          (entry) => StartupBacktestBucket(
            name: entry.key,
            sampleCount: entry.value.sampleCount,
            wins: entry.value.wins,
            avgSignalReturn: entry.value.sampleCount == 0
                ? 0
                : entry.value.totalReturn / entry.value.sampleCount,
          ),
        )
        .toList()
      ..sort((a, b) {
        final byWin = b.winRate.compareTo(a.winRate);
        if (byWin != 0) return byWin;
        final byReturn = b.avgSignalReturn.compareTo(a.avgSignalReturn);
        if (byReturn != 0) return byReturn;
        return b.sampleCount.compareTo(a.sampleCount);
      });

    return StartupStrategyBacktestReport(
      generatedAt: DateTime.now(),
      policy: policy,
      eligibleSymbols: states.first.nextCloseReturns.keys.toList()..sort(),
      simulatedHours: states.length,
      sampleCount: samples,
      wins: wins,
      silentHours: silentHours,
      avgSignalReturn: samples == 0 ? 0 : totalSignalReturn / samples,
      avgBestReturn: samples == 0 ? 0 : totalBestReturn / samples,
      topSymbols: topSymbols,
    );
  }

  double _optimizationScore(StartupStrategyBacktestReport report) {
    final samples = report.sampleCount;
    final sampleConfidence = samples <= 0 ? 0.0 : min(1.0, samples / 12.0);
    final winComponent = report.winRate * 100;
    final returnComponent = report.avgSignalReturn * 100 * 7.5;
    final bestReturnComponent = report.avgBestReturn * 100 * 1.5;
    final sampleComponent = sampleConfidence * 14;
    final silencePenalty = report.silentRate * 6;
    final lowSamplePenalty = samples < 4
        ? (4 - samples) * 22.0
        : samples < 8
            ? (8 - samples) * 4.5
            : 0.0;

    return winComponent +
        returnComponent +
        bestReturnComponent +
        sampleComponent -
        silencePenalty -
        lowSamplePenalty;
  }

  List<Kline> _sorted(List<Kline> bars) {
    final copy = [...bars];
    copy.sort((a, b) => a.closeTime.compareTo(b.closeTime));
    return copy;
  }

  List<Kline> _dailyClosedBefore(List<Kline> bars, DateTime at) {
    return bars
        .where((bar) => bar.closeTime <= at.millisecondsSinceEpoch)
        .toList();
  }

  CoinData _snapshotCoin(String symbol, List<Kline> bars24h) {
    final last = bars24h.last;
    final open24h = bars24h.first.open;
    final high24h = bars24h.map((bar) => bar.high).reduce(max).toDouble();
    final low24h = bars24h.map((bar) => bar.low).reduce(min).toDouble();
    final quoteVolume =
        bars24h.fold<double>(0, (sum, bar) => sum + bar.quoteVolume);
    final volume = bars24h.fold<double>(0, (sum, bar) => sum + bar.volume);
    final tradeCount = bars24h.fold<int>(0, (sum, bar) => sum + bar.tradeCount);
    final priceChange = last.close - open24h;
    final changePercent =
        open24h <= 0 ? 0.0 : ((last.close - open24h) / open24h) * 100;

    return CoinData(
      symbol: symbol,
      lastPrice: last.close,
      priceChange: priceChange,
      priceChangePercent: changePercent,
      highPrice: high24h,
      lowPrice: low24h,
      openPrice: open24h,
      quoteVolume: quoteVolume,
      volume: volume,
      count: tradeCount,
    );
  }

  String _displayName(String symbol) {
    final upper = symbol.toUpperCase();
    if (upper.endsWith('USDT')) {
      return upper.substring(0, upper.length - 4);
    }
    return upper;
  }
}

class StartupPolicyRound {
  final String id;
  final String label;
  final StartupScanPolicy policy;

  const StartupPolicyRound({
    required this.id,
    required this.label,
    required this.policy,
  });
}

class StartupPolicyRoundResult {
  final String id;
  final String label;
  final StartupScanPolicy policy;
  final StartupStrategyBacktestReport report;
  final double score;

  const StartupPolicyRoundResult({
    required this.id,
    required this.label,
    required this.policy,
    required this.report,
    this.score = 0.0,
  });

  StartupPolicyRoundResult copyWith({
    double? score,
  }) {
    return StartupPolicyRoundResult(
      id: id,
      label: label,
      policy: policy,
      report: report,
      score: score ?? this.score,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'score': score,
        'policy': policy.toJson(),
        'report': report.toJson(),
      };
}

class StartupStrategyOptimizationResult {
  final DateTime generatedAt;
  final List<StartupPolicyRoundResult> rounds;
  final StartupPolicyRoundResult baselineRound;
  final StartupPolicyRoundResult bestRound;

  const StartupStrategyOptimizationResult({
    required this.generatedAt,
    required this.rounds,
    required this.baselineRound,
    required this.bestRound,
  });

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'testedRounds': rounds.length,
        'baselineRound': baselineRound.toJson(),
        'bestRound': bestRound.toJson(),
        'rounds': rounds.map((item) => item.toJson()).toList(),
      };
}

class StartupStrategyBacktestReport {
  final DateTime generatedAt;
  final StartupScanPolicy policy;
  final List<String> eligibleSymbols;
  final int simulatedHours;
  final int sampleCount;
  final int wins;
  final int silentHours;
  final double avgSignalReturn;
  final double avgBestReturn;
  final List<StartupBacktestBucket> topSymbols;

  const StartupStrategyBacktestReport({
    required this.generatedAt,
    required this.policy,
    required this.eligibleSymbols,
    required this.simulatedHours,
    required this.sampleCount,
    required this.wins,
    required this.silentHours,
    required this.avgSignalReturn,
    required this.avgBestReturn,
    required this.topSymbols,
  });

  const StartupStrategyBacktestReport.empty({
    required this.generatedAt,
    required this.policy,
    required this.eligibleSymbols,
  })  : simulatedHours = 0,
        sampleCount = 0,
        wins = 0,
        silentHours = 0,
        avgSignalReturn = 0,
        avgBestReturn = 0,
        topSymbols = const [];

  double get winRate => sampleCount == 0 ? 0 : wins / sampleCount;

  double get silentRate =>
      simulatedHours == 0 ? 0 : silentHours / simulatedHours;

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'policy': policy.toJson(),
        'eligibleSymbols': eligibleSymbols,
        'simulatedHours': simulatedHours,
        'sampleCount': sampleCount,
        'wins': wins,
        'winRate': winRate,
        'silentHours': silentHours,
        'silentRate': silentRate,
        'avgSignalReturn': avgSignalReturn,
        'avgBestReturn': avgBestReturn,
        'topSymbols': topSymbols.map((item) => item.toJson()).toList(),
      };
}

class StartupBacktestBucket {
  final String name;
  final int sampleCount;
  final int wins;
  final double avgSignalReturn;

  const StartupBacktestBucket({
    required this.name,
    required this.sampleCount,
    required this.wins,
    required this.avgSignalReturn,
  });

  double get winRate => sampleCount == 0 ? 0 : wins / sampleCount;

  Map<String, dynamic> toJson() => {
        'name': name,
        'sampleCount': sampleCount,
        'wins': wins,
        'winRate': winRate,
        'avgSignalReturn': avgSignalReturn,
      };
}

class _StartupReplayState {
  final DateTime at;
  final List<StartupScanCandidate> actionableCandidates;
  final Map<String, double> nextCloseReturns;
  final Map<String, double> nextBestReturns;

  const _StartupReplayState({
    required this.at,
    required this.actionableCandidates,
    required this.nextCloseReturns,
    required this.nextBestReturns,
  });
}

class _MutableSignalBucket {
  int sampleCount = 0;
  int wins = 0;
  double totalReturn = 0.0;

  void add(double signalReturn, bool isWin) {
    sampleCount += 1;
    totalReturn += signalReturn;
    if (isWin) {
      wins += 1;
    }
  }
}
