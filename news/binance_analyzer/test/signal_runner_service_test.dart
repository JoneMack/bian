import 'dart:convert';
import 'dart:io';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/models/strategy_snapshot.dart';
import 'package:binance_analyzer/services/recommendation_engine.dart';
import 'package:binance_analyzer/services/signal_runner_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('auto provider prefers feishu webhook when configured', () async {
    final tempDir = await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      );
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['msg_type'], 'text');
      expect((payload['content'] as Map<String, dynamic>)['text'], contains('FET'));
      expect(
        (payload['content'] as Map<String, dynamic>)['text'],
        contains('可入场'),
      );
      return http.Response('{"code":0,"msg":"success"}', 200);
    });

    final service = SignalRunnerService(httpClient: client);
    final result = await service.publishSignal(
      engine: _engineFixture(),
      policy: EntrySignalPolicy.defaultPolicy,
      provider: PushProvider.auto,
      feishuWebhookUrl:
          'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      topic: 'fallback-topic',
      dedupe: true,
      statePath: '${tempDir.path}/push_state.json',
    );

    expect(result.sent, isTrue);
    expect(result.provider, 'feishu');
    expect(result.status, 'sent');
  });

  test('dedupe is isolated per provider', () async {
    final tempDir = await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final client = MockClient((request) async {
      if (request.url.host.contains('feishu')) {
        return http.Response('{"code":0,"msg":"success"}', 200);
      }
      if (request.url.host.contains('ntfy')) {
        expect(request.body, contains('FET'));
        return http.Response('', 200);
      }
      fail('Unexpected request: ${request.url}');
    });

    final service = SignalRunnerService(httpClient: client);
    final statePath = '${tempDir.path}/push_state.json';

    final feishuResult = await service.publishSignal(
      engine: _engineFixture(),
      policy: EntrySignalPolicy.defaultPolicy,
      provider: PushProvider.feishu,
      feishuWebhookUrl:
          'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      dedupe: true,
      statePath: statePath,
    );

    final ntfyResult = await service.publishSignal(
      engine: _engineFixture(),
      policy: EntrySignalPolicy.defaultPolicy,
      provider: PushProvider.ntfy,
      topic: 'signals',
      server: 'https://ntfy.sh',
      dedupe: true,
      statePath: statePath,
    );

    expect(feishuResult.sent, isTrue);
    expect(ntfyResult.sent, isTrue);
    expect(ntfyResult.status, 'sent');
    expect(ntfyResult.provider, 'ntfy');
  });

  test('publishTestMessage sends feishu test push when configured', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      );
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['msg_type'], 'text');
      expect(
        (payload['content'] as Map<String, dynamic>)['text'],
        contains('测试推送'),
      );
      return http.Response('{"code":0,"msg":"success"}', 200);
    });

    final service = SignalRunnerService(httpClient: client);
    final result = await service.publishTestMessage(
      provider: PushProvider.auto,
      feishuWebhookUrl:
          'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
    );

    expect(result.sent, isTrue);
    expect(result.provider, 'feishu');
    expect(result.status, 'sent_test');
  });

  test('publishSignal also sends when only sell signals are actionable', () async {
    final tempDir = await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      final text = (payload['content'] as Map<String, dynamic>)['text'] as String;
      expect(text, contains('卖出信号'));
      expect(text, contains('止盈减仓'));
      return http.Response('{"code":0,"msg":"success"}', 200);
    });

    final service = SignalRunnerService(httpClient: client);
    final result = await service.publishSignal(
      engine: _engineFixture(
        entryShouldNotify: false,
        exitShouldNotify: true,
      ),
      policy: EntrySignalPolicy.defaultPolicy,
      provider: PushProvider.feishu,
      feishuWebhookUrl:
          'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      dedupe: true,
      statePath: '${tempDir.path}/push_state.json',
    );

    expect(result.sent, isTrue);
    expect(result.provider, 'feishu');
    expect(result.status, 'sent');
  });
}

RecommendationEngineResult _engineFixture({
  bool entryShouldNotify = true,
  bool exitShouldNotify = true,
}) {
  final coin = CoinData(
    symbol: 'FETUSDT',
    lastPrice: 1.23,
    priceChange: 0.12,
    priceChangePercent: 10.8,
    highPrice: 1.30,
    lowPrice: 1.05,
    openPrice: 1.11,
    quoteVolume: 1234567,
    volume: 1000000,
    count: 3210,
    score: 0.88,
    entryScore: 0.79,
    timingLabel: '可入场',
    timingReason: '突破后回踩稳住',
    recommendation: '优先关注',
  );

  return RecommendationEngineResult(
    rankedCoins: [coin],
    top3: [coin],
    report: StrategyBacktestReport(
      presetId: 'rotation',
      presetLabel: '轮动优先',
      testDays: 28,
      avgTop3Return: 3.4,
      benchmarkReturn: 1.1,
      winRate: 0.67,
      positiveDaysRate: 0.71,
      generatedAt: DateTime(2026, 4, 3, 12),
    ),
    entryAlerts: [
      EntryAlertSignal(
        symbol: 'FET',
        timingLabel: '可入场',
        timingReason: '突破后回踩稳住',
        currentPrice: 1.23,
        dayChangePercent: 10.8,
        totalScore: 0.88,
        entryScore: 0.79,
        volumeRatio: 1.6,
        breakoutDistance: 0.9,
        pullbackPercent: 1.2,
        shouldNotify: entryShouldNotify,
      ),
    ],
    exitAlerts: [
      EntryAlertSignal(
        symbol: 'FET',
        timingLabel: '止盈减仓',
        timingReason: '1h MA8 跌破 MA21；距18h高点回撤 4.20%',
        currentPrice: 1.23,
        dayChangePercent: -4.6,
        totalScore: 0.88,
        entryScore: 0.74,
        volumeRatio: 0,
        breakoutDistance: -2.1,
        pullbackPercent: 4.2,
        shouldNotify: exitShouldNotify,
      ),
    ],
  );
}
