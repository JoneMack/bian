import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/material.dart';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/models/strategy_snapshot.dart';
import 'package:binance_analyzer/screens/main_nav_screen.dart';
import 'package:binance_analyzer/screens/picks_screen.dart';
import 'package:binance_analyzer/services/history_service.dart';
import 'package:binance_analyzer/theme/app_theme.dart';

void main() {
  testWidgets('Dashboard renders top picks and overview sections',
      (WidgetTester tester) async {
    final coins = [
      CoinData(
        symbol: 'FETUSDT',
        lastPrice: 1.245,
        priceChange: 0.08,
        priceChangePercent: 6.8,
        highPrice: 1.31,
        lowPrice: 1.12,
        openPrice: 1.16,
        quoteVolume: 45600000,
        volume: 30000000,
        count: 150000,
        score: 0.81,
        level: RecommendationLevel.strongBuy,
        recommendation: '强烈推荐',
        reason: '上涨动量良好；成交量活跃',
      ),
      CoinData(
        symbol: 'TONUSDT',
        lastPrice: 5.42,
        priceChange: 0.12,
        priceChangePercent: 2.3,
        highPrice: 5.56,
        lowPrice: 5.1,
        openPrice: 5.3,
        quoteVolume: 29500000,
        volume: 10000000,
        count: 90000,
        score: 0.69,
        level: RecommendationLevel.buy,
        recommendation: '推荐买入',
        reason: '区间位置较低；趋势仍在延续',
      ),
      CoinData(
        symbol: 'AVAXUSDT',
        lastPrice: 31.2,
        priceChange: 0.21,
        priceChangePercent: 0.9,
        highPrice: 32.1,
        lowPrice: 30.0,
        openPrice: 30.9,
        quoteVolume: 18200000,
        volume: 8000000,
        count: 62000,
        score: 0.61,
        level: RecommendationLevel.buy,
        recommendation: '推荐买入',
        reason: '价格仍处区间低位，上涨空间充足',
      ),
    ];

    final state = MarketState(
      allCoins: coins,
      top3: coins,
      updatedAt: DateTime(2026, 4, 2, 10, 30),
      loading: false,
      liveConnected: true,
      entryAlerts: const [
        EntryAlertSignal(
          symbol: 'FET',
          timingLabel: '可入场',
          timingReason: '突破后回踩稳住',
          currentPrice: 1.245,
          dayChangePercent: 6.8,
          totalScore: 0.81,
          entryScore: 0.76,
          volumeRatio: 1.4,
          breakoutDistance: 0.8,
          pullbackPercent: 1.1,
          shouldNotify: true,
        ),
      ],
      exitAlerts: const [
        EntryAlertSignal(
          symbol: 'TON',
          timingLabel: '止盈减仓',
          timingReason: '短线回撤增大',
          currentPrice: 5.42,
          dayChangePercent: -2.1,
          totalScore: 0.72,
          entryScore: 0.61,
          volumeRatio: 0.9,
          breakoutDistance: -1.3,
          pullbackPercent: 3.2,
          shouldNotify: true,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: PicksScreen(
          state: state,
          onRefresh: ({bool silent = false}) async {},
          onSignalAction: (
            EntryAlertSignal signal,
            String signalType,
            String actionType,
          ) async {},
          resolveSignalActionStatus: (
            EntryAlertSignal signal,
            String signalType,
          ) =>
              null,
          isSignalActionSubmitting: (
            EntryAlertSignal signal,
            String signalType,
          ) =>
              false,
          onOpenBackendSettings: () {},
          onOpenWaitingBuys: () {},
          backendConfigured: true,
          pendingBuyCount: 1,
          openPositions: [
            OpenBuyPosition(
              symbol: 'TON',
              entryPrice: 5.42,
              boughtAt: DateTime(2026, 4, 2, 9),
              timingLabel: '已确认买入',
              timingReason: '收到飞书买入信号后已记录',
              totalScore: 0.72,
              entryScore: 0.61,
              signalId: '2026-04-02|buy|TON|可入场',
            ),
          ],
        ),
      ),
    );

    expect(find.text('领涨预测'), findsOneWidget);
    expect(find.text('下一根币安日线 · Top3 候选'), findsOneWidget);
    expect(find.text('飞书信号待处理'), findsOneWidget);
    expect(find.text('下一根日线领涨预测'), findsOneWidget);
    expect(find.text('FET'), findsWidgets);
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('取消'), findsWidgets);
  });
}
