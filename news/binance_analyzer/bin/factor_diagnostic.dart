import 'dart:io';
import 'dart:math';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/utils/technical_indicators.dart';

/// 因子诊断：分析每个评分因子和未来24h收益的相关性
/// 目标：找出真正能预测涨跌的因子，淘汰噪音因子
Future<void> main() async {
  final service = BinanceService();
  final symbols = _loadSymbols();

  stdout.writeln('正在获取数据...');
  final tickers = await service.fetchTickers(symbols: symbols);
  final activeSymbols = tickers.map((c) => c.symbol).toList()..sort();

  final dailyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1d',
    limit: 120,
    forceRefresh: true,
  );
  final hourlyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1h',
    limit: 1680,
    forceRefresh: true,
  );

  stdout.writeln('开始因子诊断 (60天 × ${activeSymbols.length}币 × 每天评估)...\n');

  // 收集每日因子值和次日收益
  final factorSamples = <String, List<_FactorSample>>{};
  final factorNames = <String>[
    'daysSinceSurge',    // 距上次大涨天数
    'sevenDayReturn',    // 7日收益
    'thirtyDayReturn',   // 30日收益
    'threeDayReturn',    // 3日收益
    'drawdownFrom30High',// 距30日高点回撤
    'upRatio30',         // 30日阳线比例
    'volatility7v30',    // 7日vs30日波动率比
    'range7v30',         // 7日vs30日区间比
    'triggerChange',     // 当日涨跌幅
    'rangePosition',     // 区间位置
    'rsi14',             // RSI(14)
    'macdHistogram',     // MACD柱状图
    'emaTrend',          // EMA趋势
    'bollingerBW',       // 布林带宽
    'bollingerPctB',     // 布林带%B
    'obvTrend',          // OBV趋势
    'adx14',             // ADX
    'volumeRank',        // 成交量排名
    'hourlyRsi',         // 小时RSI
    'hourlyMacdHist',    // 小时MACD柱
    'hourlyTrend',       // 小时趋势
  ];

  for (final name in factorNames) {
    factorSamples[name] = [];
  }

  // 按天遍历，每天计算所有币的因子值
  for (final symbol in activeSymbols) {
    final dailyBars = _sorted(dailyHistory[symbol] ?? []);
    final hourlyBars = _sorted(hourlyHistory[symbol] ?? []);
    if (dailyBars.length < 60 || hourlyBars.length < 200) continue;

    final dailyCloses = dailyBars.map((b) => b.close).toList();
    final dailyHighs = dailyBars.map((b) => b.high).toList();
    final dailyLows = dailyBars.map((b) => b.low).toList();
    final dailyVolumes = dailyBars.map((b) => b.quoteVolume).toList();

    // 从第52天开始（需要50天历史 + 观察次日）
    for (var dayIdx = 52; dayIdx < dailyBars.length - 1; dayIdx++) {
      final closes = dailyCloses.sublist(0, dayIdx + 1);
      final highs = dailyHighs.sublist(0, dayIdx + 1);
      final lows = dailyLows.sublist(0, dayIdx + 1);
      final volumes = dailyVolumes.sublist(0, dayIdx + 1);

      if (closes.length < 45) continue;
      final current = closes.last;
      if (current <= 0) continue;

      // 次日收益
      final nextReturn = ((dailyBars[dayIdx + 1].close - current) / current) * 100;

      // 计算因子
      final window30 = closes.sublist(closes.length - 30);
      final window7 = closes.sublist(closes.length - 7);
      final thirtyDayReturn = (current - closes[closes.length - 30]) / closes[closes.length - 30];
      final sevenDayReturn = (current - closes[closes.length - 7]) / closes[closes.length - 7];
      final threeDayReturn = (current - closes[closes.length - 3]) / closes[closes.length - 3];

      final maxHigh30 = highs.sublist(highs.length - 30).reduce(max);
      final drawdownFrom30High = (maxHigh30 - current) / max(maxHigh30, 0.0001);

      // 阳线比例
      var upDays = 0;
      for (var i = closes.length - 30; i < closes.length; i++) {
        if (i > 0 && closes[i] > closes[i - 1]) upDays++;
      }
      final upRatio30 = upDays / 30;

      // 波动率比
      final returns30 = <double>[];
      for (var i = closes.length - 30; i < closes.length; i++) {
        if (i > 0 && closes[i - 1] > 0) {
          returns30.add((closes[i] - closes[i - 1]) / closes[i - 1]);
        }
      }
      final returns7 = returns30.length >= 7
          ? returns30.sublist(returns30.length - 7)
          : returns30;
      final vol30 = _stdDev(returns30);
      final vol7 = _stdDev(returns7);
      final volRatio = vol30 > 0 ? vol7 / vol30 : 1.0;

      // 区间比
      final range30 = maxHigh30 - lows.sublist(lows.length - 30).reduce(min);
      final maxHigh7 = highs.sublist(highs.length - 7).reduce(max);
      final range7 = maxHigh7 - lows.sublist(lows.length - 7).reduce(min);
      final rangeRatio = range30 > 0 ? range7 / range30 : 1.0;

      // 涨跌幅和区间位置
      final prevClose = closes[closes.length - 2];
      final triggerChange = prevClose > 0 ? ((current - prevClose) / prevClose) * 100 : 0.0;
      final dayHigh = highs.last;
      final dayLow = lows.last;
      final rangePos = (dayHigh - dayLow) > 0 ? (current - dayLow) / (dayHigh - dayLow) : 0.5;

      // 距上次大涨
      var daysSinceSurge = 15;
      for (var offset = 0; offset < min(15, dayIdx); offset++) {
        final idx = dayIdx - offset;
        final prev = closes[idx - 1];
        if (prev <= 0) continue;
        final change = ((closes[idx] - prev) / prev) * 100;
        if (change >= 8) { daysSinceSurge = offset; break; }
      }

      // 技术指标
      final rsi14 = TechnicalIndicators.rsiLatest(closes);
      final macdSnap = TechnicalIndicators.macdLatest(closes);
      final bb = TechnicalIndicators.bollingerLatest(closes);
      final adx14 = highs.length >= 30
          ? TechnicalIndicators.adxLatest(highs, lows, closes)
          : 25.0;
      final ema8 = TechnicalIndicators.emaLatest(closes, 8);
      final ema21 = TechnicalIndicators.emaLatest(closes, 21);
      final ema55 = closes.length >= 55
          ? TechnicalIndicators.emaLatest(closes, 55) : ema21;
      double emaTrend;
      if (current > ema8 && ema8 > ema21 && ema21 > ema55) {
        emaTrend = 1.0;
      } else if (current > ema21 && ema8 > ema21) {
        emaTrend = 0.75;
      } else if (current > ema21) {
        emaTrend = 0.55;
      } else if (current > ema55) {
        emaTrend = 0.35;
      } else {
        emaTrend = 0.15;
      }
      final obvTrend = TechnicalIndicators.obvTrendScore(closes, volumes);

      // 小时级指标（找到对应的小时K线）
      final dayCloseTime = dailyBars[dayIdx].closeTime;
      final hourlySlice = hourlyBars
          .where((b) => b.closeTime <= dayCloseTime)
          .toList();
      double hourlyRsi = 50;
      double hourlyMacdHist = 0;
      double hourlyTrend = 0.5;
      if (hourlySlice.length >= 30) {
        final hCloses = hourlySlice.map((b) => b.close).toList();
        hourlyRsi = TechnicalIndicators.rsiLatest(hCloses);
        hourlyMacdHist = TechnicalIndicators.macdLatest(hCloses).histogram;
        final hEma8 = TechnicalIndicators.emaLatest(hCloses, 8);
        final hEma21 = TechnicalIndicators.emaLatest(hCloses, 21);
        hourlyTrend = hCloses.last > hEma8 && hEma8 > hEma21 ? 1.0
            : hCloses.last > hEma21 ? 0.6 : 0.2;
      }

      // 成交量排名（当日成交量 vs 30日均值）
      final avgVol30 = _average(volumes.sublist(max(0, volumes.length - 30)));
      final volumeRank = avgVol30 > 0 ? volumes.last / avgVol30 : 1.0;

      // 录入
      factorSamples['daysSinceSurge']!.add(_FactorSample(daysSinceSurge.toDouble(), nextReturn));
      factorSamples['sevenDayReturn']!.add(_FactorSample(sevenDayReturn * 100, nextReturn));
      factorSamples['thirtyDayReturn']!.add(_FactorSample(thirtyDayReturn * 100, nextReturn));
      factorSamples['threeDayReturn']!.add(_FactorSample(threeDayReturn * 100, nextReturn));
      factorSamples['drawdownFrom30High']!.add(_FactorSample(drawdownFrom30High * 100, nextReturn));
      factorSamples['upRatio30']!.add(_FactorSample(upRatio30, nextReturn));
      factorSamples['volatility7v30']!.add(_FactorSample(volRatio, nextReturn));
      factorSamples['range7v30']!.add(_FactorSample(rangeRatio, nextReturn));
      factorSamples['triggerChange']!.add(_FactorSample(triggerChange, nextReturn));
      factorSamples['rangePosition']!.add(_FactorSample(rangePos, nextReturn));
      factorSamples['rsi14']!.add(_FactorSample(rsi14, nextReturn));
      factorSamples['macdHistogram']!.add(_FactorSample(macdSnap.histogram, nextReturn));
      factorSamples['emaTrend']!.add(_FactorSample(emaTrend, nextReturn));
      factorSamples['bollingerBW']!.add(_FactorSample(bb.bandwidth, nextReturn));
      factorSamples['bollingerPctB']!.add(_FactorSample(bb.percentB, nextReturn));
      factorSamples['obvTrend']!.add(_FactorSample(obvTrend, nextReturn));
      factorSamples['adx14']!.add(_FactorSample(adx14, nextReturn));
      factorSamples['volumeRank']!.add(_FactorSample(volumeRank, nextReturn));
      factorSamples['hourlyRsi']!.add(_FactorSample(hourlyRsi, nextReturn));
      factorSamples['hourlyMacdHist']!.add(_FactorSample(hourlyMacdHist, nextReturn));
      factorSamples['hourlyTrend']!.add(_FactorSample(hourlyTrend, nextReturn));
    }
  }

  // 计算相关性和分位数收益
  stdout.writeln('═══════════════════════════════════════════════════════════════');
  stdout.writeln('  因子诊断报告：每个因子和次日收益的相关性');
  stdout.writeln('═══════════════════════════════════════════════════════════════\n');

  stdout.writeln('${'因子'.padRight(22)} ${'样本数'.padLeft(6)} ${'相关性'.padLeft(8)} ${'IC'.padLeft(8)} '
      '${'低分位收益'.padLeft(10)} ${'高分位收益'.padLeft(10)} ${'预测力'.padLeft(8)}');
  stdout.writeln('─' * 85);

  final factorResults = <_FactorResult>[];

  for (final name in factorNames) {
    final samples = factorSamples[name]!;
    if (samples.length < 100) continue;

    final corr = _correlation(
      samples.map((s) => s.factorValue).toList(),
      samples.map((s) => s.nextReturn).toList(),
    );
    final ic = _rankIC(
      samples.map((s) => s.factorValue).toList(),
      samples.map((s) => s.nextReturn).toList(),
    );

    // 分位数收益
    final sorted = [...samples]..sort((a, b) => a.factorValue.compareTo(b.factorValue));
    final q20 = sorted.length ~/ 5;
    final low20 = _average(sorted.sublist(0, q20).map((s) => s.nextReturn).toList());
    final high20 = _average(sorted.sublist(sorted.length - q20).map((s) => s.nextReturn).toList());
    final spread = high20 - low20;

    factorResults.add(_FactorResult(
      name: name,
      sampleCount: samples.length,
      correlation: corr,
      rankIC: ic,
      low20Return: low20,
      high20Return: high20,
      spread: spread,
    ));

    stdout.writeln(
      '${name.padRight(22)} '
      '${samples.length.toString().padLeft(6)} '
      '${corr.toStringAsFixed(4).padLeft(8)} '
      '${ic.toStringAsFixed(4).padLeft(8)} '
      '${(low20 >= 0 ? '+' : '') + low20.toStringAsFixed(3).padLeft(10)}% '
      '${(high20 >= 0 ? '+' : '') + high20.toStringAsFixed(3).padLeft(10)}% '
      '${(spread.abs()).toStringAsFixed(3).padLeft(8)}',
    );
  }

  // 按预测力排序
  factorResults.sort((a, b) => b.spread.abs().compareTo(a.spread.abs()));
  stdout.writeln('\n── 因子预测力排名（高-低分位收益差） ──');
  for (var i = 0; i < factorResults.length; i++) {
    final f = factorResults[i];
    final direction = f.spread > 0 ? '正向' : '反向';
    stdout.writeln(
      '  ${(i + 1).toString().padLeft(2)}. ${f.name.padRight(22)} '
      'spread=${f.spread.toStringAsFixed(3).padLeft(7)}% '
      'IC=${f.rankIC.toStringAsFixed(4).padLeft(8)} '
      '$direction',
    );
  }

  // 给出建议
  stdout.writeln('\n── 调优建议 ──');
  final strong = factorResults.where((f) => f.spread.abs() > 0.15).toList();
  final weak = factorResults.where((f) => f.spread.abs() < 0.05).toList();

  if (strong.isNotEmpty) {
    stdout.writeln('  强预测因子 (spread > 0.15%): ${strong.map((f) => f.name).join(', ')}');
  }
  if (weak.isNotEmpty) {
    stdout.writeln('  弱预测因子 (spread < 0.05%): ${weak.map((f) => f.name).join(', ')}');
  }
}

class _FactorSample {
  final double factorValue;
  final double nextReturn;
  const _FactorSample(this.factorValue, this.nextReturn);
}

class _FactorResult {
  final String name;
  final int sampleCount;
  final double correlation;
  final double rankIC;
  final double low20Return;
  final double high20Return;
  final double spread;

  const _FactorResult({
    required this.name,
    required this.sampleCount,
    required this.correlation,
    required this.rankIC,
    required this.low20Return,
    required this.high20Return,
    required this.spread,
  });
}

double _correlation(List<double> x, List<double> y) {
  if (x.length != y.length || x.length < 3) return 0;
  final n = x.length;
  final meanX = _average(x);
  final meanY = _average(y);
  var sumXY = 0.0, sumX2 = 0.0, sumY2 = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = x[i] - meanX;
    final dy = y[i] - meanY;
    sumXY += dx * dy;
    sumX2 += dx * dx;
    sumY2 += dy * dy;
  }
  final denom = sqrt(sumX2 * sumY2);
  return denom > 0 ? sumXY / denom : 0;
}

double _rankIC(List<double> x, List<double> y) {
  // Spearman rank correlation
  final n = x.length;
  if (n < 3) return 0;
  final rankX = _ranks(x);
  final rankY = _ranks(y);
  return _correlation(rankX, rankY);
}

List<double> _ranks(List<double> values) {
  final indexed = List.generate(values.length, (i) => MapEntry(i, values[i]));
  indexed.sort((a, b) => a.value.compareTo(b.value));
  final ranks = List<double>.filled(values.length, 0);
  for (var i = 0; i < indexed.length; i++) {
    ranks[indexed[i].key] = i.toDouble();
  }
  return ranks;
}

double _average(List<double> values) {
  if (values.isEmpty) return 0;
  return values.reduce((a, b) => a + b) / values.length;
}

double _stdDev(List<double> values) {
  if (values.length < 2) return 0;
  final avg = _average(values);
  final variance = values.map((v) => pow(v - avg, 2).toDouble()).reduce((a, b) => a + b) / values.length;
  return sqrt(variance);
}

List<Kline> _sorted(List<Kline> bars) {
  final copy = [...bars];
  copy.sort((a, b) => a.closeTime.compareTo(b.closeTime));
  return copy;
}

List<String> _loadSymbols() {
  final raw = Platform.environment['WATCHLIST'];
  if (raw == null || raw.trim().isEmpty) {
    return BinanceService.defaultWatchlistSymbols;
  }
  return raw.split(',').map(BinanceService.toSymbol).toSet().toList()..sort();
}
