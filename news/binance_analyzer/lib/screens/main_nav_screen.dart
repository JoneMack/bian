import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import '../utils/signal_action_helper.dart';
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
  final List<EntryAlertSignal> exitAlerts;
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
    this.exitAlerts = const [],
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
    List<EntryAlertSignal>? exitAlerts,
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
      exitAlerts: exitAlerts ?? this.exitAlerts,
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
  Map<String, String> _signalActionStatuses = {};
  List<OpenBuyPosition> _openBuyPositions = const [];
  final Set<String> _submittingSignalIds = <String>{};
  bool _refreshInFlight = false;
  bool _refreshQueued = false;

  @override
  void initState() {
    super.initState();
    unawaited(_notifications.requestPermissions());
    unawaited(_loadSignalActionStatuses());
    unawaited(_loadOpenBuyPositions());
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

  Future<void> _loadSignalActionStatuses() async {
    final cached = await _history.loadSignalActionStatuses();
    if (!mounted) return;
    setState(() {
      _signalActionStatuses = cached;
    });
  }

  Future<void> _loadOpenBuyPositions() async {
    final cached = await _history.loadOpenBuyPositions();
    if (!mounted) return;
    setState(() {
      _openBuyPositions = cached;
    });
  }

  String _signalIdFor(EntryAlertSignal signal, String signalType) {
    return buildSignalActionSignalId(
      signal: signal,
      signalType: signalType,
      at: _state.updatedAt,
    );
  }

  String? _signalActionStatusOf(EntryAlertSignal signal, String signalType) {
    return _signalActionStatuses[_signalIdFor(signal, signalType)];
  }

  bool _isSignalActionSubmitting(EntryAlertSignal signal, String signalType) {
    return _submittingSignalIds.contains(_signalIdFor(signal, signalType));
  }

  Future<void> _submitSignalAction(
    EntryAlertSignal signal,
    String signalType,
    String actionType,
  ) async {
    final signalId = _signalIdFor(signal, signalType);
    if (_submittingSignalIds.contains(signalId)) return;

    final existingAction = _signalActionStatuses[signalId];
    if (existingAction == actionType) {
      _showSignalActionMessage(buildSignalActionStatusLabel(actionType));
      return;
    }

    if (!_backendApi.isConfigured) {
      _showSignalActionMessage('请先配置后台地址');
      await _openBackendSettings();
      return;
    }

    await HapticFeedback.selectionClick();
    setState(() {
      _submittingSignalIds.add(signalId);
    });
    _showSignalActionMessage(
      actionType == 'confirm' ? '正在提交买入确认...' : '正在提交卖出取消...',
    );

    try {
      final result = await _backendApi.submitSignalAction(
        signalId: signalId,
        symbol: normalizeSignalActionSymbol(signal.symbol),
        signalType: signalType,
        signalSource: 'feishu',
        actionType: actionType,
        price: signal.currentPrice,
        timingLabel: signal.timingLabel,
        timingReason: signal.timingReason,
        totalScore: signal.totalScore,
        entryScore: signal.entryScore,
      );

      final nextStatuses = Map<String, String>.from(_signalActionStatuses)
        ..[signalId] = actionType;
      await _history.saveSignalActionStatuses(nextStatuses);
      if (signalType == 'buy' && actionType == 'confirm') {
        await _history.upsertOpenBuyPosition(
          OpenBuyPosition(
            symbol: normalizeSignalActionSymbol(signal.symbol),
            entryPrice: signal.currentPrice,
            boughtAt: _state.updatedAt,
            timingLabel: signal.timingLabel,
            timingReason: signal.timingReason,
            totalScore: signal.totalScore,
            entryScore: signal.entryScore,
            signalId: signalId,
          ),
        );
      } else if (signalType == 'sell' && actionType == 'cancel') {
        await _history.removeOpenBuyPosition(
          normalizeSignalActionSymbol(signal.symbol),
        );
      }
      final nextPositions = await _history.loadOpenBuyPositions();

      if (!mounted) return;
      setState(() {
        _signalActionStatuses = nextStatuses;
        _openBuyPositions = nextPositions;
      });
      _showSignalActionMessage(
        result.created ? '已记录到后台统计' : '这条信号今天已经记录过了',
      );
    } catch (error) {
      _showSignalActionMessage('记录失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _submittingSignalIds.remove(signalId);
        });
      }
    }
  }

  void _showSignalActionMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _openBackendSettings() async {
    final controller = TextEditingController(
      text: _backendApi.resolvedBaseUrl ?? '',
    );
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppTheme.cardDark,
          title: const Text(
            '配置后台地址',
            style: TextStyle(color: AppTheme.textPrimary),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(
              hintText: '例如 http://你的服务器IP',
              hintStyle: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                await BackendApiService.clearBaseUrl();
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop('');
                }
              },
              child: const Text('清空'),
            ),
            FilledButton(
              onPressed: () async {
                final raw = controller.text.trim();
                if (raw.isEmpty) {
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop('');
                  }
                  return;
                }
                await BackendApiService.saveBaseUrl(raw);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(raw);
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.binanceYellow,
                foregroundColor: AppTheme.binanceDark,
              ),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (!mounted || saved == null) return;
    if (saved.isEmpty) {
      _showSignalActionMessage('已清空后台地址，将使用本地模式');
      return;
    }

    _showSignalActionMessage('后台地址已保存');
    await _loadFull(silent: true);
  }

  Future<void> _openWaitingBuySheet() async {
    final pendingBuySignals = statePendingBuySignals;
    final openPositions = _openBuyPositions;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Container(
            decoration: const BoxDecoration(
              color: AppTheme.cardDark,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.cardLight,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '等待买入 / 已买入',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '等待买入 ${pendingBuySignals.length} 个',
                    style: const TextStyle(
                      color: AppTheme.binanceYellow,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (pendingBuySignals.isEmpty)
                    const Text(
                      '当前没有待确认买入信号',
                      style: TextStyle(color: AppTheme.textSecondary),
                    )
                  else
                    ...pendingBuySignals.take(5).map(
                          (signal) => _WaitingSignalRow(
                            symbol: normalizeSignalActionSymbol(signal.symbol),
                            subtitle: signal.timingReason,
                            trailing:
                                '参考 ${signal.currentPrice.toStringAsFixed(signal.currentPrice >= 1 ? 4 : 6)}',
                          ),
                        ),
                  const SizedBox(height: 16),
                  Text(
                    '已买入待卖 ${openPositions.length} 个',
                    style: const TextStyle(
                      color: AppTheme.green,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (openPositions.isEmpty)
                    const Text(
                      '当前没有已确认买入的持仓',
                      style: TextStyle(color: AppTheme.textSecondary),
                    )
                  else
                    ...openPositions.take(8).map(
                          (position) => _WaitingSignalRow(
                            symbol: position.symbol,
                            subtitle: '买入理由：${position.timingReason}',
                            trailing:
                                '买入 ${position.entryPrice.toStringAsFixed(position.entryPrice >= 1 ? 4 : 6)}',
                          ),
                        ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<EntryAlertSignal> get statePendingBuySignals => _state.entryAlerts
      .where((item) => item.shouldNotify)
      .where((item) => _signalActionStatusOf(item, 'buy') != 'confirm')
      .take(5)
      .toList();

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
          exitAlerts: snapshot.exitAlerts,
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
        onSignalAction: _submitSignalAction,
        onOpenBackendSettings: _openBackendSettings,
        onOpenWaitingBuys: _openWaitingBuySheet,
        pendingBuyCount: statePendingBuySignals.length,
        backendConfigured: _backendApi.isConfigured,
        openPositions: _openBuyPositions,
        resolveSignalActionStatus: _signalActionStatusOf,
        isSignalActionSubmitting: _isSignalActionSubmitting,
      ),
      MarketScreen(
        state: _state,
        onRefresh: _loadFull,
        onSaveWatchlist: _saveWatchlist,
        onOpenWaitingBuys: _openWaitingBuySheet,
        pendingBuyCount: statePendingBuySignals.length,
        onSignalAction: _submitSignalAction,
        openPositions: _openBuyPositions,
        resolveSignalActionStatus: _signalActionStatusOf,
        isSignalActionSubmitting: _isSignalActionSubmitting,
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

class _WaitingSignalRow extends StatelessWidget {
  final String symbol;
  final String subtitle;
  final String trailing;

  const _WaitingSignalRow({
    required this.symbol,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  symbol,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            trailing,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
