import 'package:binance_analyzer/services/backend_api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('fetches remote market snapshot and restores computed coin fields',
      () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), contains('/market-snapshot'));
      expect(request.url.queryParameters['symbols'], 'FETUSDT,TONUSDT');
      expect(request.url.queryParameters['refresh'], '1');

      return http.Response(
        '''
        {
          "allCoins": [
            {
              "symbol": "FETUSDT",
              "lastPrice": 1.23,
              "priceChange": 0.12,
              "priceChangePercent": 10.8,
              "highPrice": 1.30,
              "lowPrice": 1.05,
              "openPrice": 1.11,
              "quoteVolume": 1234567,
              "volume": 1000000,
              "count": 3210,
              "score": 0.88,
              "historicalScore": 0.81,
              "entryScore": 0.79,
              "expectedEdge": 0.14,
              "thirtyDayChange": 42.3,
              "sevenDayChange": 9.7,
              "daysSinceSurge": 5,
              "level": "strongBuy",
              "recommendation": "优先关注",
              "reason": "轮动与量能共振",
              "timingLabel": "可入场",
              "timingReason": "突破后回踩稳住"
            }
          ],
          "top3": [
            {
              "symbol": "FETUSDT",
              "lastPrice": 1.23,
              "priceChange": 0.12,
              "priceChangePercent": 10.8,
              "highPrice": 1.30,
              "lowPrice": 1.05,
              "openPrice": 1.11,
              "quoteVolume": 1234567,
              "volume": 1000000,
              "count": 3210,
              "score": 0.88,
              "historicalScore": 0.81,
              "entryScore": 0.79,
              "expectedEdge": 0.14,
              "thirtyDayChange": 42.3,
              "sevenDayChange": 9.7,
              "daysSinceSurge": 5,
              "level": "strongBuy",
              "recommendation": "优先关注",
              "reason": "轮动与量能共振",
              "timingLabel": "可入场",
              "timingReason": "突破后回踩稳住"
            }
          ],
          "updatedAt": "2026-04-03T12:00:00.000Z",
          "watchlistSymbols": ["FETUSDT", "TONUSDT"],
          "entryAlerts": [
            {
              "symbol": "FET",
              "timingLabel": "可入场",
              "timingReason": "突破后回踩稳住",
              "currentPrice": 1.23,
              "dayChangePercent": 10.8,
              "totalScore": 0.88,
              "entryScore": 0.79,
              "volumeRatio": 1.6,
              "breakoutDistance": 0.9,
              "pullbackPercent": 1.2,
              "shouldNotify": true
            }
          ],
          "engineReport": {
            "presetId": "rotation",
            "presetLabel": "轮动优先",
            "testDays": 28,
            "avgTop3Return": 3.4,
            "benchmarkReturn": 1.1,
            "winRate": 0.67,
            "positiveDaysRate": 0.71,
            "generatedAt": "2026-04-03T11:58:00.000Z"
          }
        }
        ''',
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = BackendApiService(
      client: client,
      baseUrlOverride: 'https://example.com/api/',
    );

    final snapshot = await service.fetchMarketSnapshot(
      symbols: const ['ton', 'fetusdt'],
      forceRefresh: true,
    );

    expect(snapshot.allCoins, hasLength(1));
    expect(snapshot.top3.single.symbol, 'FETUSDT');
    expect(snapshot.top3.single.score, closeTo(0.88, 0.0001));
    expect(snapshot.top3.single.level.name, 'strongBuy');
    expect(snapshot.top3.single.timingLabel, '可入场');
    expect(snapshot.watchlistSymbols, ['FETUSDT', 'TONUSDT']);
    expect(snapshot.entryAlerts.single.shouldNotify, isTrue);
    expect(snapshot.engineReport?.presetLabel, '轮动优先');
  });

  test('fetches remote news feed with translated content', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), contains('/news'));
      expect(request.url.queryParameters['limit'], '20');
      expect(request.url.queryParameters['categories'], 'BTC,ETH');
      expect(request.url.queryParameters['refresh'], '1');

      return http.Response(
        '''
        {
          "items": [
            {
              "id": "story-1",
              "title": "Bitcoin traders watch ETF flows",
              "body": "ETF demand lifted sentiment across majors.",
              "translatedTitle": "比特币交易员关注 ETF 资金流",
              "translatedBody": "ETF 需求回升，带动主流币情绪改善。",
              "url": "https://example.com/story-1",
              "source": "Cointelegraph",
              "imageUrl": "https://example.com/story-1.png",
              "publishedAt": "2026-04-08T12:00:00.000Z",
              "tags": ["BTC", "ETF"],
              "isHot": true
            }
          ],
          "updatedAt": "2026-04-08T12:01:00.000Z"
        }
        ''',
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = BackendApiService(
      client: client,
      baseUrlOverride: 'https://example.com/api',
    );

    final items = await service.fetchNewsFeed(
      limit: 20,
      categories: const ['eth', 'btc'],
      forceRefresh: true,
    );

    expect(items, hasLength(1));
    expect(items.single.title, 'Bitcoin traders watch ETF flows');
    expect(items.single.translatedTitle, '比特币交易员关注 ETF 资金流');
    expect(items.single.translatedBody, 'ETF 需求回升，带动主流币情绪改善。');
    expect(items.single.displayTitle, '比特币交易员关注 ETF 资金流');
    expect(items.single.source, 'Cointelegraph');
    expect(items.single.tags, ['BTC', 'ETF']);
    expect(items.single.isHot, isTrue);
  });
}
