import '../models/coin_data.dart';
import '../models/market_snapshot.dart';
import '../models/strategy_snapshot.dart';
import '../utils/coin_analyzer.dart';
import 'binance_service.dart';
import 'leader_prediction_service.dart';
import 'recommendation_engine.dart';

class MarketSnapshotService {
  final BinanceService _binance;
  final LeaderPredictionService _leaderPrediction;

  MarketSnapshotService({
    BinanceService? binance,
    LeaderPredictionService? leaderPrediction,
  })  : _binance = binance ?? BinanceService(),
        _leaderPrediction = leaderPrediction ?? LeaderPredictionService();

  Future<MarketSnapshot> buildSnapshot({
    List<String>? requestedSymbols,
    EntrySignalPolicy? policy,
    bool forceRefresh = true,
  }) async {
    final watchlistSymbols = _normalizeSymbols(
      requestedSymbols ?? BinanceService.defaultWatchlistSymbols,
    );
    final coins = await _binance.fetchTickers(symbols: watchlistSymbols);
    if (coins.isEmpty) {
      throw Exception('数据为空：API 有响应但没有返回币种数据，请稍后再试');
    }

    List<CoinData> analyzed;
    List<CoinData> top3;
    StrategyBacktestReport? engineReport;
    List<EntryAlertSignal> entryAlerts = const [];
    List<EntryAlertSignal> exitAlerts = const [];

    try {
      final symbols = coins.map((coin) => coin.symbol).toList();
      final histories = await Future.wait([
        _binance.fetchWatchlistKlines(
          symbols: symbols,
          interval: '1d',
          limit: 90,
          forceRefresh: forceRefresh,
        ),
        _binance.fetchWatchlistKlines(
          symbols: symbols,
          interval: '1h',
          limit: 72,
          forceRefresh: forceRefresh,
        ),
        _binance.fetchWatchlistKlines(
          symbols: const ['BTCUSDT'],
          interval: '1d',
          limit: 60,
          forceRefresh: forceRefresh,
        ),
      ]);

      final engine = RecommendationEngine.analyze(
        currentCoins: coins,
        dailyHistory: histories[0],
        hourlyHistory: histories[1],
        policy: policy ?? EntrySignalPolicy.defaultPolicy,
      );

      final leaderPrediction = _leaderPrediction.analyze(
        currentCoins: engine.rankedCoins,
        dailyHistory: histories[0],
        btcDailyHistory: histories[2]['BTCUSDT'] ?? const [],
      );

      analyzed = leaderPrediction.rankedCoins;
      top3 = leaderPrediction.top3;
      engineReport = engine.report;
      entryAlerts = _buildLeaderPredictionEntryAlerts(leaderPrediction);
      exitAlerts = const [];
    } catch (_) {
      analyzed = CoinAnalyzer.analyze(coins);
      top3 = CoinAnalyzer.top3Picks(analyzed);
    }

    return MarketSnapshot(
      allCoins: analyzed,
      top3: top3,
      updatedAt: DateTime.now(),
      engineReport: engineReport,
      entryAlerts: entryAlerts,
      exitAlerts: exitAlerts,
      watchlistSymbols: watchlistSymbols,
    );
  }

  List<String> _normalizeSymbols(List<String> symbols) {
    final results = <String>{};
    for (final symbol in symbols) {
      final normalized = BinanceService.toSymbol(symbol);
      if (normalized.isEmpty) continue;
      results.add(normalized);
    }
    final ordered = results.toList();
    ordered.sort();
    return ordered;
  }

  List<EntryAlertSignal> _buildLeaderPredictionEntryAlerts(
    LeaderPredictionResult result,
  ) {
    if (result.regimeStatus != 'recommend') {
      return const [];
    }

    return result.top3.take(3).map((coin) {
      return EntryAlertSignal(
        symbol: coin.displayName,
        timingLabel: coin.timingLabel.isEmpty ? '等待确认' : coin.timingLabel,
        timingReason: coin.timingReason,
        currentPrice: coin.lastPrice,
        dayChangePercent: coin.priceChangePercent,
        totalScore: coin.score,
        entryScore: coin.entryScore,
        volumeRatio: 0,
        breakoutDistance: 0,
        pullbackPercent: 0,
        shouldNotify: true,
      );
    }).toList();
  }
}
