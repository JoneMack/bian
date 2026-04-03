import 'package:flutter_test/flutter_test.dart';

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
}
