import 'package:flutter_test/flutter_test.dart';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/startup_scanner_service.dart';

void main() {
  test('prioritizes breakout candidate and filters weak symbol', () {
    final service = StartupScannerService();
    final policy = StartupScanPolicy.defaultPolicy.copyWith(
      label: '测试策略',
      minScore: 0.68,
      minTrendScore: 0.58,
      minCompressionScore: 0.12,
      minLiquidityScore: 0.0,
      minMomentumScore: 0.18,
      minMarketTrendBreadth: 0.0,
      minMarketMomentumBreadth: 0.0,
      minMarketTrendBreadthForEntry: 0.0,
      minMarketMomentumBreadthForEntry: 0.0,
      minMarketVolumeBreadthForEntry: 0.0,
      maxRedBreadthForEntry: 1.0,
      maxDeepRedBreadthForEntry: 1.0,
      minVolumeRatio: 1.20,
      minDailyChangePercent: 0.5,
      maxPushCandidates: 3,
    );
    final now = DateTime.now();

    final breakoutCoin = CoinData(
      symbol: 'STARTUSDT',
      lastPrice: 9.18,
      priceChange: 0.34,
      priceChangePercent: 3.8,
      highPrice: 9.22,
      lowPrice: 8.82,
      openPrice: 8.84,
      quoteVolume: 18000000,
      volume: 2100000,
      count: 24000,
    );
    final weakCoin = CoinData(
      symbol: 'WEAKUSDT',
      lastPrice: 4.12,
      priceChange: -0.08,
      priceChangePercent: -1.9,
      highPrice: 4.28,
      lowPrice: 4.05,
      openPrice: 4.20,
      quoteVolume: 1200000,
      volume: 320000,
      count: 1800,
    );

    final fillerCoins = List.generate(
      8,
      (index) => CoinData(
        symbol: 'FILL${index}USDT',
        lastPrice: 6 + index * 0.2,
        priceChange: 0.03,
        priceChangePercent: 0.8,
        highPrice: 6.4 + index * 0.2,
        lowPrice: 5.8 + index * 0.2,
        openPrice: 5.95 + index * 0.2,
        quoteVolume: 5000000 + index * 400000,
        volume: 900000,
        count: 9000 + index * 250,
      ),
    );

    final dailyHistory = <String, List<Kline>>{
      'STARTUSDT': _buildBreakoutDailyBars(now),
      'WEAKUSDT': _buildWeakDailyBars(now),
      for (var i = 0; i < fillerCoins.length; i++)
        'FILL${i}USDT': _buildFillerDailyBars(now, i),
    };
    final hourlyHistory = <String, List<Kline>>{
      'STARTUSDT': _buildBreakoutHourlyBars(now),
      'WEAKUSDT': _buildWeakHourlyBars(now),
      for (var i = 0; i < fillerCoins.length; i++)
        'FILL${i}USDT': _buildFillerHourlyBars(now, i),
    };

    final report = service.analyzeMarket(
      currentCoins: [breakoutCoin, weakCoin, ...fillerCoins],
      dailyHistory: dailyHistory,
      hourlyHistory: hourlyHistory,
      policy: policy,
    );

    expect(report.candidates, isNotEmpty);
    expect(report.candidates.first.symbol, 'START');
    expect(report.candidates.first.shouldNotify, isTrue);
    expect(
      report.candidates
          .where((item) => item.symbol == 'WEAK')
          .first
          .shouldNotify,
      isFalse,
    );
  });

  test('blocks startup buy when BTC and ETH benchmark regime is weak', () {
    final service = StartupScannerService();
    final policy = StartupScanPolicy.defaultPolicy.copyWith(
      label: '基准过滤测试',
      minScore: 0.68,
      minTrendScore: 0.58,
      minCompressionScore: 0.12,
      minLiquidityScore: 0.0,
      minMomentumScore: 0.18,
      minMarketTrendBreadth: 0.0,
      minMarketMomentumBreadth: 0.0,
      minMarketTrendBreadthForEntry: 0.0,
      minMarketMomentumBreadthForEntry: 0.0,
      minMarketVolumeBreadthForEntry: 0.0,
      maxRedBreadthForEntry: 1.0,
      maxDeepRedBreadthForEntry: 1.0,
      minVolumeRatio: 1.20,
      minDailyChangePercent: 0.5,
      maxPushCandidates: 3,
    );
    final now = DateTime.now();
    final breakoutCoin = CoinData(
      symbol: 'STARTUSDT',
      lastPrice: 9.18,
      priceChange: 0.34,
      priceChangePercent: 3.8,
      highPrice: 9.22,
      lowPrice: 8.82,
      openPrice: 8.84,
      quoteVolume: 18000000,
      volume: 2100000,
      count: 24000,
    );

    final report = service.analyzeMarket(
      currentCoins: [breakoutCoin],
      dailyHistory: {
        'STARTUSDT': _buildBreakoutDailyBars(now),
        'BTCUSDT': _buildWeakBenchmarkDailyBars(now, 68000),
        'ETHUSDT': _buildWeakBenchmarkDailyBars(now, 3200),
      },
      hourlyHistory: {
        'STARTUSDT': _buildBreakoutHourlyBars(now),
        'BTCUSDT': _buildWeakBenchmarkHourlyBars(now, 68000),
        'ETHUSDT': _buildWeakBenchmarkHourlyBars(now, 3200),
      },
      policy: policy,
    );

    expect(report.marketRegime.allowEntries, isFalse);
    expect(report.marketRegime.benchmarkStatus, 'weak');
    expect(report.marketRegime.benchmarkScore, lessThan(0.56));
    expect(report.candidates, isNotEmpty);
    expect(report.candidates.first.symbol, 'START');
    expect(report.candidates.first.shouldWatch, isTrue);
    expect(report.candidates.first.shouldNotify, isFalse);
    expect(report.candidates.first.blockedByMarket, isTrue);
    expect(report.candidates.first.signalStage, 'blocked_by_market');
  });
}

List<Kline> _buildBreakoutDailyBars(DateTime now) {
  final bars = <Kline>[];
  for (var i = 0; i < 60; i++) {
    final close = i < 30
        ? 8.25 + i * 0.012
        : i < 53
            ? 8.68 + (i - 30) * 0.008
            : 8.92 + (i - 53) * 0.043;
    final high = close + (i >= 53 ? 0.08 : 0.16);
    final low = close - (i >= 53 ? 0.06 : 0.18);
    bars.add(_bar(
      closeTime: now.subtract(Duration(days: 60 - i)),
      open: close - 0.04,
      high: high,
      low: low,
      close: close,
      quoteVolume: i >= 53 ? 5200000 : 3400000,
      tradeCount: i >= 53 ? 12000 : 9000,
    ));
  }
  return bars;
}

List<Kline> _buildWeakDailyBars(DateTime now) {
  final bars = <Kline>[];
  for (var i = 0; i < 60; i++) {
    final close = 4.9 - i * 0.013;
    bars.add(_bar(
      closeTime: now.subtract(Duration(days: 60 - i)),
      open: close + 0.02,
      high: close + 0.12,
      low: close - 0.11,
      close: close,
      quoteVolume: 900000,
      tradeCount: 1200,
    ));
  }
  return bars;
}

List<Kline> _buildFillerDailyBars(DateTime now, int seed) {
  final bars = <Kline>[];
  for (var i = 0; i < 60; i++) {
    final base = 6.0 + seed * 0.18;
    final close = base + i * 0.006;
    bars.add(_bar(
      closeTime: now.subtract(Duration(days: 60 - i)),
      open: close - 0.02,
      high: close + 0.14,
      low: close - 0.12,
      close: close,
      quoteVolume: 2200000 + seed * 200000,
      tradeCount: 7000 + seed * 120,
    ));
  }
  return bars;
}

List<Kline> _buildBreakoutHourlyBars(DateTime now) {
  final bars = <Kline>[];
  for (var i = 0; i < 48; i++) {
    final close = i < 36 ? 8.72 + i * 0.006 : 8.94 + (i - 36) * 0.022;
    final quoteVolume = i >= 45 ? 620000.0 : 210000.0;
    bars.add(_bar(
      closeTime: now.subtract(Duration(hours: 48 - i)),
      open: close - 0.03,
      high: close + 0.05,
      low: close - 0.04,
      close: close,
      quoteVolume: quoteVolume,
      tradeCount: i >= 45 ? 2400 : 1200,
    ));
  }
  return bars;
}

List<Kline> _buildWeakHourlyBars(DateTime now) {
  final bars = <Kline>[];
  for (var i = 0; i < 48; i++) {
    final close = 4.55 - i * 0.008;
    bars.add(_bar(
      closeTime: now.subtract(Duration(hours: 48 - i)),
      open: close + 0.01,
      high: close + 0.03,
      low: close - 0.05,
      close: close,
      quoteVolume: 35000,
      tradeCount: 90,
    ));
  }
  return bars;
}

List<Kline> _buildFillerHourlyBars(DateTime now, int seed) {
  final bars = <Kline>[];
  for (var i = 0; i < 48; i++) {
    final base = 6.0 + seed * 0.18;
    final close = base + i * 0.003;
    bars.add(_bar(
      closeTime: now.subtract(Duration(hours: 48 - i)),
      open: close - 0.01,
      high: close + 0.04,
      low: close - 0.03,
      close: close,
      quoteVolume: 110000 + seed * 12000,
      tradeCount: 500 + seed * 30,
    ));
  }
  return bars;
}

List<Kline> _buildWeakBenchmarkDailyBars(DateTime now, double startPrice) {
  final bars = <Kline>[];
  for (var i = 0; i < 60; i++) {
    final close = startPrice - i * (startPrice * 0.006);
    bars.add(_bar(
      closeTime: now.subtract(Duration(days: 60 - i)),
      open: close + startPrice * 0.002,
      high: close + startPrice * 0.004,
      low: close - startPrice * 0.005,
      close: close,
      quoteVolume: 4200000,
      tradeCount: 18000,
    ));
  }
  return bars;
}

List<Kline> _buildWeakBenchmarkHourlyBars(DateTime now, double startPrice) {
  final bars = <Kline>[];
  for (var i = 0; i < 48; i++) {
    final close = startPrice - i * (startPrice * 0.0014);
    bars.add(_bar(
      closeTime: now.subtract(Duration(hours: 48 - i)),
      open: close + startPrice * 0.0004,
      high: close + startPrice * 0.0008,
      low: close - startPrice * 0.0012,
      close: close,
      quoteVolume: 900000,
      tradeCount: 6000,
    ));
  }
  return bars;
}

Kline _bar({
  required DateTime closeTime,
  required double open,
  required double high,
  required double low,
  required double close,
  required double quoteVolume,
  required int tradeCount,
}) {
  final closeMs = closeTime.millisecondsSinceEpoch;
  return Kline(
    openTime: closeMs - const Duration(hours: 1).inMilliseconds,
    open: open,
    high: high,
    low: low,
    close: close,
    volume: quoteVolume / close,
    closeTime: closeMs,
    quoteVolume: quoteVolume,
    tradeCount: tradeCount,
  );
}
