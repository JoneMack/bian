import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:binance_analyzer/services/watchlist_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('watchlist service normalizes and persists symbols', () async {
    SharedPreferences.setMockInitialValues({});
    final service = WatchlistService();

    await service.saveWatchlistSymbols([' btc ', 'ethusdt', 'BTCUSDT', 'fet']);
    final symbols = await service.loadWatchlistSymbols();

    expect(symbols, ['BTCUSDT', 'ETHUSDT', 'FETUSDT']);
    expect(WatchlistService.displayName('BTCUSDT'), 'BTC');
    expect(WatchlistService.normalizeSymbol('ton'), 'TONUSDT');
  });
}
