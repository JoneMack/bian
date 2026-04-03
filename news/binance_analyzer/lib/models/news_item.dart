class NewsItem {
  final String id;
  final String title;
  final String body;
  final String translatedTitle;
  final String translatedBody;
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
    final text = translatedBody.isNotEmpty ? translatedBody : summary;
    if (text.length <= 120) return text;
    return '${text.substring(0, 120)}...';
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

  NewsItem copyWith({
    String? id,
    String? title,
    String? body,
    String? translatedTitle,
    String? translatedBody,
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
