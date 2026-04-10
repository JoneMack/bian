class NewsItem {
  final String id;
  final String title;
  final String body;
  final String translatedTitle;
  final String translatedBody;
  final String eventSummary;
  final String impactSummary;
  final String impactDirection;
  final double impactScore;
  final List<String> relatedSymbols;
  final bool actionableSignal;
  final String url;
  final String source;
  final String imageUrl;
  final DateTime publishedAt;
  final List<String> tags;
  final bool isHot; // 热点标记

  NewsItem({
    required this.id,
    required this.title,
    required this.body,
    this.translatedTitle = '',
    this.translatedBody = '',
    this.eventSummary = '',
    this.impactSummary = '',
    this.impactDirection = 'neutral',
    this.impactScore = 0,
    this.relatedSymbols = const [],
    this.actionableSignal = false,
    required this.url,
    required this.source,
    required this.imageUrl,
    required this.publishedAt,
    required this.tags,
    this.isHot = false,
  });

  /// 时间友好显示
  String get timeAgo {
    final diff = DateTime.now().difference(publishedAt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }

  /// 正文摘要（最多120字）
  String get summary {
    if (body.length <= 120) return body;
    return '${body.substring(0, 120)}...';
  }

  bool get hasChineseTranslation =>
      _looksChinese(translatedTitle) || _looksChinese(translatedBody);

  String get displayTitle =>
      translatedTitle.isNotEmpty ? translatedTitle : title;

  String get displaySummary {
    final text = impactSummary.trim().isNotEmpty
        ? impactSummary.trim()
        : translatedBody.isNotEmpty
            ? translatedBody
            : summary;
    if (text.length <= 120) return text;
    return '${text.substring(0, 120)}...';
  }

  String get displayDetailBody {
    final parts = <String>[
      if (eventSummary.trim().isNotEmpty) '事件判断：${eventSummary.trim()}',
      if (impactSummary.trim().isNotEmpty) '影响分析：${impactSummary.trim()}',
      if (translatedBody.trim().isNotEmpty)
        translatedBody.trim()
      else if (body.trim().isNotEmpty)
        body.trim(),
    ];
    final text = parts.join('\n\n').trim();
    if (text.trim().isEmpty) return displayTitle;
    return text.trim();
  }

  /// 是否与自选币相关
  bool isRelatedTo(List<String> symbols) {
    final tagsLower = tags.map((t) => t.toLowerCase()).toSet();
    return symbols.any((s) {
      final name = s.replaceAll('USDT', '').toLowerCase();
      return tagsLower.contains(name);
    });
  }

  // ── CryptoCompare 格式 ─────────────────────────────────
  factory NewsItem.fromCryptoCompare(Map<String, dynamic> json) {
    final ts = json['published_on'] as int? ?? 0;
    final rawTags = (json['tags'] as String? ?? '').split('|');
    final cats = (json['categories'] as String? ?? '').split('|');
    final allTags = {...rawTags, ...cats}.where((t) => t.isNotEmpty).toList();

    return NewsItem(
      id: json['id']?.toString() ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      url: json['url'] as String? ?? '',
      source: (json['source_info'] as Map?)?['name'] as String? ??
          json['source'] as String? ??
          '',
      imageUrl: json['imageurl'] as String? ?? '',
      publishedAt: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
      tags: allTags,
    );
  }

  // ── Binance 公告格式 ───────────────────────────────────
  factory NewsItem.fromBinance(Map<String, dynamic> json) {
    final ts = json['releaseDate'] as int? ?? 0;
    return NewsItem(
      id: json['id']?.toString() ?? '',
      title: json['title'] as String? ?? '',
      body: json['brief'] as String? ?? '',
      url:
          'https://www.binance.com/en/support/announcement/${json['code'] ?? ''}',
      source: 'Binance',
      imageUrl: '',
      publishedAt:
          ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now(),
      tags: const ['Binance'],
      isHot: true,
    );
  }

  factory NewsItem.fromJson(Map<String, dynamic> json) {
    return NewsItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      translatedTitle: json['translatedTitle']?.toString() ?? '',
      translatedBody: json['translatedBody']?.toString() ?? '',
      eventSummary: json['eventSummary']?.toString() ?? '',
      impactSummary: json['impactSummary']?.toString() ?? '',
      impactDirection: json['impactDirection']?.toString() ?? 'neutral',
      impactScore: (json['impactScore'] as num?)?.toDouble() ?? 0,
      relatedSymbols: (json['relatedSymbols'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(),
      actionableSignal: json['actionableSignal'] as bool? ?? false,
      url: json['url']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString() ?? '',
      publishedAt: DateTime.tryParse(json['publishedAt']?.toString() ?? '') ??
          DateTime.now(),
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(),
      isHot: json['isHot'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'translatedTitle': translatedTitle,
        'translatedBody': translatedBody,
        'eventSummary': eventSummary,
        'impactSummary': impactSummary,
        'impactDirection': impactDirection,
        'impactScore': impactScore,
        'relatedSymbols': relatedSymbols,
        'actionableSignal': actionableSignal,
        'url': url,
        'source': source,
        'imageUrl': imageUrl,
        'publishedAt': publishedAt.toIso8601String(),
        'tags': tags,
        'isHot': isHot,
      };

  NewsItem copyWith({
    String? id,
    String? title,
    String? body,
    String? translatedTitle,
    String? translatedBody,
    String? eventSummary,
    String? impactSummary,
    String? impactDirection,
    double? impactScore,
    List<String>? relatedSymbols,
    bool? actionableSignal,
    String? url,
    String? source,
    String? imageUrl,
    DateTime? publishedAt,
    List<String>? tags,
    bool? isHot,
  }) {
    return NewsItem(
      id: id ?? this.id,
      title: title ?? this.title,
      body: body ?? this.body,
      translatedTitle: translatedTitle ?? this.translatedTitle,
      translatedBody: translatedBody ?? this.translatedBody,
      eventSummary: eventSummary ?? this.eventSummary,
      impactSummary: impactSummary ?? this.impactSummary,
      impactDirection: impactDirection ?? this.impactDirection,
      impactScore: impactScore ?? this.impactScore,
      relatedSymbols: relatedSymbols ?? this.relatedSymbols,
      actionableSignal: actionableSignal ?? this.actionableSignal,
      url: url ?? this.url,
      source: source ?? this.source,
      imageUrl: imageUrl ?? this.imageUrl,
      publishedAt: publishedAt ?? this.publishedAt,
      tags: tags ?? this.tags,
      isHot: isHot ?? this.isHot,
    );
  }

  static bool _looksChinese(String text) =>
      RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
}
