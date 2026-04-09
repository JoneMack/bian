import 'dart:convert';
import 'dart:math';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/news_item.dart';
import 'news_translation_service.dart';

/// 加密货币资讯服务
/// 当前优先级：Cointelegraph RSS → Decrypt RSS → Binance 公告
///
/// 原来的 CryptoCompare 新闻接口在 2026-04-02 实测已要求 API Key，
/// 会直接返回 "You need a valid auth key or api key to access this endpoint"，
/// 因此改为无需鉴权的 RSS 源，避免资讯页首屏一直报错。
class NewsService {
  static const Map<String, String> _headers = {
    'User-Agent': 'binance-analyzer/1.0 (Flutter)',
    'Accept': 'application/json, application/xml, text/xml;q=0.9, */*;q=0.8',
  };
  static const Map<String, String> _articleHeaders = {
    'User-Agent': 'Mozilla/5.0 (compatible; binance-analyzer/1.0)',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  };

  static const List<_RssSource> _rssSources = [
    _RssSource(
      name: 'Cointelegraph',
      url: 'https://cointelegraph.com/rss',
    ),
    _RssSource(
      name: 'Decrypt',
      url: 'https://decrypt.co/feed',
    ),
  ];

  static const String _binanceAnnouncementsUrl =
      'https://www.binance.com/bapi/composite/v1/public/cms/article/list/query';

  static const List<String> _hotKeywords = [
    'breaking',
    'bitcoin',
    'btc',
    'ethereum',
    'eth',
    'solana',
    'etf',
    'sec',
    'hack',
    'exploit',
    'liquidation',
    'listing',
    'lawsuit',
    'binance',
    'fed',
    'cpi',
    'tariff',
    'trump',
    'war',
    'ai',
  ];

  static const Map<String, List<String>> _symbolAliases = {
    'BTC': ['BTC', 'BITCOIN'],
    'ETH': ['ETH', 'ETHEREUM'],
    'SOL': ['SOL', 'SOLANA'],
    'BNB': ['BNB', 'BINANCE COIN'],
    'XRP': ['XRP', 'RIPPLE'],
    'DOGE': ['DOGE', 'DOGECOIN'],
    'ADA': ['ADA', 'CARDANO'],
    'AVAX': ['AVAX', 'AVALANCHE'],
    'LINK': ['LINK', 'CHAINLINK'],
    'FET': ['FET', 'FETCH AI', 'FETCH.AI'],
    'ARB': ['ARB', 'ARBITRUM'],
    'OP': ['OP', 'OPTIMISM'],
    'TON': ['TON', 'TONCOIN'],
    'LTC': ['LTC', 'LITECOIN'],
  };

  static const Map<String, double> _bullishKeywords = {
    'listing': 0.42,
    'listings': 0.42,
    'listed': 0.42,
    'launchpool': 0.40,
    'launchpad': 0.40,
    'approval': 0.34,
    'approved': 0.34,
    'etf inflows': 0.30,
    'inflows spike': 0.28,
    'buyback': 0.32,
    'burn': 0.26,
    'partnership': 0.22,
    'mainnet': 0.24,
    'upgrade': 0.18,
    'treasury buy': 0.26,
    'accumulation': 0.16,
    'record high': 0.14,
    'all-time high': 0.14,
    'surges': 0.12,
    'rally': 0.10,
    'rebounds': 0.08,
  };

  static const Map<String, double> _bearishKeywords = {
    'delist': 0.44,
    'delisting': 0.44,
    'delisted': 0.44,
    'hack': 0.44,
    'exploit': 0.42,
    'breach': 0.40,
    'stolen': 0.32,
    'lawsuit': 0.36,
    'charged': 0.32,
    'investigation': 0.28,
    'bankruptcy': 0.36,
    'liquidation': 0.34,
    'liquidations': 0.34,
    'ban': 0.30,
    'suspend': 0.28,
    'suspended': 0.28,
    'outflows': 0.24,
    'outflow': 0.24,
    'sell-off': 0.18,
    'selloff': 0.18,
    'war': 0.16,
    'tariff': 0.16,
    'cpi hotter': 0.22,
    'hawkish': 0.22,
    'rate hike': 0.22,
    'slumps': 0.10,
    'drops': 0.10,
  };

  final _translator = NewsTranslationService();
  final Map<String, String> _articleBodyCache = {};

  /// 获取最新资讯（最多 [limit] 条）
  ///
  /// [categories] 现在不再传给远端接口过滤，而是在本地做相关新闻增强和排序，
  /// 这样不会因为第三方 API 的鉴权变化导致整页加载失败。
  Future<List<NewsItem>> fetchNews({
    int limit = 30,
    List<String> categories = const [],
  }) async {
    final relatedSymbols = categories
        .map((item) => item.trim().toUpperCase())
        .where((item) => item.isNotEmpty)
        .toList();

    final results = await Future.wait([
      for (final source in _rssSources)
        _guardedFetch(source.name, () => _fetchRssSource(source)),
      _guardedFetch('Binance', _fetchBinanceAnnouncements),
    ]);

    final merged = <NewsItem>[];
    final failures = <String>[];

    for (final result in results) {
      if (result.error != null) {
        failures.add('${result.source}: ${result.error}');
        continue;
      }
      merged.addAll(result.items);
    }

    final deduped = _dedupeNews(merged)
        .map((item) => _decorateNewsItem(item, relatedSymbols))
        .toList();

    if (deduped.isEmpty) {
      final detail = failures.isEmpty ? '未知错误' : failures.join('\n');
      throw Exception('资讯源暂时不可用，请稍后重试\n$detail');
    }

    deduped.sort((a, b) => _compareNews(a, b, relatedSymbols));
    final selected = await _hydrateArticleBodies(deduped.take(limit).toList());
    final localized = await _translator.translateNewsItems(selected);
    return localized.map(_enrichSignalAssessment).toList();
  }

  List<NewsItem> selectActionableSignals(
    List<NewsItem> items, {
    int maxCandidates = 3,
    Duration maxAge = const Duration(hours: 12),
  }) {
    final now = DateTime.now();
    final candidates = items
        .map(_enrichSignalAssessment)
        .where(
          (item) =>
              item.actionableSignal &&
              now.difference(item.publishedAt) <= maxAge,
        )
        .toList()
      ..sort((a, b) {
        final byScore = b.impactScore.compareTo(a.impactScore);
        if (byScore != 0) return byScore;
        return b.publishedAt.compareTo(a.publishedAt);
      });
    return candidates.take(maxCandidates).toList();
  }

  Future<List<NewsItem>> _hydrateArticleBodies(List<NewsItem> items) async {
    final results = <NewsItem>[];
    for (final chunk in _chunk(items, 4)) {
      final enriched = await Future.wait(chunk.map(_hydrateArticleBody));
      results.addAll(enriched);
    }
    return results;
  }

  Future<NewsItem> _hydrateArticleBody(NewsItem item) async {
    if (item.source == 'Binance' || item.url.trim().isEmpty) {
      return item;
    }

    final cached = _articleBodyCache[item.url];
    if (cached != null && cached.isNotEmpty) {
      return item.copyWith(body: cached);
    }

    try {
      final response = await http
          .get(Uri.parse(item.url), headers: _articleHeaders)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return item;
      }

      final html = utf8.decode(response.bodyBytes, allowMalformed: true);
      final extracted = extractArticleBody(
        html,
        sourceName: item.source,
      );
      if (extracted.isEmpty || extracted.length <= item.body.length + 40) {
        return item;
      }

      _articleBodyCache[item.url] = extracted;
      return item.copyWith(body: extracted);
    } catch (_) {
      return item;
    }
  }

  Future<_SourceFetchResult> _guardedFetch(
    String source,
    Future<List<NewsItem>> Function() loader,
  ) async {
    try {
      final items = await loader();
      return _SourceFetchResult(source: source, items: items);
    } catch (error) {
      return _SourceFetchResult(source: source, error: error.toString());
    }
  }

  Future<List<NewsItem>> _fetchRssSource(_RssSource source) async {
    final resp = await http
        .get(Uri.parse(source.url), headers: _headers)
        .timeout(const Duration(seconds: 12));

    if (resp.statusCode != 200) {
      throw Exception('${source.name} ${resp.statusCode}');
    }

    final xml = utf8.decode(resp.bodyBytes, allowMalformed: true);
    return parseRssFeed(xml, sourceName: source.name);
  }

  Future<List<NewsItem>> _fetchBinanceAnnouncements() async {
    final uri = Uri.parse(_binanceAnnouncementsUrl).replace(queryParameters: {
      'type': '1',
      'pageNo': '1',
      'pageSize': '10',
    });

    final resp = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 8));

    if (resp.statusCode != 200) {
      throw Exception('Binance ${resp.statusCode}');
    }

    final body = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true))
        as Map<String, dynamic>;
    final articles = (body['data']?['articles'] as List<dynamic>?) ?? [];

    return articles
        .map((item) {
          try {
            return NewsItem.fromBinance(item as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<NewsItem>()
        .toList();
  }

  static List<NewsItem> parseRssFeed(
    String xml, {
    required String sourceName,
  }) {
    final items = <NewsItem>[];
    final matches = RegExp(r'<item\b[\s\S]*?<\/item>', caseSensitive: false)
        .allMatches(xml);

    for (final match in matches) {
      final block = match.group(0) ?? '';
      final title = _normalizeText(_extractTag(block, 'title'));
      final link = _cleanUrl(_normalizeText(_extractTag(block, 'link')));
      final description =
          _stripHtml(_normalizeText(_extractTag(block, 'description')));
      final pubDate =
          _parseRssDate(_normalizeText(_extractTag(block, 'pubDate')));
      final imageUrl = _extractImageUrl(block);
      final categories = _extractTags(block, 'category');
      final creator = _normalizeText(_extractTag(block, 'dc:creator'));
      final tags = <String>{
        ...categories,
        ..._extractKeywordTags('$title $description'),
      }.where((item) => item.isNotEmpty).toList();

      if (title.isEmpty || link.isEmpty) continue;

      items.add(
        NewsItem(
          id: link,
          title: title,
          body: description.isNotEmpty ? description : title,
          url: link,
          source: sourceName,
          imageUrl: imageUrl,
          publishedAt: pubDate,
          tags: tags,
          isHot: _isHotArticle('$title $description $creator'),
        ),
      );
    }

    return items;
  }

  NewsItem _decorateNewsItem(NewsItem item, List<String> relatedSymbols) {
    final text = '${item.title} ${item.body}'.toUpperCase();
    final mentions = relatedSymbols
        .where((symbol) => symbol.isNotEmpty && text.contains(symbol))
        .toList();
    final mergedTags = <String>{...item.tags, ...mentions}.toList();

    return NewsItem(
      id: item.id,
      title: item.title,
      body: item.body,
      url: item.url,
      source: item.source,
      imageUrl: item.imageUrl,
      publishedAt: item.publishedAt,
      tags: mergedTags,
      isHot: item.isHot || _isHotArticle('${item.title} ${item.body}'),
    );
  }

  NewsItem _enrichSignalAssessment(NewsItem item) {
    final assessment = _buildImpactAssessment(item);
    return item.copyWith(
      eventSummary: assessment.eventSummary,
      impactSummary: assessment.impactSummary,
      impactDirection: assessment.impactDirection,
      impactScore: assessment.impactScore,
      relatedSymbols: assessment.relatedSymbols,
      actionableSignal: assessment.actionableSignal,
    );
  }

  _NewsImpactAssessment _buildImpactAssessment(NewsItem item) {
    final rawText = [
      item.title,
      item.body,
      item.translatedTitle,
      item.translatedBody,
      item.tags.join(' '),
    ].join(' ');
    final text = rawText.toLowerCase();
    final bullishScore = _scoreKeywordHits(text, _bullishKeywords);
    final bearishScore = _scoreKeywordHits(text, _bearishKeywords);
    final relatedSymbols = _extractRelatedSymbols(rawText, item.tags);
    final age = DateTime.now().difference(item.publishedAt);

    final recencyBoost = age.inHours <= 2
        ? 0.12
        : age.inHours <= 6
            ? 0.08
            : age.inHours <= 12
                ? 0.04
                : 0.0;
    final sourceBoost = item.source == 'Binance' ? 0.10 : 0.04;
    final hotBoost = item.isHot ? 0.08 : 0.0;
    final symbolBoost = relatedSymbols.isNotEmpty ? 0.08 : 0.0;
    final eventBoost = _eventBoost(text);
    final bias = bullishScore - bearishScore;

    final impactDirection = bias >= 0.10
        ? 'bullish'
        : bias <= -0.10
            ? 'bearish'
            : 'neutral';
    final magnitude = (max(bullishScore, bearishScore) +
            recencyBoost +
            sourceBoost +
            hotBoost +
            symbolBoost +
            eventBoost)
        .clamp(0.0, 1.0);
    final eventSummary = _eventSummaryFrom(text, impactDirection);
    final directionLabel = switch (impactDirection) {
      'bullish' => '强利多',
      'bearish' => '强利空',
      _ => '中性'
    };
    final impactedTarget =
        relatedSymbols.isEmpty ? '全市场/主流币' : relatedSymbols.join(', ');
    final impactSummary =
        '$directionLabel | $eventSummary | 影响对象: $impactedTarget';
    final actionableSignal = impactDirection != 'neutral' &&
        magnitude >= 0.72 &&
        age.inHours <= 12 &&
        (relatedSymbols.isNotEmpty || eventSummary.contains('宏观'));

    return _NewsImpactAssessment(
      eventSummary: eventSummary,
      impactSummary: impactSummary,
      impactDirection: impactDirection,
      impactScore: magnitude,
      relatedSymbols: relatedSymbols,
      actionableSignal: actionableSignal,
    );
  }

  double _scoreKeywordHits(String text, Map<String, double> weights) {
    var score = 0.0;
    for (final entry in weights.entries) {
      if (text.contains(entry.key)) {
        score += entry.value;
      }
    }
    return score.clamp(0.0, 0.72);
  }

  double _eventBoost(String text) {
    if (text.contains('listing') ||
        text.contains('delist') ||
        text.contains('hack') ||
        text.contains('exploit') ||
        text.contains('approval')) {
      return 0.10;
    }
    if (text.contains('lawsuit') ||
        text.contains('investigation') ||
        text.contains('tariff') ||
        text.contains('war') ||
        text.contains('cpi')) {
      return 0.06;
    }
    return 0.0;
  }

  List<String> _extractRelatedSymbols(String text, List<String> tags) {
    final upper = text.toUpperCase();
    final tagSet = tags.map((item) => item.toUpperCase()).toSet();
    final related = <String>[];
    for (final entry in _symbolAliases.entries) {
      final matchedAlias = entry.value.any(upper.contains);
      if (matchedAlias || tagSet.contains(entry.key)) {
        related.add(entry.key);
      }
    }
    related.sort();
    return related;
  }

  String _eventSummaryFrom(String text, String impactDirection) {
    if (text.contains('listing') || text.contains('launchpool')) {
      return '交易所上币/交易支持';
    }
    if (text.contains('delist') || text.contains('suspended')) {
      return '下币/交易限制';
    }
    if (text.contains('hack') ||
        text.contains('exploit') ||
        text.contains('breach')) {
      return '安全事件/资产受损';
    }
    if (text.contains('approval') || text.contains('etf')) {
      return 'ETF/监管进展';
    }
    if (text.contains('lawsuit') || text.contains('investigation')) {
      return '监管诉讼/执法风险';
    }
    if (text.contains('tariff') ||
        text.contains('war') ||
        text.contains('cpi') ||
        text.contains('fed')) {
      return '宏观风险事件';
    }
    if (impactDirection == 'bullish') {
      return '偏利多事件';
    }
    if (impactDirection == 'bearish') {
      return '偏利空事件';
    }
    return '资讯观察';
  }

  List<NewsItem> _dedupeNews(List<NewsItem> items) {
    final seen = <String>{};
    final results = <NewsItem>[];

    for (final item in items) {
      final key = '${item.title.toLowerCase()}|${item.url.toLowerCase()}';
      if (seen.add(key)) {
        results.add(item);
      }
    }

    return results;
  }

  int _compareNews(NewsItem a, NewsItem b, List<String> relatedSymbols) {
    final scoreA = _newsPriority(a, relatedSymbols);
    final scoreB = _newsPriority(b, relatedSymbols);

    if (scoreA != scoreB) {
      return scoreB.compareTo(scoreA);
    }

    return b.publishedAt.compareTo(a.publishedAt);
  }

  int _newsPriority(NewsItem item, List<String> relatedSymbols) {
    var score = 0;
    if (item.isHot) score += 100;
    if (item.source == 'Binance') score += 30;
    if (item.isRelatedTo(relatedSymbols)) score += 50;

    final age = DateTime.now().difference(item.publishedAt);
    score -= age.inMinutes ~/ 30;

    return score;
  }

  static String extractArticleBody(
    String html, {
    required String sourceName,
  }) {
    final document = html_parser.parse(html);
    final candidates = <String>[
      _extractFromJsonLd(document.outerHtml),
      _extractFromSelectors(document, sourceName: sourceName),
      _extractMetaDescription(document.outerHtml),
    ].where((item) => item.trim().isNotEmpty).toList();

    if (candidates.isEmpty) {
      return '';
    }

    candidates.sort((a, b) => b.length.compareTo(a.length));
    return _normalizeArticleBody(candidates.first);
  }

  static String _extractFromSelectors(
    dynamic document, {
    required String sourceName,
  }) {
    final selectors = <String>[
      ...switch (sourceName) {
        'Cointelegraph' => const [
            '.post__content-wrapper p',
            '.post__content p',
            '.article-content p',
          ],
        'Decrypt' => const [
            'article p',
            '.post-content p',
            '[class*="PostContent"] p',
            '[class*="article-content"] p',
          ],
        _ => const <String>[],
      },
      'article p',
      'main article p',
      '[itemprop="articleBody"] p',
      '[data-article-body] p',
      '.article__content p',
      '.entry-content p',
    ];

    for (final selector in selectors) {
      final elements = document.querySelectorAll(selector);
      final text = _collectParagraphText(elements);
      if (text.length >= 220) {
        return text;
      }
    }

    return '';
  }

  static String _collectParagraphText(List<dynamic> elements) {
    final lines = <String>[];
    for (final element in elements) {
      final text = _normalizeArticleBody(element.text ?? '');
      if (_isUsefulArticleLine(text) && !lines.contains(text)) {
        lines.add(text);
      }
    }
    return lines.join('\n\n');
  }

  static bool _isUsefulArticleLine(String text) {
    if (text.isEmpty) return false;
    if (text.length < 35) return false;

    final lower = text.toLowerCase();
    const blacklist = [
      'advertisement',
      'read more',
      'listen to article',
      'editor’s note',
      'editors note',
      'subscribe',
      'sign up',
      'disclaimer',
    ];

    return !blacklist.any(lower.contains);
  }

  static String _extractFromJsonLd(String html) {
    final scripts = RegExp(
      r'''<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>''',
      caseSensitive: false,
    ).allMatches(html);

    final candidates = <String>[];
    for (final match in scripts) {
      final raw = _normalizeText(match.group(1) ?? '');
      if (raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        candidates.add(_readJsonLdBody(decoded));
      } catch (_) {
        continue;
      }
    }

    candidates.removeWhere((item) => item.trim().isEmpty);
    candidates.sort((a, b) => b.length.compareTo(a.length));
    return candidates.isEmpty ? '' : candidates.first;
  }

  static String _readJsonLdBody(dynamic node) {
    final found = <String>[];

    void visit(dynamic value) {
      if (value is Map) {
        final articleBody = value['articleBody'];
        if (articleBody is String && articleBody.trim().isNotEmpty) {
          found.add(articleBody);
        }
        final text = value['text'];
        if (text is String && text.trim().isNotEmpty) {
          found.add(text);
        }
        final description = value['description'];
        if (description is String && description.trim().isNotEmpty) {
          found.add(description);
        }
        for (final child in value.values) {
          visit(child);
        }
      } else if (value is List) {
        for (final child in value) {
          visit(child);
        }
      }
    }

    visit(node);
    found.sort((a, b) => b.length.compareTo(a.length));
    return found.isEmpty ? '' : _normalizeArticleBody(found.first);
  }

  static String _extractMetaDescription(String html) {
    final match = RegExp(
      r'''<meta[^>]+(?:name|property)=["'](?:description|og:description)["'][^>]+content=["']([\s\S]*?)["'][^>]*>''',
      caseSensitive: false,
    ).firstMatch(html);

    return _normalizeArticleBody(match?.group(1) ?? '');
  }

  static String _normalizeArticleBody(String text) {
    final normalized = _stripHtml(_normalizeText(text))
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(' .', '.')
        .replaceAll(' ,', ',')
        .trim();
    if (normalized.length <= 1600) {
      return normalized;
    }
    return '${normalized.substring(0, 1600)}...';
  }

  static List<List<T>> _chunk<T>(List<T> items, int size) {
    final chunks = <List<T>>[];
    for (var i = 0; i < items.length; i += size) {
      chunks.add(items.sublist(
        i,
        i + size > items.length ? items.length : i + size,
      ));
    }
    return chunks;
  }

  static String _extractTag(String block, String tag) {
    final pattern = RegExp('<$tag(?:\\s[^>]*)?>([\\s\\S]*?)<\\/$tag>',
        caseSensitive: false);
    final match = pattern.firstMatch(block);
    return match?.group(1) ?? '';
  }

  static List<String> _extractTags(String block, String tag) {
    final pattern = RegExp('<$tag(?:\\s[^>]*)?>([\\s\\S]*?)<\\/$tag>',
        caseSensitive: false);

    return pattern
        .allMatches(block)
        .map((match) => _normalizeText(match.group(1) ?? ''))
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static String _extractImageUrl(String block) {
    final patterns = [
      RegExp(r'<media:content\b[^>]*\burl="([^"]+)"', caseSensitive: false),
      RegExp(r'<media:thumbnail\b[^>]*\burl="([^"]+)"', caseSensitive: false),
      RegExp(r'<enclosure\b[^>]*\burl="([^"]+)"', caseSensitive: false),
      RegExp(r'<img[^>]+src="([^"]+)"', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(block);
      final url = _normalizeText(match?.group(1) ?? '');
      if (url.isNotEmpty) return url;
    }

    return '';
  }

  static String _normalizeText(String input) {
    if (input.isEmpty) return '';

    var text = input
        .replaceAll('<![CDATA[', '')
        .replaceAll(']]>', '')
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ')
        .trim();

    text = _decodeXmlEntities(text);
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _decodeXmlEntities(String text) {
    final named = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&#039;', "'");

    final hexDecoded = named.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (match) {
        final code = int.tryParse(match.group(1) ?? '', radix: 16);
        return code == null ? match.group(0)! : String.fromCharCode(code);
      },
    );

    return hexDecoded.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (match) {
        final code = int.tryParse(match.group(1) ?? '');
        return code == null ? match.group(0)! : String.fromCharCode(code);
      },
    );
  }

  static String _stripHtml(String text) {
    return _normalizeText(
      text
          .replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'<[^>]+>'), ' '),
    );
  }

  static String _cleanUrl(String url) {
    if (url.isEmpty) return '';
    final uri = Uri.tryParse(url);
    if (uri == null) return url;

    final filteredQuery = Map<String, String>.from(uri.queryParameters)
      ..removeWhere((key, _) => key.startsWith('utm_'));

    if (filteredQuery.isEmpty) {
      final cleaned = uri.replace(query: '').toString();
      return cleaned.endsWith('?')
          ? cleaned.substring(0, cleaned.length - 1)
          : cleaned;
    }

    return uri.replace(queryParameters: filteredQuery).toString();
  }

  static DateTime _parseRssDate(String raw) {
    if (raw.isEmpty) return DateTime.now();

    final normalized = raw.replaceAll('GMT', '+0000').trim();
    final match = RegExp(
      r'^\w{3},\s(\d{1,2})\s(\w{3})\s(\d{4})\s(\d{2}):(\d{2}):(\d{2})\s([+-]\d{4})$',
    ).firstMatch(normalized);

    if (match == null) return DateTime.now();

    const months = <String, int>{
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };

    final day = int.tryParse(match.group(1) ?? '');
    final month = months[match.group(2)];
    final year = int.tryParse(match.group(3) ?? '');
    final hour = int.tryParse(match.group(4) ?? '');
    final minute = int.tryParse(match.group(5) ?? '');
    final second = int.tryParse(match.group(6) ?? '');
    final zone = match.group(7) ?? '+0000';

    if ([day, month, year, hour, minute, second].contains(null)) {
      return DateTime.now();
    }

    final sign = zone.startsWith('-') ? -1 : 1;
    final offsetHours = int.tryParse(zone.substring(1, 3)) ?? 0;
    final offsetMinutes = int.tryParse(zone.substring(3, 5)) ?? 0;
    final base = DateTime.utc(year!, month!, day!, hour!, minute!, second!);

    return base.subtract(
      Duration(
        hours: sign * offsetHours,
        minutes: sign * offsetMinutes,
      ),
    );
  }

  static List<String> _extractKeywordTags(String text) {
    final normalized = text.toUpperCase();
    final tags = <String>{};

    const aliases = <String, List<String>>{
      'BTC': ['BTC', 'BITCOIN'],
      'ETH': ['ETH', 'ETHEREUM'],
      'SOL': ['SOL', 'SOLANA'],
      'BNB': ['BNB', 'BINANCE COIN'],
      'AI': ['AI', 'ARTIFICIAL INTELLIGENCE'],
      'ETF': ['ETF'],
      'SEC': ['SEC'],
      'BINANCE': ['BINANCE'],
      'MARKETS': ['MARKETS', 'MARKET'],
    };

    for (final entry in aliases.entries) {
      if (entry.value.any(normalized.contains)) {
        tags.add(entry.key);
        tags.addAll(entry.value.where((item) => item.length > 3));
      }
    }

    return tags.toList();
  }

  static bool _isHotArticle(String text) {
    final lower = text.toLowerCase();
    var hits = 0;

    for (final keyword in _hotKeywords) {
      if (lower.contains(keyword)) {
        hits += 1;
      }
    }

    return lower.contains('breaking') || hits >= 2;
  }
}

class _RssSource {
  final String name;
  final String url;

  const _RssSource({
    required this.name,
    required this.url,
  });
}

class _SourceFetchResult {
  final String source;
  final List<NewsItem> items;
  final String? error;

  const _SourceFetchResult({
    required this.source,
    this.items = const [],
    this.error,
  });
}

class _NewsImpactAssessment {
  final String eventSummary;
  final String impactSummary;
  final String impactDirection;
  final double impactScore;
  final List<String> relatedSymbols;
  final bool actionableSignal;

  const _NewsImpactAssessment({
    required this.eventSummary,
    required this.impactSummary,
    required this.impactDirection,
    required this.impactScore,
    required this.relatedSymbols,
    required this.actionableSignal,
  });
}
