import 'package:shared_preferences/shared_preferences.dart';

import 'binance_service.dart';

class WatchlistService {
  static const String _key = 'custom_watchlist_symbols_v1';

  Future<List<String>> loadWatchlistSymbols() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key);
    final base = raw == null || raw.isEmpty
        ? BinanceService.defaultWatchlistSymbols
        : raw;
    return _normalizeList(base);
  }

  Future<void> saveWatchlistSymbols(List<String> symbols) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeList(symbols);
    final next = normalized.isEmpty
        ? BinanceService.defaultWatchlistSymbols.take(3).toList()
        : normalized;
    await prefs.setStringList(_key, next);
  }

  static String normalizeSymbol(String input) {
    final normalized =
        input.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty) return '';
    if (normalized.endsWith('USDT')) return normalized;
    return '${normalized}USDT';
  }

  static String displayName(String symbol) {
    final upper = symbol.toUpperCase();
    if (upper.endsWith('USDT')) {
      return upper.substring(0, upper.length - 4);
    }
    return upper;
  }

  static List<String> _normalizeList(List<String> symbols) {
    final unique = <String>{};
    final results = <String>[];

    for (final symbol in symbols) {
      final normalized = normalizeSymbol(symbol);
      if (normalized.isEmpty || !unique.add(normalized)) continue;
      results.add(normalized);
    }

    return results;
  }
}
