import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/models/strategy_snapshot.dart';
import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/hourly_replay_service.dart';
import 'package:binance_analyzer/services/recommendation_engine.dart';

const int _hourlyBarsFor45Days = 1200;
const int _dailyBars = 90;
const int _maxExitSignalsPerHour = 3;

Future<void> main() async {
  final service = BinanceService();
  final replay = HourlyReplayService();
  final requestedSymbols = _loadSymbols();

  stdout.writeln('Resolving active symbols...');
  final activeSymbols = (await service.fetchTickers(symbols: requestedSymbols))
      .map((coin) => coin.symbol)
      .toList()
    ..sort();

  stdout
      .writeln('Fetching daily history for ${activeSymbols.length} symbols...');
  final dailyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1d',
    limit: _dailyBars,
    forceRefresh: true,
  );

  stdout.writeln('Fetching hourly history ($_hourlyBarsFor45Days bars)...');
  final hourlyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1h',
    limit: _hourlyBarsFor45Days,
    forceRefresh: true,
  );

  stdout.writeln('Building optimized buy policy from 45-day replay...');
  final replayReport = await replay.generateReport(
    dailyHistory: dailyHistory,
    hourlyHistory: hourlyHistory,
  );

  stdout.writeln('Evaluating buy and sell signals...');
  final analyzer = _StrategySignalBacktestAnalyzer();
  final signalReport = analyzer.analyze(
    dailyHistory: dailyHistory,
    hourlyHistory: hourlyHistory,
    entryPolicy: replayReport.optimizedPolicy,
    windowStart: replayReport.windowStart,
    windowEnd: replayReport.windowEnd,
  );

  final payload = {
    'generatedAt': DateTime.now().toIso8601String(),
    'requestedSymbols': requestedSymbols,
    'activeSymbols': activeSymbols,
    'replayReport': replayReport.toJson(),
    'signalReport': signalReport.toJson(),
  };

  final reportsDir = Directory('build/reports')..createSync(recursive: true);
  final output = File('${reportsDir.path}/strategy_signal_backtest_45d.json');
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );

  stdout.writeln('');
  stdout.writeln('=== Strategy Signal Backtest 45d ===');
  stdout.writeln(
    'Window: ${signalReport.windowStart.toIso8601String()} -> '
    '${signalReport.windowEnd.toIso8601String()}',
  );
  stdout.writeln(
    'Simulated hours: ${signalReport.simulatedHours} '
    '| Eligible symbols: ${signalReport.eligibleSymbols.length}',
  );
  stdout.writeln('Buy policy: ${replayReport.optimizedPolicy.summary}');
  stdout.writeln(
    'Buy signals: ${signalReport.buy.sampleCount} samples '
    '| WinRate ${(signalReport.buy.winRate * 100).toStringAsFixed(1)}% '
    '| Avg ${(signalReport.buy.avgSignalReturn * 100).toStringAsFixed(2)}% '
    '| Silent ${(signalReport.buy.silentRate * 100).toStringAsFixed(1)}%',
  );
  stdout.writeln(
    'Sell signals: ${signalReport.sell.sampleCount} samples '
    '| WinRate ${(signalReport.sell.winRate * 100).toStringAsFixed(1)}% '
    '| Avg ${(signalReport.sell.avgSignalReturn * 100).toStringAsFixed(2)}% '
    '| Silent ${(signalReport.sell.silentRate * 100).toStringAsFixed(1)}%',
  );

  if (signalReport.buy.topSymbols.isNotEmpty) {
    stdout.writeln(
      'Best buy symbols: ${signalReport.buy.topSymbols.take(3).map((item) => item.summary).join(' | ')}',
    );
  }
  if (signalReport.sell.topSymbols.isNotEmpty) {
    stdout.writeln(
      'Best sell symbols: ${signalReport.sell.topSymbols.take(3).map((item) => item.summary).join(' | ')}',
    );
  }

  stdout.writeln('');
  stdout.writeln('Saved strategy backtest report to ${output.path}');
}

class _StrategySignalBacktestAnalyzer {
  StrategySignalBacktestReport analyze({
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    required EntrySignalPolicy entryPolicy,
    required DateTime windowStart,
    required DateTime windowEnd,
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
                  RecommendationEngine.minimumDailyBars &&
              (normalizedHourly[symbol]?.length ?? 0) >= 120,
        )
        .toList()
      ..sort();

    if (eligibleSymbols.length < 5) {
      return StrategySignalBacktestReport(
        generatedAt: DateTime.now(),
        windowStart: windowStart,
        windowEnd: windowEnd,
        simulatedHours: 0,
        eligibleSymbols: eligibleSymbols,
        buy: const SignalPerformance.empty(),
        sell: const SignalPerformance.empty(),
      );
    }

    final timelineSymbol = eligibleSymbols.first;
    final replayHours = normalizedHourly[timelineSymbol]!
        .where((bar) {
          final at = DateTime.fromMillisecondsSinceEpoch(bar.closeTime);
          return !at.isBefore(windowStart) && !at.isAfter(windowEnd);
        })
        .map((bar) => DateTime.fromMillisecondsSinceEpoch(bar.closeTime))
        .toList();

    final states = <_SignalReplayState>[];
    for (final at in replayHours) {
      final state = _buildReplayState(
        at: at,
        symbols: eligibleSymbols,
        dailyHistory: normalizedDaily,
        hourlyHistory: normalizedHourly,
        entryPolicy: entryPolicy,
      );
      if (state != null) {
        states.add(state);
      }
    }

    return StrategySignalBacktestReport(
      generatedAt: DateTime.now(),
      windowStart: windowStart,
      windowEnd: windowEnd,
      simulatedHours: states.length,
      eligibleSymbols: eligibleSymbols,
      buy: _evaluateBuySignals(states, entryPolicy),
      sell: _evaluateSellSignals(states),
    );
  }

  _SignalReplayState? _buildReplayState({
    required DateTime at,
    required List<String> symbols,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    required EntrySignalPolicy entryPolicy,
  }) {
    final currentCoins = <CoinData>[];
    final dailySlices = <String, List<Kline>>{};
    final hourlySlices = <String, List<Kline>>{};
    final nextCloseReturns = <String, double>{};
    final nextBestReturns = <String, double>{};
    final nextWorstReturns = <String, double>{};

    for (final symbol in symbols) {
      final hourlyBars = hourlyHistory[symbol] ?? const [];
      final index = _lastClosedIndexBefore(hourlyBars, at);
      if (index < 71 || index + 24 >= hourlyBars.length) continue;

      final dailyBars =
          _dailyClosedBefore(dailyHistory[symbol] ?? const [], at);
      if (dailyBars.length < RecommendationEngine.minimumDailyBars) continue;

      final recent24 = hourlyBars.sublist(index - 23, index + 1);
      final recent72 = hourlyBars.sublist(index - 71, index + 1);
      final currentClose = hourlyBars[index].close;
      if (currentClose <= 0) continue;

      final next24 = hourlyBars.sublist(index + 1, index + 25);
      final next24Close = hourlyBars[index + 24].close;
      final next24High = next24.map((bar) => bar.high).reduce(max);
      final next24Low = next24.map((bar) => bar.low).reduce(min);
      final displayName = _displayName(symbol);

      currentCoins.add(_snapshotCoin(symbol, recent24));
      dailySlices[symbol] = dailyBars;
      hourlySlices[symbol] = recent72;
      nextCloseReturns[displayName] =
          ((next24Close - currentClose) / currentClose);
      nextBestReturns[displayName] =
          ((next24High - currentClose) / currentClose);
      nextWorstReturns[displayName] =
          ((next24Low - currentClose) / currentClose);
    }

    if (currentCoins.length < 5) return null;

    final engine = RecommendationEngine.analyze(
      currentCoins: currentCoins,
      dailyHistory: dailySlices,
      hourlyHistory: hourlySlices,
      policy: entryPolicy,
    );

    return _SignalReplayState(
      at: at,
      entryAlerts: engine.entryAlerts,
      exitAlerts: engine.exitAlerts,
      nextCloseReturns: nextCloseReturns,
      nextBestReturns: nextBestReturns,
      nextWorstReturns: nextWorstReturns,
    );
  }

  SignalPerformance _evaluateBuySignals(
    List<_SignalReplayState> states,
    EntrySignalPolicy policy,
  ) {
    var samples = 0;
    var wins = 0;
    var silentHours = 0;
    var totalSignalReturn = 0.0;
    var totalBestReturn = 0.0;
    final lastTriggeredAtBySymbol = <String, DateTime>{};
    final byLabel = <String, _MutableSignalBucket>{};
    final bySymbol = <String, _MutableSignalBucket>{};

    for (final state in states) {
      final selected = state.entryAlerts.where(policy.matches).toList()
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

        final nextReturn = state.nextCloseReturns[alert.symbol];
        final bestReturn = state.nextBestReturns[alert.symbol];
        if (nextReturn == null || bestReturn == null) continue;

        final isWin = nextReturn > 0;
        samples += 1;
        totalSignalReturn += nextReturn;
        totalBestReturn += bestReturn;
        if (isWin) wins += 1;
        lastTriggeredAtBySymbol[alert.symbol] = state.at;

        byLabel
            .putIfAbsent(alert.timingLabel, _MutableSignalBucket.new)
            .add(nextReturn, isWin);
        bySymbol.putIfAbsent(alert.symbol, _MutableSignalBucket.new).add(
              nextReturn,
              isWin,
            );
      }
    }

    return SignalPerformance(
      sampleCount: samples,
      wins: wins,
      silentHours: silentHours,
      avgSignalReturn: samples == 0 ? 0 : totalSignalReturn / samples,
      avgBestReturn: samples == 0 ? 0 : totalBestReturn / samples,
      byLabel: _freezeBucketsBySamples(byLabel),
      topSymbols: _freezeBucketsByReturn(bySymbol),
    );
  }

  SignalPerformance _evaluateSellSignals(List<_SignalReplayState> states) {
    var samples = 0;
    var wins = 0;
    var silentHours = 0;
    var totalSignalReturn = 0.0;
    var totalBestReturn = 0.0;
    final byLabel = <String, _MutableSignalBucket>{};
    final bySymbol = <String, _MutableSignalBucket>{};

    for (final state in states) {
      final selected =
          state.exitAlerts.where((alert) => alert.shouldNotify).toList();
      if (selected.isEmpty) {
        silentHours += 1;
        continue;
      }

      for (final alert in selected.take(_maxExitSignalsPerHour)) {
        final nextReturn = state.nextCloseReturns[alert.symbol];
        final worstReturn = state.nextWorstReturns[alert.symbol];
        if (nextReturn == null || worstReturn == null) continue;

        final signalReturn = -nextReturn;
        final bestReturn = -worstReturn;
        final isWin = nextReturn < 0;
        samples += 1;
        totalSignalReturn += signalReturn;
        totalBestReturn += bestReturn;
        if (isWin) wins += 1;

        byLabel
            .putIfAbsent(alert.timingLabel, _MutableSignalBucket.new)
            .add(signalReturn, isWin);
        bySymbol.putIfAbsent(alert.symbol, _MutableSignalBucket.new).add(
              signalReturn,
              isWin,
            );
      }
    }

    return SignalPerformance(
      sampleCount: samples,
      wins: wins,
      silentHours: silentHours,
      avgSignalReturn: samples == 0 ? 0 : totalSignalReturn / samples,
      avgBestReturn: samples == 0 ? 0 : totalBestReturn / samples,
      byLabel: _freezeBucketsBySamples(byLabel),
      topSymbols: _freezeBucketsByReturn(bySymbol),
    );
  }

  List<SignalBucket> _freezeBucketsBySamples(
      Map<String, _MutableSignalBucket> buckets) {
    final result = buckets.entries
        .map(
          (entry) => SignalBucket(
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
        final bySamples = b.sampleCount.compareTo(a.sampleCount);
        if (bySamples != 0) return bySamples;
        return b.winRate.compareTo(a.winRate);
      });
    return result;
  }

  List<SignalBucket> _freezeBucketsByReturn(
      Map<String, _MutableSignalBucket> buckets) {
    final result = buckets.entries
        .map(
          (entry) => SignalBucket(
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
        final byReturn = b.avgSignalReturn.compareTo(a.avgSignalReturn);
        if (byReturn != 0) return byReturn;
        return b.sampleCount.compareTo(a.sampleCount);
      });
    return result;
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

class _SignalReplayState {
  final DateTime at;
  final List<EntryAlertSignal> entryAlerts;
  final List<EntryAlertSignal> exitAlerts;
  final Map<String, double> nextCloseReturns;
  final Map<String, double> nextBestReturns;
  final Map<String, double> nextWorstReturns;

  const _SignalReplayState({
    required this.at,
    required this.entryAlerts,
    required this.exitAlerts,
    required this.nextCloseReturns,
    required this.nextBestReturns,
    required this.nextWorstReturns,
  });
}

class _MutableSignalBucket {
  int sampleCount = 0;
  int wins = 0;
  double totalReturn = 0;

  void add(double signalReturn, bool isWin) {
    sampleCount += 1;
    totalReturn += signalReturn;
    if (isWin) wins += 1;
  }
}

class StrategySignalBacktestReport {
  final DateTime generatedAt;
  final DateTime windowStart;
  final DateTime windowEnd;
  final int simulatedHours;
  final List<String> eligibleSymbols;
  final SignalPerformance buy;
  final SignalPerformance sell;

  const StrategySignalBacktestReport({
    required this.generatedAt,
    required this.windowStart,
    required this.windowEnd,
    required this.simulatedHours,
    required this.eligibleSymbols,
    required this.buy,
    required this.sell,
  });

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'windowStart': windowStart.toIso8601String(),
        'windowEnd': windowEnd.toIso8601String(),
        'simulatedHours': simulatedHours,
        'eligibleSymbols': eligibleSymbols,
        'buy': buy.toJson(),
        'sell': sell.toJson(),
      };
}

class SignalPerformance {
  final int sampleCount;
  final int wins;
  final int silentHours;
  final double avgSignalReturn;
  final double avgBestReturn;
  final List<SignalBucket> byLabel;
  final List<SignalBucket> topSymbols;

  const SignalPerformance({
    required this.sampleCount,
    required this.wins,
    required this.silentHours,
    required this.avgSignalReturn,
    required this.avgBestReturn,
    required this.byLabel,
    required this.topSymbols,
  });

  const SignalPerformance.empty()
      : sampleCount = 0,
        wins = 0,
        silentHours = 0,
        avgSignalReturn = 0,
        avgBestReturn = 0,
        byLabel = const [],
        topSymbols = const [];

  double get winRate => sampleCount == 0 ? 0 : wins / sampleCount;

  double get silentRate => sampleCount + silentHours == 0
      ? 0
      : silentHours / (sampleCount + silentHours);

  Map<String, dynamic> toJson() => {
        'sampleCount': sampleCount,
        'wins': wins,
        'winRate': winRate,
        'silentHours': silentHours,
        'silentRate': silentRate,
        'avgSignalReturn': avgSignalReturn,
        'avgBestReturn': avgBestReturn,
        'byLabel': byLabel.map((item) => item.toJson()).toList(),
        'topSymbols': topSymbols.map((item) => item.toJson()).toList(),
      };
}

class SignalBucket {
  final String name;
  final int sampleCount;
  final int wins;
  final double avgSignalReturn;

  const SignalBucket({
    required this.name,
    required this.sampleCount,
    required this.wins,
    required this.avgSignalReturn,
  });

  double get winRate => sampleCount == 0 ? 0 : wins / sampleCount;

  String get summary =>
      '$name $wins/$sampleCount ${(winRate * 100).toStringAsFixed(0)}% '
      'avg ${(avgSignalReturn * 100).toStringAsFixed(2)}%';

  Map<String, dynamic> toJson() => {
        'name': name,
        'sampleCount': sampleCount,
        'wins': wins,
        'winRate': winRate,
        'avgSignalReturn': avgSignalReturn,
      };
}

List<String> _loadSymbols() {
  final raw = Platform.environment['WATCHLIST'];
  if (raw == null || raw.trim().isEmpty) {
    return BinanceService.defaultWatchlistSymbols;
  }

  return raw.split(',').map(BinanceService.toSymbol).toSet().toList()..sort();
}
