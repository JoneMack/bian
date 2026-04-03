import 'dart:math';

import '../models/coin_data.dart';
import '../models/strategy_snapshot.dart';
import 'binance_service.dart';
import 'recommendation_engine.dart';

class HourlyReplayService {
  static const double targetWinRate = 0.80;
  static const Duration replayWindow = Duration(days: 30);
  static const Duration validationWindow = Duration(days: 14);

  Future<HourlyReplayReport> generateReport({
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
  }) async {
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
              (normalizedDaily[symbol]?.length ?? 0) >= 35 &&
              (normalizedHourly[symbol]?.length ?? 0) >= 120,
        )
        .toList()
      ..sort();

    if (eligibleSymbols.length < 5) {
      return HourlyReplayReport(
        generatedAt: DateTime.now(),
        windowStart: DateTime.now(),
        windowEnd: DateTime.now(),
        simulatedHours: 0,
        silentHours: 0,
        top3SampleCount: 0,
        top3WinRate: 0,
        top3AvgReturn: 0,
        alertSampleCount: 0,
        alertWinRate: 0,
        alertAvgReturn: 0,
        alertBestReturn: 0,
        validationHours: 0,
        validationSilentHours: 0,
        validationAlertSampleCount: 0,
        validationAlertWinRate: 0,
        validationAlertAvgReturn: 0,
        targetWinRate: targetWinRate,
        targetMet: false,
        optimizedPolicy: EntrySignalPolicy.defaultPolicy,
        notes:
            '可用于小时回放的币种不足，当前只有 ${eligibleSymbols.length} 个标的满足最近 30 天日线和 120 小时样本要求。',
        recentAlerts: const [],
      );
    }

    final timelineSymbol = eligibleSymbols.first;
    final timelineBars = normalizedHourly[timelineSymbol]!;
    final latestEvaluableTime = DateTime.fromMillisecondsSinceEpoch(
      eligibleSymbols
          .map(
            (symbol) =>
                normalizedHourly[symbol]![normalizedHourly[symbol]!.length - 25]
                    .closeTime,
          )
          .reduce((a, b) => a < b ? a : b),
    );
    final earliestTime = DateTime.fromMillisecondsSinceEpoch(
      eligibleSymbols
          .map((symbol) => normalizedHourly[symbol]![71].closeTime)
          .reduce((a, b) => a > b ? a : b),
    );
    final windowStart = _maxDate(
      earliestTime,
      latestEvaluableTime.subtract(replayWindow),
    );
    final windowEnd = latestEvaluableTime;

    final replayHours = timelineBars
        .where((bar) {
          final at = DateTime.fromMillisecondsSinceEpoch(bar.closeTime);
          return !at.isBefore(windowStart) && !at.isAfter(windowEnd);
        })
        .map((bar) => DateTime.fromMillisecondsSinceEpoch(bar.closeTime))
        .toList();

    final states = <_ReplayState>[];
    for (final at in replayHours) {
      final state = _buildReplayState(
        at: at,
        symbols: eligibleSymbols,
        dailyHistory: normalizedDaily,
        hourlyHistory: normalizedHourly,
      );
      if (state != null) {
        states.add(state);
      }
    }

    if (states.isEmpty) {
      return HourlyReplayReport(
        generatedAt: DateTime.now(),
        windowStart: windowStart,
        windowEnd: windowEnd,
        simulatedHours: 0,
        silentHours: 0,
        top3SampleCount: 0,
        top3WinRate: 0,
        top3AvgReturn: 0,
        alertSampleCount: 0,
        alertWinRate: 0,
        alertAvgReturn: 0,
        alertBestReturn: 0,
        validationHours: 0,
        validationSilentHours: 0,
        validationAlertSampleCount: 0,
        validationAlertWinRate: 0,
        validationAlertAvgReturn: 0,
        targetWinRate: targetWinRate,
        targetMet: false,
        optimizedPolicy: EntrySignalPolicy.defaultPolicy,
        notes: '回放窗口内没有生成足够的小时级状态，请检查 K 线样本是否完整。',
        recentAlerts: const [],
      );
    }

    final validationStart = windowEnd.subtract(validationWindow);
    final validationStates =
        states.where((state) => !state.at.isBefore(validationStart)).toList();

    final top3Stats = _evaluateTop3(states);
    final defaultValidation = _evaluatePolicy(
      EntrySignalPolicy.defaultPolicy,
      validationStates,
    );
    final optimizedPolicy = _pickBestPolicy(validationStates);
    final fullAlertStats = _evaluatePolicy(optimizedPolicy, states);
    final validationAlertStats =
        _evaluatePolicy(optimizedPolicy, validationStates);

    final targetMet = validationAlertStats.sampleCount >= 6 &&
        validationAlertStats.winRate >= targetWinRate;
    final notes = targetMet
        ? '近 14 天推送胜率从默认 ${(defaultValidation.winRate * 100).toStringAsFixed(1)}% '
            '优化到 ${(validationAlertStats.winRate * 100).toStringAsFixed(1)}%，'
            '样本 ${validationAlertStats.sampleCount} 条，已达到 ${(targetWinRate * 100).round()}% 目标。'
        : '近 14 天推送胜率从默认 ${(defaultValidation.winRate * 100).toStringAsFixed(1)}% '
            '优化到 ${(validationAlertStats.winRate * 100).toStringAsFixed(1)}%，'
            '样本 ${validationAlertStats.sampleCount} 条，仍未达到 ${(targetWinRate * 100).round()}% 目标，当前策略更适合继续观察并累积样本。';

    final recentAlerts = fullAlertStats.outcomes.reversed.take(8).toList();

    return HourlyReplayReport(
      generatedAt: DateTime.now(),
      windowStart: windowStart,
      windowEnd: windowEnd,
      simulatedHours: states.length,
      silentHours: fullAlertStats.silentHours,
      top3SampleCount: top3Stats.sampleCount,
      top3WinRate: top3Stats.winRate,
      top3AvgReturn: top3Stats.avgReturn,
      alertSampleCount: fullAlertStats.sampleCount,
      alertWinRate: fullAlertStats.winRate,
      alertAvgReturn: fullAlertStats.avgReturn,
      alertBestReturn: fullAlertStats.bestReturn,
      validationHours: validationStates.length,
      validationSilentHours: validationAlertStats.silentHours,
      validationAlertSampleCount: validationAlertStats.sampleCount,
      validationAlertWinRate: validationAlertStats.winRate,
      validationAlertAvgReturn: validationAlertStats.avgReturn,
      targetWinRate: targetWinRate,
      targetMet: targetMet,
      optimizedPolicy: optimizedPolicy,
      notes: notes,
      recentAlerts: recentAlerts,
    );
  }

  _ReplayState? _buildReplayState({
    required DateTime at,
    required List<String> symbols,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
  }) {
    final currentCoins = <CoinData>[];
    final dailySlices = <String, List<Kline>>{};
    final hourlySlices = <String, List<Kline>>{};
    final nextReturns = <String, double>{};
    final nextBestReturns = <String, double>{};

    for (final symbol in symbols) {
      final hourlyBars = hourlyHistory[symbol] ?? const [];
      final index = _lastClosedIndexBefore(hourlyBars, at);
      if (index < 71 || index + 24 >= hourlyBars.length) continue;

      final recent24 = hourlyBars.sublist(index - 23, index + 1);
      final recent72 = hourlyBars.sublist(index - 71, index + 1);
      final dailyBars =
          _dailyClosedBefore(dailyHistory[symbol] ?? const [], at);
      if (dailyBars.length < 35) continue;

      currentCoins.add(_snapshotCoin(symbol, recent24));
      dailySlices[symbol] = dailyBars;
      hourlySlices[symbol] = recent72;

      final currentClose = hourlyBars[index].close;
      if (currentClose <= 0) continue;

      final next24Close = hourlyBars[index + 24].close;
      final next24High = hourlyBars
          .sublist(index + 1, index + 25)
          .map((bar) => bar.high)
          .reduce(max);

      final displayName = _displayName(symbol);
      nextReturns[displayName] =
          ((next24Close - currentClose) / currentClose) * 100;
      nextBestReturns[displayName] =
          ((next24High - currentClose) / currentClose) * 100;
    }

    if (currentCoins.length < 5) return null;

    final result = RecommendationEngine.analyze(
      currentCoins: currentCoins,
      dailyHistory: dailySlices,
      hourlyHistory: hourlySlices,
      policy: EntrySignalPolicy.defaultPolicy,
    );

    return _ReplayState(
      at: at,
      top3: result.top3,
      alerts: result.entryAlerts,
      nextReturns: nextReturns,
      nextBestReturns: nextBestReturns,
    );
  }

  _Top3Stats _evaluateTop3(List<_ReplayState> states) {
    var samples = 0;
    var wins = 0;
    var totalReturn = 0.0;

    for (final state in states) {
      for (final coin in state.top3.take(3)) {
        final nextReturn = state.nextReturns[coin.displayName];
        if (nextReturn == null) continue;
        samples += 1;
        totalReturn += nextReturn;
        if (nextReturn > 0) {
          wins += 1;
        }
      }
    }

    return _Top3Stats(
      sampleCount: samples,
      winRate: samples == 0 ? 0 : wins / samples,
      avgReturn: samples == 0 ? 0 : totalReturn / samples,
    );
  }

  _AlertStats _evaluatePolicy(
    EntrySignalPolicy policy,
    List<_ReplayState> states,
  ) {
    var samples = 0;
    var wins = 0;
    var silentHours = 0;
    var totalReturn = 0.0;
    var totalBestReturn = 0.0;
    final outcomes = <ReplayAlertOutcome>[];
    final lastTriggeredAtBySymbol = <String, DateTime>{};

    for (final state in states) {
      final selected = state.alerts.where(policy.matches).toList()
        ..sort((a, b) {
          final byTotal = b.totalScore.compareTo(a.totalScore);
          if (byTotal != 0) return byTotal;
          return b.entryScore.compareTo(a.entryScore);
        });

      if (selected.isEmpty) {
        silentHours += 1;
        continue;
      }

      for (final alert in selected.take(policy.maxSignalsPerHour)) {
        final lastTriggeredAt = lastTriggeredAtBySymbol[alert.symbol];
        if (lastTriggeredAt != null &&
            state.at.difference(lastTriggeredAt).inHours <
                policy.cooldownHours) {
          continue;
        }

        final nextReturn = state.nextReturns[alert.symbol];
        final nextBestReturn = state.nextBestReturns[alert.symbol];
        if (nextReturn == null || nextBestReturn == null) continue;

        final isWin = nextReturn > 0;
        samples += 1;
        totalReturn += nextReturn;
        totalBestReturn += nextBestReturn;
        if (isWin) {
          wins += 1;
        }
        lastTriggeredAtBySymbol[alert.symbol] = state.at;

        outcomes.add(
          ReplayAlertOutcome(
            triggeredAt: state.at,
            symbol: alert.symbol,
            timingLabel: alert.timingLabel,
            totalScore: alert.totalScore,
            entryScore: alert.entryScore,
            entryPrice: alert.currentPrice,
            next24hCloseReturn: nextReturn,
            next24hBestReturn: nextBestReturn,
            isWin: isWin,
          ),
        );
      }
    }

    final winRate = samples == 0 ? 0.0 : wins / samples;
    final avgReturn = samples == 0 ? 0.0 : totalReturn / samples;
    final bestReturn = samples == 0 ? 0.0 : totalBestReturn / samples;
    final minSamples = max(6, (states.length * 0.04).round());
    final coverageScore = states.isEmpty
        ? 0.0
        : min(samples / max(minSamples, 1), 1.0).toDouble();
    final coverageRatio =
        states.isEmpty ? 0.0 : (samples / states.length).clamp(0.0, 1.0);

    var objective =
        winRate * 70 + avgReturn * 4 + coverageScore * 22 + coverageRatio * 36;
    if (avgReturn < 0) {
      objective += avgReturn * 2;
    }
    if (samples < minSamples) {
      objective -= 60 + (minSamples - samples) * 6;
    }
    if (winRate >= targetWinRate && samples >= minSamples) {
      objective += 30;
    }

    return _AlertStats(
      sampleCount: samples,
      winRate: winRate,
      avgReturn: avgReturn,
      bestReturn: bestReturn,
      silentHours: silentHours,
      objective: objective,
      outcomes: outcomes,
    );
  }

  EntrySignalPolicy _pickBestPolicy(List<_ReplayState> states) {
    if (states.isEmpty) return EntrySignalPolicy.defaultPolicy;

    _PolicyCandidate? best;
    for (final policy in _candidatePolicies()) {
      final stats = _evaluatePolicy(policy, states);
      final candidate = _PolicyCandidate(policy: policy, stats: stats);
      if (best == null || candidate.stats.objective > best.stats.objective) {
        best = candidate;
      }
    }

    return best?.policy ?? EntrySignalPolicy.defaultPolicy;
  }

  List<EntrySignalPolicy> _candidatePolicies() {
    const labelSets = [
      ['可入场'],
      ['可入场', '临近买点'],
      ['可入场', '临近买点', '等回踩'],
    ];
    const totalThresholds = [0.60, 0.64, 0.68, 0.72, 0.76];
    const entryThresholds = [0.58, 0.62, 0.66, 0.70, 0.74, 0.78];
    const volumeThresholds = [0.95, 1.00, 1.05, 1.12];
    const breakoutThresholds = [1.2, 1.8, 2.6, 3.4];

    final policies = <EntrySignalPolicy>[];
    for (var labelIndex = 0; labelIndex < labelSets.length; labelIndex++) {
      for (final minTotalScore in totalThresholds) {
        for (final minEntryScore in entryThresholds) {
          for (final minVolumeRatio in volumeThresholds) {
            for (final maxBreakoutDistance in breakoutThresholds) {
              policies.add(
                EntrySignalPolicy(
                  id: 'opt-$labelIndex-'
                      '${(minTotalScore * 100).round()}-'
                      '${(minEntryScore * 100).round()}-'
                      '${(minVolumeRatio * 100).round()}-'
                      '${(maxBreakoutDistance * 10).round()}',
                  label: '回放优化',
                  minTotalScore: minTotalScore,
                  minEntryScore: minEntryScore,
                  minVolumeRatio: minVolumeRatio,
                  maxBreakoutDistance: maxBreakoutDistance,
                  maxSignalsPerHour: 1,
                  cooldownHours: 6,
                  allowedLabels: labelSets[labelIndex],
                ),
              );
            }
          }
        }
      }
    }
    return policies;
  }

  List<Kline> _sorted(List<Kline> bars) {
    final copy = [...bars];
    copy.sort((a, b) => a.closeTime.compareTo(b.closeTime));
    return copy;
  }

  int _lastClosedIndexBefore(List<Kline> bars, DateTime at) {
    final closeTime = at.millisecondsSinceEpoch;
    var low = 0;
    var high = bars.length - 1;
    var answer = -1;

    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (bars[mid].closeTime <= closeTime) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    return answer;
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
    final quoteVolume = bars24h.fold<double>(
      0,
      (sum, bar) => sum + bar.quoteVolume,
    );
    final volume = bars24h.fold<double>(
      0,
      (sum, bar) => sum + bar.volume,
    );
    final tradeCount = bars24h.fold<int>(
      0,
      (sum, bar) => sum + bar.tradeCount,
    );
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

  DateTime _maxDate(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

  String _displayName(String symbol) {
    final upper = symbol.toUpperCase();
    if (upper.endsWith('USDT')) {
      return upper.substring(0, upper.length - 4);
    }
    return upper;
  }
}

class _ReplayState {
  final DateTime at;
  final List<CoinData> top3;
  final List<EntryAlertSignal> alerts;
  final Map<String, double> nextReturns;
  final Map<String, double> nextBestReturns;

  const _ReplayState({
    required this.at,
    required this.top3,
    required this.alerts,
    required this.nextReturns,
    required this.nextBestReturns,
  });
}

class _Top3Stats {
  final int sampleCount;
  final double winRate;
  final double avgReturn;

  const _Top3Stats({
    required this.sampleCount,
    required this.winRate,
    required this.avgReturn,
  });
}

class _AlertStats {
  final int sampleCount;
  final double winRate;
  final double avgReturn;
  final double bestReturn;
  final int silentHours;
  final double objective;
  final List<ReplayAlertOutcome> outcomes;

  const _AlertStats({
    required this.sampleCount,
    required this.winRate,
    required this.avgReturn,
    required this.bestReturn,
    required this.silentHours,
    required this.objective,
    required this.outcomes,
  });
}

class _PolicyCandidate {
  final EntrySignalPolicy policy;
  final _AlertStats stats;

  const _PolicyCandidate({
    required this.policy,
    required this.stats,
  });
}
