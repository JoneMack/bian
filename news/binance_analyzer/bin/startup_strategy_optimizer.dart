import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/startup_strategy_backtest_service.dart';

const int _dailyWarmupBars = 70;

Future<void> main() async {
  final service = BinanceService();
  final optimizer = StartupStrategyBacktestService();
  final symbolLimit = _loadSymbolLimit();
  final windowDays = optimizer.normalizeWindowDays(
    StartupStrategyBacktestService.defaultOptimizationWindowDays,
  );
  final maxWindowDays = windowDays.reduce(max);
  final hourlyBars = maxWindowDays * 24 +
      StartupStrategyBacktestService.replayLookbackHours +
      24;
  final dailyBars = maxWindowDays + _dailyWarmupBars;

  stdout.writeln('Resolving tradable USDT symbols...');
  final coins = await service.fetchTradableUsdtTickers(limit: symbolLimit);
  final activeSymbols = coins.map((coin) => coin.symbol).toList()..sort();

  stdout.writeln(
    'Fetching daily history for ${activeSymbols.length} symbols...',
  );
  final dailyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1d',
    limit: dailyBars,
    forceRefresh: true,
    chunkSize: 18,
  );

  stdout.writeln(
    'Fetching hourly history ($hourlyBars bars for ${windowDays.join('/')}d windows)...',
  );
  final hourlyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1h',
    limit: hourlyBars,
    forceRefresh: true,
    chunkSize: 18,
  );

  stdout.writeln(
      'Testing startup strategy rounds on ${windowDays.join('/')}d...');
  final result = optimizer.optimize(
    dailyHistory: dailyHistory,
    hourlyHistory: hourlyHistory,
    windowDays: windowDays,
  );

  final payload = {
    'generatedAt': DateTime.now().toIso8601String(),
    'symbolLimit': symbolLimit,
    'windowDays': windowDays,
    'activeSymbols': activeSymbols,
    'dailyBarsRequested': dailyBars,
    'hourlyBarsRequested': hourlyBars,
    'dailyHistoryCount': dailyHistory.length,
    'hourlyHistoryCount': hourlyHistory.length,
    'optimization': result.toJson(),
  };

  final reportsDir = Directory('build/reports')..createSync(recursive: true);
  final output = File(
      '${reportsDir.path}/startup_strategy_optimization_multi_window.json');
  final legacyAlias =
      File('${reportsDir.path}/startup_strategy_optimization_45d.json');
  final encoded = const JsonEncoder.withIndent('  ').convert(payload);
  await output.writeAsString(encoded);
  await legacyAlias.writeAsString(
    encoded,
  );

  stdout.writeln('');
  stdout.writeln('=== Startup Strategy Optimization Stable ===');
  stdout.writeln(
    'Windows: ${windowDays.join('/')} 天 | Rounds: ${result.rounds.length} | Symbols: ${activeSymbols.length}',
  );
  for (final window in result.windows) {
    stdout.writeln(
      '${window.days}d best: ${window.bestRound.label} '
      '| Win ${(window.bestRound.report.winRate * 100).toStringAsFixed(1)}% '
      '| Avg ${(window.bestRound.report.avgSignalReturn * 100).toStringAsFixed(2)}% '
      '| Samples ${window.bestRound.report.sampleCount}',
    );
  }
  stdout.writeln(
    'Stable best: ${result.stableBestRound.label} '
    '| Stability ${result.stableBestRound.stabilityScore.toStringAsFixed(2)} '
    '| Gate ${result.stableBestRound.meetsStabilityGate ? 'pass' : 'fallback'}',
  );
  stdout.writeln('Stable policy: ${result.stableBestRound.policy.summary}');
  stdout.writeln(result.selectionNote);
  stdout.writeln('');
  stdout.writeln('Top stable rounds:');
  for (final round in result.stableRounds.take(5)) {
    final metrics = round.windows
        .map(
          (item) =>
              '${item.days}d ${(item.report.winRate * 100).toStringAsFixed(0)}%/${item.report.sampleCount}',
        )
        .join(' | ');
    stdout.writeln(
      '${round.id} ${round.label} '
      '| stability ${round.stabilityScore.toStringAsFixed(2)} '
      '| gate ${round.meetsStabilityGate ? 'pass' : 'fallback'} '
      '| $metrics',
    );
  }

  stdout.writeln('');
  stdout.writeln('Saved optimization report to ${output.path}');
  stdout.writeln('Legacy alias updated at ${legacyAlias.path}');
}

int? _loadSymbolLimit() {
  final raw = Platform.environment['MARKET_SYMBOL_LIMIT'];
  if (raw == null || raw.trim().isEmpty) return null;
  final value = int.tryParse(raw.trim());
  if (value == null || value <= 0) return null;
  return value;
}
