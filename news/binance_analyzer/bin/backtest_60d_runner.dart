import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/models/strategy_snapshot.dart';
import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/recommendation_engine.dart';

/// 60天回测：每小时模拟一次推荐引擎，统计买入信号的胜率和收益
///
/// 统计维度：
/// 1. Top3 推荐的次日涨跌胜率
/// 2. 入场信号的 24h 收益胜率
/// 3. 分标签（可入场/临近买点/等回踩）统计
/// 4. 分币种统计最优/最差表现
const int _hourlyBarsFor60Days = 1680; // 70 days * 24h
const int _dailyBars = 120; // 4 months daily

Future<void> main() async {
  final service = BinanceService();
  final requestedSymbols = _loadSymbols();

  stdout.writeln('=== 60天回测开始 ===');
  stdout.writeln('正在获取活跃币种...');
  final activeSymbols = (await service.fetchTickers(symbols: requestedSymbols))
      .map((coin) => coin.symbol)
      .toList()
    ..sort();
  stdout.writeln('获取到 ${activeSymbols.length} 个活跃币种');

  stdout.writeln('正在获取日线数据 ($_dailyBars bars)...');
  final dailyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1d',
    limit: _dailyBars,
    forceRefresh: true,
  );

  stdout.writeln('正在获取小时线数据 ($_hourlyBarsFor60Days bars)...');
  final hourlyHistory = await service.fetchWatchlistKlines(
    symbols: activeSymbols,
    interval: '1h',
    limit: _hourlyBarsFor60Days,
    forceRefresh: true,
  );

  stdout.writeln('开始 60 天小时级回放模拟...\n');

  final analyzer = _Backtest60DAnalyzer();
  final report = analyzer.analyze(
    dailyHistory: dailyHistory,
    hourlyHistory: hourlyHistory,
  );

  // 输出结果
  stdout.writeln('════════════════════════════════════════════');
  stdout.writeln('  60天回测结果报告');
  stdout.writeln('════════════════════════════════════════════');
  stdout.writeln(
    '回测窗口: ${report.windowStart.toIso8601String().substring(0, 10)} → '
    '${report.windowEnd.toIso8601String().substring(0, 10)}',
  );
  stdout.writeln('模拟小时数: ${report.simulatedHours}');
  stdout.writeln('参与币种数: ${report.eligibleSymbols.length}');
  stdout.writeln('');

  stdout.writeln('── Top3 推荐表现 ──');
  stdout.writeln(
    '  样本数: ${report.top3Samples} | '
    '胜率: ${(report.top3WinRate * 100).toStringAsFixed(1)}% | '
    '平均收益: ${report.top3AvgReturn >= 0 ? "+" : ""}${(report.top3AvgReturn).toStringAsFixed(3)}%',
  );
  stdout.writeln('');

  stdout.writeln('── 买入信号表现 (默认策略) ──');
  stdout.writeln(
    '  样本数: ${report.defaultBuySamples} | '
    '胜率: ${(report.defaultBuyWinRate * 100).toStringAsFixed(1)}% | '
    '平均收益: ${report.defaultBuyAvgReturn >= 0 ? "+" : ""}${(report.defaultBuyAvgReturn * 100).toStringAsFixed(2)}% | '
    '最佳潜在: +${(report.defaultBuyBestReturn * 100).toStringAsFixed(2)}%',
  );
  stdout.writeln('  静默率: ${(report.defaultBuySilentRate * 100).toStringAsFixed(1)}%');
  stdout.writeln('');

  stdout.writeln('── 买入信号按标签分类 ──');
  for (final bucket in report.byLabel) {
    stdout.writeln(
      '  ${bucket.name.padRight(8)} | '
      '${bucket.sampleCount}次 | '
      '胜率 ${(bucket.winRate * 100).toStringAsFixed(1)}% | '
      '平均 ${bucket.avgReturn >= 0 ? "+" : ""}${(bucket.avgReturn * 100).toStringAsFixed(2)}%',
    );
  }
  stdout.writeln('');

  stdout.writeln('── 买入信号按币种 TOP 5 ──');
  for (final bucket in report.topSymbols.take(5)) {
    stdout.writeln(
      '  ${bucket.name.padRight(8)} | '
      '${bucket.sampleCount}次 | '
      '胜率 ${(bucket.winRate * 100).toStringAsFixed(1)}% | '
      '平均 ${bucket.avgReturn >= 0 ? "+" : ""}${(bucket.avgReturn * 100).toStringAsFixed(2)}%',
    );
  }
  if (report.worstSymbols.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('── 买入信号按币种 WORST 3 ──');
    for (final bucket in report.worstSymbols.take(3)) {
      stdout.writeln(
        '  ${bucket.name.padRight(8)} | '
        '${bucket.sampleCount}次 | '
        '胜率 ${(bucket.winRate * 100).toStringAsFixed(1)}% | '
        '平均 ${bucket.avgReturn >= 0 ? "+" : ""}${(bucket.avgReturn * 100).toStringAsFixed(2)}%',
      );
    }
  }

  stdout.writeln('');
  stdout.writeln('── 优化后策略表现 ──');
  stdout.writeln('  策略: ${report.optimizedPolicyId}');
  stdout.writeln(
    '  样本数: ${report.optimizedBuySamples} | '
    '胜率: ${(report.optimizedBuyWinRate * 100).toStringAsFixed(1)}% | '
    '平均收益: ${report.optimizedBuyAvgReturn >= 0 ? "+" : ""}${(report.optimizedBuyAvgReturn * 100).toStringAsFixed(2)}%',
  );
  stdout.writeln('');

  stdout.writeln('── 最近 10 条信号回顾 ──');
  for (final outcome in report.recentOutcomes.take(10)) {
    final tag = outcome.isWin ? '✓' : '✗';
    stdout.writeln(
      '  $tag ${outcome.symbol.padRight(8)} '
      '${outcome.timingLabel.padRight(6)} '
      'score=${outcome.totalScore.toStringAsFixed(2)} '
      '→ ${outcome.nextReturn >= 0 ? "+" : ""}${outcome.nextReturn.toStringAsFixed(2)}% '
      '(peak +${outcome.bestReturn.toStringAsFixed(2)}%) '
      '@ ${outcome.at.toIso8601String().substring(0, 16)}',
    );
  }

  stdout.writeln('');
  stdout.writeln('════════════════════════════════════════════');

  // 保存 JSON 报告
  final reportsDir = Directory('build/reports')..createSync(recursive: true);
  final output = File('${reportsDir.path}/backtest_60d_report.json');
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report.toJson()),
  );
  stdout.writeln('完整报告已保存到: ${output.path}');
}

class _Backtest60DAnalyzer {
  static const int replayDays = 60;

  _Backtest60DReport analyze({
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
  }) {
    final normalizedDaily = {
      for (final entry in dailyHistory.entries) entry.key: _sorted(entry.value),
    };
    final normalizedHourly = {
      for (final entry in hourlyHistory.entries)
        entry.key: _sorted(entry.value),
    };

    final eligibleSymbols = normalizedHourly.keys
        .where(
          (symbol) =>
              (normalizedDaily[symbol]?.length ?? 0) >=
                  RecommendationEngine.minimumDailyBars &&
              (normalizedHourly[symbol]?.length ?? 0) >= 120,
        )
        .toList()
      ..sort();

    if (eligibleSymbols.length < 5) {
      return _Backtest60DReport.empty(eligibleSymbols);
    }

    // 确定时间窗口
    final timelineSymbol = eligibleSymbols.first;
    final timelineBars = normalizedHourly[timelineSymbol]!;

    final latestEvaluableTime = DateTime.fromMillisecondsSinceEpoch(
      eligibleSymbols
          .map((symbol) =>
              normalizedHourly[symbol]![normalizedHourly[symbol]!.length - 25]
                  .closeTime)
          .reduce((a, b) => a < b ? a : b),
    );
    final earliestTime = DateTime.fromMillisecondsSinceEpoch(
      eligibleSymbols
          .map((symbol) => normalizedHourly[symbol]![71].closeTime)
          .reduce((a, b) => a > b ? a : b),
    );

    final windowEnd = latestEvaluableTime;
    final windowStart = _maxDate(
      earliestTime,
      windowEnd.subtract(const Duration(days: replayDays)),
    );

    stdout.writeln('回测窗口: ${windowStart.toIso8601String().substring(0, 10)} → ${windowEnd.toIso8601String().substring(0, 10)}');

    // 构建每小时的回放状态
    final replayHours = timelineBars
        .where((bar) {
          final at = DateTime.fromMillisecondsSinceEpoch(bar.closeTime);
          return !at.isBefore(windowStart) && !at.isAfter(windowEnd);
        })
        .map((bar) => DateTime.fromMillisecondsSinceEpoch(bar.closeTime))
        .toList();

    stdout.writeln('共 ${replayHours.length} 个小时需要模拟...');

    final states = <_ReplayState>[];
    var progress = 0;
    for (final at in replayHours) {
      final state = _buildReplayState(
        at: at,
        symbols: eligibleSymbols,
        dailyHistory: normalizedDaily,
        hourlyHistory: normalizedHourly,
      );
      if (state != null) {
        states.add(state);
      }
      progress++;
      if (progress % 100 == 0) {
        stdout.write('\r  已模拟 $progress/${replayHours.length} 小时...');
      }
    }
    stdout.writeln('\r  完成 ${states.length} 个有效小时模拟。                    ');

    // 评估 Top3 推荐
    final top3Stats = _evaluateTop3(states);

    // 评估默认策略买入信号
    final defaultPolicy = EntrySignalPolicy.defaultPolicy;
    final defaultStats = _evaluateBuySignals(states, defaultPolicy);

    // 尝试优化策略
    final optimized = _findBestPolicy(states);
    final optimizedStats = _evaluateBuySignals(states, optimized.policy);

    return _Backtest60DReport(
      windowStart: windowStart,
      windowEnd: windowEnd,
      simulatedHours: states.length,
      eligibleSymbols: eligibleSymbols,
      top3Samples: top3Stats.sampleCount,
      top3WinRate: top3Stats.winRate,
      top3AvgReturn: top3Stats.avgReturn,
      defaultBuySamples: defaultStats.sampleCount,
      defaultBuyWinRate: defaultStats.winRate,
      defaultBuyAvgReturn: defaultStats.avgReturn,
      defaultBuyBestReturn: defaultStats.bestReturn,
      defaultBuySilentRate: defaultStats.silentRate,
      byLabel: defaultStats.byLabel,
      topSymbols: defaultStats.topSymbols,
      worstSymbols: defaultStats.worstSymbols,
      optimizedPolicyId: optimized.policy.id,
      optimizedBuySamples: optimizedStats.sampleCount,
      optimizedBuyWinRate: optimizedStats.winRate,
      optimizedBuyAvgReturn: optimizedStats.avgReturn,
      recentOutcomes: defaultStats.outcomes.reversed.take(20).toList(),
    );
  }

  _ReplayState? _buildReplayState({
    required DateTime at,
    required List<String> symbols,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
  }) {
    final currentCoins = <CoinData>[];
    final dailySlices = <String, List<Kline>>{};
    final hourlySlices = <String, List<Kline>>{};
    final nextCloseReturns = <String, double>{};
    final nextBestReturns = <String, double>{};

    for (final symbol in symbols) {
      final hourlyBars = hourlyHistory[symbol] ?? const [];
      final index = _lastClosedIndexBefore(hourlyBars, at);
      if (index < 71 || index + 24 >= hourlyBars.length) continue;

      final dailyBars =
          _dailyClosedBefore(dailyHistory[symbol] ?? const [], at);
      if (dailyBars.length < RecommendationEngine.minimumDailyBars) continue;

      final recent24 = hourlyBars.sublist(index - 23, index + 1);
      final recent72 = hourlyBars.sublist(index - 71, index + 1);
      final currentClose = hourlyBars[index].close;
      if (currentClose <= 0) continue;

      final next24 = hourlyBars.sublist(index + 1, index + 25);
      final next24Close = hourlyBars[index + 24].close;
      final next24High = next24.map((bar) => bar.high).reduce(max);
      final displayName = _displayName(symbol);

      currentCoins.add(_snapshotCoin(symbol, recent24));
      dailySlices[symbol] = dailyBars;
      hourlySlices[symbol] = recent72;
      nextCloseReturns[displayName] =
          ((next24Close - currentClose) / currentClose);
      nextBestReturns[displayName] =
          ((next24High - currentClose) / currentClose);
    }

    if (currentCoins.length < 5) return null;

    final engine = RecommendationEngine.analyze(
      currentCoins: currentCoins,
      dailyHistory: dailySlices,
      hourlyHistory: hourlySlices,
      policy: EntrySignalPolicy.defaultPolicy,
    );

    return _ReplayState(
      at: at,
      top3: engine.top3,
      entryAlerts: engine.entryAlerts,
      nextCloseReturns: nextCloseReturns,
      nextBestReturns: nextBestReturns,
    );
  }

  _Top3Stats _evaluateTop3(List<_ReplayState> states) {
    var samples = 0;
    var wins = 0;
    var totalReturn = 0.0;

    for (final state in states) {
      for (final coin in state.top3.take(3)) {
        final nextReturn = state.nextCloseReturns[coin.displayName];
        if (nextReturn == null) continue;
        samples += 1;
        totalReturn += nextReturn * 100;
        if (nextReturn > 0) wins += 1;
      }
    }

    return _Top3Stats(
      sampleCount: samples,
      winRate: samples == 0 ? 0 : wins / samples,
      avgReturn: samples == 0 ? 0 : totalReturn / samples,
    );
  }

  _BuySignalStats _evaluateBuySignals(
    List<_ReplayState> states,
    EntrySignalPolicy policy,
  ) {
    var samples = 0;
    var wins = 0;
    var silentHours = 0;
    var totalReturn = 0.0;
    var totalBestReturn = 0.0;
    final outcomes = <_Outcome>[];
    final lastTriggeredAtBySymbol = <String, DateTime>{};
    final byLabel = <String, _MutableBucket>{};
    final bySymbol = <String, _MutableBucket>{};

    for (final state in states) {
      final selected = state.entryAlerts.where(policy.matches).toList()
        ..sort((a, b) {
          final byTotal = b.totalScore.compareTo(a.totalScore);
          if (byTotal != 0) return byTotal;
          return b.entryScore.compareTo(a.entryScore);
        });

      if (selected.isEmpty) {
        silentHours += 1;
        continue;
      }

      for (final alert in selected.take(policy.maxSignalsPerHour)) {
        final lastTriggeredAt = lastTriggeredAtBySymbol[alert.symbol];
        if (lastTriggeredAt != null &&
            state.at.difference(lastTriggeredAt).inHours <
                policy.cooldownHours) {
          continue;
        }

        final nextReturn = state.nextCloseReturns[alert.symbol];
        final bestReturn = state.nextBestReturns[alert.symbol];
        if (nextReturn == null || bestReturn == null) continue;

        final isWin = nextReturn > 0;
        samples += 1;
        totalReturn += nextReturn;
        totalBestReturn += bestReturn;
        if (isWin) wins += 1;
        lastTriggeredAtBySymbol[alert.symbol] = state.at;

        byLabel
            .putIfAbsent(alert.timingLabel, _MutableBucket.new)
            .add(nextReturn, isWin);
        bySymbol
            .putIfAbsent(alert.symbol, _MutableBucket.new)
            .add(nextReturn, isWin);

        outcomes.add(_Outcome(
          at: state.at,
          symbol: alert.symbol,
          timingLabel: alert.timingLabel,
          totalScore: alert.totalScore,
          entryScore: alert.entryScore,
          nextReturn: nextReturn * 100,
          bestReturn: bestReturn * 100,
          isWin: isWin,
        ));
      }
    }

    final labelBuckets = byLabel.entries
        .map((e) => _Bucket(
              name: e.key,
              sampleCount: e.value.count,
              wins: e.value.wins,
              avgReturn: e.value.count == 0 ? 0 : e.value.total / e.value.count,
            ))
        .toList()
      ..sort((a, b) => b.sampleCount.compareTo(a.sampleCount));

    final symbolBuckets = bySymbol.entries
        .map((e) => _Bucket(
              name: e.key,
              sampleCount: e.value.count,
              wins: e.value.wins,
              avgReturn: e.value.count == 0 ? 0 : e.value.total / e.value.count,
            ))
        .toList();

    final topSymbols = [...symbolBuckets]
      ..sort((a, b) => b.avgReturn.compareTo(a.avgReturn));
    final worstSymbols = [...symbolBuckets]
      ..sort((a, b) => a.avgReturn.compareTo(b.avgReturn));

    return _BuySignalStats(
      sampleCount: samples,
      winRate: samples == 0 ? 0 : wins / samples,
      avgReturn: samples == 0 ? 0 : totalReturn / samples,
      bestReturn: samples == 0 ? 0 : totalBestReturn / samples,
      silentRate: (samples + silentHours) == 0
          ? 0
          : silentHours / (samples + silentHours),
      byLabel: labelBuckets,
      topSymbols: topSymbols,
      worstSymbols: worstSymbols,
      outcomes: outcomes,
    );
  }

  _PolicyResult _findBestPolicy(List<_ReplayState> states) {
    const labelSets = [
      ['可入场'],
      ['可入场', '临近买点'],
      ['可入场', '临近买点', '等回踩'],
    ];
    const totalThresholds = [0.60, 0.64, 0.68, 0.72, 0.76];
    const entryThresholds = [0.58, 0.62, 0.66, 0.70, 0.74, 0.78];
    const volumeThresholds = [0.95, 1.00, 1.05, 1.12];
    const breakoutThresholds = [1.2, 1.8, 2.6, 3.4];

    _PolicyResult? best;
    var tried = 0;

    for (var labelIndex = 0; labelIndex < labelSets.length; labelIndex++) {
      for (final minTotalScore in totalThresholds) {
        for (final minEntryScore in entryThresholds) {
          for (final minVolumeRatio in volumeThresholds) {
            for (final maxBreakoutDistance in breakoutThresholds) {
              final policy = EntrySignalPolicy(
                id: 'opt-$labelIndex-'
                    '${(minTotalScore * 100).round()}-'
                    '${(minEntryScore * 100).round()}-'
                    '${(minVolumeRatio * 100).round()}-'
                    '${(maxBreakoutDistance * 10).round()}',
                label: '60天优化',
                minTotalScore: minTotalScore,
                minEntryScore: minEntryScore,
                minVolumeRatio: minVolumeRatio,
                maxBreakoutDistance: maxBreakoutDistance,
                maxSignalsPerHour: 1,
                cooldownHours: 6,
                allowedLabels: labelSets[labelIndex],
              );

              final stats = _evaluateBuySignals(states, policy);
              if (stats.sampleCount < 6) continue;

              final objective = stats.winRate * 70 +
                  stats.avgReturn * 400 +
                  (stats.winRate >= 0.80 ? 30 : 0) +
                  min(stats.sampleCount / 20.0, 1.0) * 20;

              if (best == null || objective > best.objective) {
                best = _PolicyResult(
                  policy: policy,
                  objective: objective,
                );
              }
              tried++;
            }
          }
        }
      }
    }

    stdout.writeln('  尝试了 $tried 种策略组合');
    return best ?? _PolicyResult(policy: EntrySignalPolicy.defaultPolicy, objective: 0);
  }

  List<Kline> _sorted(List<Kline> bars) {
    final copy = [...bars];
    copy.sort((a, b) => a.closeTime.compareTo(b.closeTime));
    return copy;
  }

  int _lastClosedIndexBefore(List<Kline> bars, DateTime at) {
    final closeTime = at.millisecondsSinceEpoch;
    var low = 0;
    var high = bars.length - 1;
    var answer = -1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (bars[mid].closeTime <= closeTime) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return answer;
  }

  List<Kline> _dailyClosedBefore(List<Kline> bars, DateTime at) {
    return bars
        .where((bar) => bar.closeTime <= at.millisecondsSinceEpoch)
        .toList();
  }

  CoinData _snapshotCoin(String symbol, List<Kline> bars24h) {
    final last = bars24h.last;
    final open24h = bars24h.first.open;
    final high24h = bars24h.map((bar) => bar.high).reduce(max).toDouble();
    final low24h = bars24h.map((bar) => bar.low).reduce(min).toDouble();
    final quoteVolume =
        bars24h.fold<double>(0, (sum, bar) => sum + bar.quoteVolume);
    final volume = bars24h.fold<double>(0, (sum, bar) => sum + bar.volume);
    final tradeCount = bars24h.fold<int>(0, (sum, bar) => sum + bar.tradeCount);
    final priceChange = last.close - open24h;
    final changePercent =
        open24h <= 0 ? 0.0 : ((last.close - open24h) / open24h) * 100;

    return CoinData(
      symbol: symbol,
      lastPrice: last.close,
      priceChange: priceChange,
      priceChangePercent: changePercent,
      highPrice: high24h,
      lowPrice: low24h,
      openPrice: open24h,
      quoteVolume: quoteVolume,
      volume: volume,
      count: tradeCount,
    );
  }

  String _displayName(String symbol) {
    final upper = symbol.toUpperCase();
    if (upper.endsWith('USDT')) {
      return upper.substring(0, upper.length - 4);
    }
    return upper;
  }

  DateTime _maxDate(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
}

// ─── 数据模型 ───

class _ReplayState {
  final DateTime at;
  final List<CoinData> top3;
  final List<EntryAlertSignal> entryAlerts;
  final Map<String, double> nextCloseReturns;
  final Map<String, double> nextBestReturns;

  const _ReplayState({
    required this.at,
    required this.top3,
    required this.entryAlerts,
    required this.nextCloseReturns,
    required this.nextBestReturns,
  });
}

class _Top3Stats {
  final int sampleCount;
  final double winRate;
  final double avgReturn;

  const _Top3Stats({
    required this.sampleCount,
    required this.winRate,
    required this.avgReturn,
  });
}

class _BuySignalStats {
  final int sampleCount;
  final double winRate;
  final double avgReturn;
  final double bestReturn;
  final double silentRate;
  final List<_Bucket> byLabel;
  final List<_Bucket> topSymbols;
  final List<_Bucket> worstSymbols;
  final List<_Outcome> outcomes;

  const _BuySignalStats({
    required this.sampleCount,
    required this.winRate,
    required this.avgReturn,
    required this.bestReturn,
    required this.silentRate,
    required this.byLabel,
    required this.topSymbols,
    required this.worstSymbols,
    required this.outcomes,
  });
}

class _Bucket {
  final String name;
  final int sampleCount;
  final int wins;
  final double avgReturn;

  const _Bucket({
    required this.name,
    required this.sampleCount,
    required this.wins,
    required this.avgReturn,
  });

  double get winRate => sampleCount == 0 ? 0 : wins / sampleCount;

  Map<String, dynamic> toJson() => {
        'name': name,
        'sampleCount': sampleCount,
        'wins': wins,
        'winRate': winRate,
        'avgReturn': avgReturn,
      };
}

class _MutableBucket {
  int count = 0;
  int wins = 0;
  double total = 0;

  void add(double ret, bool isWin) {
    count += 1;
    total += ret;
    if (isWin) wins += 1;
  }
}

class _Outcome {
  final DateTime at;
  final String symbol;
  final String timingLabel;
  final double totalScore;
  final double entryScore;
  final double nextReturn;
  final double bestReturn;
  final bool isWin;

  const _Outcome({
    required this.at,
    required this.symbol,
    required this.timingLabel,
    required this.totalScore,
    required this.entryScore,
    required this.nextReturn,
    required this.bestReturn,
    required this.isWin,
  });

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'symbol': symbol,
        'timingLabel': timingLabel,
        'totalScore': totalScore,
        'entryScore': entryScore,
        'nextReturn': nextReturn,
        'bestReturn': bestReturn,
        'isWin': isWin,
      };
}

class _PolicyResult {
  final EntrySignalPolicy policy;
  final double objective;

  const _PolicyResult({required this.policy, required this.objective});
}

class _Backtest60DReport {
  final DateTime windowStart;
  final DateTime windowEnd;
  final int simulatedHours;
  final List<String> eligibleSymbols;
  final int top3Samples;
  final double top3WinRate;
  final double top3AvgReturn;
  final int defaultBuySamples;
  final double defaultBuyWinRate;
  final double defaultBuyAvgReturn;
  final double defaultBuyBestReturn;
  final double defaultBuySilentRate;
  final List<_Bucket> byLabel;
  final List<_Bucket> topSymbols;
  final List<_Bucket> worstSymbols;
  final String optimizedPolicyId;
  final int optimizedBuySamples;
  final double optimizedBuyWinRate;
  final double optimizedBuyAvgReturn;
  final List<_Outcome> recentOutcomes;

  const _Backtest60DReport({
    required this.windowStart,
    required this.windowEnd,
    required this.simulatedHours,
    required this.eligibleSymbols,
    required this.top3Samples,
    required this.top3WinRate,
    required this.top3AvgReturn,
    required this.defaultBuySamples,
    required this.defaultBuyWinRate,
    required this.defaultBuyAvgReturn,
    required this.defaultBuyBestReturn,
    required this.defaultBuySilentRate,
    required this.byLabel,
    required this.topSymbols,
    required this.worstSymbols,
    required this.optimizedPolicyId,
    required this.optimizedBuySamples,
    required this.optimizedBuyWinRate,
    required this.optimizedBuyAvgReturn,
    required this.recentOutcomes,
  });

  factory _Backtest60DReport.empty(List<String> symbols) => _Backtest60DReport(
        windowStart: DateTime.now(),
        windowEnd: DateTime.now(),
        simulatedHours: 0,
        eligibleSymbols: symbols,
        top3Samples: 0,
        top3WinRate: 0,
        top3AvgReturn: 0,
        defaultBuySamples: 0,
        defaultBuyWinRate: 0,
        defaultBuyAvgReturn: 0,
        defaultBuyBestReturn: 0,
        defaultBuySilentRate: 0,
        byLabel: const [],
        topSymbols: const [],
        worstSymbols: const [],
        optimizedPolicyId: 'none',
        optimizedBuySamples: 0,
        optimizedBuyWinRate: 0,
        optimizedBuyAvgReturn: 0,
        recentOutcomes: const [],
      );

  Map<String, dynamic> toJson() => {
        'generatedAt': DateTime.now().toIso8601String(),
        'windowStart': windowStart.toIso8601String(),
        'windowEnd': windowEnd.toIso8601String(),
        'simulatedHours': simulatedHours,
        'eligibleSymbols': eligibleSymbols,
        'top3': {
          'samples': top3Samples,
          'winRate': top3WinRate,
          'avgReturn': top3AvgReturn,
        },
        'defaultBuySignals': {
          'samples': defaultBuySamples,
          'winRate': defaultBuyWinRate,
          'avgReturn': defaultBuyAvgReturn,
          'bestReturn': defaultBuyBestReturn,
          'silentRate': defaultBuySilentRate,
          'byLabel': byLabel.map((b) => b.toJson()).toList(),
          'topSymbols': topSymbols.take(10).map((b) => b.toJson()).toList(),
          'worstSymbols': worstSymbols.take(5).map((b) => b.toJson()).toList(),
        },
        'optimized': {
          'policyId': optimizedPolicyId,
          'samples': optimizedBuySamples,
          'winRate': optimizedBuyWinRate,
          'avgReturn': optimizedBuyAvgReturn,
        },
        'recentOutcomes': recentOutcomes.map((o) => o.toJson()).toList(),
      };
}

List<String> _loadSymbols() {
  final raw = Platform.environment['WATCHLIST'];
  if (raw == null || raw.trim().isEmpty) {
    return BinanceService.defaultWatchlistSymbols;
  }
  return raw.split(',').map(BinanceService.toSymbol).toSet().toList()..sort();
}
