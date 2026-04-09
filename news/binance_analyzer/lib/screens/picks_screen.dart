import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/coin_data.dart';
import '../models/strategy_snapshot.dart';
import '../theme/app_theme.dart';
import '../utils/signal_action_helper.dart';
import 'main_nav_screen.dart';

typedef SignalActionHandler = Future<void> Function(
  EntryAlertSignal signal,
  String signalType,
  String actionType,
);

typedef SignalActionStatusResolver = String? Function(
  EntryAlertSignal signal,
  String signalType,
);

typedef SignalActionSubmittingResolver = bool Function(
  EntryAlertSignal signal,
  String signalType,
);

/// 今日精选 3 个 —— 首页 Tab
class PicksScreen extends StatelessWidget {
  final MarketState state;
  final Future<void> Function({bool silent}) onRefresh;
  final SignalActionHandler onSignalAction;
  final SignalActionStatusResolver resolveSignalActionStatus;
  final SignalActionSubmittingResolver isSignalActionSubmitting;

  const PicksScreen({
    super.key,
    required this.state,
    required this.onRefresh,
    required this.onSignalAction,
    required this.resolveSignalActionStatus,
    required this.isSignalActionSubmitting,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.binanceDark,
      body: RefreshIndicator(
        onRefresh: () => onRefresh(),
        color: AppTheme.binanceYellow,
        backgroundColor: AppTheme.cardDark,
        child: CustomScrollView(
          slivers: [
            _buildSliverAppBar(),
            if (state.loading)
              const SliverFillRemaining(child: _LoadingView())
            else if (state.error != null)
              SliverFillRemaining(
                child:
                    _ErrorView(error: state.error!, onRetry: () => onRefresh()),
              )
            else ...[
              SliverToBoxAdapter(child: _buildMarketMood()),
              SliverToBoxAdapter(child: _buildSignalActionSection()),
              SliverToBoxAdapter(child: _buildTop3Section()),
              SliverToBoxAdapter(child: _buildFooter()),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSliverAppBar() {
    return SliverAppBar(
      backgroundColor: AppTheme.binanceDark,
      elevation: 0,
      floating: true,
      pinned: false,
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              color: AppTheme.binanceYellow,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Text('币',
                style: TextStyle(
                    color: AppTheme.binanceDark,
                    fontWeight: FontWeight.w900,
                    fontSize: 16)),
          ),
          const SizedBox(width: 10),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('今日精选',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              Text('AI 智能推荐 · 每日3个',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            ],
          ),
        ],
      ),
      actions: [
        if (!state.loading)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Center(
              child: Text(
                DateFormat('HH:mm').format(state.updatedAt),
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
          ),
        IconButton(
          onPressed: () => onRefresh(),
          icon: state.loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.binanceYellow),
                )
              : const Icon(Icons.refresh_rounded, color: AppTheme.textPrimary),
        ),
      ],
    );
  }

  Widget _buildMarketMood() {
    final coins = state.allCoins;
    if (coins.isEmpty) return const SizedBox.shrink();

    final upCount = coins.where((c) => c.priceChangePercent > 0).length;
    final downCount = coins.where((c) => c.priceChangePercent < 0).length;
    final avg = coins.map((c) => c.priceChangePercent).reduce((a, b) => a + b) /
        coins.length;
    final mood = avg > 2
        ? ('🔥 市场偏强', AppTheme.green)
        : avg > 0
            ? ('📈 市场平稳', AppTheme.binanceYellow)
            : ('📉 市场偏弱', AppTheme.red);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: mood.$2.withAlpha(80), width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mood.$1,
                    style: TextStyle(
                        color: mood.$2,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  '${coins.length} 个自选 · ↑$upCount 涨 ↓$downCount 跌',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${avg >= 0 ? '+' : ''}${avg.toStringAsFixed(2)}%',
                style: TextStyle(
                  color: avg >= 0 ? AppTheme.green : AppTheme.red,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Text('平均涨幅',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSignalActionSection() {
    final buySignals =
        state.entryAlerts.where((item) => item.shouldNotify).take(3).toList();
    final sellSignals =
        state.exitAlerts.where((item) => item.shouldNotify).take(3).toList();

    if (buySignals.isEmpty && sellSignals.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppTheme.binanceYellow.withAlpha(50),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.notifications_active_rounded,
                  color: AppTheme.binanceYellow,
                  size: 18,
                ),
                SizedBox(width: 8),
                Text(
                  '飞书信号待处理',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '买入点确定，卖出点取消，动作会同步回后台做执行统计。',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 12),
            ...buySignals.map(
              (signal) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SignalActionTile(
                  signal: signal,
                  signalType: 'buy',
                  actionText: '确定',
                  accentColor: AppTheme.green,
                  actionStatus: resolveSignalActionStatus(signal, 'buy'),
                  submitting: isSignalActionSubmitting(signal, 'buy'),
                  onPressed: () => onSignalAction(signal, 'buy', 'confirm'),
                ),
              ),
            ),
            ...sellSignals.map(
              (signal) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SignalActionTile(
                  signal: signal,
                  signalType: 'sell',
                  actionText: '取消',
                  accentColor: AppTheme.red,
                  actionStatus: resolveSignalActionStatus(signal, 'sell'),
                  submitting: isSignalActionSubmitting(signal, 'sell'),
                  onPressed: () => onSignalAction(signal, 'sell', 'cancel'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTop3Section() {
    final picks = state.top3;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              Container(
                  width: 4,
                  height: 20,
                  decoration: BoxDecoration(
                      color: AppTheme.binanceYellow,
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              const Text('今日推荐买入',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: AppTheme.binanceYellow.withAlpha(40),
                    borderRadius: BorderRadius.circular(10)),
                child: Text(
                  '共 ${picks.length} 个',
                  style: const TextStyle(
                      color: AppTheme.binanceYellow,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 3 张卡片
          if (picks.isEmpty)
            _EmptyPicksCard()
          else
            ...List.generate(
              picks.length,
              (i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _BigPickCard(coin: picks[i], rank: i + 1),
              ),
            ),

          const SizedBox(height: 8),

          // 风险提示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.binanceYellow.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppTheme.binanceYellow.withAlpha(60), width: 1),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: AppTheme.binanceYellow, size: 15),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '推荐仅供参考，基于实时行情评分分析。加密市场风险极高，请做好仓位管理。',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📊 评分算法说明',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            _AlgoRow('动量分 (45%)', '24h涨幅在+1%~+8%得分最高'),
            _AlgoRow('位置分 (30%)', '价格在24h区间越低，上涨空间越大'),
            _AlgoRow('成交量 (25%)', '成交额越高，信号越可靠'),
          ],
        ),
      ),
    );
  }
}

class _AlgoRow extends StatelessWidget {
  final String label;
  final String desc;
  const _AlgoRow(this.label, this.desc);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• $label',
              style:
                  const TextStyle(color: AppTheme.binanceYellow, fontSize: 12)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(desc,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _SignalActionTile extends StatelessWidget {
  final EntryAlertSignal signal;
  final String signalType;
  final String actionText;
  final Color accentColor;
  final String? actionStatus;
  final bool submitting;
  final VoidCallback onPressed;

  const _SignalActionTile({
    required this.signal,
    required this.signalType,
    required this.actionText,
    required this.accentColor,
    required this.actionStatus,
    required this.submitting,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final statusText = actionStatus == null
        ? null
        : buildSignalActionStatusLabel(actionStatus!);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withAlpha(70)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      normalizeSignalActionSymbol(signal.symbol),
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withAlpha(35),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        signalType == 'sell' ? '卖出' : '买入',
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        signal.timingLabel,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  signal.timingReason,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '参考价 ${_formatActionPrice(signal.currentPrice)}  ·  综合 ${(signal.totalScore * 100).round()} 分',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (submitting)
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: accentColor,
                backgroundColor: accentColor.withAlpha(30),
              ),
            )
          else if (statusText != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: accentColor.withAlpha(22),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                statusText,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else
            FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                actionText,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }

  String _formatActionPrice(double price) {
    if (price >= 1000) return price.toStringAsFixed(2);
    if (price >= 1) return price.toStringAsFixed(4);
    if (price >= 0.01) return price.toStringAsFixed(5);
    return price.toStringAsFixed(7);
  }
}

// ─── 大号推荐卡 ────────────────────────────────────────────

class _BigPickCard extends StatelessWidget {
  final CoinData coin;
  final int rank;

  const _BigPickCard({required this.coin, required this.rank});

  Color get _accentColor => rank == 1
      ? AppTheme.strongBuyColor
      : rank == 2
          ? AppTheme.buyColor
          : AppTheme.holdColor;

  String get _rankLabel => rank == 1
      ? '🥇 首选'
      : rank == 2
          ? '🥈 次选'
          : '🥉 备选';

  @override
  Widget build(BuildContext context) {
    final chg = coin.priceChangePercent;
    final isUp = chg >= 0;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accentColor.withAlpha(100), width: 1.5),
      ),
      child: Column(
        children: [
          // ── 顶部彩色条 + 排名 + 名称 ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _accentColor.withAlpha(30),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(
              children: [
                Text(_rankLabel,
                    style: TextStyle(
                        color: _accentColor,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: _accentColor.withAlpha(50),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    coin.recommendation,
                    style: TextStyle(
                        color: _accentColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),

          // ── 主体内容 ──
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // 币名 + 价格 + 涨幅
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      coin.displayName,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 28,
                          fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'USDT',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 13),
                    ),
                    const Spacer(),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatPrice(coin.lastPrice),
                          style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.bold),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: (isUp ? AppTheme.green : AppTheme.red)
                                .withAlpha(40),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isUp
                                    ? Icons.arrow_drop_up
                                    : Icons.arrow_drop_down,
                                color: isUp ? AppTheme.green : AppTheme.red,
                                size: 18,
                              ),
                              Text(
                                '${isUp ? '+' : ''}${chg.toStringAsFixed(2)}%',
                                style: TextStyle(
                                    color: isUp ? AppTheme.green : AppTheme.red,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // 三个指标
                Row(
                  children: [
                    _Metric(
                      label: '24h最低',
                      value: _formatPrice(coin.lowPrice),
                      color: AppTheme.red,
                    ),
                    const SizedBox(width: 12),
                    _Metric(
                      label: '24h最高',
                      value: _formatPrice(coin.highPrice),
                      color: AppTheme.green,
                    ),
                    const SizedBox(width: 12),
                    _Metric(
                      label: '成交额',
                      value: _formatVol(coin.quoteVolume),
                      color: AppTheme.textSecondary,
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // 24h区间进度条
                _RangeBarFull(position: coin.rangePosition),

                const SizedBox(height: 12),

                // 综合评分
                Row(
                  children: [
                    const Text('综合评分',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: coin.score,
                          minHeight: 8,
                          backgroundColor: _accentColor.withAlpha(40),
                          valueColor:
                              AlwaysStoppedAnimation<Color>(_accentColor),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${(coin.score * 100).toInt()}分',
                      style: TextStyle(
                          color: _accentColor,
                          fontSize: 13,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),

                if (coin.reason.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.cardLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '📊 ${coin.reason}',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatPrice(double p) {
    if (p >= 1000) return p.toStringAsFixed(2);
    if (p >= 1) return p.toStringAsFixed(4);
    if (p >= 0.01) return p.toStringAsFixed(5);
    return p.toStringAsFixed(7);
  }

  String _formatVol(double v) {
    if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Metric(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.cardLight,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 10)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _RangeBarFull extends StatelessWidget {
  final double position;
  const _RangeBarFull({required this.position});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, cs) {
      final w = cs.maxWidth;
      return Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                height: 6,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.red, AppTheme.holdColor, AppTheme.green],
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              if (w > 12)
                Positioned(
                  left: (w * position.clamp(0.0, 1.0) - 6).clamp(0.0, w - 12),
                  top: -3,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppTheme.cardDark, width: 2),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withAlpha(80), blurRadius: 4)
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('最低',
                  style: TextStyle(color: AppTheme.red, fontSize: 10)),
              Text('当前位置 ${(position * 100).toInt()}%',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 10)),
              const Text('最高',
                  style: TextStyle(color: AppTheme.green, fontSize: 10)),
            ],
          ),
        ],
      );
    });
  }
}

class _EmptyPicksCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
          color: AppTheme.cardDark, borderRadius: BorderRadius.circular(14)),
      child: const Column(
        children: [
          Icon(Icons.sentiment_neutral,
              color: AppTheme.textSecondary, size: 40),
          SizedBox(height: 12),
          Text('今日市场整体偏弱，暂无强烈推荐',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              textAlign: TextAlign.center),
          SizedBox(height: 6),
          Text('建议观望或轻仓操作',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        CircularProgressIndicator(color: AppTheme.binanceYellow),
        SizedBox(height: 16),
        Text('正在获取行情数据...',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
      ]),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.wifi_off_rounded, color: AppTheme.red, size: 48),
          const SizedBox(height: 16),
          const Text('行情获取失败',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            error.length > 100 ? '${error.substring(0, 100)}...' : error,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.binanceYellow,
              foregroundColor: AppTheme.binanceDark,
            ),
          ),
        ]),
      ),
    );
  }
}
