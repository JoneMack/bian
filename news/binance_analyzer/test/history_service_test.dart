import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/models/recommendation_history.dart';
import 'package:binance_analyzer/services/history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('history service calculates extended review stats', () async {
    final history = [
      DailyRecommendation(
        date: DateTime(2026, 4, 2),
        picks: [
          PickRecord(
            symbol: 'FET',
            entryPrice: 1,
            date: DateTime(2026, 4, 2),
            score: 0.72,
            timingLabel: '可入场',
            signalSource: 'feishu',
            signalType: 'buy',
            exitPrice: 1.08,
            isWin: true,
          ),
          PickRecord(
            symbol: 'TON',
            entryPrice: 2,
            date: DateTime(2026, 4, 2),
            score: 0.64,
            timingLabel: '临近买点',
            signalSource: 'feishu',
            signalType: 'buy',
            exitPrice: 1.94,
            isWin: false,
          ),
          PickRecord(
            symbol: 'AVAX',
            entryPrice: 3,
            date: DateTime(2026, 4, 2),
            signalSource: 'feishu',
            signalType: 'sell',
          ),
        ],
      ),
      DailyRecommendation(
        date: DateTime(2026, 4, 1),
        picks: [
          PickRecord(
            symbol: 'FET',
            entryPrice: 1,
            date: DateTime(2026, 4, 1),
            score: 0.66,
            timingLabel: '继续等待',
            signalSource: 'legacy',
            exitPrice: 1.03,
            isWin: true,
          ),
          PickRecord(
            symbol: 'LINK',
            entryPrice: 10,
            date: DateTime(2026, 4, 1),
            score: 0.81,
            timingLabel: '止盈减仓',
            signalSource: 'feishu',
            signalType: 'sell',
            exitPrice: 9.50,
            isWin: true,
          ),
        ],
      ),
    ];

    SharedPreferences.setMockInitialValues({
      'daily_recommendations_v2': DailyRecommendation.encodeList(history),
    });

    final stats = await HistoryService().calcStats();

    expect(stats['total'], 3);
    expect(stats['wins'], 2);
    expect(stats['pending'], 1);
    expect(stats['bestSymbol'], 'FET');
    expect(stats['worstSymbol'], 'TON');
    expect(stats['highConfidenceTotal'], 3);
    expect(stats['actionableTotal'], 2);
    expect(stats['buyTotal'], 2);
    expect(stats['sellTotal'], 1);
    expect((stats['avgReturn'] as double), closeTo(3.3333, 0.001));
    expect((stats['highConfidenceWinRate'] as double), closeTo(2 / 3, 0.001));
    expect((stats['actionableWinRate'] as double), closeTo(0.5, 0.001));
  });

  test('sell signal settles as win when next price is lower', () async {
    final history = [
      DailyRecommendation(
        date: DateTime.now().subtract(const Duration(days: 1)),
        picks: [
          PickRecord(
            symbol: 'FET',
            entryPrice: 1.0,
            date: DateTime.now().subtract(const Duration(days: 1)),
            timingLabel: '止损离场',
            signalSource: 'feishu',
            signalType: 'sell',
          ),
        ],
      ),
    ];

    SharedPreferences.setMockInitialValues({
      'daily_recommendations_v2': DailyRecommendation.encodeList(history),
    });

    await HistoryService().settleYesterday([
      CoinData(
        symbol: 'FETUSDT',
        lastPrice: 0.92,
        priceChange: -0.08,
        priceChangePercent: -8,
        highPrice: 1.02,
        lowPrice: 0.90,
        openPrice: 1.0,
        quoteVolume: 1000,
        volume: 1000,
        count: 100,
      ),
    ]);

    final loaded = await HistoryService().loadHistory();
    expect(loaded.single.picks.single.isWin, isTrue);
    expect(loaded.single.picks.single.changePercent, closeTo(8.0, 0.001));
  });
}
