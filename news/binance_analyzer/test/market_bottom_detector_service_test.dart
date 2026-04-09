import 'package:flutter_test/flutter_test.dart';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/market_bottom_detector_service.dart';

void main() {
  test('detects broad selloff rebound and surfaces bottom candidates', () {
    final service = MarketBottomDetectorService();
    const policy = MarketBottomPolicy(
      label: '测试底部策略',
      minAnalyzedSymbols: 6,
      minRedBreadth: 0.50,
      minDownBreadth: 0.20,
      minCapitulationBreadth: 0.10,
      minNearLowBreadth: 0.10,
      minReboundBreadth: 0.10,
      minRecoveryBreadth: 0.05,
      minVolumeBreadth: 0.05,
      minAlertScore: 0.45,
      maxDistanceTo45dLow: 12.0,
      minBounceFrom12hLow: 0.8,
      minVolumeRatio: 0.9,
      minCandidateScore: 0.45,
      minCandidateLiquidityScore: 0.0,
      minCandidateDrawdownPercent: 5.0,
      maxCandidateDistanceTo45dLow: 12.0,
      maxCandidateBounceFrom12hLow: 12.0,
      maxPushCandidates: 2,
      cooldownHours: 12,
    );
    final now = DateTime.now();

    final leader = CoinData(
      symbol: 'BTMUSDT',
      lastPrice: 7.32,
      priceChange: -0.49,
      priceChangePercent: -6.3,
      highPrice: 7.92,
      lowPrice: 6.98,
      openPrice: 7.81,
      quoteVolume: 24000000,
      volume: 3200000,
      count: 26000,
    );
    final second = CoinData(
      symbol: 'ALTUSDT',
      lastPrice: 4.86,
      priceChange: -0.32,
      priceChangePercent: -5.8,
      highPrice: 5.28,
      lowPrice: 4.62,
      openPrice: 5.18,
      quoteVolume: 14000000,
      volume: 2600000,
      count: 19000,
    );
    final fillers = List.generate(
      6,
      (index) => CoinData(
        symbol: 'FILL${index}USDT',
        lastPrice: 2.8 + index * 0.18,
        priceChange: -0.14,
        priceChangePercent: -4.5 - index * 0.35,
        highPrice: 3.0 + index * 0.18,
        lowPrice: 2.62 + index * 0.18,
        openPrice: 2.95 + index * 0.18,
        quoteVolume: 6000000 + index * 600000,
        volume: 1800000,
        count: 11000 + index * 600,
      ),
    );

    final dailyHistory = <String, List<Kline>>{
      'BTMUSDT': _buildSelloffDailyBars(now, peak: 10.8, floor: 7.0, end: 7.28),
      'ALTUSDT': _buildSelloffDailyBars(now, peak: 6.8, floor: 4.58, end: 4.82),
      for (var i = 0; i < fillers.length; i++)
        'FILL${i}USDT': _buildSelloffDailyBars(
          now,
          peak: 4.2 + i * 0.25,
          floor: 2.5 + i * 0.18,
          end: 2.75 + i * 0.18,
        ),
    };
    final hourlyHistory = <String, List<Kline>>{
      'BTMUSDT':
          _buildReboundHourlyBars(now, start: 7.95, low: 6.92, end: 7.25),
      'ALTUSDT':
          _buildReboundHourlyBars(now, start: 5.22, low: 4.60, end: 4.81),
      for (var i = 0; i < fillers.length; i++)
        'FILL${i}USDT': _buildReboundHourlyBars(
          now,
          start: 3.15 + i * 0.18,
          low: 2.55 + i * 0.18,
          end: 2.76 + i * 0.18,
        ),
    };

    final report = service.analyzeMarket(
      currentCoins: [leader, second, ...fillers],
      dailyHistory: dailyHistory,
      hourlyHistory: hourlyHistory,
      policy: policy,
    );

    expect(report.shouldNotify, isTrue);
    expect(report.actionableCandidates, isNotEmpty);
    expect(report.actionableCandidates.first.symbol, 'BTM');
    expect(
      report.actionableCandidates.map((item) => item.symbol),
      contains('ALT'),
    );
  });

  test('does not trigger when market is calm and not in panic', () {
    final service = MarketBottomDetectorService();
    final now = DateTime.now();
    final coins = List.generate(
      7,
      (index) => CoinData(
        symbol: 'CALM${index}USDT',
        lastPrice: 4.2 + index * 0.35,
        priceChange: 0.03,
        priceChangePercent: index.isEven ? 0.8 : -0.6,
        highPrice: 4.36 + index * 0.35,
        lowPrice: 4.08 + index * 0.35,
        openPrice: 4.17 + index * 0.35,
        quoteVolume: 4000000 + index * 300000,
        volume: 1200000,
        count: 8000 + index * 300,
      ),
    );

    final dailyHistory = <String, List<Kline>>{
      for (var i = 0; i < coins.length; i++)
        'CALM${i}USDT': _buildCalmDailyBars(now, 4.0 + i * 0.3),
    };
    final hourlyHistory = <String, List<Kline>>{
      for (var i = 0; i < coins.length; i++)
        'CALM${i}USDT': _buildCalmHourlyBars(now, 4.1 + i * 0.3),
    };

    final report = service.analyzeMarket(
      currentCoins: coins,
      dailyHistory: dailyHistory,
      hourlyHistory: hourlyHistory,
      policy: const MarketBottomPolicy(
        label: '测试底部策略',
        minAnalyzedSymbols: 6,
        minRedBreadth: 0.65,
        minDownBreadth: 0.35,
        minCapitulationBreadth: 0.20,
        minNearLowBreadth: 0.18,
        minReboundBreadth: 0.12,
        minRecoveryBreadth: 0.10,
        minVolumeBreadth: 0.10,
        minAlertScore: 0.52,
        maxDistanceTo45dLow: 8.5,
        minBounceFrom12hLow: 1.2,
        minVolumeRatio: 1.0,
        minCandidateScore: 0.54,
        minCandidateLiquidityScore: 0.0,
        minCandidateDrawdownPercent: 8.0,
        maxCandidateDistanceTo45dLow: 9.0,
        maxCandidateBounceFrom12hLow: 10.0,
        maxPushCandidates: 2,
        cooldownHours: 12,
      ),
    );

    expect(report.shouldNotify, isFalse);
    expect(report.notes, contains('尚未满足'));
  });
}

List<Kline> _buildSelloffDailyBars(
  DateTime now, {
  required double peak,
  required double floor,
  required double end,
}) {
  final bars = <Kline>[];
  for (var i = 0; i < 60; i++) {
    final close = i < 24
        ? peak - i * (peak * 0.006)
        : i < 50
            ? peak - 0.9 - (i - 24) * ((peak - floor - 1.0) / 26)
            : floor + (i - 50) * ((end - floor) / 10);
    bars.add(_bar(
      closeTime: now.subtract(Duration(days: 60 - i)),
      open: close + 0.08,
      high: close + 0.22,
      low: close - 0.20,
      close: close,
      quoteVolume: i >= 50 ? 4200000 : 2600000,
      tradeCount: i >= 50 ? 15000 : 10000,
    ));
  }
  return bars;
}

List<Kline> _buildReboundHourlyBars(
  DateTime now, {
  required double start,
  required double low,
  required double end,
}) {
  final bars = <Kline>[];
  for (var i = 0; i < 40; i++) {
    final close = i < 28
        ? start - i * ((start - low) / 28)
        : low + (i - 28) * ((end - low) / 12);
    final quoteVolume = i >= 36 ? 860000.0 : 280000.0;
    bars.add(_bar(
      closeTime: now.subtract(Duration(hours: 40 - i)),
      open: close + 0.03,
      high: close + 0.06,
      low: close - 0.08,
      close: close,
      quoteVolume: quoteVolume,
      tradeCount: i >= 36 ? 2800 : 900,
    ));
  }
  return bars;
}

List<Kline> _buildCalmDailyBars(DateTime now, double base) {
  final bars = <Kline>[];
  for (var i = 0; i < 60; i++) {
    final close = base + i * 0.01;
    bars.add(_bar(
      closeTime: now.subtract(Duration(days: 60 - i)),
      open: close - 0.03,
      high: close + 0.09,
      low: close - 0.08,
      close: close,
      quoteVolume: 2200000,
      tradeCount: 7800,
    ));
  }
  return bars;
}

List<Kline> _buildCalmHourlyBars(DateTime now, double base) {
  final bars = <Kline>[];
  for (var i = 0; i < 40; i++) {
    final close = base + i * 0.004;
    bars.add(_bar(
      closeTime: now.subtract(Duration(hours: 40 - i)),
      open: close - 0.01,
      high: close + 0.03,
      low: close - 0.03,
      close: close,
      quoteVolume: 160000,
      tradeCount: 520,
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
