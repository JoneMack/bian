import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../models/coin_data.dart';
import '../models/recommendation_history.dart';
import '../models/strategy_snapshot.dart';

/// 推荐历史持久化服务
/// 每天记录今日精选 3 个，次日自动核对价格并计算准确率
class HistoryService {
  static const _key = 'daily_recommendations_v2';
  static const _replayKey = 'hourly_replay_report_v1';
  static const _policyKey = 'entry_signal_policy_v1';
  static const _signalActionStatusKey = 'signal_action_status_v1';
  static const _openBuyPositionKey = 'open_buy_positions_v1';

  // ── 读取历史 ──────────────────────────────────────
  Future<List<DailyRecommendation>> loadHistory() async {
    final list = await _loadAllHistory();
    final filtered = list
        .map(
          (day) => DailyRecommendation(
            date: day.date,
            picks: day.picks.where((pick) => pick.isFeishuSignal).toList(),
          ),
        )
        .where((day) => day.picks.isNotEmpty)
        .toList();
    filtered.sort((a, b) => b.date.compareTo(a.date));
    return filtered.take(30).toList();
  }

  Future<List<DailyRecommendation>> _loadAllHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = DailyRecommendation.decodeList(raw);
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  // ── 保存今日推荐 ──────────────────────────────────
  Future<void> saveTodayPicks(List<CoinData> top3) async {
    final prefs = await SharedPreferences.getInstance();
    var history = await loadHistory();

    final today = _dateOnly(DateTime.now());

    // 如果今天已经有记录，跳过
    if (history.any((d) => _dateOnly(d.date) == today)) return;

    final record = DailyRecommendation(
      date: today,
      picks: top3
          .take(3)
          .map((c) => PickRecord(
                symbol: c.displayName,
                entryPrice: c.lastPrice,
                date: today,
                score: c.score,
                entryScore: c.entryScore,
                recommendation: c.recommendation,
                timingLabel: c.timingLabel,
              ))
          .toList(),
    );

    history.insert(0, record);
    // 只保留30条
    if (history.length > 30) history = history.sublist(0, 30);

    await prefs.setString(_key, DailyRecommendation.encodeList(history));
  }

  Future<void> saveTodayFeishuSignals({
    required List<EntryAlertSignal> entryAlerts,
    required List<EntryAlertSignal> exitAlerts,
    required List<CoinData> marketCoins,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    var history = await _loadAllHistory();
    final today = _dateOnly(DateTime.now());
    final picks = _buildFeishuSignalPicks(
      entryAlerts: entryAlerts,
      exitAlerts: exitAlerts,
      marketCoins: marketCoins,
      date: today,
    );
    if (picks.isEmpty) return;

    final index = history.indexWhere((day) => _dateOnly(day.date) == today);
    if (index == -1) {
      history.insert(0, DailyRecommendation(date: today, picks: picks));
    } else {
      final merged = <String, PickRecord>{
        for (final pick in history[index].picks) _pickKey(pick): pick,
      };
      for (final pick in picks) {
        merged[_pickKey(pick)] = pick;
      }
      history[index] = DailyRecommendation(
        date: history[index].date,
        picks: merged.values.toList()
          ..sort((a, b) {
            if (a.signalType != b.signalType) {
              return a.signalType == 'buy' ? -1 : 1;
            }
            return a.symbol.compareTo(b.symbol);
          }),
      );
    }

    history.sort((a, b) => b.date.compareTo(a.date));
    if (history.length > 30) history = history.sublist(0, 30);
    await prefs.setString(_key, DailyRecommendation.encodeList(history));
  }

  // ── 用最新价格结算昨天的推荐 ──────────────────────
  Future<void> settleYesterday(List<CoinData> latestCoins) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await _loadAllHistory();

    final yesterday =
        _dateOnly(DateTime.now().subtract(const Duration(days: 1)));

    bool changed = false;
    for (final day in history) {
      if (_dateOnly(day.date) != yesterday) continue;

      for (final pick in day.picks) {
        if (!pick.isPending) continue;

        // 找到对应的最新价格
        final coin = latestCoins.firstWhere(
          (c) => c.displayName == pick.symbol,
          orElse: () => latestCoins.first,
        );
        if (coin.displayName != pick.symbol) continue;

        pick.exitPrice = coin.lastPrice;
        pick.isWin = pick.isSellSignal
            ? coin.lastPrice < pick.entryPrice
            : coin.lastPrice > pick.entryPrice;
        changed = true;
      }
    }

    if (changed) {
      await prefs.setString(_key, DailyRecommendation.encodeList(history));
    }
  }

  // ── 统计总体准确率 ────────────────────────────────
  Future<Map<String, dynamic>> calcStats() async {
    final history = await loadHistory();
    final replayReport = await loadReplayReport();

    int total = 0;
    int wins = 0;
    double totalReturn = 0;
    int pending = 0;
    int highConfidenceTotal = 0;
    int highConfidenceWins = 0;
    int actionableTotal = 0;
    int actionableWins = 0;
    int buyTotal = 0;
    int buyWins = 0;
    int sellTotal = 0;
    int sellWins = 0;
    final bySymbol = <String, List<double>>{};
    final dayReturns = <double>[];

    for (final day in history) {
      final settledDayReturns = <double>[];
      for (final pick in day.picks) {
        if (pick.isWin == null) {
          pending++;
          continue;
        }
        total++;
        totalReturn += pick.changePercent;
        settledDayReturns.add(pick.changePercent);
        bySymbol
            .putIfAbsent(pick.symbol, () => <double>[])
            .add(pick.changePercent);

        if (pick.isWin!) {
          wins++;
        }
        if (pick.isSellSignal) {
          sellTotal++;
          if (pick.isWin == true) sellWins++;
        } else {
          buyTotal++;
          if (pick.isWin == true) buyWins++;
        }
        if (pick.score >= 0.62) {
          highConfidenceTotal++;
          if (pick.isWin == true) {
            highConfidenceWins++;
          }
        }
        if (pick.timingLabel == '可入场' || pick.timingLabel == '临近买点') {
          actionableTotal++;
          if (pick.isWin == true) {
            actionableWins++;
          }
        }
      }
      if (settledDayReturns.isNotEmpty) {
        dayReturns.add(
          settledDayReturns.reduce((a, b) => a + b) / settledDayReturns.length,
        );
      }
    }

    final symbolEntries = bySymbol.entries.map((entry) {
      final avg = entry.value.reduce((a, b) => a + b) / entry.value.length;
      return MapEntry(entry.key, avg);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final bestSymbol = symbolEntries.isNotEmpty ? symbolEntries.first.key : '';
    final bestSymbolReturn =
        symbolEntries.isNotEmpty ? symbolEntries.first.value : 0.0;
    final worstSymbol = symbolEntries.isNotEmpty ? symbolEntries.last.key : '';
    final worstSymbolReturn =
        symbolEntries.isNotEmpty ? symbolEntries.last.value : 0.0;
    final dayAvgReturn = dayReturns.isNotEmpty
        ? dayReturns.reduce((a, b) => a + b) / dayReturns.length
        : 0.0;
    final highConfidenceWinRate = highConfidenceTotal > 0
        ? highConfidenceWins / highConfidenceTotal
        : 0.0;
    final actionableWinRate =
        actionableTotal > 0 ? actionableWins / actionableTotal : 0.0;

    return {
      'total': total,
      'wins': wins,
      'winRate': total > 0 ? wins / total : 0.0,
      'avgReturn': total > 0 ? totalReturn / total : 0.0,
      'days': history.where((d) => d.picks.any((p) => p.isWin != null)).length,
      'pending': pending,
      'bestSymbol': bestSymbol,
      'bestSymbolReturn': bestSymbolReturn,
      'worstSymbol': worstSymbol,
      'worstSymbolReturn': worstSymbolReturn,
      'dayAvgReturn': dayAvgReturn,
      'highConfidenceTotal': highConfidenceTotal,
      'highConfidenceWins': highConfidenceWins,
      'highConfidenceWinRate': highConfidenceWinRate,
      'actionableTotal': actionableTotal,
      'actionableWins': actionableWins,
      'actionableWinRate': actionableWinRate,
      'buyTotal': buyTotal,
      'buyWins': buyWins,
      'buyWinRate': buyTotal > 0 ? buyWins / buyTotal : 0.0,
      'sellTotal': sellTotal,
      'sellWins': sellWins,
      'sellWinRate': sellTotal > 0 ? sellWins / sellTotal : 0.0,
      'replayReport': replayReport,
    };
  }

  Future<void> saveReplayReport(HourlyReplayReport report) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_replayKey, HourlyReplayReport.encode(report));
    await prefs.setString(
      _policyKey,
      EntrySignalPolicy.encode(report.optimizedPolicy),
    );
  }

  Future<HourlyReplayReport?> loadReplayReport() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_replayKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return HourlyReplayReport.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<EntrySignalPolicy> loadEntrySignalPolicy() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_policyKey);
    if (raw == null || raw.isEmpty) return EntrySignalPolicy.defaultPolicy;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return EntrySignalPolicy.fromJson(decoded);
    } catch (_) {
      return EntrySignalPolicy.defaultPolicy;
    }
  }

  Future<Map<String, String>> loadSignalActionStatuses() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_signalActionStatusKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> saveSignalActionStatuses(Map<String, String> statuses) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = statuses.entries
        .where((entry) => entry.key.trim().isNotEmpty)
        .map((entry) => MapEntry(entry.key.trim(), entry.value.trim()))
        .toList();
    final limited = <String, String>{};
    for (final entry in trimmed.take(300)) {
      limited[entry.key] = entry.value;
    }
    await prefs.setString(_signalActionStatusKey, jsonEncode(limited));
  }

  Future<List<OpenBuyPosition>> loadOpenBuyPositions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_openBuyPositionKey);
    if (raw == null || raw.isEmpty) return const <OpenBuyPosition>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <OpenBuyPosition>[];
      return decoded
          .map((item) => OpenBuyPosition.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.boughtAt.compareTo(a.boughtAt));
    } catch (_) {
      return const <OpenBuyPosition>[];
    }
  }

  Future<void> saveOpenBuyPositions(List<OpenBuyPosition> positions) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = {
      for (final item in positions.where((item) => item.symbol.trim().isNotEmpty))
        item.symbol.trim().toUpperCase(): item,
    }.values.toList()
      ..sort((a, b) => b.boughtAt.compareTo(a.boughtAt));
    await prefs.setString(
      _openBuyPositionKey,
      jsonEncode(normalized.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> upsertOpenBuyPosition(OpenBuyPosition position) async {
    final positions = await loadOpenBuyPositions();
    final next = <String, OpenBuyPosition>{
      for (final item in positions) item.symbol.toUpperCase(): item,
      position.symbol.toUpperCase(): position,
    };
    await saveOpenBuyPositions(next.values.toList());
  }

  Future<void> removeOpenBuyPosition(String symbol) async {
    final normalized = symbol.trim().toUpperCase();
    if (normalized.isEmpty) return;
    final positions = await loadOpenBuyPositions();
    await saveOpenBuyPositions(
      positions
          .where((item) => item.symbol.toUpperCase() != normalized)
          .toList(),
    );
  }

  static DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  String _pickKey(PickRecord pick) =>
      '${pick.signalSource}:${pick.signalType}:${pick.symbol}';

  List<PickRecord> _buildFeishuSignalPicks({
    required List<EntryAlertSignal> entryAlerts,
    required List<EntryAlertSignal> exitAlerts,
    required List<CoinData> marketCoins,
    required DateTime date,
  }) {
    final picks = <PickRecord>[];
    final bySymbol = {for (final coin in marketCoins) coin.displayName: coin};

    for (final alert
        in entryAlerts.where((item) => item.shouldNotify).take(3)) {
      final coin = bySymbol[alert.symbol];
      picks.add(
        PickRecord(
          symbol: alert.symbol,
          entryPrice: alert.currentPrice,
          date: date,
          score: alert.totalScore,
          entryScore: alert.entryScore,
          recommendation: coin?.recommendation ?? '飞书买入信号',
          timingLabel: alert.timingLabel,
          signalType: 'buy',
          signalSource: 'feishu',
        ),
      );
    }

    for (final alert in exitAlerts.where((item) => item.shouldNotify).take(3)) {
      final coin = bySymbol[alert.symbol];
      picks.add(
        PickRecord(
          symbol: alert.symbol,
          entryPrice: alert.currentPrice,
          date: date,
          score: alert.totalScore,
          entryScore: alert.entryScore,
          recommendation: coin?.recommendation ?? '飞书卖出信号',
          timingLabel: alert.timingLabel,
          signalType: 'sell',
          signalSource: 'feishu',
        ),
      );
    }

    return picks;
  }
}

class OpenBuyPosition {
  final String symbol;
  final double entryPrice;
  final DateTime boughtAt;
  final String timingLabel;
  final String timingReason;
  final double totalScore;
  final double entryScore;
  final String signalId;

  const OpenBuyPosition({
    required this.symbol,
    required this.entryPrice,
    required this.boughtAt,
    required this.timingLabel,
    required this.timingReason,
    required this.totalScore,
    required this.entryScore,
    required this.signalId,
  });

  factory OpenBuyPosition.fromJson(Map<String, dynamic> json) {
    return OpenBuyPosition(
      symbol: json['symbol']?.toString().trim().toUpperCase() ?? '',
      entryPrice: (json['entryPrice'] as num?)?.toDouble() ?? 0,
      boughtAt: DateTime.tryParse(json['boughtAt']?.toString() ?? '') ??
          DateTime.now(),
      timingLabel: json['timingLabel']?.toString() ?? '',
      timingReason: json['timingReason']?.toString() ?? '',
      totalScore: (json['totalScore'] as num?)?.toDouble() ?? 0,
      entryScore: (json['entryScore'] as num?)?.toDouble() ?? 0,
      signalId: json['signalId']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'entryPrice': entryPrice,
        'boughtAt': boughtAt.toIso8601String(),
        'timingLabel': timingLabel,
        'timingReason': timingReason,
        'totalScore': totalScore,
        'entryScore': entryScore,
        'signalId': signalId,
      };
}
