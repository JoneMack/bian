import 'dart:convert';
import 'dart:io';

import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/startup_strategy_backtest_service.dart';

const int _hourlyBarsFor45Days = 1200;
const int _dailyBars = 90;

Future<void> main() async {
  final service = BinanceService();
  final optimizer = StartupStrategyBacktestService();
  final symbolLimit = _loadSymbolLimit();

  stdout.writeln('Resolving tradable USDT symbols...');
  final coins = await service.fetchTradableUsdtTickers(limit: symbolLimit);
  final activeSymbols = coins.map((coin) => coin.symbol).toList()..sort();

  stdout.writeln(
    'Fetching daily history for ${activeSymbols.length} symbols...',
  );
  final dailyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1d',
    limit: _dailyBars,
    forceRefresh: true,
    chunkSize: 18,
  );

  stdout.writeln(
    'Fetching hourly history ($_hourlyBarsFor45Days bars)...',
  );
  final hourlyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1h',
    limit: _hourlyBarsFor45Days,
    forceRefresh: true,
    chunkSize: 18,
  );

  stdout.writeln('Testing startup strategy rounds...');
  final result = optimizer.optimize(
    dailyHistory: dailyHistory,
    hourlyHistory: hourlyHistory,
  );

  final payload = {
    'generatedAt': DateTime.now().toIso8601String(),
    'symbolLimit': symbolLimit,
    'activeSymbols': activeSymbols,
    'dailyHistoryCount': dailyHistory.length,
    'hourlyHistoryCount': hourlyHistory.length,
    'optimization': result.toJson(),
  };

  final reportsDir = Directory('build/reports')..createSync(recursive: true);
  final output =
      File('${reportsDir.path}/startup_strategy_optimization_45d.json');
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );

  stdout.writeln('');
  stdout.writeln('=== Startup Strategy Optimization 45d ===');
  stdout.writeln(
    'Rounds tested: ${result.rounds.length} | Symbols: ${activeSymbols.length}',
  );
  stdout.writeln(
    'Baseline: ${result.baselineRound.label} '
    '| WinRate ${(result.baselineRound.report.winRate * 100).toStringAsFixed(1)}% '
    '| Avg ${(result.baselineRound.report.avgSignalReturn * 100).toStringAsFixed(2)}% '
    '| Samples ${result.baselineRound.report.sampleCount}',
  );
  stdout.writeln(
    'Best: ${result.bestRound.label} '
    '| WinRate ${(result.bestRound.report.winRate * 100).toStringAsFixed(1)}% '
    '| Avg ${(result.bestRound.report.avgSignalReturn * 100).toStringAsFixed(2)}% '
    '| Samples ${result.bestRound.report.sampleCount}',
  );
  stdout.writeln('Best policy: ${result.bestRound.policy.summary}');
  stdout.writeln('');
  stdout.writeln('Top rounds:');
  for (final round in result.rounds.take(5)) {
    stdout.writeln(
      '${round.id} ${round.label} '
      '| score ${round.score.toStringAsFixed(2)} '
      '| win ${(round.report.winRate * 100).toStringAsFixed(1)}% '
      '| avg ${(round.report.avgSignalReturn * 100).toStringAsFixed(2)}% '
      '| samples ${round.report.sampleCount} '
      '| silent ${(round.report.silentRate * 100).toStringAsFixed(1)}%',
    );
  }

  stdout.writeln('');
  stdout.writeln('Saved optimization report to ${output.path}');
}

int? _loadSymbolLimit() {
  final raw = Platform.environment['MARKET_SYMBOL_LIMIT'];
  if (raw == null || raw.trim().isEmpty) return null;
  final value = int.tryParse(raw.trim());
  if (value == null || value <= 0) return null;
  return value;
}
