import 'dart:io';

import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/signal_runner_service.dart';

Future<void> main() async {
  final service = SignalRunnerService();
  final result = await service.runDailySignal(
    requestedSymbols: _loadSymbols(),
    publishPush: true,
    dedupePush: false,
  );

  stdout.writeln('');
  stdout.writeln('=== Rotation Report ===');
  stdout.writeln(
    'Preset: ${result.engine.report.presetLabel} '
    '| AvgTop3: ${result.engine.report.avgTop3Return.toStringAsFixed(2)}% '
    '| WinRate: ${(result.engine.report.winRate * 100).toStringAsFixed(1)}%',
  );
  stdout.writeln('Policy: ${result.policy.summary}');

  stdout.writeln('');
  stdout.writeln('=== Top 3 Picks ===');
  for (final coin in result.engine.top3) {
    stdout.writeln(
      '${coin.displayName.padRight(8)} '
      'score ${(coin.score * 100).toStringAsFixed(0)} '
      '24h ${coin.priceChangePercent >= 0 ? '+' : ''}${coin.priceChangePercent.toStringAsFixed(2)}% '
      '| ${coin.timingLabel.isEmpty ? '继续等待' : coin.timingLabel}',
    );
  }

  stdout.writeln('');
  stdout.writeln(
      'Push: ${result.pushResult.status} | ${result.pushResult.message}');
  stdout.writeln('');
  stdout.writeln('Saved report to ${result.outputPath}');
}

List<String>? _loadSymbols() {
  final raw = Platform.environment['WATCHLIST'];
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }

  return raw
      .split(',')
      .map(BinanceService.toSymbol)
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
}
