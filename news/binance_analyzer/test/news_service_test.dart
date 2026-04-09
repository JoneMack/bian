import 'package:flutter_test/flutter_test.dart';

import 'package:binance_analyzer/models/news_item.dart';
import 'package:binance_analyzer/services/news_service.dart';

void main() {
  test('parseRssFeed parses Cointelegraph style items', () {
    const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
  <channel>
    <item>
      <title><![CDATA[Bitcoin ETF inflows spike as AI tokens rally]]></title>
      <pubDate>Thu, 02 Apr 2026 11:04:27 +0100</pubDate>
      <link><![CDATA[https://cointelegraph.com/news/sample-story?utm_source=rss_feed]]></link>
      <description><![CDATA[<p><img src="https://images.cointelegraph.com/cover.jpg" /></p><p>Bitcoin and AI related tokens moved sharply higher.</p>]]></description>
      <media:content url="https://images.cointelegraph.com/cover.jpg" medium="image" />
      <category><![CDATA[Bitcoin]]></category>
      <category><![CDATA[ETF]]></category>
      <dc:creator>Cointelegraph by Jane Doe</dc:creator>
    </item>
  </channel>
</rss>
''';

    final items = NewsService.parseRssFeed(xml, sourceName: 'Cointelegraph');

    expect(items, hasLength(1));
    expect(items.first.title, 'Bitcoin ETF inflows spike as AI tokens rally');
    expect(items.first.source, 'Cointelegraph');
    expect(items.first.imageUrl, 'https://images.cointelegraph.com/cover.jpg');
    expect(items.first.url, 'https://cointelegraph.com/news/sample-story');
    expect(items.first.body, contains('Bitcoin and AI related tokens'));
    expect(items.first.tags, containsAll(['Bitcoin', 'ETF', 'BTC', 'AI']));
    expect(items.first.isHot, isTrue);
  });

  test('parseRssFeed parses Decrypt style enclosure images', () {
    const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <item>
      <title>Markets slide after SEC lawsuit expands</title>
      <link>https://decrypt.co/sample-story</link>
      <pubDate>Thu, 02 Apr 2026 09:53:19 +0000</pubDate>
      <description>Markets slumped as traders reacted to the SEC action.</description>
      <enclosure url="https://cdn.decrypt.co/story.png" length="1000000" type="image/png" />
      <category>Markets</category>
    </item>
  </channel>
</rss>
''';

    final items = NewsService.parseRssFeed(xml, sourceName: 'Decrypt');

    expect(items, hasLength(1));
    expect(items.first.source, 'Decrypt');
    expect(items.first.imageUrl, 'https://cdn.decrypt.co/story.png');
    expect(items.first.body,
        'Markets slumped as traders reacted to the SEC action.');
    expect(items.first.tags, containsAll(['Markets', 'SEC', 'MARKETS']));
    expect(items.first.isHot, isTrue);
  });

  test('extractArticleBody prefers json-ld article body when present', () {
    const html = '''
<!doctype html>
<html>
  <head>
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "NewsArticle",
        "headline": "Bitcoin ETF inflows spike",
        "articleBody": "Bitcoin ETF inflows accelerated overnight as institutional desks added exposure. Traders said AI-related tokens also moved higher after the ETF momentum improved overall sentiment across majors."
      }
    </script>
  </head>
  <body>
    <article><p>Short intro only.</p></article>
  </body>
</html>
''';

    final body = NewsService.extractArticleBody(
      html,
      sourceName: 'Cointelegraph',
    );

    expect(body, contains('institutional desks added exposure'));
    expect(body, contains('overall sentiment across majors'));
    expect(body.length, greaterThan(120));
  });

  test('extractArticleBody falls back to article paragraphs', () {
    const html = '''
<!doctype html>
<html>
  <body>
    <article>
      <p>Advertisement</p>
      <p>Bitcoin held above key support while traders monitored ETF flow data and macro headlines for the next directional move.</p>
      <p>Analysts said the market backdrop improved as large-cap tokens stabilized and volumes rotated back into higher-beta names.</p>
      <p>Read more: some internal link</p>
    </article>
  </body>
</html>
''';

    final body = NewsService.extractArticleBody(
      html,
      sourceName: 'Decrypt',
    );

    expect(body, contains('Bitcoin held above key support'));
    expect(body, contains('higher-beta names'));
    expect(body, isNot(contains('Advertisement')));
    expect(body, isNot(contains('Read more')));
  });

  test('selectActionableSignals marks major listing news as bullish signal',
      () {
    final service = NewsService();
    final items = service.selectActionableSignals([
      NewsItem(
        id: '1',
        title: 'Binance announces FET listing with new trading pairs',
        body:
            'Breaking news: Binance listing for Fetch.ai token starts today and traders expect strong spot volume.',
        translatedTitle: '币安宣布上线 FET 并开放新交易对',
        translatedBody: '突发消息：币安上线 Fetch.ai，市场预期现货成交量快速放大。',
        url: 'https://example.com/fet-listing',
        source: 'Binance',
        imageUrl: '',
        publishedAt: DateTime.now().subtract(const Duration(minutes: 40)),
        tags: const ['FET', 'Binance'],
        isHot: true,
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.first.actionableSignal, isTrue);
    expect(items.first.impactDirection, 'bullish');
    expect(items.first.impactScore, greaterThanOrEqualTo(0.72));
    expect(items.first.eventSummary, contains('上币'));
    expect(items.first.relatedSymbols, contains('FET'));
  });

  test('selectActionableSignals marks exploit news as bearish signal', () {
    final service = NewsService();
    final items = service.selectActionableSignals([
      NewsItem(
        id: '2',
        title: 'Major exploit hits Solana protocol as funds are stolen',
        body:
            'Breaking: hackers exploited a Solana protocol and over \$30 million was stolen, triggering panic across the ecosystem.',
        translatedTitle: 'Solana 生态协议遭重大攻击，资金被盗',
        translatedBody: '突发：黑客利用漏洞攻击 Solana 协议，超 3000 万美元资产被盗，引发市场恐慌。',
        url: 'https://example.com/sol-hack',
        source: 'Cointelegraph',
        imageUrl: '',
        publishedAt: DateTime.now().subtract(const Duration(minutes: 25)),
        tags: const ['SOL'],
        isHot: true,
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.first.actionableSignal, isTrue);
    expect(items.first.impactDirection, 'bearish');
    expect(items.first.eventSummary, contains('安全事件'));
    expect(items.first.relatedSymbols, contains('SOL'));
  });
}
