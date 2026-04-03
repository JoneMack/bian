import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/news_item.dart';

class NewsTranslationService {
  static const String _separator = '[[NEWS_SPLIT]]';
  static const Map<String, String> _headers = {
    'User-Agent': 'binance-analyzer/1.0 (Flutter)',
  };

  static const Map<String, String> _phraseMap = {
    'bitcoin etf': '比特币 ETF',
    'ethereum etf': '以太坊 ETF',
    'ai tokens': 'AI 代币',
    'crypto market': '加密市场',
    'crypto markets': '加密市场',
    'markets slide': '市场回落',
    'markets rally': '市场走强',
    'markets slump': '市场下跌',
    'etf inflows': 'ETF 资金流入',
    'etf outflows': 'ETF 资金流出',
    'funding rate': '资金费率',
    'open interest': '未平仓合约',
    'price target': '目标价',
    'profit taking': '获利了结',
    'breaking': '突发',
    'surges': '飙升',
    'surge': '飙升',
    'spikes': '激增',
    'spike': '激增',
    'rallies': '上涨',
    'rally': '上涨',
    'slumps': '下跌',
    'slump': '下跌',
    'slides': '回落',
    'slide': '回落',
    'soars': '飙升',
    'soar': '飙升',
    'jumps': '跳涨',
    'jump': '跳涨',
    'falls': '下跌',
    'fall': '下跌',
    'rises': '上涨',
    'rise': '上涨',
    'drops': '下跌',
    'drop': '下跌',
    'hack': '黑客攻击',
    'exploit': '漏洞利用',
    'lawsuit': '诉讼',
    'lawsuits': '诉讼',
    'listing': '上币',
    'listings': '上币',
    'launches': '推出',
    'launch': '推出',
    'announces': '宣布',
    'announce': '宣布',
    'files': '提交',
    'filed': '已提交',
    'warns': '警告',
    'approval': '批准',
    'approved': '获批',
    'rejected': '被拒',
    'delayed': '延期',
    'inflation': '通胀',
    'cpi': 'CPI',
    'fed': '美联储',
    'tariff': '关税',
    'war': '战争',
    'bitcoin': '比特币',
    'ethereum': '以太坊',
    'solana': 'Solana',
    'binance': '币安',
    'markets': '市场',
    'market': '市场',
    'crypto': '加密货币',
    'token': '代币',
    'tokens': '代币',
    'coin': '代币',
    'coins': '币种',
    'price': '价格',
    'prices': '价格',
    'volume': '成交量',
    'trader': '交易者',
    'traders': '交易者',
    'whale': '巨鲸',
    'whales': '巨鲸',
    'bullish': '偏多',
    'bearish': '偏空',
    'breakout': '突破',
    'support': '支撑',
    'resistance': '阻力',
    'staking': '质押',
    'futures': '合约',
    'spot': '现货',
    'inflows': '资金流入',
    'outflows': '资金流出',
    'higher': '走高',
    'lower': '走低',
    'after': '后',
    'amid': '在',
  };

  final http.Client _client;
  final Map<String, _TranslatedBundle> _cache = {};
  bool? _remoteEnabled;

  NewsTranslationService({http.Client? client})
      : _client = client ?? http.Client();

  Future<List<NewsItem>> translateNewsItems(List<NewsItem> items) async {
    final results = <NewsItem>[];
    for (final chunk in _chunk(items, 4)) {
      final translated = await Future.wait(chunk.map(localizeNewsItem));
      results.addAll(translated);
    }
    return results;
  }

  Future<NewsItem> localizeNewsItem(NewsItem item) async {
    final title = _cleanInput(item.title);
    final body = _buildSummarySource(item.body, item.title);

    if (title.isEmpty && body.isEmpty) return item;
    if (_looksChinese(title) && (body.isEmpty || _looksChinese(body))) {
      return item.copyWith(
        translatedTitle: title,
        translatedBody: body,
      );
    }

    final cacheKey = '$title\n$_separator\n$body';
    final cached = _cache[cacheKey];
    if (cached != null) {
      return item.copyWith(
        translatedTitle: cached.title,
        translatedBody: cached.body,
      );
    }

    _TranslatedBundle bundle;
    if (_remoteEnabled != false) {
      try {
        bundle = await _translateRemote(title: title, body: body);
        _remoteEnabled = true;
      } catch (_) {
        _remoteEnabled = false;
        bundle = _fallbackTranslateBundle(title: title, body: body);
      }
    } else {
      bundle = _fallbackTranslateBundle(title: title, body: body);
    }

    _cache[cacheKey] = bundle;
    return item.copyWith(
      translatedTitle: bundle.title,
      translatedBody: bundle.body,
    );
  }

  Future<_TranslatedBundle> _translateRemote({
    required String title,
    required String body,
  }) async {
    final payload = body.isEmpty ? title : '$title\n$_separator\n$body';
    final uri = Uri.parse('https://translate.googleapis.com/translate_a/single')
        .replace(queryParameters: {
      'client': 'gtx',
      'sl': 'auto',
      'tl': 'zh-CN',
      'dt': 't',
      'q': payload,
    });

    final response = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 4));

    if (response.statusCode != 200) {
      throw Exception('translate ${response.statusCode}');
    }

    final translated = parseTranslateResponse(
        utf8.decode(response.bodyBytes, allowMalformed: true));
    if (translated.isEmpty ||
        (!_looksChinese(translated) && translated == payload)) {
      throw Exception('empty translation');
    }

    final bundle = _splitBundle(
      translated: translated,
      originalTitle: title,
      originalBody: body,
    );

    if (bundle.title.isEmpty && bundle.body.isEmpty) {
      throw Exception('invalid translation');
    }

    return bundle;
  }

  static _TranslatedBundle _fallbackTranslateBundle({
    required String title,
    required String body,
  }) {
    final translatedTitle = _fallbackTranslateText(title, compact: true);
    final translatedBody =
        body.isEmpty ? '' : _fallbackTranslateText(body, compact: false);

    return _TranslatedBundle(
      title: translatedTitle,
      body: translatedBody,
    );
  }

  static String parseTranslateResponse(String raw) {
    final data = jsonDecode(raw);
    if (data is! List || data.isEmpty) return '';
    final segments = data.first;
    if (segments is! List) return '';

    final buffer = StringBuffer();
    for (final segment in segments) {
      if (segment is List && segment.isNotEmpty) {
        buffer.write(segment.first?.toString() ?? '');
      }
    }
    return _normalizeWhitespace(buffer.toString());
  }

  static _TranslatedBundle _splitBundle({
    required String translated,
    required String originalTitle,
    required String originalBody,
  }) {
    if (originalBody.isEmpty) {
      return _TranslatedBundle(title: translated, body: '');
    }

    if (translated.contains(_separator)) {
      final parts = translated.split(_separator);
      return _TranslatedBundle(
        title: parts.first.trim(),
        body: parts.skip(1).join(_separator).trim(),
      );
    }

    final lines = translated
        .split(RegExp(r'\n+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (lines.length >= 2) {
      return _TranslatedBundle(
        title: lines.first,
        body: lines.skip(1).join(' '),
      );
    }

    final local = _fallbackTranslateBundle(
      title: originalTitle,
      body: originalBody,
    );
    return _TranslatedBundle(
      title: lines.isEmpty ? local.title : lines.first,
      body: local.body,
    );
  }

  static String _fallbackTranslateText(String text, {required bool compact}) {
    final cleaned = _cleanInput(text);
    if (cleaned.isEmpty) return '';
    if (_looksChinese(cleaned)) return cleaned;

    var translated = cleaned;
    final entries = _phraseMap.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final entry in entries) {
      translated = translated.replaceAllMapped(
        _phrasePattern(entry.key),
        (_) => entry.value,
      );
    }

    translated = translated
        .replaceAllMapped(RegExp(r'\s{2,}'), (_) => ' ')
        .replaceAll(' ,', '，')
        .replaceAll(',', '，')
        .replaceAll(' ;', '；')
        .replaceAll(';', '；')
        .replaceAll(' :', '：')
        .replaceAll(':', '：')
        .replaceAll(' .', '。')
        .trim();

    if (_looksChinese(translated)) {
      return translated;
    }

    final keywords = _extractKeywords(cleaned);
    if (keywords.isEmpty) return '';

    final prefix = compact ? '中文速览：' : '重点：';
    return '$prefix${keywords.join('，')}';
  }

  static List<String> _extractKeywords(String text) {
    final lower = text.toLowerCase();
    final hits = <String>[];

    for (final entry in _phraseMap.entries) {
      if (entry.key.length < 4) continue;
      if (lower.contains(entry.key) && !hits.contains(entry.value)) {
        hits.add(entry.value);
      }
      if (hits.length >= 5) break;
    }

    return hits;
  }

  static String _buildSummarySource(String body, String title) {
    final cleaned = _cleanInput(body);
    if (cleaned.isEmpty || cleaned == _cleanInput(title)) return '';
    if (cleaned.length <= 180) return cleaned;
    return '${cleaned.substring(0, 180)}...';
  }

  static String _cleanInput(String text) => _normalizeWhitespace(text);

  static String _normalizeWhitespace(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _looksChinese(String text) =>
      RegExp(r'[\u4e00-\u9fff]').hasMatch(text);

  static RegExp _phrasePattern(String phrase) => RegExp(
        '(?<![A-Za-z])${RegExp.escape(phrase)}(?![A-Za-z])',
        caseSensitive: false,
      );

  static List<List<NewsItem>> _chunk(List<NewsItem> items, int size) {
    final chunks = <List<NewsItem>>[];
    for (var index = 0; index < items.length; index += size) {
      final end = index + size > items.length ? items.length : index + size;
      chunks.add(items.sublist(index, end));
    }
    return chunks;
  }
}

class _TranslatedBundle {
  final String title;
  final String body;

  const _TranslatedBundle({
    required this.title,
    required this.body,
  });
}
