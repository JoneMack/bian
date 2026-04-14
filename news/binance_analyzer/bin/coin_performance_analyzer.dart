import 'dart:io';
import 'dart:math';

import 'package:binance_analyzer/services/binance_service.dart';

/// 分析每个自选币过去60天的领涨表现
/// 输出：每个币在过去60天中出现在当日 Top3 涨幅的次数
Future<void> main() async {
  final service = BinanceService();
  final requestedSymbols = _loadSymbols();

  stdout.writeln('正在获取活跃币种...');
  final tickers = await service.fetchTickers(symbols: requestedSymbols);
  final activeSymbols = tickers.map((c) => c.symbol).toList()..sort();
  stdout.writeln('共 ${activeSymbols.length} 个活跃币种\n');

  stdout.writeln('正在获取 90 天日线数据...');
  final dailyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1d',
    limit: 90,
    forceRefresh: true,
  );

  // 计算每天每个币的涨跌幅
  final symbolReturns = <String, List<_DayReturn>>{};

  for (final symbol in activeSymbols) {
    final bars = dailyHistory[symbol] ?? const [];
    if (bars.length < 60) continue;

    final sorted = [...bars]..sort((a, b) => a.closeTime.compareTo(b.closeTime));
    final returns = <_DayReturn>[];

    for (var i = 1; i < sorted.length; i++) {
      final prev = sorted[i - 1].close;
      if (prev <= 0) continue;
      final ret = ((sorted[i].close - prev) / prev) * 100;
      returns.add(_DayReturn(
        date: DateTime.fromMillisecondsSinceEpoch(sorted[i].closeTime),
        returnPct: ret,
      ));
    }

    symbolReturns[_displayName(symbol)] = returns;
  }

  // 取最近60天
  final allDates = <DateTime>{};
  for (final returns in symbolReturns.values) {
    for (final r in returns) {
      allDates.add(DateTime(r.date.year, r.date.month, r.date.day));
    }
  }
  final sortedDates = allDates.toList()..sort();
  final last60Dates = sortedDates.length > 60
      ? sortedDates.sublist(sortedDates.length - 60)
      : sortedDates;

  // 每天算 Top3 领涨
  final top3Count = <String, int>{};
  final top5Count = <String, int>{};
  final maxDailyGain = <String, double>{};
  final avgReturn = <String, double>{};
  final totalReturn60d = <String, double>{};

  for (final symbol in symbolReturns.keys) {
    top3Count[symbol] = 0;
    top5Count[symbol] = 0;
    maxDailyGain[symbol] = 0;
    avgReturn[symbol] = 0;
  }

  for (final date in last60Dates) {
    final dayResults = <String, double>{};
    for (final entry in symbolReturns.entries) {
      for (final r in entry.value) {
        final rDate = DateTime(r.date.year, r.date.month, r.date.day);
        if (rDate == date) {
          dayResults[entry.key] = r.returnPct;
          break;
        }
      }
    }

    if (dayResults.length < 5) continue;

    final ranked = dayResults.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    for (var i = 0; i < min(3, ranked.length); i++) {
      if (ranked[i].value > 0) {
        top3Count[ranked[i].key] = (top3Count[ranked[i].key] ?? 0) + 1;
      }
    }
    for (var i = 0; i < min(5, ranked.length); i++) {
      if (ranked[i].value > 0) {
        top5Count[ranked[i].key] = (top5Count[ranked[i].key] ?? 0) + 1;
      }
    }
  }

  // 计算每个币的60天总收益和最大单日涨幅
  for (final entry in symbolReturns.entries) {
    final recent = entry.value.where((r) {
      final rDate = DateTime(r.date.year, r.date.month, r.date.day);
      return last60Dates.contains(rDate);
    }).toList();

    if (recent.isEmpty) continue;

    final sum = recent.fold<double>(0, (s, r) => s + r.returnPct);
    avgReturn[entry.key] = sum / recent.length;
    maxDailyGain[entry.key] = recent.map((r) => r.returnPct).reduce(max);

    // 累计收益
    var cumReturn = 1.0;
    for (final r in recent) {
      cumReturn *= (1 + r.returnPct / 100);
    }
    totalReturn60d[entry.key] = (cumReturn - 1) * 100;
  }

  // 输出排名
  final symbols = symbolReturns.keys.toList()
    ..sort((a, b) => (top3Count[b] ?? 0).compareTo(top3Count[a] ?? 0));

  stdout.writeln('═══════════════════════════════════════════════════════════');
  stdout.writeln('  自选币 60 天领涨分析');
  stdout.writeln('═══════════════════════════════════════════════════════════');
  stdout.writeln('');
  stdout.writeln(
    '${'币种'.padRight(10)} '
    '${'Top3次数'.padLeft(8)} '
    '${'Top5次数'.padLeft(8)} '
    '${'最大日涨'.padLeft(9)} '
    '${'日均收益'.padLeft(9)} '
    '${'60日总收益'.padLeft(10)} '
    '评估',
  );
  stdout.writeln('─' * 72);

  final toRemove = <String>[];
  final toKeep = <String>[];

  for (final symbol in symbols) {
    final t3 = top3Count[symbol] ?? 0;
    final t5 = top5Count[symbol] ?? 0;
    final maxG = maxDailyGain[symbol] ?? 0;
    final avgR = avgReturn[symbol] ?? 0;
    final totalR = totalReturn60d[symbol] ?? 0;

    // 淘汰标准：Top3次数 <= 2 且 Top5次数 <= 4 且 最大单日涨幅 < 5%
    final shouldRemove = t3 <= 2 && t5 <= 4 && maxG < 5;
    final tag = shouldRemove ? '淘汰' : '保留';

    if (shouldRemove) {
      toRemove.add(symbol);
    } else {
      toKeep.add(symbol);
    }

    stdout.writeln(
      '${symbol.padRight(10)} '
      '${t3.toString().padLeft(8)} '
      '${t5.toString().padLeft(8)} '
      '${(maxG >= 0 ? '+' : '') + maxG.toStringAsFixed(1) + '%'.padLeft(9)} '
      '${(avgR >= 0 ? '+' : '') + avgR.toStringAsFixed(2) + '%'.padLeft(9)} '
      '${(totalR >= 0 ? '+' : '') + totalR.toStringAsFixed(1) + '%'.padLeft(10)} '
      '$tag',
    );
  }

  stdout.writeln('');
  stdout.writeln('─' * 72);
  stdout.writeln('保留 ${toKeep.length} 个: ${toKeep.join(', ')}');
  stdout.writeln('淘汰 ${toRemove.length} 个: ${toRemove.join(', ')}');
  stdout.writeln('');

  // 输出新的 watchlist 供使用
  final keepSymbols = toKeep.map((s) => '${s}USDT').toList();
  stdout.writeln('新自选列表 (WATCHLIST env):');
  stdout.writeln(keepSymbols.join(','));
}

class _DayReturn {
  final DateTime date;
  final double returnPct;
  const _DayReturn({required this.date, required this.returnPct});
}

String _displayName(String symbol) {
  final upper = symbol.toUpperCase();
  if (upper.endsWith('USDT')) return upper.substring(0, upper.length - 4);
  return upper;
}

List<String> _loadSymbols() {
  final raw = Platform.environment['WATCHLIST'];
  if (raw == null || raw.trim().isEmpty) {
    return BinanceService.defaultWatchlistSymbols;
  }
  return raw.split(',').map(BinanceService.toSymbol).toSet().toList()..sort();
}
