import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/coin_data.dart';
import '../services/binance_service.dart';
import '../services/watchlist_service.dart';
import '../theme/app_theme.dart';
import '../utils/coin_insight_helper.dart';
import 'coin_detail_screen.dart';
import 'main_nav_screen.dart';

enum SortBy { score, change, volume, name }

enum FilterBy { all, up, down, volume, ready }

class MarketScreen extends StatefulWidget {
  final MarketState state;
  final Future<void> Function({bool silent}) onRefresh;
  final Future<void> Function(List<String> symbols) onSaveWatchlist;

  const MarketScreen({
    super.key,
    required this.state,
    required this.onRefresh,
    required this.onSaveWatchlist,
  });

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> {
  SortBy _sortBy = SortBy.score;
  bool _sortAsc = false;
  FilterBy _filterBy = FilterBy.all;

  List<CoinData> get _sorted {
    var list = switch (_filterBy) {
      FilterBy.all => List<CoinData>.from(widget.state.allCoins),
      FilterBy.up => widget.state.allCoins
          .where((coin) => coin.priceChangePercent >= 0)
          .toList(),
      FilterBy.down => widget.state.allCoins
          .where((coin) => coin.priceChangePercent < 0)
          .toList(),
      FilterBy.volume => widget.state.allCoins
          .where((coin) =>
              CoinInsightHelper.isVolumeExpanding(coin, widget.state.allCoins))
          .toList(),
      FilterBy.ready => widget.state.allCoins
          .where(CoinInsightHelper.isPreparingBreakout)
          .toList(),
    };

    list.sort((a, b) {
      final result = switch (_sortBy) {
        SortBy.score => a.score.compareTo(b.score),
        SortBy.change => a.priceChangePercent.compareTo(b.priceChangePercent),
        SortBy.volume => a.quoteVolume.compareTo(b.quoteVolume),
        SortBy.name => a.displayName.compareTo(b.displayName),
      };
      return _sortAsc ? result : -result;
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final allCoins = widget.state.allCoins;
    final readyCount =
        allCoins.where(CoinInsightHelper.isPreparingBreakout).length;
    final volumeCount = allCoins
        .where((coin) => CoinInsightHelper.isVolumeExpanding(coin, allCoins))
        .length;

    return Scaffold(
      backgroundColor: AppTheme.binanceDark,
      appBar: _buildAppBar(),
      body: widget.state.loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.binanceYellow),
            )
          : widget.state.error != null
              ? _ErrorState(
                  error: widget.state.error!, onRetry: () => widget.onRefresh())
              : RefreshIndicator(
                  onRefresh: () => widget.onRefresh(),
                  color: AppTheme.binanceYellow,
                  backgroundColor: AppTheme.cardDark,
                  child: ListView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    children: [
                      _WatchlistHero(
                        total: allCoins.length,
                        readyCount: readyCount,
                        volumeCount: volumeCount,
                        onSelectAll: () => _setFilter(FilterBy.all),
                        onSelectVolume: () => _setFilter(FilterBy.volume),
                        onSelectReady: () => _setFilter(FilterBy.ready),
                      ),
                      const SizedBox(height: 16),
                      _buildFilterBar(),
                      const SizedBox(height: 10),
                      _buildSortBar(),
                      const SizedBox(height: 14),
                      ..._buildRows(context),
                    ],
                  ),
                ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: AppTheme.binanceDark,
      elevation: 0,
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Watchlist',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            '监控放量、评分与是否即将启动',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          onPressed: _openWatchlistManager,
          icon: const Icon(
            Icons.playlist_add_rounded,
            color: AppTheme.textPrimary,
          ),
        ),
        if (!widget.state.loading)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: Text(
                DateFormat('HH:mm:ss').format(widget.state.updatedAt),
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        IconButton(
          onPressed: () => widget.onRefresh(),
          icon: const Icon(Icons.refresh_rounded, color: AppTheme.textPrimary),
        ),
      ],
    );
  }

  Widget _buildFilterBar() {
    final all = widget.state.allCoins;
    final upCount = all.where((coin) => coin.priceChangePercent >= 0).length;
    final downCount = all.length - upCount;
    final volumeCount = all
        .where((coin) => CoinInsightHelper.isVolumeExpanding(coin, all))
        .length;
    final readyCount = all.where(CoinInsightHelper.isPreparingBreakout).length;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _FilterChip(
          label: '全部 ${all.length}',
          selected: _filterBy == FilterBy.all,
          onTap: () => setState(() => _filterBy = FilterBy.all),
          color: AppTheme.textPrimary,
        ),
        _FilterChip(
          label: '上涨 $upCount',
          selected: _filterBy == FilterBy.up,
          onTap: () => setState(() => _filterBy = FilterBy.up),
          color: AppTheme.green,
        ),
        _FilterChip(
          label: '下跌 $downCount',
          selected: _filterBy == FilterBy.down,
          onTap: () => setState(() => _filterBy = FilterBy.down),
          color: AppTheme.red,
        ),
        _FilterChip(
          label: '放量 $volumeCount',
          selected: _filterBy == FilterBy.volume,
          onTap: () => setState(() => _filterBy = FilterBy.volume),
          color: AppTheme.accentBlue,
        ),
        _FilterChip(
          label: '启动候选 $readyCount',
          selected: _filterBy == FilterBy.ready,
          onTap: () => setState(() => _filterBy = FilterBy.ready),
          color: AppTheme.accentOrange,
        ),
      ],
    );
  }

  Widget _buildSortBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          const Text(
            '排序',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(width: 8),
          _SortBtn(
            label: '评分',
            active: _sortBy == SortBy.score,
            asc: _sortAsc,
            onTap: () => _switchSort(SortBy.score, false),
          ),
          const SizedBox(width: 8),
          _SortBtn(
            label: '涨幅',
            active: _sortBy == SortBy.change,
            asc: _sortAsc,
            onTap: () => _switchSort(SortBy.change, false),
          ),
          const SizedBox(width: 8),
          _SortBtn(
            label: '成交额',
            active: _sortBy == SortBy.volume,
            asc: _sortAsc,
            onTap: () => _switchSort(SortBy.volume, false),
          ),
          const SizedBox(width: 8),
          _SortBtn(
            label: '名称',
            active: _sortBy == SortBy.name,
            asc: _sortAsc,
            onTap: () => _switchSort(SortBy.name, true),
          ),
        ],
      ),
    );
  }

  void _switchSort(SortBy target, bool defaultAsc) {
    setState(() {
      if (_sortBy == target) {
        _sortAsc = !_sortAsc;
      } else {
        _sortBy = target;
        _sortAsc = defaultAsc;
      }
    });
  }

  void _setFilter(FilterBy filter) {
    setState(() => _filterBy = filter);
  }

  Future<void> _openWatchlistManager() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _WatchlistManagerSheet(
        selectedSymbols: widget.state.watchlistSymbols,
        currentCoins: widget.state.allCoins,
        onSave: widget.onSaveWatchlist,
      ),
    );
  }

  List<Widget> _buildRows(BuildContext context) {
    final rows = _sorted;
    if (rows.isEmpty) {
      return [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: AppTheme.panelDecoration(),
          child: const Text(
            '当前筛选条件下没有匹配币种。',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ),
      ];
    }

    return rows.map((coin) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _WatchlistCard(
          coin: coin,
          peers: widget.state.allCoins,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CoinDetailScreen(
                coin: coin,
                marketCoins: widget.state.allCoins,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }
}

class _WatchlistHero extends StatelessWidget {
  final int total;
  final int readyCount;
  final int volumeCount;
  final VoidCallback onSelectAll;
  final VoidCallback onSelectVolume;
  final VoidCallback onSelectReady;

  const _WatchlistHero({
    required this.total,
    required this.readyCount,
    required this.volumeCount,
    required this.onSelectAll,
    required this.onSelectVolume,
    required this.onSelectReady,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            AppTheme.cardDark,
            AppTheme.accentBlue.withAlpha(35),
            AppTheme.cardDark,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: AppTheme.accentBlue.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '自选池正在帮你盯盘',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '重点查看三个标签：涨跌幅、是否放量、是否即将启动。右上角可以增删自选币，点数卡可直接切筛选。',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _HeroCounter(
                  label: '观察币数',
                  value: '$total',
                  onTap: onSelectAll,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroCounter(
                  label: '放量币数',
                  value: '$volumeCount',
                  onTap: onSelectVolume,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroCounter(
                  label: '启动候选',
                  value: '$readyCount',
                  onTap: onSelectReady,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroCounter extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _HeroCounter({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.cardLight.withAlpha(160),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.textSecondary,
                    size: 16,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WatchlistCard extends StatelessWidget {
  final CoinData coin;
  final List<CoinData> peers;
  final VoidCallback onTap;

  const _WatchlistCard({
    required this.coin,
    required this.peers,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.scoreColor(coin.score);
    final isUp = coin.priceChangePercent >= 0;
    final volumeExpanding = CoinInsightHelper.isVolumeExpanding(coin, peers);
    final preparing = CoinInsightHelper.isPreparingBreakout(coin);
    final sector = CoinInsightHelper.sectorFor(coin);
    final timingColor = coin.timingLabel == '可入场'
        ? AppTheme.green
        : coin.timingLabel == '临近买点'
            ? AppTheme.accentOrange
            : AppTheme.textSecondary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          decoration:
              AppTheme.panelDecoration(borderColor: accent.withAlpha(90)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: accent.withAlpha(18),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        coin.displayName
                            .substring(0, coin.displayName.length.clamp(0, 2)),
                        style: TextStyle(
                          color: accent,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            coin.displayName,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$sector · ${coin.recommendation}',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          if (coin.timingLabel.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '时机: ${coin.timingLabel}',
                              style: TextStyle(
                                color: timingColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          CoinInsightHelper.formatPrice(coin.lastPrice),
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          CoinInsightHelper.formatPercent(
                              coin.priceChangePercent),
                          style: TextStyle(
                            color: isUp ? AppTheme.green : AppTheme.red,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _StatusBadge(
                        label: '放量',
                        value: volumeExpanding ? '是' : '否',
                        color: volumeExpanding
                            ? AppTheme.green
                            : AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatusBadge(
                        label: '即将启动',
                        value: preparing ? '较强' : '一般',
                        color: preparing
                            ? AppTheme.accentOrange
                            : AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatusBadge(
                        label: '评分',
                        value: '${(coin.score * 100).round()}',
                        color: accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        coin.reason.isEmpty ? '暂无信号说明' : coin.reason,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          height: 1.5,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.textSecondary,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatusBadge({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(50)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _WatchlistManagerSheet extends StatefulWidget {
  final List<String> selectedSymbols;
  final List<CoinData> currentCoins;
  final Future<void> Function(List<String> symbols) onSave;

  const _WatchlistManagerSheet({
    required this.selectedSymbols,
    required this.currentCoins,
    required this.onSave,
  });

  @override
  State<_WatchlistManagerSheet> createState() => _WatchlistManagerSheetState();
}

class _WatchlistManagerSheetState extends State<_WatchlistManagerSheet> {
  final _binance = BinanceService();
  final _searchController = TextEditingController();

  late List<String> _selected;
  late Future<List<String>> _catalogFuture;
  String _query = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.selectedSymbols);
    _catalogFuture = _loadCatalog();
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text.trim().toUpperCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<String>> _loadCatalog() async {
    try {
      final remote = await _binance.fetchTradableUsdtSymbols(limit: 260);
      return _mergeSymbols(remote);
    } catch (_) {
      final fallback = [
        ...widget.selectedSymbols,
        ...widget.currentCoins.map((coin) => coin.symbol),
        ...BinanceService.defaultWatchlistSymbols,
      ];
      return _mergeSymbols(fallback);
    }
  }

  List<String> _mergeSymbols(List<String> items) {
    final unique = <String>{};
    final result = <String>[];

    for (final symbol in items) {
      final normalized = WatchlistService.normalizeSymbol(symbol);
      if (normalized.isEmpty || !unique.add(normalized)) continue;
      result.add(normalized);
    }

    result.sort();
    return result;
  }

  void _toggleSymbol(String symbol) {
    setState(() {
      if (_selected.contains(symbol)) {
        if (_selected.length == 1) return;
        _selected.remove(symbol);
      } else {
        _selected.add(symbol);
        _selected.sort();
      }
    });
  }

  Future<void> _save() async {
    if (_selected.isEmpty) return;
    setState(() => _saving = true);
    await widget.onSave(_selected);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 40, 12, bottomInset + 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: Material(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '管理自选币',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '添加或删除要盯的币，保存后首页、资讯和提醒都会跟着更新。',
                              style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded,
                            color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _searchController,
                    style: const TextStyle(color: AppTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: '搜索符号，例如 BTC / ETH / FET',
                      hintStyle: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded,
                          color: AppTheme.textSecondary),
                      filled: true,
                      fillColor: AppTheme.cardLight.withAlpha(120),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '当前自选',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _selected.map((symbol) {
                      return GestureDetector(
                        onTap: () => _toggleSymbol(symbol),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: AppTheme.binanceYellow.withAlpha(20),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: AppTheme.binanceYellow),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                WatchlistService.displayName(symbol),
                                style: const TextStyle(
                                  color: AppTheme.binanceYellow,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.close_rounded,
                                  color: AppTheme.binanceYellow, size: 14),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '可添加币种',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 280,
                    child: FutureBuilder<List<String>>(
                      future: _catalogFuture,
                      builder: (context, snapshot) {
                        final catalog = snapshot.data ?? const <String>[];
                        final normalizedQuery =
                            WatchlistService.normalizeSymbol(_query);
                        final filtered = catalog
                            .where((symbol) {
                              if (_query.isEmpty) return true;
                              final name = WatchlistService.displayName(symbol);
                              return symbol.contains(_query) ||
                                  name.contains(_query);
                            })
                            .take(32)
                            .toList();

                        if (snapshot.connectionState ==
                                ConnectionState.waiting &&
                            catalog.isEmpty) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: AppTheme.binanceYellow,
                            ),
                          );
                        }

                        return ListView(
                          shrinkWrap: true,
                          children: [
                            if (_query.isNotEmpty &&
                                normalizedQuery.isNotEmpty &&
                                !catalog.contains(normalizedQuery))
                              _WatchlistSymbolTile(
                                symbol: normalizedQuery,
                                selected: _selected.contains(normalizedQuery),
                                hint: '手动添加',
                                onTap: () => _toggleSymbol(normalizedQuery),
                              ),
                            ...filtered.map((symbol) => _WatchlistSymbolTile(
                                  symbol: symbol,
                                  selected: _selected.contains(symbol),
                                  onTap: () => _toggleSymbol(symbol),
                                )),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.binanceYellow,
                        foregroundColor: AppTheme.binanceDark,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.binanceDark,
                              ),
                            )
                          : Text('保存自选 (${_selected.length})'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WatchlistSymbolTile extends StatelessWidget {
  final String symbol;
  final bool selected;
  final VoidCallback onTap;
  final String hint;

  const _WatchlistSymbolTile({
    required this.symbol,
    required this.selected,
    required this.onTap,
    this.hint = 'Binance USDT',
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      title: Text(
        WatchlistService.displayName(symbol),
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        '$symbol · $hint',
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 11,
        ),
      ),
      trailing: Icon(
        selected
            ? Icons.check_circle_rounded
            : Icons.add_circle_outline_rounded,
        color: selected ? AppTheme.green : AppTheme.textSecondary,
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off_rounded, color: AppTheme.red, size: 40),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: onRetry,
              child: const Text(
                '重试',
                style: TextStyle(color: AppTheme.binanceYellow),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color color;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? color.withAlpha(22) : AppTheme.cardDark,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? color : AppTheme.cardLight),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? color : AppTheme.textSecondary,
            fontSize: 12,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _SortBtn extends StatelessWidget {
  final String label;
  final bool active;
  final bool asc;
  final VoidCallback onTap;

  const _SortBtn({
    required this.label,
    required this.active,
    required this.asc,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color:
              active ? AppTheme.binanceYellow.withAlpha(25) : AppTheme.cardDark,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? AppTheme.binanceYellow : AppTheme.cardLight,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: active ? AppTheme.binanceYellow : AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 4),
              Icon(
                asc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                color: AppTheme.binanceYellow,
                size: 12,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
