import 'dart:math';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/recommendation_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RecommendationEngine', () {
    late _Fixture fixture;

    setUp(() {
      fixture = _buildFixture();
    });

    test('builds a backtest-backed top 3 and avoids weak falling knives', () {
      final result = RecommendationEngine.analyze(
        currentCoins: fixture.coins,
        dailyHistory: fixture.dailyHistory,
        hourlyHistory: fixture.hourlyHistory,
      );

      expect(result.report.testDays, greaterThan(0));
      expect(result.top3, hasLength(3));
      expect(result.rankedCoins, hasLength(fixture.coins.length));

      final topSymbols = result.top3.map((coin) => coin.displayName).toList();
      expect(topSymbols, contains('ALP'));
      expect(topSymbols, isNot(contains('OMG')));

      final alpha = result.rankedCoins.firstWhere(
        (coin) => coin.displayName == 'ALP',
      );
      expect(alpha.thirtyDayChange, greaterThan(20));
      expect(alpha.historicalScore, greaterThan(0.55));
    });

    test('emits an actionable hourly entry alert for aligned breakouts', () {
      final result = RecommendationEngine.analyze(
        currentCoins: fixture.coins,
        dailyHistory: fixture.dailyHistory,
        hourlyHistory: fixture.hourlyHistory,
      );

      final alphaCoin = result.rankedCoins.firstWhere(
        (coin) => coin.displayName == 'ALP',
      );
      final alphaAlert = result.entryAlerts.firstWhere(
        (alert) => alert.symbol == 'ALP',
      );

      expect(alphaCoin.entryScore, greaterThan(0.76));
      expect(alphaCoin.timingLabel, '可入场');
      expect(alphaAlert.timingLabel, '可入场');
      expect(alphaAlert.shouldNotify, isTrue);
    });
  });
}

_Fixture _buildFixture() {
  final dailyHistory = <String, List<Kline>>{
    'ALPUSDT': _barsFromCloses(
      _alphaDailyCloses(),
      stepHours: 24,
      baseVolume: 180,
    ),
    'BETUSDT': _barsFromCloses(
      _betaDailyCloses(),
      stepHours: 24,
      baseVolume: 150,
    ),
    'GAMUSDT': _barsFromCloses(
      _gammaDailyCloses(),
      stepHours: 24,
      baseVolume: 110,
    ),
    'DIPUSDT': _barsFromCloses(
      _dipDailyCloses(),
      stepHours: 24,
      baseVolume: 130,
    ),
    'OMGUSDT': _barsFromCloses(
      _omgDailyCloses(),
      stepHours: 24,
      baseVolume: 120,
    ),
  };

  final hourlyHistory = <String, List<Kline>>{
    'ALPUSDT': _barsFromCloses(
      _alphaHourlyCloses(),
      stepHours: 1,
      baseVolume: 100,
      customVolumes: [
        ...List.filled(24, 100.0),
        ...List.filled(6, 280.0),
      ],
    ),
    'BETUSDT': _barsFromCloses(
      _betaHourlyCloses(),
      stepHours: 1,
      baseVolume: 95,
    ),
    'GAMUSDT': _barsFromCloses(
      _gammaHourlyCloses(),
      stepHours: 1,
      baseVolume: 90,
    ),
    'DIPUSDT': _barsFromCloses(
      _dipHourlyCloses(),
      stepHours: 1,
      baseVolume: 85,
    ),
    'OMGUSDT': _barsFromCloses(
      _omgHourlyCloses(),
      stepHours: 1,
      baseVolume: 80,
    ),
  };

  final coins = [
    _coin(
      symbol: 'ALPUSDT',
      lastPrice: 160.3,
      changePercent: 2.4,
      highPrice: 178,
      lowPrice: 152.5,
      quoteVolume: 5200000,
      count: 160000,
    ),
    _coin(
      symbol: 'BETUSDT',
      lastPrice: 151.2,
      changePercent: 1.1,
      highPrice: 158,
      lowPrice: 144,
      quoteVolume: 4300000,
      count: 128000,
    ),
    _coin(
      symbol: 'GAMUSDT',
      lastPrice: 111.0,
      changePercent: 0.3,
      highPrice: 114,
      lowPrice: 108.5,
      quoteVolume: 2600000,
      count: 87000,
    ),
    _coin(
      symbol: 'DIPUSDT',
      lastPrice: 86.8,
      changePercent: -3.4,
      highPrice: 94,
      lowPrice: 85.5,
      quoteVolume: 3100000,
      count: 98000,
    ),
    _coin(
      symbol: 'OMGUSDT',
      lastPrice: 97.0,
      changePercent: -5.6,
      highPrice: 108,
      lowPrice: 95.5,
      quoteVolume: 2800000,
      count: 93000,
    ),
  ];

  return _Fixture(
    coins: coins,
    dailyHistory: dailyHistory,
    hourlyHistory: hourlyHistory,
  );
}

CoinData _coin({
  required String symbol,
  required double lastPrice,
  required double changePercent,
  required double highPrice,
  required double lowPrice,
  required double quoteVolume,
  required int count,
}) {
  final openPrice = lastPrice / (1 + changePercent / 100);
  return CoinData(
    symbol: symbol,
    lastPrice: lastPrice,
    priceChange: lastPrice - openPrice,
    priceChangePercent: changePercent,
    highPrice: highPrice,
    lowPrice: lowPrice,
    openPrice: openPrice,
    quoteVolume: quoteVolume,
    volume: quoteVolume / max(lastPrice, 0.0001),
    count: count,
  );
}

List<Kline> _barsFromCloses(
  List<double> closes, {
  required int stepHours,
  required double baseVolume,
  List<double>? customVolumes,
}) {
  final stepMs = Duration(hours: stepHours).inMilliseconds;
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final startMs = nowMs - stepMs * (closes.length + 4);
  final volumes = customVolumes ??
      List<double>.generate(closes.length, (index) => baseVolume + index * 3);

  return List<Kline>.generate(closes.length, (index) {
    final close = closes[index];
    final open = index == 0 ? close * 0.997 : closes[index - 1];
    final high = max(open, close) * 1.001;
    final low = min(open, close) * 0.999;
    final volume = volumes[index];
    final openTime = startMs + stepMs * index;
    final closeTime = openTime + stepMs - 1000;

    return Kline(
      openTime: openTime,
      open: open,
      high: high,
      low: low,
      close: close,
      volume: volume,
      closeTime: closeTime,
      quoteVolume: volume * close,
      tradeCount: 1000 + index * 20,
    );
  });
}

List<double> _alphaDailyCloses() {
  return List<double>.generate(40, (index) {
    if (index < 30) {
      return 100 + index * 2.2;
    }
    return 163.8 - (index - 29) * 0.5;
  });
}

List<double> _betaDailyCloses() {
  return List<double>.generate(40, (index) {
    if (index < 33) {
      return 102 + index * 1.45;
    }
    return 148.4 + (index - 32) * 0.35;
  });
}

List<double> _gammaDailyCloses() {
  return List<double>.generate(40, (index) {
    return 110 + sin(index / 2.2) * 1.8 + index * 0.04;
  });
}

List<double> _dipDailyCloses() {
  return List<double>.generate(40, (index) => 120 - index * 0.85);
}

List<double> _omgDailyCloses() {
  return List<double>.generate(40, (index) => 150 - index * 1.35);
}

List<double> _alphaHourlyCloses() {
  return List<double>.generate(30, (index) {
    if (index < 24) {
      return 150 + index * 0.2;
    }
    if (index < 29) {
      return 154.8 + (index - 23) * 0.9;
    }
    return 160.3;
  });
}

List<double> _betaHourlyCloses() {
  return List<double>.generate(30, (index) => 145 + index * 0.18);
}

List<double> _gammaHourlyCloses() {
  return List<double>.generate(30, (index) {
    return 110 + sin(index / 2.5) * 0.9;
  });
}

List<double> _dipHourlyCloses() {
  return List<double>.generate(30, (index) => 94 - index * 0.22);
}

List<double> _omgHourlyCloses() {
  return List<double>.generate(30, (index) => 108 - index * 0.33);
}

class _Fixture {
  final List<CoinData> coins;
  final Map<String, List<Kline>> dailyHistory;
  final Map<String, List<Kline>> hourlyHistory;

  const _Fixture({
    required this.coins,
    required this.dailyHistory,
    required this.hourlyHistory,
  });
}
