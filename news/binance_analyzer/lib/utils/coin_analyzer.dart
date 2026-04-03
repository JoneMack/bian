import 'dart:math';
import '../models/coin_data.dart';

/// 币种评分与推荐算法
///
/// 评分维度（满分1.0）：
///   1. 动量分 (Momentum)  权重 45%
///      - 24h涨幅在 +1% ~ +8% 得分最高，说明有上涨趋势但未严重超买
///      - 大跌（<-5%）大幅拖低得分
///      - 暴涨（>15%）适度降分（可能回调）
///
///   2. 位置分 (Position)  权重 30%
///      - 当前价相对24h区间位置（越低越好，代表仍有上涨空间）
///      - 仅在正动量时加权，避免"越跌越买"陷阱
///
///   3. 成交量分 (Volume)  权重 25%
///      - 对数归一化成交额，高成交量说明市场活跃，信号更可靠
///
/// 最终等级：
///   score ≥ 0.72 → 强烈推荐 🟢🟢
///   score ≥ 0.58 → 推荐买入 🟢
///   score ≥ 0.42 → 可以考虑 🟡
///   score < 0.42 → 暂不推荐 🔴
class CoinAnalyzer {
  static List<CoinData> analyze(List<CoinData> coins) {
    if (coins.isEmpty) return coins;

    // 预计算统计量
    final volumes = coins.map((c) => c.quoteVolume).toList();
    final logMaxVol = log(volumes.reduce(max) + 1);
    final logMinVol = log(volumes.reduce(min) + 1);

    for (final coin in coins) {
      final ms = _momentumScore(coin.priceChangePercent);
      final ps = _positionScore(coin, ms);
      final vs = _volumeScore(coin.quoteVolume, logMinVol, logMaxVol);

      double score = 0.45 * ms + 0.30 * ps + 0.25 * vs;

      // 奖励：正动量 + 价格在低位区间（强势初期）
      if (coin.priceChangePercent > 0 && coin.rangePosition < 0.45) {
        score *= 1.12;
      }

      coin.score = score.clamp(0.0, 1.0);
      coin.level = _level(coin.score);
      coin.recommendation = _label(coin.level);
      coin.reason = _buildReason(coin, ms, ps, vs);
    }

    // 按评分降序
    coins.sort((a, b) => b.score.compareTo(a.score));
    return coins;
  }

  // ──────────────── 各维度评分 ────────────────

  static double _momentumScore(double changePct) {
    if (changePct >= 0) {
      // 上涨：1%~8% 最佳区间，超过8%适当折扣
      if (changePct <= 1) {
        return 0.45 + changePct * 0.05; // 0.45~0.50
      } else if (changePct <= 5) {
        return 0.50 + ((changePct - 1) / 4) * 0.50; // 0.50~1.00
      } else if (changePct <= 10) {
        return 1.00 - ((changePct - 5) / 5) * 0.20; // 1.00~0.80
      } else if (changePct <= 20) {
        return 0.80 - ((changePct - 10) / 10) * 0.30; // 0.80~0.50
      } else {
        return 0.50; // 暴涨，谨慎
      }
    } else {
      // 下跌
      if (changePct >= -3) {
        return 0.45 + (changePct / 3) * 0.15; // 微跌 0.45~0.30
      } else if (changePct >= -8) {
        return 0.30 + ((changePct + 3) / 5) * 0.20; // 中跌 0.10~0.30
      } else {
        return max(0.0, 0.10 + (changePct + 8) / 20); // 大跌 接近0
      }
    }
  }

  static double _positionScore(CoinData coin, double momentumScore) {
    // 只在上涨动量下，位置低才加分；下跌时减权避免抄底陷阱
    final pos = coin.rangePosition; // 0=低位 1=高位
    final raw = 1.0 - pos; // 越低位得分越高
    if (momentumScore >= 0.5) {
      return raw; // 正动量时完整使用位置分
    } else {
      return raw * (momentumScore / 0.5) * 0.5; // 负动量时大幅折减
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

  /// 今日精选：强烈推荐+推荐中最多取3个
  /// 若不足3个，从「可以考虑」中补充，始终返回最优的
  static List<CoinData> top3Picks(List<CoinData> analyzed) {
    final strong = analyzed
        .where((c) =>
            c.level == RecommendationLevel.strongBuy ||
            c.level == RecommendationLevel.buy)
        .toList();

    if (strong.length >= 3) return strong.take(3).toList();

    // 补充「可以考虑」
    final hold = analyzed
        .where((c) => c.level == RecommendationLevel.hold)
        .toList();

    return [...strong, ...hold].take(3).toList();
  }

  /// 兼容旧接口
  static List<CoinData> topPicks(List<CoinData> analyzed) =>
      top3Picks(analyzed);
}
