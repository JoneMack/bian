import 'dart:convert';
import 'dart:io';

import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/hourly_replay_service.dart';

Future<void> main() async {
  final service = BinanceService();
  final replay = HourlyReplayService();
  final requestedSymbols = _loadSymbols();

  stdout.writeln('Resolving active symbols...');
  final activeSymbols = (await service.fetchTickers(symbols: requestedSymbols))
      .map((coin) => coin.symbol)
      .toList();

  stdout.writeln('Fetching daily history for ${activeSymbols.length} symbols...');
  final dailyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1d',
    limit: 90,
    forceRefresh: true,
  );

  stdout.writeln('Fetching hourly history...');
  final hourlyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1h',
    limit: 960,
    forceRefresh: true,
  );

  stdout.writeln('Replaying last 30 days...');
  final report = await replay.generateReport(
    dailyHistory: dailyHistory,
    hourlyHistory: hourlyHistory,
  );

  final payload = {
    'generatedAt': DateTime.now().toIso8601String(),
    'watchlist': requestedSymbols,
    'activeSymbols': activeSymbols,
    'report': report.toJson(),
  };

  final reportsDir = Directory('build/reports')..createSync(recursive: true);
  final output = File('${reportsDir.path}/hourly_replay_report.json');
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );

  stdout.writeln('');
  stdout.writeln('=== Hourly Replay ===');
  stdout.writeln(
    'Window: ${report.windowStart.toIso8601String()} -> ${report.windowEnd.toIso8601String()}',
  );
  stdout.writeln(
    '14d Alert WinRate: ${(report.validationAlertWinRate * 100).toStringAsFixed(1)}% '
    '| Samples: ${report.validationAlertSampleCount} '
    '| Avg: ${report.validationAlertAvgReturn.toStringAsFixed(2)}%',
  );
  stdout.writeln(
    '30d Alert WinRate: ${(report.alertWinRate * 100).toStringAsFixed(1)}% '
    '| Top3 WinRate: ${(report.top3WinRate * 100).toStringAsFixed(1)}%',
  );
  stdout.writeln('Policy: ${report.optimizedPolicy.summary}');
  stdout.writeln('Target ${(report.targetWinRate * 100).round()}%: '
      '${report.targetMet ? 'hit' : 'not hit'}');
  stdout.writeln(report.notes);

  if (report.recentAlerts.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Recent alerts:');
    for (final alert in report.recentAlerts.take(5)) {
      stdout.writeln(
        '${alert.triggeredAt.toIso8601String()} '
        '${alert.symbol.padRight(8)} '
        '${alert.timingLabel.padRight(6)} '
        '${alert.next24hCloseReturn >= 0 ? '+' : ''}'
        '${alert.next24hCloseReturn.toStringAsFixed(2)}%',
      );
    }
  }

  stdout.writeln('');
  stdout.writeln('Saved replay report to ${output.path}');
}

List<String> _loadSymbols() {
  final raw = Platform.environment['WATCHLIST'];
  if (raw == null || raw.trim().isEmpty) {
    return BinanceService.defaultWatchlistSymbols;
  }

  return raw.split(',').map(BinanceService.toSymbol).toSet().toList()..sort();
}
