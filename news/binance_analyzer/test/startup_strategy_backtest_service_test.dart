import 'package:flutter_test/flutter_test.dart';

import 'package:binance_analyzer/services/startup_scanner_service.dart';
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

  test('normalizeWindowDays keeps positive unique sorted values', () {
    final service = StartupStrategyBacktestService();
    final normalized = service.normalizeWindowDays([180, 45, 90, 45, 0, -2]);

    expect(normalized, [45, 90, 180]);
  });

  test(
      'stability ranking prefers steady sample-rich policy over lucky sparse policy',
      () {
    final service = StartupStrategyBacktestService();
    final rounds = [
      StartupPolicyRound(
        id: 'steady',
        label: 'Steady',
        policy: StartupScanPolicy.defaultPolicy.copyWith(label: 'Steady'),
      ),
      StartupPolicyRound(
        id: 'lucky',
        label: 'Lucky',
        policy: StartupScanPolicy.defaultPolicy.copyWith(label: 'Lucky'),
      ),
    ];

    final windows = [
      StartupOptimizationWindowResult(
        days: 45,
        rounds: [
          _roundResult(
            id: 'steady',
            label: 'Steady',
            policy: rounds[0].policy,
            score: 58,
            sampleCount: 6,
            wins: 4,
            avgSignalReturn: 0.010,
            avgBestReturn: 0.028,
          ),
          _roundResult(
            id: 'lucky',
            label: 'Lucky',
            policy: rounds[1].policy,
            score: 74,
            sampleCount: 2,
            wins: 2,
            avgSignalReturn: 0.028,
            avgBestReturn: 0.060,
          ),
        ],
        baselineRound: _roundResult(
          id: 'steady',
          label: 'Steady',
          policy: rounds[0].policy,
          score: 58,
          sampleCount: 6,
          wins: 4,
          avgSignalReturn: 0.010,
          avgBestReturn: 0.028,
        ),
        bestRound: _roundResult(
          id: 'lucky',
          label: 'Lucky',
          policy: rounds[1].policy,
          score: 74,
          sampleCount: 2,
          wins: 2,
          avgSignalReturn: 0.028,
          avgBestReturn: 0.060,
        ),
      ),
      StartupOptimizationWindowResult(
        days: 90,
        rounds: [
          _roundResult(
            id: 'steady',
            label: 'Steady',
            policy: rounds[0].policy,
            score: 61,
            sampleCount: 11,
            wins: 7,
            avgSignalReturn: 0.011,
            avgBestReturn: 0.030,
          ),
          _roundResult(
            id: 'lucky',
            label: 'Lucky',
            policy: rounds[1].policy,
            score: 69,
            sampleCount: 3,
            wins: 2,
            avgSignalReturn: 0.020,
            avgBestReturn: 0.058,
          ),
        ],
        baselineRound: _roundResult(
          id: 'steady',
          label: 'Steady',
          policy: rounds[0].policy,
          score: 61,
          sampleCount: 11,
          wins: 7,
          avgSignalReturn: 0.011,
          avgBestReturn: 0.030,
        ),
        bestRound: _roundResult(
          id: 'lucky',
          label: 'Lucky',
          policy: rounds[1].policy,
          score: 69,
          sampleCount: 3,
          wins: 2,
          avgSignalReturn: 0.020,
          avgBestReturn: 0.058,
        ),
      ),
      StartupOptimizationWindowResult(
        days: 180,
        rounds: [
          _roundResult(
            id: 'steady',
            label: 'Steady',
            policy: rounds[0].policy,
            score: 63,
            sampleCount: 18,
            wins: 11,
            avgSignalReturn: 0.012,
            avgBestReturn: 0.031,
          ),
          _roundResult(
            id: 'lucky',
            label: 'Lucky',
            policy: rounds[1].policy,
            score: 64,
            sampleCount: 4,
            wins: 3,
            avgSignalReturn: 0.015,
            avgBestReturn: 0.052,
          ),
        ],
        baselineRound: _roundResult(
          id: 'steady',
          label: 'Steady',
          policy: rounds[0].policy,
          score: 63,
          sampleCount: 18,
          wins: 11,
          avgSignalReturn: 0.012,
          avgBestReturn: 0.031,
        ),
        bestRound: _roundResult(
          id: 'lucky',
          label: 'Lucky',
          policy: rounds[1].policy,
          score: 64,
          sampleCount: 4,
          wins: 3,
          avgSignalReturn: 0.015,
          avgBestReturn: 0.052,
        ),
      ),
    ];

    final ranking = service.buildStabilityRanking(
      windows: windows,
      rounds: rounds,
    );

    expect(ranking.first.id, 'steady');
    expect(ranking.first.meetsStabilityGate, isTrue);
    expect(ranking.last.id, 'lucky');
    expect(ranking.last.meetsStabilityGate, isFalse);
  });
}

StartupPolicyRoundResult _roundResult({
  required String id,
  required String label,
  required StartupScanPolicy policy,
  required double score,
  required int sampleCount,
  required int wins,
  required double avgSignalReturn,
  required double avgBestReturn,
}) {
  return StartupPolicyRoundResult(
    id: id,
    label: label,
    policy: policy,
    score: score,
    report: StartupStrategyBacktestReport(
      generatedAt: DateTime(2026, 4, 9),
      policy: policy,
      eligibleSymbols: const ['FETUSDT', 'TONUSDT'],
      simulatedHours: 100,
      sampleCount: sampleCount,
      wins: wins,
      silentHours: 90,
      avgSignalReturn: avgSignalReturn,
      avgBestReturn: avgBestReturn,
      topSymbols: const [],
    ),
  );
}
