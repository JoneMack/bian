import 'dart:math';
import '../models/coin_data.dart';
import '../services/binance_service.dart';
import 'technical_indicators.dart';

/// 币种评分与推荐算法
///
/// 评分维度（满分1.0）：
///
/// **基础维度（无K线时使用，权重100%；有K线时降为40%）：**
///   1. 动量分 (Momentum)  权重 45%
///   2. 位置分 (Position)  权重 30%
///   3. 成交量分 (Volume)  权重 25%
///
/// **技术指标维度（有K线时额外加入，权重60%）：**
///   1. RSI (18%) — 超卖回升区最佳
///   2. MACD (18%) — 金叉/柱状图方向
///   3. EMA趋势 (22%) — 多头排列
///   4. 布林带 (12%) — 蓄势突破
///   5. 量能趋势 (12%) — OBV 确认
///   6. ADX (10%) — 趋势强度
///   7. RSI背离 (8%) — 底背离加分
///
/// 最终等级：
///   score ≥ 0.72 → 强烈推荐
///   score ≥ 0.58 → 推荐买入
///   score ≥ 0.42 → 可以考虑
///   score < 0.42 → 暂不推荐
class CoinAnalyzer {
  /// 基础分析（仅用24h数据，无K线历史）
  static List<CoinData> analyze(List<CoinData> coins) {
    if (coins.isEmpty) return coins;

    final volumes = coins.map((c) => c.quoteVolume).toList();
    final logMaxVol = log(volumes.reduce(max) + 1);
    final logMinVol = log(volumes.reduce(min) + 1);

    for (final coin in coins) {
      final ms = _momentumScore(coin.priceChangePercent);
      final ps = _positionScore(coin, ms);
      final vs = _volumeScore(coin.quoteVolume, logMinVol, logMaxVol);

      double score = 0.45 * ms + 0.30 * ps + 0.25 * vs;

      if (coin.priceChangePercent > 0 && coin.rangePosition < 0.45) {
        score *= 1.12;
      }

      coin.score = score.clamp(0.0, 1.0);
      coin.level = _level(coin.score);
      coin.recommendation = _label(coin.level);
      coin.reason = _buildReason(coin, ms, ps, vs);
    }

    coins.sort((a, b) => b.score.compareTo(a.score));
    return coins;
  }

  /// 增强分析（融合K线历史的技术指标）
  static List<CoinData> analyzeWithHistory(
    List<CoinData> coins, {
    required Map<String, List<Kline>> hourlyHistory,
    Map<String, List<Kline>>? dailyHistory,
  }) {
    if (coins.isEmpty) return coins;

    final volumes = coins.map((c) => c.quoteVolume).toList();
    final logMaxVol = log(volumes.reduce(max) + 1);
    final logMinVol = log(volumes.reduce(min) + 1);

    for (final coin in coins) {
      final ms = _momentumScore(coin.priceChangePercent);
      final ps = _positionScore(coin, ms);
      final vs = _volumeScore(coin.quoteVolume, logMinVol, logMaxVol);
      final baseScore = (0.45 * ms + 0.30 * ps + 0.25 * vs).clamp(0.0, 1.0);

      // 尝试获取 K 线历史计算技术指标
      final hourlyBars = hourlyHistory[coin.symbol];
      final dailyBars = dailyHistory?[coin.symbol];

      // 优先用日线，回退到小时线
      final bars = dailyBars ?? hourlyBars;
      if (bars != null && bars.length >= 30) {
        final closes = bars.map((b) => b.close).toList();
        final highs = bars.map((b) => b.high).toList();
        final lows = bars.map((b) => b.low).toList();
        final vols = bars.map((b) => b.quoteVolume).toList();

        final techScore = TechnicalIndicators.compositeScore(
          closes: closes,
          highs: highs,
          lows: lows,
          volumes: vols,
        );

        // 基础 40% + 技术指标 60%
        var finalScore = baseScore * 0.40 + techScore.total * 0.60;

        // 奖励：正动量 + 低位 + 技术面向好
        if (coin.priceChangePercent > 0 &&
            coin.rangePosition < 0.45 &&
            techScore.trendScore >= 0.55) {
          finalScore *= 1.10;
        }

        coin.score = finalScore.clamp(0.0, 1.0);
        coin.level = _level(coin.score);
        coin.recommendation = _label(coin.level);
        coin.reason = _buildEnhancedReason(coin, ms, ps, vs, techScore);
      } else {
        // 无足够 K 线，降级为基础评分
        var score = baseScore;
        if (coin.priceChangePercent > 0 && coin.rangePosition < 0.45) {
          score *= 1.12;
        }
        coin.score = score.clamp(0.0, 1.0);
        coin.level = _level(coin.score);
        coin.recommendation = _label(coin.level);
        coin.reason = _buildReason(coin, ms, ps, vs);
      }
    }

    coins.sort((a, b) => b.score.compareTo(a.score));
    return coins;
  }

  // ──────────────── 各维度评分 ────────────────

  static double _momentumScore(double changePct) {
    if (changePct >= 0) {
      if (changePct <= 1) {
        return 0.45 + changePct * 0.05;
      } else if (changePct <= 5) {
        return 0.50 + ((changePct - 1) / 4) * 0.50;
      } else if (changePct <= 10) {
        return 1.00 - ((changePct - 5) / 5) * 0.20;
      } else if (changePct <= 20) {
        return 0.80 - ((changePct - 10) / 10) * 0.30;
      } else {
        return 0.50;
      }
    } else {
      if (changePct >= -3) {
        return 0.45 + (changePct / 3) * 0.15;
      } else if (changePct >= -8) {
        return 0.30 + ((changePct + 3) / 5) * 0.20;
      } else {
        return max(0.0, 0.10 + (changePct + 8) / 20);
      }
    }
  }

  static double _positionScore(CoinData coin, double momentumScore) {
    final pos = coin.rangePosition;
    final raw = 1.0 - pos;
    if (momentumScore >= 0.5) {
      return raw;
    } else {
      return raw * (momentumScore / 0.5) * 0.5;
    }
  }

  static double _volumeScore(double vol, double logMin, double logMax) {
    if (logMax <= logMin) return 0.5;
    return (log(vol + 1) - logMin) / (logMax - logMin);
  }

  // ──────────────── 等级与标签 ────────────────

  static RecommendationLevel _level(double score) {
    if (score >= 0.72) return RecommendationLevel.strongBuy;
    if (score >= 0.58) return RecommendationLevel.buy;
    if (score >= 0.42) return RecommendationLevel.hold;
    return RecommendationLevel.avoid;
  }

  static String _label(RecommendationLevel level) {
    switch (level) {
      case RecommendationLevel.strongBuy:
        return '强烈推荐';
      case RecommendationLevel.buy:
        return '推荐买入';
      case RecommendationLevel.hold:
        return '可以考虑';
      case RecommendationLevel.avoid:
        return '暂不推荐';
    }
  }

  static String _buildReason(
      CoinData coin, double ms, double ps, double vs) {
    final List<String> parts = [];
    final chg = coin.priceChangePercent;

    if (chg > 8) {
      parts.add('涨幅偏大(${chg.toStringAsFixed(1)}%)，注意回调风险');
    } else if (chg > 0) {
      parts.add('上涨动量良好(+${chg.toStringAsFixed(1)}%)');
    } else {
      parts.add('当前下跌(${chg.toStringAsFixed(1)}%)，趋势偏弱');
    }

    if (coin.rangePosition < 0.35 && chg > 0) {
      parts.add('价格仍处区间低位，上涨空间充足');
    } else if (coin.rangePosition > 0.80) {
      parts.add('价格接近24h高点，追高需谨慎');
    }

    if (vs > 0.7) {
      parts.add('成交量活跃');
    } else if (vs < 0.3) {
      parts.add('成交量偏低');
    }

    return parts.join('；');
  }

  static String _buildEnhancedReason(
      CoinData coin, double ms, double ps, double vs, TechnicalScore tech) {
    final List<String> parts = [];
    final chg = coin.priceChangePercent;

    if (chg > 8) {
      parts.add('涨幅偏大(${chg.toStringAsFixed(1)}%)');
    } else if (chg > 0) {
      parts.add('+${chg.toStringAsFixed(1)}%');
    } else {
      parts.add('${chg.toStringAsFixed(1)}%');
    }

    // 技术指标摘要
    if (tech.trendScore >= 0.75) {
      parts.add('EMA多头排列');
    } else if (tech.trendScore <= 0.35) {
      parts.add('EMA空头');
    }

    if (tech.macdScore >= 0.80) {
      parts.add('MACD强势');
    } else if (tech.macdScore <= 0.25) {
      parts.add('MACD弱势');
    }

    if (tech.rsiScore >= 0.80) {
      parts.add('RSI超卖回升');
    } else if (tech.rsiScore <= 0.25) {
      parts.add('RSI超买');
    }

    if (tech.bollingerScore >= 0.70) {
      parts.add('布林带蓄势');
    }

    if (tech.divergenceScore > 0.3) {
      parts.add('RSI看涨背离');
    }

    if (tech.adxScore >= 0.7) {
      parts.add('强趋势');
    }

    if (vs > 0.7) {
      parts.add('量活跃');
    } else if (vs < 0.3) {
      parts.add('量偏低');
    }

    return parts.join('；');
  }

  /// 今日精选：强烈推荐+推荐中最多取3个
  static List<CoinData> top3Picks(List<CoinData> analyzed) {
    final strong = analyzed
        .where((c) =>
            c.level == RecommendationLevel.strongBuy ||
            c.level == RecommendationLevel.buy)
        .toList();

    if (strong.length >= 3) return strong.take(3).toList();

    final hold = analyzed
        .where((c) => c.level == RecommendationLevel.hold)
        .toList();

    return [...strong, ...hold].take(3).toList();
  }

  /// 兼容旧接口
  static List<CoinData> topPicks(List<CoinData> analyzed) =>
      top3Picks(analyzed);
}
