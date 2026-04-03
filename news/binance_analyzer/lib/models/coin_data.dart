enum RecommendationLevel { strongBuy, buy, hold, avoid }

class CoinData {
  final String symbol;
  final double lastPrice;
  final double priceChange;
  final double priceChangePercent;
  final double highPrice;
  final double lowPrice;
  final double openPrice;
  final double quoteVolume;
  final double volume;
  final int count; // 成交笔数

  // 分析结果
  double score;
  double historicalScore;
  double entryScore;
  double expectedEdge;
  double thirtyDayChange;
  double sevenDayChange;
  int daysSinceSurge;
  RecommendationLevel level;
  String recommendation;
  String reason;
  String timingLabel;
  String timingReason;

  CoinData({
    required this.symbol,
    required this.lastPrice,
    required this.priceChange,
    required this.priceChangePercent,
    required this.highPrice,
    required this.lowPrice,
    required this.openPrice,
    required this.quoteVolume,
    required this.volume,
    required this.count,
    this.score = 0.0,
    this.historicalScore = 0.0,
    this.entryScore = 0.0,
    this.expectedEdge = 0.0,
    this.thirtyDayChange = 0.0,
    this.sevenDayChange = 0.0,
    this.daysSinceSurge = 0,
    this.level = RecommendationLevel.hold,
    this.recommendation = '',
    this.reason = '',
    this.timingLabel = '',
    this.timingReason = '',
  });

  /// 显示名（去掉USDT后缀，转大写）
  String get displayName {
    if (symbol.toUpperCase().endsWith('USDT')) {
      return symbol.substring(0, symbol.length - 4).toUpperCase();
    }
    return symbol.toUpperCase();
  }

  /// 价格在24h区间的位置 0=最低 1=最高
  double get rangePosition {
    final range = highPrice - lowPrice;
    if (range <= 0) return 0.5;
    return (lastPrice - lowPrice) / range;
  }

  /// 距24h高点的跌幅%
  double get dropFromHigh {
    if (highPrice <= 0) return 0;
    return ((highPrice - lastPrice) / highPrice) * 100;
  }

  factory CoinData.fromJson(Map<String, dynamic> json) {
    return CoinData(
      symbol: json['symbol']?.toString() ?? '',
      lastPrice: _asDouble(json['lastPrice']),
      priceChange: _asDouble(json['priceChange']),
      priceChangePercent: _asDouble(json['priceChangePercent']),
      highPrice: _asDouble(json['highPrice']),
      lowPrice: _asDouble(json['lowPrice']),
      openPrice: _asDouble(json['openPrice']),
      quoteVolume: _asDouble(json['quoteVolume']),
      volume: _asDouble(json['volume']),
      count: _asInt(json['count']),
      score: _asDouble(json['score']),
      historicalScore: _asDouble(json['historicalScore']),
      entryScore: _asDouble(json['entryScore']),
      expectedEdge: _asDouble(json['expectedEdge']),
      thirtyDayChange: _asDouble(json['thirtyDayChange']),
      sevenDayChange: _asDouble(json['sevenDayChange']),
      daysSinceSurge: _asInt(json['daysSinceSurge']),
      level: _parseLevel(json['level']),
      recommendation: json['recommendation']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      timingLabel: json['timingLabel']?.toString() ?? '',
      timingReason: json['timingReason']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'lastPrice': lastPrice,
        'priceChange': priceChange,
        'priceChangePercent': priceChangePercent,
        'highPrice': highPrice,
        'lowPrice': lowPrice,
        'openPrice': openPrice,
        'quoteVolume': quoteVolume,
        'volume': volume,
        'count': count,
        'score': score,
        'historicalScore': historicalScore,
        'entryScore': entryScore,
        'expectedEdge': expectedEdge,
        'thirtyDayChange': thirtyDayChange,
        'sevenDayChange': sevenDayChange,
        'daysSinceSurge': daysSinceSurge,
        'level': level.name,
        'recommendation': recommendation,
        'reason': reason,
        'timingLabel': timingLabel,
        'timingReason': timingReason,
      };

  @override
  String toString() =>
      'CoinData($symbol, price=$lastPrice, change=$priceChangePercent%, score=$score)';

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value == null) return 0.0;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value == null) return 0;
    return int.tryParse(value.toString()) ?? 0;
  }

  static RecommendationLevel _parseLevel(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    return RecommendationLevel.values.firstWhere(
      (item) => item.name.toLowerCase() == normalized,
      orElse: () => RecommendationLevel.hold,
    );
  }
}
