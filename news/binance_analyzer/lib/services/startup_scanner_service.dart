import 'dart:math';

import '../models/coin_data.dart';
import '../utils/technical_indicators.dart';
import 'binance_service.dart';

class StartupScannerService {
  static const int minimumDailyBars = 55;
  static const int minimumHourlyBars = 30;

  StartupScanReport analyzeMarket({
    required List<CoinData> currentCoins,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    StartupScanPolicy policy = StartupScanPolicy.defaultPolicy,
  }) {
    final closedDaily = {
      for (final entry in dailyHistory.entries)
        entry.key: _closedBars(entry.value),
    };
    final closedHourly = {
      for (final entry in hourlyHistory.entries)
        entry.key: _closedBars(entry.value),
    };

    final profiles = <_RawStartupProfile>[];
    for (final coin in currentCoins) {
      final dailyBars = _sorted(closedDaily[coin.symbol] ?? const []);
      final hourlyBars = _sorted(closedHourly[coin.symbol] ?? const []);
      if (dailyBars.length < minimumDailyBars ||
          hourlyBars.length < minimumHourlyBars) {
        continue;
      }

      final profile = _buildRawProfile(
        coin: coin,
        dailyBars: dailyBars,
        hourlyBars: hourlyBars,
      );
      if (profile != null) {
        profiles.add(profile);
      }
    }

    if (profiles.isEmpty) {
      return StartupScanReport(
        generatedAt: DateTime.now(),
        universeSize: currentCoins.length,
        analyzedSymbols: 0,
        strategyLabel: policy.label,
        marketRegime: const StartupMarketRegime(
          allowEntries: false,
          status: 'neutral',
          reason: '历史数据不足，暂不出手。',
          marketTrendBreadth: 0,
          marketMomentumBreadth: 0,
          marketVolumeBreadth: 0,
          redBreadth: 0,
          deepRedBreadth: 0,
        ),
        candidates: const [],
        notes: '可用于启动扫描的币种不足，可能是历史 K 线样本不够。',
      );
    }

    final liquidityRanks = _percentileRank({
      for (final profile in profiles)
        profile.symbol: log(profile.coin.quoteVolume + 1) +
            log(profile.coin.count + 1) * 0.35,
    });
    final momentumRanks = _percentileRank({
      for (final profile in profiles)
        profile.symbol: profile.momentum7 * 0.7 + profile.momentum30 * 0.3,
    });
    final marketTrendBreadth = profiles
            .where((profile) => profile.coin.lastPrice > profile.sma20)
            .length /
        profiles.length;
    final marketMomentumBreadth =
        profiles.where((profile) => profile.momentum7 > 0).length /
            profiles.length;
    final marketVolumeBreadth = profiles
            .where(
                (profile) => profile.volumeRatio >= policy.minWatchVolumeRatio)
            .length /
        profiles.length;
    final redBreadth = profiles
            .where((profile) => profile.coin.priceChangePercent < 0)
            .length /
        profiles.length;
    final deepRedBreadth = profiles
            .where((profile) => profile.coin.priceChangePercent <= -3.0)
            .length /
        profiles.length;
    final benchmarkContext = _buildBenchmarkContext(
      dailyHistory: closedDaily,
      hourlyHistory: closedHourly,
    );
    final marketRegime = _buildMarketRegime(
      marketTrendBreadth: marketTrendBreadth,
      marketMomentumBreadth: marketMomentumBreadth,
      marketVolumeBreadth: marketVolumeBreadth,
      redBreadth: redBreadth,
      deepRedBreadth: deepRedBreadth,
      benchmarkContext: benchmarkContext,
      policy: policy,
    );

    final candidates = profiles
        .map(
          (profile) => _toCandidate(
            profile,
            liquidityRank: liquidityRanks[profile.symbol] ?? 0,
            momentumRank: momentumRanks[profile.symbol] ?? 0,
            marketTrendBreadth: marketTrendBreadth,
            marketMomentumBreadth: marketMomentumBreadth,
            marketRegime: marketRegime,
            policy: policy,
          ),
        )
        .toList()
      ..sort((a, b) {
        final byNotify =
            (b.shouldNotify ? 1 : 0).compareTo(a.shouldNotify ? 1 : 0);
        if (byNotify != 0) return byNotify;
        final byWatch =
            (b.shouldWatch ? 1 : 0).compareTo(a.shouldWatch ? 1 : 0);
        if (byWatch != 0) return byWatch;
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return b.volumeRatio.compareTo(a.volumeRatio);
      });

    final actionable = candidates.where((item) => item.shouldNotify).length;
    final watchCount =
        candidates.where((item) => item.signalStage == 'watch').length;
    final blockedCount = candidates
        .where((item) => item.signalStage == 'blocked_by_market')
        .length;
    final notes = actionable > 0
        ? '当前共发现 $actionable 个满足正式买入阈值的币，已按总分和量能排序。'
        : watchCount > 0
            ? '当前有 $watchCount 个币进入观察区，建议等待下一轮确认后再买。'
            : blockedCount > 0
                ? '存在 $blockedCount 个候选币，但全局市场过滤器建议空仓等待。'
                : '当前没有满足启动阈值的币，建议继续等待放量突破。';

    return StartupScanReport(
      generatedAt: DateTime.now(),
      universeSize: currentCoins.length,
      analyzedSymbols: profiles.length,
      strategyLabel: policy.label,
      marketRegime: marketRegime,
      candidates: candidates,
      notes: notes,
    );
  }

  _RawStartupProfile? _buildRawProfile({
    required CoinData coin,
    required List<Kline> dailyBars,
    required List<Kline> hourlyBars,
  }) {
    final dailyCloses = dailyBars.map((bar) => bar.close).toList();
    final hourlyCloses = hourlyBars.map((bar) => bar.close).toList();
    final latestDailyClose = dailyCloses.last;
    final latestHourlyClose = hourlyCloses.last;
    if (latestDailyClose <= 0 || latestHourlyClose <= 0) return null;

    final dailyWindow30 = dailyBars.sublist(dailyBars.length - 30);
    final dailyWindow7 = dailyBars.sublist(dailyBars.length - 7);
    final priorDaily20 =
        dailyBars.sublist(dailyBars.length - 21, dailyBars.length - 1);
    final priorHourly24 =
        hourlyBars.sublist(hourlyBars.length - 25, hourlyBars.length - 1);

    final sma20 = _average(dailyCloses.sublist(dailyCloses.length - 20));
    final sma50 = _average(dailyCloses.sublist(dailyCloses.length - 50));
    final hourlySma8 = _average(hourlyCloses.sublist(hourlyCloses.length - 8));
    final hourlySma21 =
        _average(hourlyCloses.sublist(hourlyCloses.length - 21));

    final high20 = priorDaily20.map((bar) => bar.high).reduce(max);
    final high10 = dailyBars
        .sublist(dailyBars.length - 11, dailyBars.length - 1)
        .map((bar) => bar.high)
        .reduce(max);
    final high24h = priorHourly24.map((bar) => bar.high).reduce(max);
    final low30 = dailyWindow30.map((bar) => bar.low).reduce(min);
    final high30 = dailyWindow30.map((bar) => bar.high).reduce(max);
    final low7 = dailyWindow7.map((bar) => bar.low).reduce(min);
    final high7 = dailyWindow7.map((bar) => bar.high).reduce(max);

    final dailyBreakoutDistance =
        high20 <= 0 ? 0 : ((coin.lastPrice - high20) / high20) * 100;
    final hourlyBreakoutDistance =
        high24h <= 0 ? 0 : ((coin.lastPrice - high24h) / high24h) * 100;
    final momentum7 =
        ((latestDailyClose - dailyBars[dailyBars.length - 8].close) /
                max(dailyBars[dailyBars.length - 8].close, 0.000001)) *
            100;
    final momentum30 =
        ((latestDailyClose - dailyBars[dailyBars.length - 31].close) /
                max(dailyBars[dailyBars.length - 31].close, 0.000001)) *
            100;
    final dailyRange30 = (high30 - low30) / max(latestDailyClose, 0.000001);
    final dailyRange7 = (high7 - low7) / max(latestDailyClose, 0.000001);
    final volumeRatio = _average(
          hourlyBars
              .sublist(hourlyBars.length - 3)
              .map((bar) => bar.quoteVolume)
              .toList(),
        ) /
        max(
          _average(
            hourlyBars
                .sublist(hourlyBars.length - 27, hourlyBars.length - 3)
                .map((bar) => bar.quoteVolume)
                .toList(),
          ),
          0.000001,
        );

    // 计算技术指标
    final dailyClosesList = dailyCloses;
    final dailyHighsList = dailyBars.map((b) => b.high).toList();
    final dailyLowsList = dailyBars.map((b) => b.low).toList();
    final dailyVolumesList = dailyBars.map((b) => b.quoteVolume).toList();
    final hourlyClosesList = hourlyCloses;
    final dailyRsi = TechnicalIndicators.rsiLatest(dailyClosesList);
    final hourlyRsi = TechnicalIndicators.rsiLatest(hourlyClosesList);
    final dailyMacd = TechnicalIndicators.macdLatest(dailyClosesList);
    final hourlyMacd = TechnicalIndicators.macdLatest(hourlyClosesList);
    final bb = TechnicalIndicators.bollingerLatest(dailyClosesList);
    final adxVal = dailyHighsList.length >= 30
        ? TechnicalIndicators.adxLatest(
            dailyHighsList, dailyLowsList, dailyClosesList)
        : 25.0;
    final obvTrend =
        TechnicalIndicators.obvTrendScore(dailyClosesList, dailyVolumesList);

    return _RawStartupProfile(
      coin: coin,
      symbol: coin.displayName,
      sma20: sma20,
      sma50: sma50,
      hourlySma8: hourlySma8,
      hourlySma21: hourlySma21,
      dailyBreakoutDistance: dailyBreakoutDistance.toDouble(),
      hourlyBreakoutDistance: hourlyBreakoutDistance.toDouble(),
      momentum7: momentum7,
      momentum30: momentum30,
      dailyRange30: dailyRange30,
      dailyRange7: dailyRange7,
      nearTermPivotDistance:
          high10 <= 0 ? 0 : ((coin.lastPrice - high10) / high10) * 100,
      volumeRatio: volumeRatio,
      dailyRsi: dailyRsi,
      hourlyRsi: hourlyRsi,
      dailyMacdHistogram: dailyMacd.histogram,
      dailyMacdCrossover: dailyMacd.crossover,
      hourlyMacdHistogram: hourlyMacd.histogram,
      hourlyMacdCrossover: hourlyMacd.crossover,
      bollingerPercentB: bb.percentB,
      bollingerBandwidth: bb.bandwidth,
      adx: adxVal,
      obvTrend: obvTrend,
    );
  }

  StartupScanCandidate _toCandidate(
    _RawStartupProfile profile, {
    required double liquidityRank,
    required double momentumRank,
    required double marketTrendBreadth,
    required double marketMomentumBreadth,
    required StartupMarketRegime marketRegime,
    required StartupScanPolicy policy,
  }) {
    final price = profile.coin.lastPrice;
    final trendScore = ((price > profile.sma20 ? 1.0 : 0.15) * 0.4 +
            (profile.sma20 > profile.sma50 ? 1.0 : 0.15) * 0.35 +
            (profile.hourlySma8 > profile.hourlySma21 ? 1.0 : 0.2) * 0.25)
        .clamp(0.0, 1.0);

    final compressionScore =
        (1 - (profile.dailyRange7 / max(profile.dailyRange30, 0.000001)))
            .clamp(0.0, 1.0);
    final pivotScore =
        _sweetSpot(profile.nearTermPivotDistance, 0.35, 1.6).clamp(0.0, 1.0);
    final breakoutScore =
        (_breakoutProximityScore(profile.dailyBreakoutDistance) * 0.65 +
                _breakoutProximityScore(profile.hourlyBreakoutDistance) * 0.35)
            .clamp(0.0, 1.0);
    final volumeScore = _clamp01((profile.volumeRatio - 1.0) / 1.05);
    final dailyChangeScore = _sweetSpot(
      profile.coin.priceChangePercent,
      3.2,
      4.8,
    );
    final marketScore = (marketTrendBreadth * 0.6 + marketMomentumBreadth * 0.4)
        .clamp(0.0, 1.0);
    final momentumScore = (momentumRank * 0.45 +
            _sweetSpot(profile.momentum7, 5.5, 6.0) * 0.25 +
            _sweetSpot(profile.momentum30, 10, 16) * 0.2 +
            dailyChangeScore * 0.1)
        .clamp(0.0, 1.0);
    final confirmationScore = (trendScore * 0.36 +
            breakoutScore * 0.28 +
            volumeScore * 0.22 +
            marketScore * 0.14)
        .clamp(0.0, 1.0);

    final overextendedPenalty = profile.momentum30 > 36 ||
            profile.coin.priceChangePercent > 8.6 ||
            profile.dailyBreakoutDistance > 2.8 ||
            profile.nearTermPivotDistance > 2.2
        ? 0.14
        : 0.0;
    final weakLiquidityPenalty = liquidityRank < 0.18 ? 0.04 : 0.0;

    // 原始评分（保持100%权重，不稀释）
    var score = (trendScore * 0.22 +
            compressionScore * 0.20 +
            breakoutScore * 0.22 +
            volumeScore * 0.15 +
            pivotScore * 0.11 +
            momentumScore * 0.06 +
            liquidityRank * 0.03 +
            marketScore * 0.01 -
            weakLiquidityPenalty -
            overextendedPenalty)
        .clamp(0.0, 1.0);

    // ─── 技术指标乘数调整 ───

    // MACD 金叉确认 → +8%
    if (profile.dailyMacdCrossover || profile.hourlyMacdCrossover) {
      score *= 1.08;
    }
    // MACD 双周期负向 → -5%
    if (profile.dailyMacdHistogram < 0 && profile.hourlyMacdHistogram < 0) {
      score *= 0.95;
    }

    // 布林带极窄(蓄势) + 趋势向好 → +6%
    if (profile.bollingerBandwidth < 0.04 && trendScore >= 0.5) {
      score *= 1.06;
    }

    // RSI 超买 → -10%
    if (profile.dailyRsi > 78 || profile.hourlyRsi > 80) {
      score *= 0.90;
    }

    // ADX 强趋势 + 方向正确 → +4%
    if (profile.adx > 30 && trendScore >= 0.6) {
      score *= 1.04;
    }

    // OBV 量价配合确认 → +4%
    if (profile.obvTrend > 0.65) {
      score *= 1.04;
    }

    score = score.clamp(0.0, 1.0);

    final shouldWatch = score >= policy.minWatchScore &&
        trendScore >= policy.minWatchTrendScore &&
        compressionScore >= policy.minWatchCompressionScore &&
        liquidityRank >= policy.minWatchLiquidityScore &&
        momentumScore >= policy.minWatchMomentumScore &&
        profile.volumeRatio >= policy.minWatchVolumeRatio &&
        profile.coin.quoteVolume >= policy.minWatchQuoteVolume &&
        profile.coin.count >= policy.minWatchTradeCount &&
        profile.dailyBreakoutDistance >= policy.minWatchBreakoutDistance &&
        profile.dailyBreakoutDistance <= policy.maxWatchBreakoutDistance &&
        profile.hourlyBreakoutDistance >=
            policy.minWatchHourlyBreakoutDistance &&
        profile.hourlyBreakoutDistance <=
            policy.maxWatchHourlyBreakoutDistance &&
        profile.nearTermPivotDistance >= policy.minWatchNearTermPivotDistance &&
        profile.nearTermPivotDistance <= policy.maxWatchNearTermPivotDistance &&
        profile.momentum30 <= policy.maxThirtyDayMomentum &&
        profile.coin.priceChangePercent <= policy.maxDailyChangePercent;

    final rawShouldNotify = score >= policy.minScore &&
        trendScore >= policy.minTrendScore &&
        compressionScore >= policy.minCompressionScore &&
        liquidityRank >= policy.minLiquidityScore &&
        momentumScore >= policy.minMomentumScore &&
        marketTrendBreadth >= policy.minMarketTrendBreadth &&
        marketMomentumBreadth >= policy.minMarketMomentumBreadth &&
        profile.volumeRatio >= policy.minVolumeRatio &&
        profile.coin.quoteVolume >= policy.minQuoteVolume &&
        profile.coin.count >= policy.minTradeCount &&
        profile.coin.priceChangePercent >= policy.minDailyChangePercent &&
        profile.dailyBreakoutDistance >= policy.minBreakoutDistance &&
        profile.dailyBreakoutDistance <= policy.maxBreakoutDistance &&
        profile.hourlyBreakoutDistance >= policy.minHourlyBreakoutDistance &&
        profile.hourlyBreakoutDistance <= policy.maxHourlyBreakoutDistance &&
        profile.nearTermPivotDistance >= policy.minNearTermPivotDistance &&
        profile.nearTermPivotDistance <= policy.maxNearTermPivotDistance &&
        profile.momentum30 <= policy.maxThirtyDayMomentum &&
        profile.coin.priceChangePercent <= policy.maxDailyChangePercent;
    final blockedByMarket = !marketRegime.allowEntries && shouldWatch;
    final shouldNotify = rawShouldNotify && marketRegime.allowEntries;
    final signalStage = shouldNotify
        ? 'buy'
        : blockedByMarket
            ? 'blocked_by_market'
            : shouldWatch
                ? 'watch'
                : 'ignore';

    final reasonParts = <String>[
      '24h额 ${_compactUsd(profile.coin.quoteVolume)}',
      '量比 ${profile.volumeRatio.toStringAsFixed(2)}x',
      'RSI ${profile.dailyRsi.toStringAsFixed(0)}/${profile.hourlyRsi.toStringAsFixed(0)}',
      '距20日突破位 ${profile.dailyBreakoutDistance >= 0 ? '+' : ''}${profile.dailyBreakoutDistance.toStringAsFixed(2)}%',
    ];

    if (profile.dailyMacdCrossover || profile.hourlyMacdCrossover) {
      reasonParts.add('MACD金叉');
    } else if (profile.dailyMacdHistogram > 0) {
      reasonParts.add('MACD柱正向');
    }
    if (profile.bollingerBandwidth < 0.04) {
      reasonParts.add('布林收窄蓄势');
    }
    if (profile.adx > 30) {
      reasonParts.add('强趋势ADX${profile.adx.toStringAsFixed(0)}');
    }
    if (profile.obvTrend > 0.65) {
      reasonParts.add('OBV量价配合');
    }
    if (compressionScore >= 0.55) {
      reasonParts.add('波动收缩');
    }
    if (trendScore >= 0.7) {
      reasonParts.add('趋势同步');
    }
    if (marketTrendBreadth >= 0.55) {
      reasonParts.add('市场配合');
    }

    return StartupScanCandidate(
      symbol: profile.symbol,
      currentPrice: profile.coin.lastPrice,
      score: score,
      setupScore: score,
      confirmationScore: confirmationScore,
      trendScore: trendScore,
      compressionScore: compressionScore,
      momentumScore: momentumScore,
      liquidityScore: liquidityRank,
      volumeRatio: profile.volumeRatio,
      dailyBreakoutDistance: profile.dailyBreakoutDistance,
      hourlyBreakoutDistance: profile.hourlyBreakoutDistance,
      nearTermPivotDistance: profile.nearTermPivotDistance,
      marketTrendBreadth: marketTrendBreadth,
      marketMomentumBreadth: marketMomentumBreadth,
      sevenDayMomentum: profile.momentum7,
      thirtyDayMomentum: profile.momentum30,
      reason: reasonParts.join('；'),
      signalStage: signalStage,
      shouldWatch: shouldWatch,
      blockedByMarket: blockedByMarket,
      shouldNotify: shouldNotify,
    );
  }

  StartupMarketRegime _buildMarketRegime({
    required double marketTrendBreadth,
    required double marketMomentumBreadth,
    required double marketVolumeBreadth,
    required double redBreadth,
    required double deepRedBreadth,
    required _BenchmarkContext benchmarkContext,
    required StartupScanPolicy policy,
  }) {
    final breadthAllows =
        marketTrendBreadth >= policy.minMarketTrendBreadthForEntry &&
            marketMomentumBreadth >= policy.minMarketMomentumBreadthForEntry &&
            marketVolumeBreadth >= policy.minMarketVolumeBreadthForEntry &&
            redBreadth <= policy.maxRedBreadthForEntry &&
            deepRedBreadth <= policy.maxDeepRedBreadthForEntry;
    final benchmarkAllows =
        !benchmarkContext.available || benchmarkContext.score >= 0.56;
    final allowEntries = breadthAllows && benchmarkAllows;

    final status = allowEntries
        ? 'risk_on'
        : benchmarkContext.available && !benchmarkAllows
            ? 'risk_off'
            : redBreadth > policy.maxRedBreadthForEntry ||
                    deepRedBreadth > policy.maxDeepRedBreadthForEntry
                ? 'risk_off'
                : 'neutral';

    final reason = allowEntries
        ? '市场环境允许试仓，启动信号可继续跟踪确认。'
        : benchmarkContext.available && !benchmarkAllows
            ? benchmarkContext.reason
            : redBreadth > policy.maxRedBreadthForEntry ||
                    deepRedBreadth > policy.maxDeepRedBreadthForEntry
                ? '全市场下跌广度偏大，先空仓等待更稳。'
                : '市场趋势和量能尚未同步，先观察不追。';

    return StartupMarketRegime(
      allowEntries: allowEntries,
      status: status,
      reason: reason,
      marketTrendBreadth: marketTrendBreadth,
      marketMomentumBreadth: marketMomentumBreadth,
      marketVolumeBreadth: marketVolumeBreadth,
      redBreadth: redBreadth,
      deepRedBreadth: deepRedBreadth,
      benchmarkStatus:
          benchmarkContext.available ? benchmarkContext.status : 'unavailable',
      benchmarkScore: benchmarkContext.score,
      benchmarkReason: benchmarkContext.reason,
      btcDailyTrend: benchmarkContext.btcDailyTrend,
      btcHourlyTrend: benchmarkContext.btcHourlyTrend,
      ethDailyTrend: benchmarkContext.ethDailyTrend,
      ethHourlyTrend: benchmarkContext.ethHourlyTrend,
    );
  }

  _BenchmarkContext _buildBenchmarkContext({
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
  }) {
    _BenchmarkSnapshot? assetSnapshot(String symbol) {
      final dailyBars = _sorted(dailyHistory[symbol] ?? const []);
      final hourlyBars = _sorted(hourlyHistory[symbol] ?? const []);
      if (dailyBars.length < 50 || hourlyBars.length < 21) {
        return null;
      }

      final dailyCloses = dailyBars.map((bar) => bar.close).toList();
      final hourlyCloses = hourlyBars.map((bar) => bar.close).toList();
      final dailyLast = dailyCloses.last;
      final hourlyLast = hourlyCloses.last;
      final sma20 = _average(dailyCloses.sublist(dailyCloses.length - 20));
      final sma50 = _average(dailyCloses.sublist(dailyCloses.length - 50));
      final hourlySma8 =
          _average(hourlyCloses.sublist(hourlyCloses.length - 8));
      final hourlySma21 =
          _average(hourlyCloses.sublist(hourlyCloses.length - 21));

      final dailyTrend = ((dailyLast > sma20 ? 1.0 : 0.12) * 0.58 +
              (sma20 > sma50 ? 1.0 : 0.18) * 0.42)
          .clamp(0.0, 1.0);
      final hourlyTrend = ((hourlyLast > hourlySma8 ? 1.0 : 0.16) * 0.55 +
              (hourlySma8 > hourlySma21 ? 1.0 : 0.2) * 0.45)
          .clamp(0.0, 1.0);
      return _BenchmarkSnapshot(
        symbol: symbol,
        score: (dailyTrend * 0.62 + hourlyTrend * 0.38).clamp(0.0, 1.0),
        dailyTrend: dailyTrend,
        hourlyTrend: hourlyTrend,
      );
    }

    final btc = assetSnapshot('BTCUSDT');
    final eth = assetSnapshot('ETHUSDT');
    final availableBenchmarks =
        [btc, eth].whereType<_BenchmarkSnapshot>().toList();
    if (availableBenchmarks.isEmpty) {
      return const _BenchmarkContext.unavailable();
    }

    final score =
        _average(availableBenchmarks.map((item) => item.score).toList());
    final status = score >= 0.64
        ? 'aligned'
        : score >= 0.56
            ? 'mixed'
            : 'weak';
    final reason = status == 'aligned'
        ? 'BTC/ETH 结构同步偏强，大盘允许继续观察启动信号。'
        : status == 'mixed'
            ? 'BTC/ETH 结构分化，允许轻仓试错但不宜激进追高。'
            : 'BTC/ETH 主趋势未确认，先减少山寨启动交易，等待大盘结构修复。';

    return _BenchmarkContext(
      available: true,
      score: score,
      status: status,
      reason: reason,
      btcDailyTrend: btc?.dailyTrend ?? 0.0,
      btcHourlyTrend: btc?.hourlyTrend ?? 0.0,
      ethDailyTrend: eth?.dailyTrend ?? 0.0,
      ethHourlyTrend: eth?.hourlyTrend ?? 0.0,
    );
  }

  static List<Kline> _closedBars(List<Kline> bars) {
    if (bars.isEmpty) return const [];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final filtered =
        bars.where((bar) => bar.closeTime < nowMs - 60 * 1000).toList();
    return filtered.isNotEmpty ? filtered : bars;
  }

  static List<Kline> _sorted(List<Kline> bars) {
    final copy = [...bars];
    copy.sort((a, b) => a.closeTime.compareTo(b.closeTime));
    return copy;
  }

  static Map<String, double> _percentileRank(Map<String, double> values) {
    if (values.isEmpty) return const {};
    final entries = values.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (entries.length == 1) {
      return {entries.first.key: 1};
    }

    final result = <String, double>{};
    for (var i = 0; i < entries.length; i++) {
      result[entries[i].key] = i / (entries.length - 1);
    }
    return result;
  }

  static double _average(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double _clamp01(double value) => value.clamp(0.0, 1.0);

  static double _sweetSpot(double value, double center, double width) {
    if (width <= 0) return 0;
    return (1 - ((value - center).abs() / width)).clamp(0.0, 1.0);
  }

  static double _breakoutProximityScore(double distancePercent) {
    if (distancePercent < -4.5 || distancePercent > 4.5) return 0;
    if (distancePercent <= 1.4) {
      return _sweetSpot(distancePercent, 0.4, 2.0);
    }
    return _sweetSpot(distancePercent, 1.6, 2.8);
  }

  static String _compactUsd(double value) {
    if (value >= 1000000000) {
      return '${(value / 1000000000).toStringAsFixed(2)}B';
    }
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(0)}K';
    }
    return value.toStringAsFixed(0);
  }
}

class StartupScanPolicy {
  final String label;
  final double minScore;
  final double minTrendScore;
  final double minCompressionScore;
  final double minLiquidityScore;
  final double minMomentumScore;
  final double minMarketTrendBreadth;
  final double minMarketMomentumBreadth;
  final double minVolumeRatio;
  final double minDailyChangePercent;
  final double minBreakoutDistance;
  final double maxBreakoutDistance;
  final double minHourlyBreakoutDistance;
  final double maxHourlyBreakoutDistance;
  final double minNearTermPivotDistance;
  final double maxNearTermPivotDistance;
  final double maxThirtyDayMomentum;
  final double maxDailyChangePercent;
  final double minQuoteVolume;
  final int minTradeCount;
  final double minWatchScore;
  final double minWatchTrendScore;
  final double minWatchCompressionScore;
  final double minWatchLiquidityScore;
  final double minWatchMomentumScore;
  final double minWatchVolumeRatio;
  final double minWatchBreakoutDistance;
  final double maxWatchBreakoutDistance;
  final double minWatchHourlyBreakoutDistance;
  final double maxWatchHourlyBreakoutDistance;
  final double minWatchNearTermPivotDistance;
  final double maxWatchNearTermPivotDistance;
  final double minWatchQuoteVolume;
  final int minWatchTradeCount;
  final double minMarketTrendBreadthForEntry;
  final double minMarketMomentumBreadthForEntry;
  final double minMarketVolumeBreadthForEntry;
  final double maxRedBreadthForEntry;
  final double maxDeepRedBreadthForEntry;
  final int maxPushCandidates;
  final int maxObservationCandidates;
  final int observationCooldownHours;
  final int confirmationWindowHours;
  final int cooldownHours;

  static const StartupScanPolicy defaultPolicy = StartupScanPolicy(
    label: '全市场启动扫描',
    minScore: 0.74,
    minTrendScore: 0.66,
    minCompressionScore: 0.24,
    minLiquidityScore: 0.18,
    minMomentumScore: 0.26,
    minMarketTrendBreadth: 0.54,
    minMarketMomentumBreadth: 0.48,
    minVolumeRatio: 1.42,
    minDailyChangePercent: 1.8,
    minBreakoutDistance: -1.4,
    maxBreakoutDistance: 2.4,
    minHourlyBreakoutDistance: -1.2,
    maxHourlyBreakoutDistance: 2.2,
    minNearTermPivotDistance: -1.0,
    maxNearTermPivotDistance: 1.8,
    maxThirtyDayMomentum: 42,
    maxDailyChangePercent: 9,
    minQuoteVolume: 3000000,
    minTradeCount: 6000,
    minWatchScore: 0.67,
    minWatchTrendScore: 0.58,
    minWatchCompressionScore: 0.18,
    minWatchLiquidityScore: 0.14,
    minWatchMomentumScore: 0.20,
    minWatchVolumeRatio: 1.15,
    minWatchBreakoutDistance: -2.2,
    maxWatchBreakoutDistance: 2.8,
    minWatchHourlyBreakoutDistance: -1.8,
    maxWatchHourlyBreakoutDistance: 2.6,
    minWatchNearTermPivotDistance: -1.3,
    maxWatchNearTermPivotDistance: 2.0,
    minWatchQuoteVolume: 1800000,
    minWatchTradeCount: 3200,
    minMarketTrendBreadthForEntry: 0.52,
    minMarketMomentumBreadthForEntry: 0.45,
    minMarketVolumeBreadthForEntry: 0.30,
    maxRedBreadthForEntry: 0.58,
    maxDeepRedBreadthForEntry: 0.26,
    maxPushCandidates: 2,
    maxObservationCandidates: 3,
    observationCooldownHours: 2,
    confirmationWindowHours: 4,
    cooldownHours: 10,
  );

  const StartupScanPolicy({
    required this.label,
    required this.minScore,
    required this.minTrendScore,
    required this.minCompressionScore,
    required this.minLiquidityScore,
    required this.minMomentumScore,
    required this.minMarketTrendBreadth,
    required this.minMarketMomentumBreadth,
    required this.minVolumeRatio,
    required this.minDailyChangePercent,
    required this.minBreakoutDistance,
    required this.maxBreakoutDistance,
    required this.minHourlyBreakoutDistance,
    required this.maxHourlyBreakoutDistance,
    required this.minNearTermPivotDistance,
    required this.maxNearTermPivotDistance,
    required this.maxThirtyDayMomentum,
    required this.maxDailyChangePercent,
    required this.minQuoteVolume,
    required this.minTradeCount,
    required this.minWatchScore,
    required this.minWatchTrendScore,
    required this.minWatchCompressionScore,
    required this.minWatchLiquidityScore,
    required this.minWatchMomentumScore,
    required this.minWatchVolumeRatio,
    required this.minWatchBreakoutDistance,
    required this.maxWatchBreakoutDistance,
    required this.minWatchHourlyBreakoutDistance,
    required this.maxWatchHourlyBreakoutDistance,
    required this.minWatchNearTermPivotDistance,
    required this.maxWatchNearTermPivotDistance,
    required this.minWatchQuoteVolume,
    required this.minWatchTradeCount,
    required this.minMarketTrendBreadthForEntry,
    required this.minMarketMomentumBreadthForEntry,
    required this.minMarketVolumeBreadthForEntry,
    required this.maxRedBreadthForEntry,
    required this.maxDeepRedBreadthForEntry,
    required this.maxPushCandidates,
    required this.maxObservationCandidates,
    required this.observationCooldownHours,
    required this.confirmationWindowHours,
    required this.cooldownHours,
  });

  String get summary => 'score>=${(minScore * 100).round()} '
      '| watch>=${(minWatchScore * 100).round()} '
      '| trend>=${(minTrendScore * 100).round()} '
      '| compression>=${(minCompressionScore * 100).round()} '
      '| liquidity>=${(minLiquidityScore * 100).round()} '
      '| momentum>=${(minMomentumScore * 100).round()} '
      '| marketTrend>=${(minMarketTrendBreadthForEntry * 100).round()} '
      '| marketMomentum>=${(minMarketMomentumBreadthForEntry * 100).round()} '
      '| volume>=${minVolumeRatio.toStringAsFixed(2)}x '
      '| watchCooldown=${observationCooldownHours}h '
      '| confirmWindow=${confirmationWindowHours}h '
      '| cooldown=${cooldownHours}h';

  StartupScanPolicy copyWith({
    String? label,
    double? minScore,
    double? minTrendScore,
    double? minCompressionScore,
    double? minLiquidityScore,
    double? minMomentumScore,
    double? minMarketTrendBreadth,
    double? minMarketMomentumBreadth,
    double? minVolumeRatio,
    double? minDailyChangePercent,
    double? minBreakoutDistance,
    double? maxBreakoutDistance,
    double? minHourlyBreakoutDistance,
    double? maxHourlyBreakoutDistance,
    double? minNearTermPivotDistance,
    double? maxNearTermPivotDistance,
    double? maxThirtyDayMomentum,
    double? maxDailyChangePercent,
    double? minQuoteVolume,
    int? minTradeCount,
    double? minWatchScore,
    double? minWatchTrendScore,
    double? minWatchCompressionScore,
    double? minWatchLiquidityScore,
    double? minWatchMomentumScore,
    double? minWatchVolumeRatio,
    double? minWatchBreakoutDistance,
    double? maxWatchBreakoutDistance,
    double? minWatchHourlyBreakoutDistance,
    double? maxWatchHourlyBreakoutDistance,
    double? minWatchNearTermPivotDistance,
    double? maxWatchNearTermPivotDistance,
    double? minWatchQuoteVolume,
    int? minWatchTradeCount,
    double? minMarketTrendBreadthForEntry,
    double? minMarketMomentumBreadthForEntry,
    double? minMarketVolumeBreadthForEntry,
    double? maxRedBreadthForEntry,
    double? maxDeepRedBreadthForEntry,
    int? maxPushCandidates,
    int? maxObservationCandidates,
    int? observationCooldownHours,
    int? confirmationWindowHours,
    int? cooldownHours,
  }) {
    return StartupScanPolicy(
      label: label ?? this.label,
      minScore: minScore ?? this.minScore,
      minTrendScore: minTrendScore ?? this.minTrendScore,
      minCompressionScore: minCompressionScore ?? this.minCompressionScore,
      minLiquidityScore: minLiquidityScore ?? this.minLiquidityScore,
      minMomentumScore: minMomentumScore ?? this.minMomentumScore,
      minMarketTrendBreadth:
          minMarketTrendBreadth ?? this.minMarketTrendBreadth,
      minMarketMomentumBreadth:
          minMarketMomentumBreadth ?? this.minMarketMomentumBreadth,
      minVolumeRatio: minVolumeRatio ?? this.minVolumeRatio,
      minDailyChangePercent:
          minDailyChangePercent ?? this.minDailyChangePercent,
      minBreakoutDistance: minBreakoutDistance ?? this.minBreakoutDistance,
      maxBreakoutDistance: maxBreakoutDistance ?? this.maxBreakoutDistance,
      minHourlyBreakoutDistance:
          minHourlyBreakoutDistance ?? this.minHourlyBreakoutDistance,
      maxHourlyBreakoutDistance:
          maxHourlyBreakoutDistance ?? this.maxHourlyBreakoutDistance,
      minNearTermPivotDistance:
          minNearTermPivotDistance ?? this.minNearTermPivotDistance,
      maxNearTermPivotDistance:
          maxNearTermPivotDistance ?? this.maxNearTermPivotDistance,
      maxThirtyDayMomentum: maxThirtyDayMomentum ?? this.maxThirtyDayMomentum,
      maxDailyChangePercent:
          maxDailyChangePercent ?? this.maxDailyChangePercent,
      minQuoteVolume: minQuoteVolume ?? this.minQuoteVolume,
      minTradeCount: minTradeCount ?? this.minTradeCount,
      minWatchScore: minWatchScore ?? this.minWatchScore,
      minWatchTrendScore: minWatchTrendScore ?? this.minWatchTrendScore,
      minWatchCompressionScore:
          minWatchCompressionScore ?? this.minWatchCompressionScore,
      minWatchLiquidityScore:
          minWatchLiquidityScore ?? this.minWatchLiquidityScore,
      minWatchMomentumScore:
          minWatchMomentumScore ?? this.minWatchMomentumScore,
      minWatchVolumeRatio: minWatchVolumeRatio ?? this.minWatchVolumeRatio,
      minWatchBreakoutDistance:
          minWatchBreakoutDistance ?? this.minWatchBreakoutDistance,
      maxWatchBreakoutDistance:
          maxWatchBreakoutDistance ?? this.maxWatchBreakoutDistance,
      minWatchHourlyBreakoutDistance:
          minWatchHourlyBreakoutDistance ?? this.minWatchHourlyBreakoutDistance,
      maxWatchHourlyBreakoutDistance:
          maxWatchHourlyBreakoutDistance ?? this.maxWatchHourlyBreakoutDistance,
      minWatchNearTermPivotDistance:
          minWatchNearTermPivotDistance ?? this.minWatchNearTermPivotDistance,
      maxWatchNearTermPivotDistance:
          maxWatchNearTermPivotDistance ?? this.maxWatchNearTermPivotDistance,
      minWatchQuoteVolume: minWatchQuoteVolume ?? this.minWatchQuoteVolume,
      minWatchTradeCount: minWatchTradeCount ?? this.minWatchTradeCount,
      minMarketTrendBreadthForEntry:
          minMarketTrendBreadthForEntry ?? this.minMarketTrendBreadthForEntry,
      minMarketMomentumBreadthForEntry: minMarketMomentumBreadthForEntry ??
          this.minMarketMomentumBreadthForEntry,
      minMarketVolumeBreadthForEntry:
          minMarketVolumeBreadthForEntry ?? this.minMarketVolumeBreadthForEntry,
      maxRedBreadthForEntry:
          maxRedBreadthForEntry ?? this.maxRedBreadthForEntry,
      maxDeepRedBreadthForEntry:
          maxDeepRedBreadthForEntry ?? this.maxDeepRedBreadthForEntry,
      maxPushCandidates: maxPushCandidates ?? this.maxPushCandidates,
      maxObservationCandidates:
          maxObservationCandidates ?? this.maxObservationCandidates,
      observationCooldownHours:
          observationCooldownHours ?? this.observationCooldownHours,
      confirmationWindowHours:
          confirmationWindowHours ?? this.confirmationWindowHours,
      cooldownHours: cooldownHours ?? this.cooldownHours,
    );
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'minScore': minScore,
        'minTrendScore': minTrendScore,
        'minCompressionScore': minCompressionScore,
        'minLiquidityScore': minLiquidityScore,
        'minMomentumScore': minMomentumScore,
        'minMarketTrendBreadth': minMarketTrendBreadth,
        'minMarketMomentumBreadth': minMarketMomentumBreadth,
        'minVolumeRatio': minVolumeRatio,
        'minDailyChangePercent': minDailyChangePercent,
        'minBreakoutDistance': minBreakoutDistance,
        'maxBreakoutDistance': maxBreakoutDistance,
        'minHourlyBreakoutDistance': minHourlyBreakoutDistance,
        'maxHourlyBreakoutDistance': maxHourlyBreakoutDistance,
        'minNearTermPivotDistance': minNearTermPivotDistance,
        'maxNearTermPivotDistance': maxNearTermPivotDistance,
        'maxThirtyDayMomentum': maxThirtyDayMomentum,
        'maxDailyChangePercent': maxDailyChangePercent,
        'minQuoteVolume': minQuoteVolume,
        'minTradeCount': minTradeCount,
        'minWatchScore': minWatchScore,
        'minWatchTrendScore': minWatchTrendScore,
        'minWatchCompressionScore': minWatchCompressionScore,
        'minWatchLiquidityScore': minWatchLiquidityScore,
        'minWatchMomentumScore': minWatchMomentumScore,
        'minWatchVolumeRatio': minWatchVolumeRatio,
        'minWatchBreakoutDistance': minWatchBreakoutDistance,
        'maxWatchBreakoutDistance': maxWatchBreakoutDistance,
        'minWatchHourlyBreakoutDistance': minWatchHourlyBreakoutDistance,
        'maxWatchHourlyBreakoutDistance': maxWatchHourlyBreakoutDistance,
        'minWatchNearTermPivotDistance': minWatchNearTermPivotDistance,
        'maxWatchNearTermPivotDistance': maxWatchNearTermPivotDistance,
        'minWatchQuoteVolume': minWatchQuoteVolume,
        'minWatchTradeCount': minWatchTradeCount,
        'minMarketTrendBreadthForEntry': minMarketTrendBreadthForEntry,
        'minMarketMomentumBreadthForEntry': minMarketMomentumBreadthForEntry,
        'minMarketVolumeBreadthForEntry': minMarketVolumeBreadthForEntry,
        'maxRedBreadthForEntry': maxRedBreadthForEntry,
        'maxDeepRedBreadthForEntry': maxDeepRedBreadthForEntry,
        'maxPushCandidates': maxPushCandidates,
        'maxObservationCandidates': maxObservationCandidates,
        'observationCooldownHours': observationCooldownHours,
        'confirmationWindowHours': confirmationWindowHours,
        'cooldownHours': cooldownHours,
        'summary': summary,
      };

  factory StartupScanPolicy.fromJson(Map<String, dynamic> json) {
    return StartupScanPolicy(
      label: json['label'] as String? ?? defaultPolicy.label,
      minScore:
          (json['minScore'] as num?)?.toDouble() ?? defaultPolicy.minScore,
      minTrendScore: (json['minTrendScore'] as num?)?.toDouble() ??
          defaultPolicy.minTrendScore,
      minCompressionScore: (json['minCompressionScore'] as num?)?.toDouble() ??
          defaultPolicy.minCompressionScore,
      minLiquidityScore: (json['minLiquidityScore'] as num?)?.toDouble() ??
          defaultPolicy.minLiquidityScore,
      minMomentumScore: (json['minMomentumScore'] as num?)?.toDouble() ??
          defaultPolicy.minMomentumScore,
      minMarketTrendBreadth:
          (json['minMarketTrendBreadth'] as num?)?.toDouble() ??
              defaultPolicy.minMarketTrendBreadth,
      minMarketMomentumBreadth:
          (json['minMarketMomentumBreadth'] as num?)?.toDouble() ??
              defaultPolicy.minMarketMomentumBreadth,
      minVolumeRatio: (json['minVolumeRatio'] as num?)?.toDouble() ??
          defaultPolicy.minVolumeRatio,
      minDailyChangePercent:
          (json['minDailyChangePercent'] as num?)?.toDouble() ??
              defaultPolicy.minDailyChangePercent,
      minBreakoutDistance: (json['minBreakoutDistance'] as num?)?.toDouble() ??
          defaultPolicy.minBreakoutDistance,
      maxBreakoutDistance: (json['maxBreakoutDistance'] as num?)?.toDouble() ??
          defaultPolicy.maxBreakoutDistance,
      minHourlyBreakoutDistance:
          (json['minHourlyBreakoutDistance'] as num?)?.toDouble() ??
              defaultPolicy.minHourlyBreakoutDistance,
      maxHourlyBreakoutDistance:
          (json['maxHourlyBreakoutDistance'] as num?)?.toDouble() ??
              defaultPolicy.maxHourlyBreakoutDistance,
      minNearTermPivotDistance:
          (json['minNearTermPivotDistance'] as num?)?.toDouble() ??
              defaultPolicy.minNearTermPivotDistance,
      maxNearTermPivotDistance:
          (json['maxNearTermPivotDistance'] as num?)?.toDouble() ??
              defaultPolicy.maxNearTermPivotDistance,
      maxThirtyDayMomentum:
          (json['maxThirtyDayMomentum'] as num?)?.toDouble() ??
              defaultPolicy.maxThirtyDayMomentum,
      maxDailyChangePercent:
          (json['maxDailyChangePercent'] as num?)?.toDouble() ??
              defaultPolicy.maxDailyChangePercent,
      minQuoteVolume: (json['minQuoteVolume'] as num?)?.toDouble() ??
          defaultPolicy.minQuoteVolume,
      minTradeCount: (json['minTradeCount'] as num?)?.toInt() ??
          defaultPolicy.minTradeCount,
      minWatchScore: (json['minWatchScore'] as num?)?.toDouble() ??
          defaultPolicy.minWatchScore,
      minWatchTrendScore: (json['minWatchTrendScore'] as num?)?.toDouble() ??
          defaultPolicy.minWatchTrendScore,
      minWatchCompressionScore:
          (json['minWatchCompressionScore'] as num?)?.toDouble() ??
              defaultPolicy.minWatchCompressionScore,
      minWatchLiquidityScore:
          (json['minWatchLiquidityScore'] as num?)?.toDouble() ??
              defaultPolicy.minWatchLiquidityScore,
      minWatchMomentumScore:
          (json['minWatchMomentumScore'] as num?)?.toDouble() ??
              defaultPolicy.minWatchMomentumScore,
      minWatchVolumeRatio: (json['minWatchVolumeRatio'] as num?)?.toDouble() ??
          defaultPolicy.minWatchVolumeRatio,
      minWatchBreakoutDistance:
          (json['minWatchBreakoutDistance'] as num?)?.toDouble() ??
              defaultPolicy.minWatchBreakoutDistance,
      maxWatchBreakoutDistance:
          (json['maxWatchBreakoutDistance'] as num?)?.toDouble() ??
              defaultPolicy.maxWatchBreakoutDistance,
      minWatchHourlyBreakoutDistance:
          (json['minWatchHourlyBreakoutDistance'] as num?)?.toDouble() ??
              defaultPolicy.minWatchHourlyBreakoutDistance,
      maxWatchHourlyBreakoutDistance:
          (json['maxWatchHourlyBreakoutDistance'] as num?)?.toDouble() ??
              defaultPolicy.maxWatchHourlyBreakoutDistance,
      minWatchNearTermPivotDistance:
          (json['minWatchNearTermPivotDistance'] as num?)?.toDouble() ??
              defaultPolicy.minWatchNearTermPivotDistance,
      maxWatchNearTermPivotDistance:
          (json['maxWatchNearTermPivotDistance'] as num?)?.toDouble() ??
              defaultPolicy.maxWatchNearTermPivotDistance,
      minWatchQuoteVolume: (json['minWatchQuoteVolume'] as num?)?.toDouble() ??
          defaultPolicy.minWatchQuoteVolume,
      minWatchTradeCount: (json['minWatchTradeCount'] as num?)?.toInt() ??
          defaultPolicy.minWatchTradeCount,
      minMarketTrendBreadthForEntry:
          (json['minMarketTrendBreadthForEntry'] as num?)?.toDouble() ??
              defaultPolicy.minMarketTrendBreadthForEntry,
      minMarketMomentumBreadthForEntry:
          (json['minMarketMomentumBreadthForEntry'] as num?)?.toDouble() ??
              defaultPolicy.minMarketMomentumBreadthForEntry,
      minMarketVolumeBreadthForEntry:
          (json['minMarketVolumeBreadthForEntry'] as num?)?.toDouble() ??
              defaultPolicy.minMarketVolumeBreadthForEntry,
      maxRedBreadthForEntry:
          (json['maxRedBreadthForEntry'] as num?)?.toDouble() ??
              defaultPolicy.maxRedBreadthForEntry,
      maxDeepRedBreadthForEntry:
          (json['maxDeepRedBreadthForEntry'] as num?)?.toDouble() ??
              defaultPolicy.maxDeepRedBreadthForEntry,
      maxPushCandidates: (json['maxPushCandidates'] as num?)?.toInt() ??
          defaultPolicy.maxPushCandidates,
      maxObservationCandidates:
          (json['maxObservationCandidates'] as num?)?.toInt() ??
              defaultPolicy.maxObservationCandidates,
      observationCooldownHours:
          (json['observationCooldownHours'] as num?)?.toInt() ??
              defaultPolicy.observationCooldownHours,
      confirmationWindowHours:
          (json['confirmationWindowHours'] as num?)?.toInt() ??
              defaultPolicy.confirmationWindowHours,
      cooldownHours: (json['cooldownHours'] as num?)?.toInt() ??
          defaultPolicy.cooldownHours,
    );
  }
}

class StartupMarketRegime {
  final bool allowEntries;
  final String status;
  final String reason;
  final double marketTrendBreadth;
  final double marketMomentumBreadth;
  final double marketVolumeBreadth;
  final double redBreadth;
  final double deepRedBreadth;
  final String benchmarkStatus;
  final double benchmarkScore;
  final String benchmarkReason;
  final double btcDailyTrend;
  final double btcHourlyTrend;
  final double ethDailyTrend;
  final double ethHourlyTrend;

  const StartupMarketRegime({
    required this.allowEntries,
    required this.status,
    required this.reason,
    required this.marketTrendBreadth,
    required this.marketMomentumBreadth,
    required this.marketVolumeBreadth,
    required this.redBreadth,
    required this.deepRedBreadth,
    this.benchmarkStatus = 'unavailable',
    this.benchmarkScore = 0,
    this.benchmarkReason = '',
    this.btcDailyTrend = 0,
    this.btcHourlyTrend = 0,
    this.ethDailyTrend = 0,
    this.ethHourlyTrend = 0,
  });

  Map<String, dynamic> toJson() => {
        'allowEntries': allowEntries,
        'status': status,
        'reason': reason,
        'marketTrendBreadth': marketTrendBreadth,
        'marketMomentumBreadth': marketMomentumBreadth,
        'marketVolumeBreadth': marketVolumeBreadth,
        'redBreadth': redBreadth,
        'deepRedBreadth': deepRedBreadth,
        'benchmarkStatus': benchmarkStatus,
        'benchmarkScore': benchmarkScore,
        'benchmarkReason': benchmarkReason,
        'btcDailyTrend': btcDailyTrend,
        'btcHourlyTrend': btcHourlyTrend,
        'ethDailyTrend': ethDailyTrend,
        'ethHourlyTrend': ethHourlyTrend,
      };
}

class StartupScanCandidate {
  final String symbol;
  final double currentPrice;
  final double score;
  final double setupScore;
  final double confirmationScore;
  final double trendScore;
  final double compressionScore;
  final double momentumScore;
  final double liquidityScore;
  final double volumeRatio;
  final double dailyBreakoutDistance;
  final double hourlyBreakoutDistance;
  final double nearTermPivotDistance;
  final double marketTrendBreadth;
  final double marketMomentumBreadth;
  final double sevenDayMomentum;
  final double thirtyDayMomentum;
  final String reason;
  final String signalStage;
  final bool shouldWatch;
  final bool blockedByMarket;
  final bool shouldNotify;

  const StartupScanCandidate({
    required this.symbol,
    required this.currentPrice,
    required this.score,
    required this.setupScore,
    required this.confirmationScore,
    required this.trendScore,
    required this.compressionScore,
    required this.momentumScore,
    required this.liquidityScore,
    required this.volumeRatio,
    required this.dailyBreakoutDistance,
    required this.hourlyBreakoutDistance,
    required this.nearTermPivotDistance,
    required this.marketTrendBreadth,
    required this.marketMomentumBreadth,
    required this.sevenDayMomentum,
    required this.thirtyDayMomentum,
    required this.reason,
    required this.signalStage,
    required this.shouldWatch,
    required this.blockedByMarket,
    required this.shouldNotify,
  });

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'currentPrice': currentPrice,
        'score': score,
        'setupScore': setupScore,
        'confirmationScore': confirmationScore,
        'trendScore': trendScore,
        'compressionScore': compressionScore,
        'momentumScore': momentumScore,
        'liquidityScore': liquidityScore,
        'volumeRatio': volumeRatio,
        'dailyBreakoutDistance': dailyBreakoutDistance,
        'hourlyBreakoutDistance': hourlyBreakoutDistance,
        'nearTermPivotDistance': nearTermPivotDistance,
        'marketTrendBreadth': marketTrendBreadth,
        'marketMomentumBreadth': marketMomentumBreadth,
        'sevenDayMomentum': sevenDayMomentum,
        'thirtyDayMomentum': thirtyDayMomentum,
        'reason': reason,
        'signalStage': signalStage,
        'shouldWatch': shouldWatch,
        'blockedByMarket': blockedByMarket,
        'shouldNotify': shouldNotify,
      };
}

class StartupScanReport {
  final DateTime generatedAt;
  final int universeSize;
  final int analyzedSymbols;
  final String strategyLabel;
  final StartupMarketRegime marketRegime;
  final List<StartupScanCandidate> candidates;
  final String notes;

  const StartupScanReport({
    required this.generatedAt,
    required this.universeSize,
    required this.analyzedSymbols,
    required this.strategyLabel,
    required this.marketRegime,
    required this.candidates,
    required this.notes,
  });

  List<StartupScanCandidate> get actionableCandidates =>
      candidates.where((item) => item.shouldNotify).toList();

  List<StartupScanCandidate> get observationCandidates =>
      candidates.where((item) => item.signalStage == 'watch').toList();

  List<StartupScanCandidate> get blockedCandidates => candidates
      .where((item) => item.signalStage == 'blocked_by_market')
      .toList();

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'universeSize': universeSize,
        'analyzedSymbols': analyzedSymbols,
        'strategyLabel': strategyLabel,
        'marketRegime': marketRegime.toJson(),
        'notes': notes,
        'candidates': candidates.map((item) => item.toJson()).toList(),
      };
}

class _RawStartupProfile {
  final CoinData coin;
  final String symbol;
  final double sma20;
  final double sma50;
  final double hourlySma8;
  final double hourlySma21;
  final double dailyBreakoutDistance;
  final double hourlyBreakoutDistance;
  final double nearTermPivotDistance;
  final double momentum7;
  final double momentum30;
  final double dailyRange30;
  final double dailyRange7;
  final double volumeRatio;
  // 新增技术指标
  final double dailyRsi;
  final double hourlyRsi;
  final double dailyMacdHistogram;
  final bool dailyMacdCrossover;
  final double hourlyMacdHistogram;
  final bool hourlyMacdCrossover;
  final double bollingerPercentB;
  final double bollingerBandwidth;
  final double adx;
  final double obvTrend;

  const _RawStartupProfile({
    required this.coin,
    required this.symbol,
    required this.sma20,
    required this.sma50,
    required this.hourlySma8,
    required this.hourlySma21,
    required this.dailyBreakoutDistance,
    required this.hourlyBreakoutDistance,
    required this.nearTermPivotDistance,
    required this.momentum7,
    required this.momentum30,
    required this.dailyRange30,
    required this.dailyRange7,
    required this.volumeRatio,
    this.dailyRsi = 50,
    this.hourlyRsi = 50,
    this.dailyMacdHistogram = 0,
    this.dailyMacdCrossover = false,
    this.hourlyMacdHistogram = 0,
    this.hourlyMacdCrossover = false,
    this.bollingerPercentB = 0.5,
    this.bollingerBandwidth = 0.05,
    this.adx = 25,
    this.obvTrend = 0.5,
  });
}

class _BenchmarkSnapshot {
  final String symbol;
  final double score;
  final double dailyTrend;
  final double hourlyTrend;

  const _BenchmarkSnapshot({
    required this.symbol,
    required this.score,
    required this.dailyTrend,
    required this.hourlyTrend,
  });
}

class _BenchmarkContext {
  final bool available;
  final double score;
  final String status;
  final String reason;
  final double btcDailyTrend;
  final double btcHourlyTrend;
  final double ethDailyTrend;
  final double ethHourlyTrend;

  const _BenchmarkContext({
    required this.available,
    required this.score,
    required this.status,
    required this.reason,
    required this.btcDailyTrend,
    required this.btcHourlyTrend,
    required this.ethDailyTrend,
    required this.ethHourlyTrend,
  });

  const _BenchmarkContext.unavailable()
      : available = false,
        score = 0,
        status = 'unavailable',
        reason = 'BTC/ETH 基准数据不足，暂时仅按全市场广度过滤。',
        btcDailyTrend = 0,
        btcHourlyTrend = 0,
        ethDailyTrend = 0,
        ethHourlyTrend = 0;
}
