import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/signal_runner_service.dart';

Future<void> main(List<String> args) async {
  final windowDays = _loadWindowDays(args);
  final reportPath = _loadReportPath(windowDays);
  final symbols = _loadSymbols();

  final runner = SignalRunnerService();
  stdout.writeln('Running leader prediction backtest for $windowDays days...');
  stdout.writeln('Symbols: ${symbols.join(', ')}');

  final payload = await runner.refreshLeaderPredictionStats(
    requestedSymbols: symbols,
    logPath: SignalRunnerService.defaultLeaderPredictionLogPath,
    statsPath: SignalRunnerService.defaultLeaderPredictionStatsPath,
    lookbackDays: windowDays,
  );

  final backtestRecords =
      (payload['backtestRecords'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
  final settled = backtestRecords
      .where((record) => record['status']?.toString() == 'settled')
      .toList();
  final actionable =
      settled.where((record) => record['actionable'] == true).toList();
  final strongRecommend =
      settled.where((record) => record['strongActionable'] == true).toList();
  final profit = {
    'allPredictions': _buildProfitSummary(settled),
    'actionable': _buildProfitSummary(actionable),
    'strongRecommend': _buildProfitSummary(strongRecommend),
  };

  final report = {
    'generatedAt': DateTime.now().toIso8601String(),
    'windowDays': windowDays,
    'symbols': symbols,
    'summary': payload['summary'],
    'benchmarks': payload['benchmarks'],
    'experimentHistory': payload['experimentHistory'],
    'bestExperiment': payload['bestExperiment'],
    'experimentSelectionPolicy': payload['experimentSelectionPolicy'],
    'profit': profit,
    'backtestRecords': backtestRecords,
  };

  final outputFile = File(reportPath);
  await outputFile.parent.create(recursive: true);
  await outputFile
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));

  final summary = Map<String, dynamic>.from(payload['summary'] as Map);
  stdout.writeln('');
  stdout.writeln('=== Leader Prediction Backtest ===');
  stdout.writeln('Window: $windowDays 天');
  stdout.writeln('Mode: rotation_top1_walk_forward');
  stdout.writeln('Current regime: ${summary['currentRegimeStatus']}');
  stdout.writeln('Model version: ${summary['currentModelVersion']}');
  stdout.writeln('Current confidence: ${summary['currentConfidence']}');
  stdout.writeln('Selected experiment: ${summary['selectedExperimentLabel']}');
  stdout.writeln(
      'Prediction days: ${summary['predictionDays'] ?? summary['totalDays']}');
  stdout.writeln('Recommend days: ${summary['recommendDays']}');
  stdout.writeln('Watch-only days: ${summary['watchOnlyDays'] ?? 0}');
  stdout.writeln('Actionable days: ${summary['actionableDays'] ?? 0}');
  stdout.writeln('Suppressed days: ${summary['suppressedDays']}');
  stdout.writeln(
    'Top1 hit rate: ${(_asDouble(summary['top1HitRate']) * 100).toStringAsFixed(1)}%',
  );
  stdout.writeln(
    'Top3 hit rate: ${(_asDouble(summary['top3HitRate']) * 100).toStringAsFixed(1)}%',
  );
  stdout.writeln(
    'Actionable Top1 hit rate: ${(_asDouble(summary['actionableTop1HitRate']) * 100).toStringAsFixed(1)}%',
  );
  stdout.writeln(
    'Recommend Top1 hit rate: ${(_asDouble(summary['recommendTop1HitRate']) * 100).toStringAsFixed(1)}%',
  );
  stdout.writeln(
    'Avg predicted return: ${_asDouble(summary['avgPredictedReturn']).toStringAsFixed(2)}%',
  );
  stdout.writeln(
    'Actionable avg return: ${_asDouble(summary['actionableAvgPredictedReturn']).toStringAsFixed(2)}%',
  );
  stdout.writeln(
    'Recommend avg return: ${_asDouble(summary['recommendAvgPredictedReturn']).toStringAsFixed(2)}%',
  );
  stdout.writeln(
    'Avg excess vs median: ${_asDouble(summary['avgExcessVsMedian']).toStringAsFixed(2)}%',
  );
  stdout.writeln(
    'All prediction simple total return: ${_asDouble((profit['allPredictions'] as Map<String, dynamic>)['simpleTotalReturnPercent']).toStringAsFixed(2)}%',
  );
  stdout.writeln(
    'All prediction compounded return: ${_asDouble((profit['allPredictions'] as Map<String, dynamic>)['compoundedReturnPercent']).toStringAsFixed(2)}%',
  );
  stdout.writeln(
    'Actionable compounded return: ${_asDouble((profit['actionable'] as Map<String, dynamic>)['compoundedReturnPercent']).toStringAsFixed(2)}%',
  );
  stdout.writeln(
    'Recommend compounded return: ${_asDouble((profit['strongRecommend'] as Map<String, dynamic>)['compoundedReturnPercent']).toStringAsFixed(2)}%',
  );
  final bestExperiment = payload['bestExperiment'];
  if (bestExperiment is Map) {
    stdout.writeln(
      'Best experiment: ${(bestExperiment['label'] ?? bestExperiment['id'])} | Top1 ${(100 * _asDouble(bestExperiment['top1HitRate'])).toStringAsFixed(1)}%',
    );
  }
  stdout.writeln('Saved report to ${outputFile.path}');
}

Map<String, dynamic> _buildProfitSummary(List<Map<String, dynamic>> settled) {
  var simpleTotal = 0.0;
  var compounded = 1.0;
  var wins = 0;
  var losses = 0;
  double? bestTrade;
  double? worstTrade;

  for (final record in settled) {
    final value = _asDouble(record['predictedCoinReturn']);
    simpleTotal += value;
    compounded *= 1 + value / 100;
    if (value > 0) {
      wins += 1;
    } else {
      losses += 1;
    }
    bestTrade = bestTrade == null ? value : max(bestTrade, value);
    worstTrade = worstTrade == null ? value : min(worstTrade, value);
  }

  return {
    'tradeCount': settled.length,
    'wins': wins,
    'losses': losses,
    'simpleTotalReturnPercent': simpleTotal,
    'compoundedReturnPercent': (compounded - 1) * 100,
    'bestTradePercent': bestTrade ?? 0.0,
    'worstTradePercent': worstTrade ?? 0.0,
  };
}

List<String> _loadSymbols() {
  final raw = Platform.environment['WATCHLIST'];
  if (raw == null || raw.trim().isEmpty) {
    return BinanceService.defaultLeaderPredictionSymbols;
  }
  return raw
      .split(',')
      .map(BinanceService.toSymbol)
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
}

int _loadWindowDays(List<String> args) {
  final fromArg = args.map((item) => item.trim()).firstWhere(
        (item) => item.startsWith('--window-days='),
        orElse: () => '',
      );
  final argValue =
      fromArg.isEmpty ? null : int.tryParse(fromArg.split('=').last.trim());
  final envValue = int.tryParse(
    Platform.environment['LEADER_BACKTEST_WINDOW_DAYS'] ?? '',
  );
  final resolved = argValue ?? envValue ?? 60;
  return resolved > 0 ? resolved : 60;
}

String _loadReportPath(int windowDays) {
  final custom = Platform.environment['LEADER_BACKTEST_REPORT_PATH'];
  if (custom != null && custom.trim().isNotEmpty) {
    return custom.trim();
  }
  return 'build/reports/leader_prediction_backtest_${windowDays}d.json';
}

double _asDouble(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value == null) return 0.0;
  return double.tryParse(value.toString()) ?? 0.0;
}
