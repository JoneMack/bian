import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/news_item.dart';

class NewsTranslationService {
  static const String _separator = '[[NEWS_SPLIT]]';
  static const Map<String, String> _headers = {
    'User-Agent': 'binance-analyzer/1.0 (Flutter)',
  };

  static const Set<String> _noiseWords = {
    'the',
    'a',
    'an',
    'and',
    'or',
    'but',
    'to',
    'of',
    'in',
    'on',
    'at',
    'for',
    'from',
    'with',
    'without',
    'into',
    'onto',
    'over',
    'under',
    'after',
    'before',
    'amid',
    'during',
    'as',
    'by',
    'via',
    'that',
    'this',
    'these',
    'those',
    'its',
    'their',
    'his',
    'her',
    'been',
    'being',
    'was',
    'were',
    'are',
    'is',
    'be',
    'it',
    'they',
    'them',
    'he',
    'she',
    'you',
    'we',
    'will',
    'would',
    'could',
    'should',
    'may',
    'might',
  };

  static const Map<String, String> _phraseMap = {
    'breaking news': '突发消息',
    'bitcoin etf': '比特币 ETF',
    'ethereum etf': '以太坊 ETF',
    'spot bitcoin etf': '现货比特币 ETF',
    'spot ethereum etf': '现货以太坊 ETF',
    'ai tokens': 'AI 代币',
    'crypto market': '加密市场',
    'crypto markets': '加密市场',
    'market cap': '市值',
    'markets slide': '市场回落',
    'markets rally': '市场走强',
    'markets slump': '市场下跌',
    'market rebounds': '市场反弹',
    'market rebound': '市场反弹',
    'etf inflows': 'ETF 资金流入',
    'etf outflows': 'ETF 资金流出',
    'funding rate': '资金费率',
    'open interest': '未平仓合约',
    'price target': '目标价',
    'price action': '价格表现',
    'profit taking': '获利了结',
    'all-time high': '历史新高',
    'record high': '新高',
    'record low': '新低',
    'interest rate': '利率',
    'interest rates': '利率',
    'rate cut': '降息',
    'rate cuts': '降息',
    'breaking': '突发',
    'surges': '飙升',
    'surge': '飙升',
    'spikes': '激增',
    'spike': '激增',
    'rallies': '上涨',
    'rally': '上涨',
    'slumps': '下跌',
    'slump': '下跌',
    'slumped': '下跌',
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
    'rebounds': '反弹',
    'rebound': '反弹',
    'retreats': '回调',
    'retreat': '回调',
    'drops': '下跌',
    'drop': '下跌',
    'hack': '黑客攻击',
    'exploit': '漏洞利用',
    'lawsuit': '诉讼',
    'lawsuits': '诉讼',
    'settlement': '和解',
    'settles': '达成和解',
    'listing': '上币',
    'listings': '上币',
    'launches': '推出',
    'launch': '推出',
    'announces': '宣布',
    'announce': '宣布',
    'reveals': '披露',
    'reveal': '披露',
    'files': '提交',
    'filed': '已提交',
    'warns': '警告',
    'warning': '警告',
    'approval': '批准',
    'approved': '获批',
    'rejected': '被拒',
    'delayed': '延期',
    'delay': '延期',
    'expands': '扩大',
    'expand': '扩大',
    'reacted': '作出反应',
    'reacts': '作出反应',
    'reaction': '反应',
    'moved': '波动',
    'moves': '波动',
    'action': '动作',
    'actions': '动作',
    'higher': '走高',
    'lower': '走低',
    'sharply': '明显',
    'briefly': '短暂',
    'signals': '信号',
    'signal': '信号',
    'outlook': '前景',
    'outflows': '资金流出',
    'outflow': '资金流出',
    'inflow': '资金流入',
    'volatility': '波动率',
    'breaks above': '突破',
    'break above': '突破',
    'breaks below': '跌破',
    'break below': '跌破',
    'pullback': '回踩',
    'pulls back': '回踩',
    'selloff': '抛售',
    'sell-off': '抛售',
    'whipsaw': '震荡',
    'risk-on': '风险偏好回升',
    'risk off': '风险偏好回落',
    'risk-off': '风险偏好回落',
    'inflation': '通胀',
    'cpi': 'CPI',
    'fed': '美联储',
    'sec': 'SEC',
    'treasury': '美债',
    'tariff': '关税',
    'war': '战争',
    'liquidation': '爆仓',
    'liquidations': '爆仓',
    'short squeeze': '空头挤压',
    'whale activity': '巨鲸动向',
    'exchange inflows': '交易所净流入',
    'exchange outflows': '交易所净流出',
    'bitcoin': '比特币',
    'ethereum': '以太坊',
    'solana': 'Solana',
    'dogecoin': 'Dogecoin',
    'ripple': 'Ripple',
    'xrp': 'XRP',
    'cardano': 'Cardano',
    'avalanche': 'Avalanche',
    'chainlink': 'Chainlink',
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
    'after': '后',
    'amid': '在',
    'analysts': '分析师',
    'analyst': '分析师',
    'investors': '投资者',
    'investor': '投资者',
    'institutions': '机构',
    'institutional': '机构',
    'watch': '关注',
    'eyes': '关注',
    'eyeing': '关注',
    'boosts': '提振',
    'boost': '提振',
    'weighs': '压制',
    'weigh': '压制',
    'supports': '支撑',
    'supported': '受支撑',
    'pressures': '施压',
    'pressure': '压力',
    'gains': '涨幅',
    'gain': '上涨',
    'losses': '跌幅',
    'loss': '下跌',
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
    final body = _buildTranslationSource(item.body, item.title);

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
    final translatedBody = _fallbackTranslateText(
      body.isEmpty ? title : '$title. $body',
      compact: false,
    );

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
    if (_looksChinese(cleaned)) {
      return _condenseChineseText(
        cleaned,
        maxLength: compact ? 48 : 120,
        terminate: !compact,
      );
    }

    final localized = _localizeWithPhraseMap(cleaned);
    final normalized = _normalizeLocalizedText(localized);

    if (_isReadableChinese(normalized)) {
      final condensed = _condenseChineseText(
        normalized,
        maxLength: compact ? 48 : 480,
        terminate: !compact,
      );
      if (!compact && _hasEnglishNoise(condensed)) {
        final keywords = _extractKeywords(cleaned);
        if (keywords.isNotEmpty) {
          return '要点：${keywords.join('，')}。';
        }
      }
      return compact ? condensed : '要点：$condensed';
    }

    final keywords = _extractKeywords(cleaned);
    if (keywords.isEmpty) return compact ? '中文快讯' : '要点：暂无可用中文摘要。';

    final joined = keywords.join('，');
    return compact ? joined : '要点：$joined。';
  }

  static List<String> _extractKeywords(String text) {
    final cleaned = _cleanInput(text);
    if (cleaned.isEmpty) return const [];

    final hits = <_KeywordHit>[];
    final lower = cleaned.toLowerCase();

    for (final entry in _phraseMap.entries) {
      if (entry.key.length < 4) continue;
      final index = lower.indexOf(entry.key);
      if (index >= 0) {
        hits.add(_KeywordHit(index, entry.value));
      }
    }

    for (final match in RegExp(r'\b[A-Z]{2,10}\b').allMatches(cleaned)) {
      hits.add(_KeywordHit(match.start, match.group(0)!));
    }

    for (final match in RegExp(r'\b\d+(?:\.\d+)?%?\b').allMatches(cleaned)) {
      hits.add(_KeywordHit(match.start, match.group(0)!));
    }

    hits.sort((a, b) => a.index.compareTo(b.index));

    final ordered = <String>[];
    for (final hit in hits) {
      if (ordered.contains(hit.value)) continue;
      ordered.add(hit.value);
      if (ordered.length >= 6) break;
    }

    return ordered;
  }

  static String _buildTranslationSource(String body, String title) {
    final cleaned = _cleanInput(body);
    if (cleaned.isEmpty || cleaned == _cleanInput(title)) return '';
    if (cleaned.length <= 1400) return cleaned;
    return '${cleaned.substring(0, 1400)}...';
  }

  static String _cleanInput(String text) => _normalizeWhitespace(text);

  static String _normalizeWhitespace(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _looksChinese(String text) =>
      RegExp(r'[\u4e00-\u9fff]').hasMatch(text);

  static String _localizeWithPhraseMap(String text) {
    var translated = text;
    final entries = _phraseMap.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final entry in entries) {
      translated = translated.replaceAllMapped(
        _phrasePattern(entry.key),
        (_) => entry.value,
      );
    }

    translated = translated
        .replaceAll('&amp;', '&')
        .replaceAllMapped(RegExp(r'\b([a-z]{1,12})\b'), (match) {
      final word = match.group(1) ?? '';
      if (_noiseWords.contains(word.toLowerCase())) {
        return '';
      }
      return match.group(0) ?? '';
    });

    return translated;
  }

  static String _normalizeLocalizedText(String text) {
    final normalized = text
        .replaceAllMapped(RegExp(r'\s+'), (_) => ' ')
        .replaceAll(' ,', '，')
        .replaceAll(',', '，')
        .replaceAll(' ;', '；')
        .replaceAll(';', '；')
        .replaceAll(' :', '：')
        .replaceAll(':', '：')
        .replaceAll(' .', '。')
        .replaceAll('.', '。')
        .replaceAll(' !', '！')
        .replaceAll('?', '？')
        .replaceAll(' ；', '；')
        .replaceAll(' ，', '，')
        .replaceAll(' 。', '。')
        .replaceAll(RegExp(r'(，){2,}'), '，')
        .replaceAll(RegExp(r'(。){2,}'), '。')
        .replaceAll(RegExp(r'(；){2,}'), '；')
        .trim();

    final tightened = normalized
        .replaceAllMapped(
            RegExp(r'\s*([，。；：！？])\s*'), (match) => match.group(1)!)
        .replaceAllMapped(RegExp(r'([\u4e00-\u9fff])\s+([\u4e00-\u9fff])'),
            (match) => '${match.group(1)}${match.group(2)}')
        .replaceAllMapped(RegExp(r'([\u4e00-\u9fff])\s+([A-Z0-9])'),
            (match) => '${match.group(1)}${match.group(2)}')
        .replaceAllMapped(RegExp(r'([A-Z0-9])\s+([\u4e00-\u9fff])'),
            (match) => '${match.group(1)}${match.group(2)}');

    return tightened.replaceAll(RegExp(r'^[，。；：]+|[，。；：]+$'), '');
  }

  static bool _isReadableChinese(String text) {
    if (!_looksChinese(text)) return false;
    final englishNoiseCount = RegExp(r'\b[a-z]{4,}\b').allMatches(text).length;
    return englishNoiseCount <= 2;
  }

  static bool _hasEnglishNoise(String text) =>
      RegExp(r'\b[a-z]{3,}\b').hasMatch(text);

  static String _condenseChineseText(
    String text, {
    required int maxLength,
    required bool terminate,
  }) {
    final cleaned = _normalizeLocalizedText(text);
    if (cleaned.isEmpty) return '';

    final parts = cleaned
        .split(RegExp(r'[。！？；]'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();

    String result;
    if (parts.isEmpty) {
      result = cleaned;
    } else {
      result = parts.take(2).join('；');
    }

    if (result.length > maxLength) {
      result = '${result.substring(0, maxLength)}...';
    }

    if (terminate &&
        !result.endsWith('...') &&
        !RegExp(r'[。！？]$').hasMatch(result)) {
      result = '$result。';
    }

    return result;
  }

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

class _KeywordHit {
  final int index;
  final String value;

  const _KeywordHit(this.index, this.value);
}
