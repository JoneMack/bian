import 'dart:convert';

import 'coin_data.dart';
import 'strategy_snapshot.dart';

class MarketSnapshot {
  final List<CoinData> allCoins;
  final List<CoinData> top3;
  final DateTime updatedAt;
  final StrategyBacktestReport? engineReport;
  final List<EntryAlertSignal> entryAlerts;
  final List<String> watchlistSymbols;

  const MarketSnapshot({
    required this.allCoins,
    required this.top3,
    required this.updatedAt,
    required this.watchlistSymbols,
    this.engineReport,
    this.entryAlerts = const [],
  });

  Map<String, dynamic> toJson() => {
        'allCoins': allCoins.map((coin) => coin.toJson()).toList(),
        'top3': top3.map((coin) => coin.toJson()).toList(),
        'updatedAt': updatedAt.toIso8601String(),
        'engineReport': engineReport?.toJson(),
        'entryAlerts': entryAlerts.map((item) => item.toJson()).toList(),
        'watchlistSymbols': watchlistSymbols,
      };

  factory MarketSnapshot.fromJson(Map<String, dynamic> json) {
    return MarketSnapshot(
      allCoins: (json['allCoins'] as List<dynamic>? ?? const [])
          .map((item) => CoinData.fromJson(item as Map<String, dynamic>))
          .toList(),
      top3: (json['top3'] as List<dynamic>? ?? const [])
          .map((item) => CoinData.fromJson(item as Map<String, dynamic>))
          .toList(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      engineReport: json['engineReport'] is Map
          ? StrategyBacktestReport.fromJson(
              Map<String, dynamic>.from(json['engineReport'] as Map),
            )
          : null,
      entryAlerts: (json['entryAlerts'] as List<dynamic>? ?? const [])
          .map((item) => EntryAlertSignal.fromJson(item as Map<String, dynamic>))
          .toList(),
      watchlistSymbols: (json['watchlistSymbols'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(),
    );
  }

  static String encode(MarketSnapshot snapshot) => jsonEncode(snapshot.toJson());
}
