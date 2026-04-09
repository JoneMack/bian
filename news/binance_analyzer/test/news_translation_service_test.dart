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

  test('sends longer body content for translation instead of short intro only',
      () async {
    late Uri requestedUri;
    final client = MockClient((request) async {
      requestedUri = request.url;
      return http.Response(
        '[[["比特币关注资金流变化\\n[[NEWS_SPLIT]]\\n第一段中文。第二段中文。第三段中文。","",null,null]],null,"en"]',
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = NewsTranslationService(client: client);
    final longBody = [
      'Bitcoin held above key support while traders monitored ETF flow data.',
      'Analysts said market breadth improved as large-cap tokens stabilized.',
      'Funds rotated back into higher-beta names during the US session.',
      'Derivatives positioning also showed a modest improvement in risk appetite.',
    ].join(' ');

    final item = NewsItem(
      id: '3',
      title: 'Bitcoin traders watch ETF flow',
      body: longBody,
      url: 'https://example.com/story-3',
      source: 'Cointelegraph',
      imageUrl: '',
      publishedAt: DateTime(2026, 4, 2, 9),
      tags: const ['BTC'],
    );

    final localized = await service.localizeNewsItem(item);

    expect(localized.translatedBody, contains('第一段中文'));
    expect(requestedUri.queryParameters['q'], contains('higher-beta names'));
    expect(requestedUri.queryParameters['q']!.length, greaterThan(180));
  });
}
