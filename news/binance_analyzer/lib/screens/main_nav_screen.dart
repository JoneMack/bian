import 'dart:async';

import 'package:flutter/material.dart';

import '../models/coin_data.dart';
import '../models/market_snapshot.dart';
import '../models/strategy_snapshot.dart';
import '../services/backend_api_service.dart';
import '../services/history_service.dart';
import '../services/market_snapshot_service.dart';
import '../services/notification_service.dart';
import '../services/realtime_service.dart';
import '../services/watchlist_service.dart';
import '../theme/app_theme.dart';
import 'history_screen.dart';
import 'market_screen.dart';
import 'news_screen.dart';
import 'picks_screen.dart';

class MarketState {
  final List<CoinData> allCoins;
  final List<CoinData> top3;
  final DateTime updatedAt;
  final bool loading;
  final String? error;
  final bool liveConnected;
  final StrategyBacktestReport? engineReport;
  final List<EntryAlertSignal> entryAlerts;
  final List<String> watchlistSymbols;

  const MarketState({
    this.allCoins = const [],
    this.top3 = const [],
    required this.updatedAt,
    this.loading = true,
    this.error,
    this.liveConnected = false,
    this.engineReport,
    this.entryAlerts = const [],
    this.watchlistSymbols = const [],
  });

  MarketState copyWith({
    List<CoinData>? allCoins,
    List<CoinData>? top3,
    DateTime? updatedAt,
    bool? loading,
    String? error,
    bool? liveConnected,
    StrategyBacktestReport? engineReport,
    List<EntryAlertSignal>? entryAlerts,
    List<String>? watchlistSymbols,
  }) {
    return MarketState(
      allCoins: allCoins ?? this.allCoins,
      top3: top3 ?? this.top3,
      updatedAt: updatedAt ?? this.updatedAt,
      loading: loading ?? this.loading,
      error: error,
      liveConnected: liveConnected ?? this.liveConnected,
      engineReport: engineReport ?? this.engineReport,
      entryAlerts: entryAlerts ?? this.entryAlerts,
      watchlistSymbols: watchlistSymbols ?? this.watchlistSymbols,
    );
  }
}

class MainNavScreen extends StatefulWidget {
  const MainNavScreen({super.key});

  @override
  State<MainNavScreen> createState() => _MainNavScreenState();
}

class _MainNavScreenState extends State<MainNavScreen> {
  static const _fullRefreshInterval = Duration(minutes: 1);
  static const _priceUiThrottle = Duration(milliseconds: 450);

  int _currentIndex = 0;
  MarketState _state = MarketState(updatedAt: DateTime.now());

  final _history = HistoryService();
  final _backendApi = BackendApiService();
  final _snapshotService = MarketSnapshotService();
  final _notifications = NotificationService.instance;
  final _realtime = RealtimeService();
  final _watchlist = WatchlistService();

  Timer? _fullRefreshTimer;
  Timer? _connectionTimer;
  Timer? _priceFlushTimer;
  StreamSubscription<PriceUpdate>? _priceSub;
  final Map<String, PriceUpdate> _pendingPriceUpdates = {};
  bool _refreshInFlight = false;
  bool _refreshQueued = false;

  @override
  void initState() {
    super.initState();
    unawaited(_notifications.requestPermissions());
    _loadFull();
    _fullRefreshTimer = Timer.periodic(
      _fullRefreshInterval,
      (_) => _loadFull(silent: true),
    );
  }

  @override
  void dispose() {
    _fullRefreshTimer?.cancel();
    _connectionTimer?.cancel();
    _priceFlushTimer?.cancel();
    _priceSub?.cancel();
    _realtime.disconnect();
    super.dispose();
  }

  Future<void> _loadFull({bool silent = false}) async {
    if (_refreshInFlight) {
      _refreshQueued = true;
      return;
    }
    _refreshInFlight = true;

    if (!silent && mounted) {
      setState(() => _state = _state.copyWith(loading: true, error: null));
    }

    try {
      final watchlistSymbols = await _watchlist.loadWatchlistSymbols();
      final snapshot = await _loadSnapshot(
        watchlistSymbols,
        forceRefresh: !silent,
      );

      await _history.saveTodayFeishuSignals(
        entryAlerts: snapshot.entryAlerts,
        exitAlerts: snapshot.exitAlerts,
        marketCoins: snapshot.allCoins,
      );
      await _history.settleYesterday(snapshot.allCoins);
      await _startRealtime(snapshot.watchlistSymbols);

      if (!mounted) return;
      setState(() {
        _state = _state.copyWith(
          allCoins: snapshot.allCoins,
          top3: snapshot.top3,
          updatedAt: snapshot.updatedAt,
          loading: false,
          error: null,
          engineReport: snapshot.engineReport,
          entryAlerts: snapshot.entryAlerts,
          watchlistSymbols: snapshot.watchlistSymbols,
        );
      });
      unawaited(
        _notifications.notifyEntrySignals(
          snapshot.entryAlerts,
          presetLabel: snapshot.engineReport?.presetLabel,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _state.copyWith(
          loading: false,
          error: error.toString(),
        );
      });
    } finally {
      _refreshInFlight = false;
      if (_refreshQueued && mounted) {
        _refreshQueued = false;
        unawaited(_loadFull(silent: true));
      }
    }
  }

  Future<MarketSnapshot> _loadSnapshot(
    List<String> watchlistSymbols, {
    required bool forceRefresh,
  }) async {
    Object? backendError;

    if (_backendApi.isConfigured) {
      try {
        return await _backendApi.fetchMarketSnapshot(
          symbols: watchlistSymbols,
          forceRefresh: forceRefresh,
        );
      } catch (error) {
        backendError = error;
      }
    }

    try {
      final entryPolicy = await _history.loadEntrySignalPolicy();
      return await _snapshotService.buildSnapshot(
        requestedSymbols: watchlistSymbols,
        policy: entryPolicy,
        forceRefresh: forceRefresh,
      );
    } catch (error) {
      if (backendError != null) {
        throw Exception(
          '后台模式失败：$backendError\n本地兜底也失败：$error',
        );
      }
      rethrow;
    }
  }

  Future<void> _startRealtime(List<String> symbols) async {
    try {
      await _realtime.connect(symbols: symbols);
      _priceSub ??= _realtime.priceStream.listen(_onPriceUpdate);

      _connectionTimer?.cancel();
      _connectionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted) return;
        final connected = _realtime.isConnected;
        if (_state.liveConnected != connected) {
          setState(() {
            _state = _state.copyWith(liveConnected: connected);
          });
        }
      });
    } catch (_) {
      // WebSocket 不可用时静默降级为定时轮询。
    }
  }

  Future<void> _saveWatchlist(List<String> symbols) async {
    await _watchlist.saveWatchlistSymbols(symbols);
    await _loadFull();
  }

  void _onPriceUpdate(PriceUpdate update) {
    if (!mounted || _state.allCoins.isEmpty) return;
    _pendingPriceUpdates[update.symbol] = update;
    _priceFlushTimer ??= Timer(_priceUiThrottle, _flushQueuedPriceUpdates);
  }

  void _flushQueuedPriceUpdates() {
    _priceFlushTimer = null;
    if (!mounted || _state.allCoins.isEmpty || _pendingPriceUpdates.isEmpty) {
      return;
    }

    final queued = Map<String, PriceUpdate>.from(_pendingPriceUpdates);
    _pendingPriceUpdates.clear();

    var changed = false;
    final updated = _state.allCoins.map((coin) {
      final update = queued[coin.symbol];
      if (update == null) return coin;
      changed = true;
      return CoinData(
        symbol: coin.symbol,
        lastPrice: update.lastPrice,
        priceChange: update.lastPrice - update.openPrice,
        priceChangePercent: update.changePercent,
        highPrice: update.highPrice > coin.highPrice
            ? update.highPrice
            : coin.highPrice,
        lowPrice: update.lowPrice > 0 && update.lowPrice < coin.lowPrice
            ? update.lowPrice
            : coin.lowPrice,
        openPrice: update.openPrice,
        quoteVolume:
            update.quoteVolume > 0 ? update.quoteVolume : coin.quoteVolume,
        volume: coin.volume,
        count: coin.count,
        score: coin.score,
        historicalScore: coin.historicalScore,
        entryScore: coin.entryScore,
        expectedEdge: coin.expectedEdge,
        thirtyDayChange: coin.thirtyDayChange,
        sevenDayChange: coin.sevenDayChange,
        daysSinceSurge: coin.daysSinceSurge,
        level: coin.level,
        recommendation: coin.recommendation,
        reason: coin.reason,
        timingLabel: coin.timingLabel,
        timingReason: coin.timingReason,
      );
    }).toList();

    if (!changed) return;

    final updatedBySymbol = {
      for (final coin in updated) coin.symbol: coin,
    };
    final updatedTop3 = _state.top3
        .map((coin) => updatedBySymbol[coin.symbol] ?? coin)
        .toList();

    setState(() {
      _state = _state.copyWith(
        allCoins: updated,
        top3: updatedTop3,
        liveConnected: true,
        updatedAt: DateTime.now(),
      );
    });

    if (_pendingPriceUpdates.isNotEmpty && mounted) {
      _priceFlushTimer ??= Timer(_priceUiThrottle, _flushQueuedPriceUpdates);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      PicksScreen(
        state: _state,
        onRefresh: _loadFull,
      ),
      MarketScreen(
        state: _state,
        onRefresh: _loadFull,
        onSaveWatchlist: _saveWatchlist,
      ),
      const HistoryScreen(),
      const NewsScreen(),
    ];

    return Scaffold(
      backgroundColor: AppTheme.binanceDark,
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: _buildNavBar(),
    );
  }

  Widget _buildNavBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.cardDark.withAlpha(245),
        border: Border(
          top: BorderSide(color: AppTheme.cardLight.withAlpha(180)),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 20,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppTheme.binanceYellow,
        unselectedItemColor: AppTheme.textSecondary,
        selectedLabelStyle:
            const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.space_dashboard_rounded),
            label: '首页',
          ),
          BottomNavigationBarItem(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.stacked_line_chart_rounded),
                if (_state.liveConnected)
                  Positioned(
                    right: -4,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppTheme.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            label: '自选',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.analytics_rounded),
            label: '复盘',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.newspaper_rounded),
            label: '资讯',
          ),
        ],
      ),
    );
  }
}
