import 'dart:convert';
import 'dart:io';

import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/signal_runner_service.dart';
import 'package:binance_analyzer/services/startup_strategy_backtest_service.dart';

const int _dailyWarmupBars = 70;

Future<void> main(List<String> args) async {
  final windowDays = _loadWindowDays(args);
  final symbolLimit = _loadSymbolLimit();
  final reportPath = _loadReportPath(windowDays);
  final startupStrategyReportPath =
      Platform.environment['STARTUP_STRATEGY_REPORT_PATH'] ??
          SignalRunnerService.defaultStartupStrategyReportPath;

  final signalRunner = SignalRunnerService();
  final binance = BinanceService();
  final backtest = StartupStrategyBacktestService();
  final policySelection =
      await signalRunner.loadOptimizedStartupPolicySelection(
    startupStrategyReportPath: startupStrategyReportPath,
  );

  final dailyBars = windowDays + _dailyWarmupBars;
  final hourlyBars =
      windowDays * 24 + StartupStrategyBacktestService.replayLookbackHours + 24;

  stdout.writeln('Resolving tradable USDT symbols...');
  final coins = await binance.fetchTradableUsdtTickers(limit: symbolLimit);
  final activeSymbols = coins.map((coin) => coin.symbol).toList()..sort();

  stdout
      .writeln('Fetching daily history for ${activeSymbols.length} symbols...');
  final dailyHistory = await binance.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1d',
    limit: dailyBars,
    forceRefresh: true,
    chunkSize: 18,
  );

  stdout.writeln(
    'Fetching hourly history ($hourlyBars bars for ${windowDays}d backtest)...',
  );
  final hourlyHistory = await binance.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1h',
    limit: hourlyBars,
    forceRefresh: true,
    chunkSize: 18,
  );

  stdout.writeln(
      'Running ${windowDays}d backtest with ${policySelection.summary}...');
  final report = backtest.analyze(
    dailyHistory: dailyHistory,
    hourlyHistory: hourlyHistory,
    policy: policySelection.policy,
    windowDays: windowDays,
  );

  final payload = {
    'generatedAt': DateTime.now().toIso8601String(),
    'windowDays': windowDays,
    'symbolLimit': symbolLimit,
    'startupStrategyReportPath': startupStrategyReportPath,
    'policySelection': policySelection.toJson(),
    'policy': policySelection.policy.toJson(),
    'activeSymbols': activeSymbols,
    'dailyBarsRequested': dailyBars,
    'hourlyBarsRequested': hourlyBars,
    'dailyHistoryCount': dailyHistory.length,
    'hourlyHistoryCount': hourlyHistory.length,
    'report': report.toJson(),
  };

  final outputFile = File(reportPath)..parent.createSync(recursive: true);
  await outputFile
      .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));

  stdout.writeln('');
  stdout.writeln('=== Startup Strategy Backtest ===');
  stdout.writeln('Window: $windowDays 天');
  stdout.writeln('Policy: $policySelection.summary');
  stdout.writeln('Samples: $report.sampleCount');
  stdout.writeln('Win rate: ${(report.winRate * 100).toStringAsFixed(1)}%');
  stdout.writeln(
    'Avg signal return: ${(report.avgSignalReturn * 100).toStringAsFixed(2)}%',
  );
  stdout.writeln(
    'Avg best return: ${(report.avgBestReturn * 100).toStringAsFixed(2)}%',
  );
  stdout.writeln('Saved report to ${outputFile.path}');
}

int _loadWindowDays(List<String> args) {
  final fromArg = args.map((item) => item.trim()).firstWhere(
        (item) => item.startsWith('--window-days='),
        orElse: () => '',
      );
  final argValue =
      fromArg.isEmpty ? null : int.tryParse(fromArg.split('=').last.trim());
  final envValue = int.tryParse(
    Platform.environment['STARTUP_BACKTEST_WINDOW_DAYS'] ?? '',
  );
  final resolved = argValue ?? envValue ?? 60;
  return resolved > 0 ? resolved : 60;
}

int? _loadSymbolLimit() {
  final raw = Platform.environment['MARKET_SYMBOL_LIMIT'];
  if (raw == null || raw.trim().isEmpty) return null;
  final value = int.tryParse(raw.trim());
  if (value == null || value <= 0) return null;
  return value;
}

String _loadReportPath(int windowDays) {
  final custom = Platform.environment['STARTUP_BACKTEST_REPORT_PATH'];
  if (custom != null && custom.trim().isNotEmpty) {
    return custom.trim();
  }
  return 'build/reports/startup_strategy_backtest_${windowDays}d.json';
}
