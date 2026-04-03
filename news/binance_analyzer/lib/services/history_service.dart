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

  // ── 读取历史 ──────────────────────────────────────
  Future<List<DailyRecommendation>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = DailyRecommendation.decodeList(raw);
    // 最近30天
    list.sort((a, b) => b.date.compareTo(a.date));
    return list.take(30).toList();
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

  // ── 用最新价格结算昨天的推荐 ──────────────────────
  Future<void> settleYesterday(List<CoinData> latestCoins) async {
    final prefs = await SharedPreferences.getInstance();
    var history = await loadHistory();

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
        pick.isWin = coin.lastPrice > pick.entryPrice;
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

  static DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
}
