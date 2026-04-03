import 'package:flutter/material.dart';
import '../models/recommendation_history.dart';
import '../services/history_service.dart';
import '../theme/app_theme.dart';

/// 历史推荐准确率 Tab（CLAUDE.md: 自测每日推荐3个看准不准确，进行优化）
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _svc = HistoryService();
  List<DailyRecommendation> _history = [];
  Map<String, dynamic> _stats = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final h = await _svc.loadHistory();
    final s = await _svc.calcStats();
    if (mounted) {
      setState(() {
        _history = h;
        _stats = s;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.binanceDark,
      appBar: AppBar(
        backgroundColor: AppTheme.binanceDark,
        elevation: 0,
        title: const Text('历史准确率',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded,
                color: AppTheme.textPrimary),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.binanceYellow))
          : RefreshIndicator(
              onRefresh: _load,
              color: AppTheme.binanceYellow,
              backgroundColor: AppTheme.cardDark,
              child: _history.isEmpty
                  ? _buildEmpty()
                  : CustomScrollView(slivers: [
                      SliverToBoxAdapter(child: _buildStatsCard()),
                      SliverToBoxAdapter(
                          child: _buildSectionTitle('历史记录')),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) =>
                              _DayCard(day: _history[i]),
                          childCount: _history.length,
                        ),
                      ),
                      const SliverToBoxAdapter(
                          child: SizedBox(height: 40)),
                    ]),
            ),
    );
  }

  Widget _buildEmpty() {
    return ListView(
      children: const [
        SizedBox(height: 80),
        Center(
          child: Column(
            children: [
              Icon(Icons.history_rounded,
                  color: AppTheme.textSecondary, size: 60),
              SizedBox(height: 16),
              Text('暂无历史记录',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text(
                '每天查看「今日精选」后\n系统自动记录推荐并追踪结果',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatsCard() {
    final total = _stats['total'] as int? ?? 0;
    final wins = _stats['wins'] as int? ?? 0;
    final winRate = _stats['winRate'] as double? ?? 0.0;
    final avgReturn = _stats['avgReturn'] as double? ?? 0.0;
    final days = _stats['days'] as int? ?? 0;

    if (total == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: AppTheme.cardDark,
              borderRadius: BorderRadius.circular(14)),
          child: const Text('等待次日结算后显示准确率统计',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13),
              textAlign: TextAlign.center),
        ),
      );
    }

    final rateColor = winRate >= 0.6
        ? AppTheme.green
        : winRate >= 0.4
            ? AppTheme.holdColor
            : AppTheme.red;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: rateColor.withAlpha(80), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('📈 整体统计',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _BigStat(
                  label: '胜率',
                  value: '${(winRate * 100).toStringAsFixed(1)}%',
                  color: rateColor,
                  big: true,
                ),
                _BigStat(
                  label: '平均收益',
                  value:
                      '${avgReturn >= 0 ? '+' : ''}${avgReturn.toStringAsFixed(2)}%',
                  color:
                      avgReturn >= 0 ? AppTheme.green : AppTheme.red,
                ),
                _BigStat(
                    label: '累计推荐',
                    value: '$total 次',
                    color: AppTheme.textSecondary),
                _BigStat(
                    label: '统计天数',
                    value: '$days 天',
                    color: AppTheme.textSecondary),
              ],
            ),
            const SizedBox(height: 12),
            // 胜率进度条
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: winRate.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: AppTheme.cardLight,
                valueColor: AlwaysStoppedAnimation<Color>(rateColor),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('胜 $wins / 负 ${total - wins}',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11)),
                Text(
                    winRate >= 0.6
                        ? '✅ 准确率良好'
                        : winRate >= 0.4
                            ? '⚠️ 准确率一般'
                            : '❌ 准确率偏低，算法待优化',
                    style: TextStyle(color: rateColor, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Container(
              width: 3,
              height: 16,
              decoration: BoxDecoration(
                  color: AppTheme.binanceYellow,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ── 日卡片 ──────────────────────────────────────────────

class _DayCard extends StatelessWidget {
  final DailyRecommendation day;
  const _DayCard({required this.day});

  @override
  Widget build(BuildContext context) {
    final wins = day.picks.where((p) => p.isWin == true).length;
    final settled = day.picks.where((p) => p.isWin != null).length;

    Color borderColor;
    if (day.isPending) {
      borderColor = AppTheme.holdColor;
    } else {
      borderColor =
          wins >= 2 ? AppTheme.green : wins == 1 ? AppTheme.holdColor : AppTheme.red;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor.withAlpha(80), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              children: [
                Text(day.dateLabel,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                if (day.isPending)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.holdColor.withAlpha(40),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('待结算',
                        style: TextStyle(
                            color: AppTheme.holdColor, fontSize: 11)),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: borderColor.withAlpha(40),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$wins / $settled 胜',
                      style: TextStyle(
                          color: borderColor,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // 每个推荐
            ...day.picks.map((p) => _PickRow(pick: p)),
          ],
        ),
      ),
    );
  }
}

class _PickRow extends StatelessWidget {
  final PickRecord pick;
  const _PickRow({required this.pick});

  @override
  Widget build(BuildContext context) {
    Color resultColor;
    String resultLabel;

    if (pick.isPending) {
      resultColor = AppTheme.textSecondary;
      resultLabel = '待结算';
    } else if (pick.isWin == true) {
      resultColor = AppTheme.green;
      resultLabel = '✅ +${pick.changePercent.toStringAsFixed(2)}%';
    } else {
      resultColor = AppTheme.red;
      resultLabel = '❌ ${pick.changePercent.toStringAsFixed(2)}%';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
                color: resultColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(pick.symbol,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 6),
          Text(
            '@${_fmt(pick.entryPrice)}',
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 11),
          ),
          const Spacer(),
          Text(resultLabel,
              style: TextStyle(
                  color: resultColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  String _fmt(double p) {
    if (p >= 100) return p.toStringAsFixed(2);
    if (p >= 1) return p.toStringAsFixed(4);
    return p.toStringAsFixed(6);
  }
}

// ── 数字格 ─────────────────────────────────────────────

class _BigStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool big;
  const _BigStat(
      {required this.label,
      required this.value,
      required this.color,
      this.big = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                color: color,
                fontSize: big ? 22 : 16,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 11)),
      ],
    );
  }
}
