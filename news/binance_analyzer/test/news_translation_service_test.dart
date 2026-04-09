import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:binance_analyzer/models/news_item.dart';
import 'package:binance_analyzer/services/news_translation_service.dart';

void main() {
  test('uses remote translation when endpoint responds', () async {
    final client = MockClient((request) async {
      return http.Response(
        '[[["比特币 ETF 资金流入激增，AI 代币走强\\n[[NEWS_SPLIT]]\\n比特币和 AI 相关代币大幅上涨。","",null,null]],null,"en"]',
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = NewsTranslationService(client: client);
    final item = NewsItem(
      id: '1',
      title: 'Bitcoin ETF inflows spike as AI tokens rally',
      body: 'Bitcoin and AI related tokens moved sharply higher.',
      url: 'https://example.com/story',
      source: 'Cointelegraph',
      imageUrl: '',
      publishedAt: DateTime(2026, 4, 2, 12),
      tags: const ['BTC', 'AI'],
    );

    final localized = await service.localizeNewsItem(item);

    expect(localized.translatedTitle, '比特币 ETF 资金流入激增，AI 代币走强');
    expect(localized.translatedBody, '比特币和 AI 相关代币大幅上涨。');
    expect(localized.displayTitle, localized.translatedTitle);
    expect(localized.hasChineseTranslation, isTrue);
  });

  test('falls back to local chinese brief when remote translation fails',
      () async {
    final client = MockClient((request) async {
      return http.Response('server error', 500);
    });

    final service = NewsTranslationService(client: client);
    final item = NewsItem(
      id: '2',
      title: 'Markets slide after SEC lawsuit expands',
      body: 'Markets slumped as traders reacted to the SEC action.',
      url: 'https://example.com/story-2',
      source: 'Decrypt',
      imageUrl: '',
      publishedAt: DateTime(2026, 4, 2, 9),
      tags: const ['SEC'],
    );

    final localized = await service.localizeNewsItem(item);

    expect(localized.translatedTitle, contains('市场'));
    expect(localized.translatedTitle, contains('SEC'));
    expect(localized.translatedTitle, contains('诉讼'));
    expect(localized.translatedBody, startsWith('要点：'));
    expect(localized.displayDetailBody, contains('市场'));
    expect(localized.displaySummary, isNotEmpty);
    expect(localized.hasChineseTranslation, isTrue);
  });
}
