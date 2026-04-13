import 'dart:math';

/// 技术指标计算工具库
///
/// 包含：RSI、MACD、EMA、布林带、ADX、OBV、ATR 等经典指标
/// 所有方法均为纯函数，输入 close/high/low/volume 序列，输出指标值。
class TechnicalIndicators {
  // ══════════════════════════════════════════════════════
  //  EMA — 指数移动平均
  // ══════════════════════════════════════════════════════

  /// 计算 EMA 序列，返回与 [values] 等长的列表。
  /// 第一个值用 SMA 初始化。
  static List<double> ema(List<double> values, int period) {
    if (values.isEmpty) return const [];
    if (values.length < period) {
      final avg = _average(values);
      return List.filled(values.length, avg);
    }

    final multiplier = 2.0 / (period + 1);
    final result = List<double>.filled(values.length, 0);
    // 前 period 个用 SMA 初始化
    result[period - 1] = _average(values.sublist(0, period));
    for (var i = period; i < values.length; i++) {
      result[i] = (values[i] - result[i - 1]) * multiplier + result[i - 1];
    }
    // 填充前面未计算的部分
    for (var i = 0; i < period - 1; i++) {
      result[i] = result[period - 1];
    }
    return result;
  }

  /// 返回最新的 EMA 值
  static double emaLatest(List<double> values, int period) {
    if (values.isEmpty) return 0;
    return ema(values, period).last;
  }

  // ══════════════════════════════════════════════════════
  //  RSI — 相对强弱指标 (Wilder's smoothing)
  // ══════════════════════════════════════════════════════

  /// 计算 RSI 序列 (0~100)。
  /// [period] 默认 14。
  static List<double> rsi(List<double> closes, {int period = 14}) {
    if (closes.length < period + 1) {
      return List.filled(closes.length, 50);
    }

    final result = List<double>.filled(closes.length, 50);
    var avgGain = 0.0;
    var avgLoss = 0.0;

    // 初始化：前 period 个变化的平均
    for (var i = 1; i <= period; i++) {
      final change = closes[i] - closes[i - 1];
      if (change >= 0) {
        avgGain += change;
      } else {
        avgLoss -= change;
      }
    }
    avgGain /= period;
    avgLoss /= period;

    result[period] =
        avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);

    for (var i = period + 1; i < closes.length; i++) {
      final change = closes[i] - closes[i - 1];
      final gain = change >= 0 ? change : 0.0;
      final loss = change < 0 ? -change : 0.0;
      avgGain = (avgGain * (period - 1) + gain) / period;
      avgLoss = (avgLoss * (period - 1) + loss) / period;
      result[i] =
          avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);
    }

    // 向前填充
    for (var i = 0; i < period; i++) {
      result[i] = result[period];
    }
    return result;
  }

  /// 返回最新 RSI 值
  static double rsiLatest(List<double> closes, {int period = 14}) {
    if (closes.isEmpty) return 50;
    return rsi(closes, period: period).last;
  }

  // ══════════════════════════════════════════════════════
  //  MACD — 指数平滑异同移动平均线
  // ══════════════════════════════════════════════════════

  /// 返回 (macdLine, signalLine, histogram) 各为等长列表。
  static MacdResult macd(
    List<double> closes, {
    int fastPeriod = 12,
    int slowPeriod = 26,
    int signalPeriod = 9,
  }) {
    final emaFast = ema(closes, fastPeriod);
    final emaSlow = ema(closes, slowPeriod);
    final macdLine = List<double>.generate(
      closes.length,
      (i) => emaFast[i] - emaSlow[i],
    );
    final signal = ema(macdLine, signalPeriod);
    final histogram = List<double>.generate(
      closes.length,
      (i) => macdLine[i] - signal[i],
    );
    return MacdResult(
      macdLine: macdLine,
      signalLine: signal,
      histogram: histogram,
    );
  }

  /// 返回最新 MACD 状态
  static MacdSnapshot macdLatest(List<double> closes) {
    final result = macd(closes);
    final i = closes.length - 1;
    final prevI = max(0, i - 1);
    return MacdSnapshot(
      macdLine: result.macdLine[i],
      signalLine: result.signalLine[i],
      histogram: result.histogram[i],
      prevHistogram: result.histogram[prevI],
      crossover: result.macdLine[i] > result.signalLine[i] &&
          result.macdLine[prevI] <= result.signalLine[prevI],
      crossunder: result.macdLine[i] < result.signalLine[i] &&
          result.macdLine[prevI] >= result.signalLine[prevI],
    );
  }

  // ══════════════════════════════════════════════════════
  //  布林带 (Bollinger Bands)
  // ══════════════════════════════════════════════════════

  /// 返回最新布林带状态
  static BollingerSnapshot bollingerLatest(
    List<double> closes, {
    int period = 20,
    double multiplier = 2.0,
  }) {
    if (closes.length < period) {
      final avg = _average(closes);
      return BollingerSnapshot(
        upper: avg,
        middle: avg,
        lower: avg,
        bandwidth: 0,
        percentB: 0.5,
      );
    }

    final window = closes.sublist(closes.length - period);
    final middle = _average(window);
    final stddev = _stdDev(window);
    final upper = middle + multiplier * stddev;
    final lower = middle - multiplier * stddev;
    final bandwidth =
        middle > 0 ? (upper - lower) / middle : 0.0;
    final percentB =
        (upper - lower) > 0 ? (closes.last - lower) / (upper - lower) : 0.5;

    return BollingerSnapshot(
      upper: upper,
      middle: middle,
      lower: lower,
      bandwidth: bandwidth,
      percentB: percentB.clamp(0.0, 1.0),
    );
  }

  // ══════════════════════════════════════════════════════
  //  ADX — 平均趋向指标 (Wilder's smoothing)
  // ══════════════════════════════════════════════════════

  /// 返回最新 ADX 值 (0~100)
  /// ADX > 25 表示强趋势，< 20 表示震荡。
  static double adxLatest(
    List<double> highs,
    List<double> lows,
    List<double> closes, {
    int period = 14,
  }) {
    final n = highs.length;
    if (n < period * 2 + 1) return 25; // 数据不足返回中性值

    // 计算 True Range, +DM, -DM
    final tr = <double>[];
    final plusDM = <double>[];
    final minusDM = <double>[];

    for (var i = 1; i < n; i++) {
      final highDiff = highs[i] - highs[i - 1];
      final lowDiff = lows[i - 1] - lows[i];

      tr.add([
        highs[i] - lows[i],
        (highs[i] - closes[i - 1]).abs(),
        (lows[i] - closes[i - 1]).abs(),
      ].reduce(max));

      plusDM.add(highDiff > lowDiff && highDiff > 0 ? highDiff : 0);
      minusDM.add(lowDiff > highDiff && lowDiff > 0 ? lowDiff : 0);
    }

    // Wilder's smoothing 初始化
    var smoothTR = tr.sublist(0, period).reduce((a, b) => a + b);
    var smoothPlusDM = plusDM.sublist(0, period).reduce((a, b) => a + b);
    var smoothMinusDM = minusDM.sublist(0, period).reduce((a, b) => a + b);

    final dx = <double>[];

    for (var i = period; i < tr.length; i++) {
      smoothTR = smoothTR - smoothTR / period + tr[i];
      smoothPlusDM = smoothPlusDM - smoothPlusDM / period + plusDM[i];
      smoothMinusDM = smoothMinusDM - smoothMinusDM / period + minusDM[i];

      final plusDI = smoothTR > 0 ? 100 * smoothPlusDM / smoothTR : 0.0;
      final minusDI = smoothTR > 0 ? 100 * smoothMinusDM / smoothTR : 0.0;
      final diSum = plusDI + minusDI;
      dx.add(diSum > 0 ? 100 * (plusDI - minusDI).abs() / diSum : 0);
    }

    if (dx.length < period) return dx.isNotEmpty ? dx.last : 25;

    // ADX = Wilder's smoothing of DX
    var adx = _average(dx.sublist(0, period));
    for (var i = period; i < dx.length; i++) {
      adx = (adx * (period - 1) + dx[i]) / period;
    }
    return adx;
  }

  // ══════════════════════════════════════════════════════
  //  ATR — 平均真实波幅
  // ══════════════════════════════════════════════════════

  /// 返回最新 ATR 值
  static double atrLatest(
    List<double> highs,
    List<double> lows,
    List<double> closes, {
    int period = 14,
  }) {
    final n = highs.length;
    if (n < period + 1) return 0;

    final trValues = <double>[];
    for (var i = 1; i < n; i++) {
      trValues.add([
        highs[i] - lows[i],
        (highs[i] - closes[i - 1]).abs(),
        (lows[i] - closes[i - 1]).abs(),
      ].reduce(max));
    }

    // Wilder's smoothing
    var atr = _average(trValues.sublist(0, period));
    for (var i = period; i < trValues.length; i++) {
      atr = (atr * (period - 1) + trValues[i]) / period;
    }
    return atr;
  }

  // ══════════════════════════════════════════════════════
  //  OBV — 能量潮
  // ══════════════════════════════════════════════════════

  /// 返回 OBV 序列
  static List<double> obv(List<double> closes, List<double> volumes) {
    if (closes.isEmpty) return const [];
    final result = List<double>.filled(closes.length, 0);
    result[0] = volumes[0];
    for (var i = 1; i < closes.length; i++) {
      if (closes[i] > closes[i - 1]) {
        result[i] = result[i - 1] + volumes[i];
      } else if (closes[i] < closes[i - 1]) {
        result[i] = result[i - 1] - volumes[i];
      } else {
        result[i] = result[i - 1];
      }
    }
    return result;
  }

  /// OBV 趋势判断：OBV 的短期 EMA 是否高于长期 EMA
  static double obvTrendScore(List<double> closes, List<double> volumes) {
    final obvValues = obv(closes, volumes);
    if (obvValues.length < 21) return 0.5;
    final obvEma8 = emaLatest(obvValues, 8);
    final obvEma21 = emaLatest(obvValues, 21);
    // 归一化：OBV 短期均线 vs 长期均线
    if (obvEma21 == 0) return 0.5;
    final ratio = (obvEma8 - obvEma21) / obvEma21.abs();
    return (0.5 + ratio * 10).clamp(0.0, 1.0);
  }

  // ══════════════════════════════════════════════════════
  //  RSI 背离检测
  // ══════════════════════════════════════════════════════

  /// 检测看涨背离（价格创新低但 RSI 未创新低）
  /// 返回 0~1 的背离强度分
  static double bullishDivergenceScore(
    List<double> closes, {
    int lookback = 14,
    int rsiPeriod = 14,
  }) {
    if (closes.length < lookback + rsiPeriod + 1) return 0;
    final rsiValues = rsi(closes, period: rsiPeriod);
    final n = closes.length;
    final priceWindow = closes.sublist(n - lookback);
    final rsiWindow = rsiValues.sublist(n - lookback);

    // 找价格最低点
    final priceLowIdx = _minIndex(priceWindow);
    final priceCurrentLow = priceWindow.last;
    final pricePrevLow = priceWindow[priceLowIdx];

    // 价格创新低或接近新低
    if (priceCurrentLow > pricePrevLow * 1.01) return 0;

    // RSI 是否未创新低
    final rsiAtPrevLow = rsiWindow[priceLowIdx];
    final rsiCurrent = rsiWindow.last;
    if (rsiCurrent <= rsiAtPrevLow) return 0;

    // 背离强度 = RSI 差值
    return ((rsiCurrent - rsiAtPrevLow) / 30).clamp(0.0, 1.0);
  }

  // ══════════════════════════════════════════════════════
  //  VWAP 近似（小时级加权均价）
  // ══════════════════════════════════════════════════════

  /// 返回最近 N 根 K 线的 VWAP
  static double vwap(
    List<double> highs,
    List<double> lows,
    List<double> closes,
    List<double> volumes, {
    int period = 24,
  }) {
    final n = highs.length;
    final start = max(0, n - period);
    var sumPV = 0.0;
    var sumV = 0.0;
    for (var i = start; i < n; i++) {
      final typicalPrice = (highs[i] + lows[i] + closes[i]) / 3;
      sumPV += typicalPrice * volumes[i];
      sumV += volumes[i];
    }
    return sumV > 0 ? sumPV / sumV : closes.last;
  }

  // ══════════════════════════════════════════════════════
  //  综合信号评分（融合多指标）
  // ══════════════════════════════════════════════════════

  /// 综合技术指标评分，返回 0~1
  /// 融合 RSI + MACD + 布林带 + EMA趋势 + 量能
  static TechnicalScore compositeScore({
    required List<double> closes,
    required List<double> highs,
    required List<double> lows,
    required List<double> volumes,
  }) {
    if (closes.length < 30) {
      return const TechnicalScore(
        total: 0.5,
        rsiScore: 0.5,
        macdScore: 0.5,
        bollingerScore: 0.5,
        trendScore: 0.5,
        volumeScore: 0.5,
        divergenceScore: 0,
        adxScore: 0.5,
      );
    }

    // 1. RSI 评分：RSI 30-50 区间最佳买入（超卖回升），> 70 惩罚
    final rsiVal = rsiLatest(closes);
    double rsiScore;
    if (rsiVal <= 30) {
      rsiScore = 0.85; // 超卖，反弹概率高
    } else if (rsiVal <= 45) {
      rsiScore = 0.85 + (rsiVal - 30) / 15 * 0.15; // 30~45 → 0.85~1.0
    } else if (rsiVal <= 55) {
      rsiScore = 0.70; // 中性偏强
    } else if (rsiVal <= 70) {
      rsiScore = 0.70 - (rsiVal - 55) / 15 * 0.30; // 55~70 → 0.70~0.40
    } else {
      rsiScore = 0.40 - (rsiVal - 70) / 30 * 0.30; // 超买惩罚
    }
    rsiScore = rsiScore.clamp(0.0, 1.0);

    // 2. MACD 评分
    final macdSnap = macdLatest(closes);
    double macdScoreVal = 0.5;
    if (macdSnap.crossover) {
      macdScoreVal = 0.95; // 金叉
    } else if (macdSnap.crossunder) {
      macdScoreVal = 0.15; // 死叉
    } else if (macdSnap.histogram > 0) {
      // 柱状图为正且在增大
      macdScoreVal = macdSnap.histogram > macdSnap.prevHistogram ? 0.80 : 0.65;
    } else {
      // 柱状图为负
      macdScoreVal = macdSnap.histogram > macdSnap.prevHistogram ? 0.45 : 0.25;
    }

    // 3. 布林带评分
    final bb = bollingerLatest(closes);
    double bbScore;
    if (bb.percentB <= 0.2) {
      bbScore = 0.80; // 触及下轨，超卖反弹
    } else if (bb.percentB <= 0.5) {
      bbScore = 0.80 - (bb.percentB - 0.2) / 0.3 * 0.15; // 0.80~0.65
    } else if (bb.percentB <= 0.8) {
      bbScore = 0.65 - (bb.percentB - 0.5) / 0.3 * 0.25; // 0.65~0.40
    } else {
      bbScore = 0.30; // 触及上轨，追高风险
    }
    // 布林带收窄加分（蓄势突破）
    if (bb.bandwidth < 0.04) {
      bbScore = (bbScore + 0.15).clamp(0.0, 1.0);
    }

    // 4. EMA 趋势评分
    final ema8 = emaLatest(closes, 8);
    final ema21 = emaLatest(closes, 21);
    final ema55 = emaLatest(closes, 55);
    final price = closes.last;
    double trendScore = 0.0;
    if (price > ema8 && ema8 > ema21 && ema21 > ema55) {
      trendScore = 1.0; // 完美多头排列
    } else if (price > ema21 && ema8 > ema21) {
      trendScore = 0.75;
    } else if (price > ema21) {
      trendScore = 0.55;
    } else if (price > ema55) {
      trendScore = 0.35;
    } else {
      trendScore = 0.15;
    }

    // 5. OBV 量能趋势
    final volumeScore = obvTrendScore(closes, volumes);

    // 6. RSI 背离检测
    final divScore = bullishDivergenceScore(closes);

    // 7. ADX 趋势强度
    final adxVal = adxLatest(highs, lows, closes);
    // ADX > 25 且趋势向上 → 好信号
    final adxScore = adxVal > 25 && trendScore >= 0.55
        ? (0.5 + (adxVal - 25) / 50).clamp(0.5, 1.0)
        : adxVal < 20
            ? 0.45 // 震荡市，适合均值回归
            : 0.55;

    // 综合加权
    final total = (rsiScore * 0.18 +
            macdScoreVal * 0.18 +
            bbScore * 0.12 +
            trendScore * 0.22 +
            volumeScore * 0.12 +
            divScore * 0.08 +
            adxScore * 0.10)
        .clamp(0.0, 1.0);

    return TechnicalScore(
      total: total,
      rsiScore: rsiScore,
      macdScore: macdScoreVal,
      bollingerScore: bbScore,
      trendScore: trendScore,
      volumeScore: volumeScore,
      divergenceScore: divScore,
      adxScore: adxScore,
    );
  }

  // ══════════════════════════════════════════════════════
  //  辅助函数
  // ══════════════════════════════════════════════════════

  static double _average(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double _stdDev(List<double> values) {
    if (values.length < 2) return 0;
    final avg = _average(values);
    final variance = values
            .map((v) => pow(v - avg, 2).toDouble())
            .reduce((a, b) => a + b) /
        values.length;
    return sqrt(variance);
  }

  static int _minIndex(List<double> values) {
    var idx = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] < values[idx]) idx = i;
    }
    return idx;
  }
}

// ══════════════════════════════════════════════════════
//  数据模型
// ══════════════════════════════════════════════════════

class MacdResult {
  final List<double> macdLine;
  final List<double> signalLine;
  final List<double> histogram;

  const MacdResult({
    required this.macdLine,
    required this.signalLine,
    required this.histogram,
  });
}

class MacdSnapshot {
  final double macdLine;
  final double signalLine;
  final double histogram;
  final double prevHistogram;
  final bool crossover;  // 金叉
  final bool crossunder; // 死叉

  const MacdSnapshot({
    required this.macdLine,
    required this.signalLine,
    required this.histogram,
    required this.prevHistogram,
    required this.crossover,
    required this.crossunder,
  });
}

class BollingerSnapshot {
  final double upper;
  final double middle;
  final double lower;
  final double bandwidth;  // (上-下)/中
  final double percentB;   // 价格在带中的位置 0~1

  const BollingerSnapshot({
    required this.upper,
    required this.middle,
    required this.lower,
    required this.bandwidth,
    required this.percentB,
  });
}

class TechnicalScore {
  final double total;
  final double rsiScore;
  final double macdScore;
  final double bollingerScore;
  final double trendScore;
  final double volumeScore;
  final double divergenceScore;
  final double adxScore;

  const TechnicalScore({
    required this.total,
    required this.rsiScore,
    required this.macdScore,
    required this.bollingerScore,
    required this.trendScore,
    required this.volumeScore,
    required this.divergenceScore,
    required this.adxScore,
  });
}
