import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
            exitPrice: 1.08,
            isWin: true,
          ),
          PickRecord(
            symbol: 'TON',
            entryPrice: 2,
            date: DateTime(2026, 4, 2),
            score: 0.64,
            timingLabel: '临近买点',
            exitPrice: 1.94,
            isWin: false,
          ),
          PickRecord(
            symbol: 'AVAX',
            entryPrice: 3,
            date: DateTime(2026, 4, 2),
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
            exitPrice: 1.03,
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
    expect((stats['avgReturn'] as double), closeTo(2.6667, 0.001));
    expect((stats['highConfidenceWinRate'] as double), closeTo(2 / 3, 0.001));
    expect((stats['actionableWinRate'] as double), closeTo(0.5, 0.001));
  });
}
