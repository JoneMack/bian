import 'dart:convert';

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

  final _translator = NewsTranslationService();

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
    final selected = deduped.take(limit).toList();
    return _translator.translateNewsItems(selected);
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
