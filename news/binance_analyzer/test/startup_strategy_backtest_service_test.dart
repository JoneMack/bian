import 'package:flutter_test/flutter_test.dart';

import 'package:binance_analyzer/services/startup_strategy_backtest_service.dart';

void main() {
  test('buildDefaultPolicyRounds provides at least 10 optimization rounds', () {
    final service = StartupStrategyBacktestService();
    final rounds = service.buildDefaultPolicyRounds();

    expect(rounds.length, greaterThanOrEqualTo(10));
    expect(
      rounds.map((item) => item.id).toSet().length,
      rounds.length,
    );
    expect(rounds.first.id, 'round_01_baseline');
  });
}
