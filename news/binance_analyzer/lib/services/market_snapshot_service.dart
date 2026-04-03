import '../models/coin_data.dart';
import '../models/market_snapshot.dart';
import '../models/strategy_snapshot.dart';
import '../utils/coin_analyzer.dart';
import 'binance_service.dart';
import 'recommendation_engine.dart';

class MarketSnapshotService {
  final BinanceService _binance;

  MarketSnapshotService({
    BinanceService? binance,
  }) : _binance = binance ?? BinanceService();

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

    try {
      final symbols = coins.map((coin) => coin.symbol).toList();
      final histories = await Future.wait([
        _binance.fetchWatchlistKlines(
          symbols: symbols,
          interval: '1d',
          limit: 75,
          forceRefresh: forceRefresh,
        ),
        _binance.fetchWatchlistKlines(
          symbols: symbols,
          interval: '1h',
          limit: 72,
          forceRefresh: forceRefresh,
        ),
      ]);

      final engine = RecommendationEngine.analyze(
        currentCoins: coins,
        dailyHistory: histories[0],
        hourlyHistory: histories[1],
        policy: policy ?? EntrySignalPolicy.defaultPolicy,
      );

      analyzed = engine.rankedCoins;
      top3 = engine.top3;
      engineReport = engine.report;
      entryAlerts = engine.entryAlerts;
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
}
