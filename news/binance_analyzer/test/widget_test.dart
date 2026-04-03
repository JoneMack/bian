import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/material.dart';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/screens/main_nav_screen.dart';
import 'package:binance_analyzer/screens/picks_screen.dart';
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
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: PicksScreen(
          state: state,
          onRefresh: ({bool silent = false}) async {},
        ),
      ),
    );

    expect(find.text('今日精选'), findsOneWidget);
    expect(find.text('AI 智能推荐 · 每日3个'), findsOneWidget);
    expect(find.text('今日推荐买入'), findsOneWidget);
    expect(find.text('FET'), findsOneWidget);
  });
}
