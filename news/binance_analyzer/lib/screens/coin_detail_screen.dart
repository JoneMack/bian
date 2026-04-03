import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/coin_data.dart';
import '../services/binance_service.dart';
import '../theme/app_theme.dart';
import '../utils/coin_insight_helper.dart';

class CoinDetailScreen extends StatefulWidget {
  final CoinData coin;
  final List<CoinData> marketCoins;

  const CoinDetailScreen({
    super.key,
    required this.coin,
    required this.marketCoins,
  });

  @override
  State<CoinDetailScreen> createState() => _CoinDetailScreenState();
}

class _CoinDetailScreenState extends State<CoinDetailScreen> {
  final _binance = BinanceService();
  final List<String> _intervals = const ['15m', '1h', '4h', '1d'];

  late String _selectedInterval;
  late Future<List<Kline>> _klineFuture;

  @override
  void initState() {
    super.initState();
    _selectedInterval = _intervals[1];
    _klineFuture = _loadKlines();
  }

  Future<List<Kline>> _loadKlines() {
    return _binance.fetchKlines(
      widget.coin.symbol,
      interval: _selectedInterval,
      limit: _selectedInterval == '15m' ? 32 : 36,
    );
  }

  void _changeInterval(String interval) {
    if (_selectedInterval == interval) return;
    setState(() {
      _selectedInterval = interval;
      _klineFuture = _loadKlines();
    });
  }

  @override
  Widget build(BuildContext context) {
    final coin = widget.coin;
    final sector = CoinInsightHelper.sectorFor(coin);
    final isUp = coin.priceChangePercent >= 0;
    final snapshots =
        CoinInsightHelper.buildSectorSnapshots(widget.marketCoins);
    final sectorRank =
        snapshots.indexWhere((snapshot) => snapshot.name == sector) + 1;

    return Scaffold(
      backgroundColor: AppTheme.binanceDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          '${coin.displayName} 详情',
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              child: Column(
                children: [
                  _buildHeroCard(coin, sector, sectorRank, isUp),
                  const SizedBox(height: 16),
                  _buildChartCard(coin),
                  const SizedBox(height: 16),
                  _buildMetricsGrid(coin),
                  const SizedBox(height: 16),
                  _buildSignalCard(coin),
                  const SizedBox(height: 16),
                  _buildSectorCard(sector, sectorRank, snapshots),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(
    CoinData coin,
    String sector,
    int sectorRank,
    bool isUp,
  ) {
    final scoreColor = AppTheme.scoreColor(coin.score);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            AppTheme.cardDark,
            scoreColor.withAlpha(45),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: scoreColor.withAlpha(110)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.binanceYellow.withAlpha(26),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  sector,
                  style: const TextStyle(
                    color: AppTheme.binanceYellow,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.cardLight,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  CoinInsightHelper.setupLabel(coin, widget.marketCoins),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      coin.displayName,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'USDT · ${coin.recommendation}',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      CoinInsightHelper.formatPrice(coin.lastPrice),
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: (isUp ? AppTheme.green : AppTheme.red)
                            .withAlpha(26),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        CoinInsightHelper.formatPercent(
                            coin.priceChangePercent),
                        style: TextStyle(
                          color: isUp ? AppTheme.green : AppTheme.red,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 104,
                height: 104,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 104,
                      height: 104,
                      child: CircularProgressIndicator(
                        value: coin.score,
                        strokeWidth: 9,
                        backgroundColor: AppTheme.cardLight,
                        valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
                      ),
                    ),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          CoinInsightHelper.scoreLabel(coin.score),
                          style: TextStyle(
                            color: scoreColor,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          '${(coin.score * 100).round()}分',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _MiniStatTile(
                  label: '放量状态',
                  value: CoinInsightHelper.isVolumeExpanding(
                          coin, widget.marketCoins)
                      ? '是'
                      : '否',
                  accent: CoinInsightHelper.isVolumeExpanding(
                          coin, widget.marketCoins)
                      ? AppTheme.green
                      : AppTheme.textSecondary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MiniStatTile(
                  label: '区间位置',
                  value: '${(coin.rangePosition * 100).round()}%',
                  accent: AppTheme.binanceYellow,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MiniStatTile(
                  label: '板块排名',
                  value: sectorRank > 0 ? '#$sectorRank' : '--',
                  accent: AppTheme.accentBlue,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChartCard(CoinData coin) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'K线图',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '观察 ${coin.displayName} 在不同周期的趋势和波动区间',
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            children: _intervals.map((interval) {
              final selected = interval == _selectedInterval;
              return GestureDetector(
                onTap: () => _changeInterval(interval),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color:
                        selected ? AppTheme.binanceYellow : AppTheme.cardLight,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    interval,
                    style: TextStyle(
                      color: selected
                          ? AppTheme.binanceDark
                          : AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          FutureBuilder<List<Kline>>(
            future: _klineFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                  height: 240,
                  child: Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.binanceYellow),
                  ),
                );
              }

              final klines = snapshot.data ?? const <Kline>[];
              if (klines.isEmpty) {
                return Container(
                  height: 220,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.cardLight.withAlpha(120),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Text(
                    'K线暂时拉取失败，稍后重试',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                );
              }

              final highest = klines
                  .map((item) => item.high)
                  .reduce((a, b) => a > b ? a : b);
              final lowest = klines
                  .map((item) => item.low)
                  .reduce((a, b) => a < b ? a : b);
              final latest = klines.last.close;
              final first = klines.first.open;
              final delta = ((latest - first) / first) * 100;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _ChartBadge(
                        label: '区间高点',
                        value: CoinInsightHelper.formatPrice(highest),
                        accent: AppTheme.green,
                      ),
                      const SizedBox(width: 10),
                      _ChartBadge(
                        label: '区间低点',
                        value: CoinInsightHelper.formatPrice(lowest),
                        accent: AppTheme.red,
                      ),
                      const SizedBox(width: 10),
                      _ChartBadge(
                        label: '阶段变化',
                        value: CoinInsightHelper.formatPercent(delta),
                        accent: delta >= 0 ? AppTheme.green : AppTheme.red,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    height: 240,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.cardLight.withAlpha(90),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: CustomPaint(
                      painter: _CandlestickPainter(
                        klines: klines,
                        riseColor: AppTheme.green,
                        fallColor: AppTheme.red,
                        gridColor: AppTheme.textSecondary.withAlpha(40),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsGrid(CoinData coin) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '指标数据',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            childAspectRatio: 1.7,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            children: [
              _MetricCard(
                label: '30天变化',
                value: CoinInsightHelper.formatPercent(coin.thirtyDayChange),
                tone: coin.thirtyDayChange >= 0 ? AppTheme.green : AppTheme.red,
              ),
              _MetricCard(
                label: '7天变化',
                value: CoinInsightHelper.formatPercent(coin.sevenDayChange),
                tone: coin.sevenDayChange >= 0 ? AppTheme.green : AppTheme.red,
              ),
              _MetricCard(
                label: '24h成交额',
                value: CoinInsightHelper.formatVolume(coin.quoteVolume),
                tone: AppTheme.accentBlue,
              ),
              _MetricCard(
                label: '24h最高',
                value: CoinInsightHelper.formatPrice(coin.highPrice),
                tone: AppTheme.green,
              ),
              _MetricCard(
                label: '24h最低',
                value: CoinInsightHelper.formatPrice(coin.lowPrice),
                tone: AppTheme.red,
              ),
              _MetricCard(
                label: '轮动间隔',
                value: '${coin.daysSinceSurge} 天',
                tone: AppTheme.binanceYellow,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSignalCard(CoinData coin) {
    final volumeExpanding =
        CoinInsightHelper.isVolumeExpanding(coin, widget.marketCoins);
    final preparing = CoinInsightHelper.isPreparingBreakout(coin);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '当前评分',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: coin.score,
              minHeight: 10,
              backgroundColor: AppTheme.cardLight,
              valueColor: AlwaysStoppedAnimation<Color>(
                  AppTheme.scoreColor(coin.score)),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            coin.reason.isEmpty ? '当前暂无额外解释' : coin.reason,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          if (coin.timingLabel.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '买点判断: ${coin.timingLabel} · ${coin.timingReason}',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StatusPill(
                  title: '放量',
                  value: volumeExpanding ? '已确认' : '一般',
                  active: volumeExpanding,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatusPill(
                  title: '买入时机',
                  value: coin.timingLabel.isNotEmpty
                      ? coin.timingLabel
                      : (preparing ? '较高概率' : '继续观察'),
                  active: coin.timingLabel == '可入场' || preparing,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectorCard(
    String sector,
    int sectorRank,
    List<SectorSnapshot> snapshots,
  ) {
    final current = snapshots.cast<SectorSnapshot?>().firstWhere(
          (snapshot) => snapshot?.name == sector,
          orElse: () => null,
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '所属板块',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  label: '板块名称',
                  value: sector,
                  tone: AppTheme.binanceYellow,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  label: '强度排名',
                  value: sectorRank > 0 ? '#$sectorRank' : '--',
                  tone: AppTheme.accentBlue,
                ),
              ),
            ],
          ),
          if (current != null) ...[
            const SizedBox(height: 14),
            Text(
              '板块平均涨幅 ${CoinInsightHelper.formatPercent(current.averageChange)} · 平均评分 ${(current.averageScore * 100).round()}分',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: current.coins.take(5).map((coin) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppTheme.cardLight,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${coin.displayName} ${(coin.score * 100).round()}',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniStatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  const _MiniStatTile({
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardLight.withAlpha(160),
        borderRadius: BorderRadius.circular(16),
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
              color: accent,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  const _ChartBadge({
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: accent.withAlpha(18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withAlpha(60)),
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
                color: accent,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final Color tone;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tone.withAlpha(18),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tone.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: tone,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String title;
  final String value;
  final bool active;

  const _StatusPill({
    required this.title,
    required this.value,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppTheme.green : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: active ? AppTheme.green.withAlpha(16) : AppTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _CandlestickPainter extends CustomPainter {
  final List<Kline> klines;
  final Color riseColor;
  final Color fallColor;
  final Color gridColor;

  const _CandlestickPainter({
    required this.klines,
    required this.riseColor,
    required this.fallColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (klines.isEmpty) return;

    final highs = klines.map((item) => item.high);
    final lows = klines.map((item) => item.low);
    final highest = highs.reduce(math.max);
    final lowest = lows.reduce(math.min);
    final range = math.max(highest - lowest, 0.0000001);
    final candleWidth = size.width / klines.length;
    final bodyWidth = math.max(3.0, candleWidth * 0.56);

    final gridPaint = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var i = 1; i <= 4; i++) {
      final y = size.height * (i / 5);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    for (var i = 0; i < klines.length; i++) {
      final item = klines[i];
      final x = candleWidth * i + candleWidth / 2;
      final openY = _mapY(item.open, highest, lowest, range, size.height);
      final closeY = _mapY(item.close, highest, lowest, range, size.height);
      final highY = _mapY(item.high, highest, lowest, range, size.height);
      final lowY = _mapY(item.low, highest, lowest, range, size.height);
      final color = item.close >= item.open ? riseColor : fallColor;

      final wickPaint = Paint()
        ..color = color
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(Offset(x, highY), Offset(x, lowY), wickPaint);

      final bodyTop = math.min(openY, closeY);
      final bodyBottom = math.max(openY, closeY);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - bodyWidth / 2,
          bodyTop,
          bodyWidth,
          math.max(2, bodyBottom - bodyTop),
        ),
        const Radius.circular(3),
      );

      final bodyPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      canvas.drawRRect(rect, bodyPaint);
    }
  }

  double _mapY(
    double value,
    double highest,
    double lowest,
    double range,
    double height,
  ) {
    return ((highest - value) / range) * (height - 10) + 5;
  }

  @override
  bool shouldRepaint(covariant _CandlestickPainter oldDelegate) {
    return oldDelegate.klines != klines ||
        oldDelegate.riseColor != riseColor ||
        oldDelegate.fallColor != fallColor ||
        oldDelegate.gridColor != gridColor;
  }
}
