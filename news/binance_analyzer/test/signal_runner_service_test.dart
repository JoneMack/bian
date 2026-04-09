import 'dart:convert';
import 'dart:io';

import 'package:binance_analyzer/models/coin_data.dart';
import 'package:binance_analyzer/models/strategy_snapshot.dart';
import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/market_bottom_detector_service.dart';
import 'package:binance_analyzer/services/recommendation_engine.dart';
import 'package:binance_analyzer/services/signal_runner_service.dart';
import 'package:binance_analyzer/services/startup_scanner_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('auto provider prefers feishu webhook when configured', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      );
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['msg_type'], 'text');
      expect((payload['content'] as Map<String, dynamic>)['text'],
          contains('FET'));
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
    final tempDir =
        await Directory.systemTemp.createTemp('signal-runner-test-');
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

  test('publishSignal also sends when only sell signals are actionable',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      final text =
          (payload['content'] as Map<String, dynamic>)['text'] as String;
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

  test('publishStartupScan sends feishu when only market bottom alert triggers',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      final text =
          (payload['content'] as Map<String, dynamic>)['text'] as String;
      expect(text, contains('恐慌见底监控'));
      expect(text, contains('抄底观察'));
      expect(text, contains('BTC'));
      return http.Response('{"code":0,"msg":"success"}', 200);
    });

    final service = SignalRunnerService(httpClient: client);
    final result = await service.publishStartupScan(
      report: StartupScanReport(
        generatedAt: DateTime(2026, 4, 8, 12),
        universeSize: 200,
        analyzedSymbols: 180,
        strategyLabel: '全市场启动扫描',
        marketRegime: _riskOnRegime(),
        candidates: [],
        notes: '暂无启动信号',
      ),
      policy: StartupScanPolicy.defaultPolicy,
      marketBottomAlert: _marketBottomFixture(),
      provider: PushProvider.feishu,
      feishuWebhookUrl:
          'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      dedupe: true,
      statePath: '${tempDir.path}/push_state.json',
    );

    expect(result.sent, isTrue);
    expect(result.provider, 'feishu');
    expect(result.status, 'sent');
    expect(result.message, contains('恐慌见底'));
  });

  test('loadOptimizedStartupPolicySelection prefers stable policy artifact',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final reportPath = '${tempDir.path}/startup_strategy_optimization.json';
    await File(reportPath).writeAsString(
      jsonEncode(
        _startupOptimizationArtifact(
          policy: StartupScanPolicy.defaultPolicy.copyWith(label: '稳健轮动'),
          roundId: 'round_stable',
          roundLabel: '稳健轮动',
        ),
      ),
    );

    final service = SignalRunnerService();
    final selection = await service.loadOptimizedStartupPolicySelection(
      startupStrategyReportPath: reportPath,
    );

    expect(selection.source, 'report_stable');
    expect(selection.policy.label, '稳健轮动');
    expect(selection.meetsStabilityGate, isTrue);
    expect(selection.windowDays, [45, 90, 180]);
    expect(selection.summary, contains('多窗口稳定策略'));
  });

  test('runMarketStartupScan sends watch first and buy after confirmation',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final pushedTexts = <String>[];
    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      pushedTexts
          .add((payload['content'] as Map<String, dynamic>)['text'] as String);
      return http.Response('{"code":0,"msg":"success"}', 200);
    });

    final service = SignalRunnerService(
      binance: _FakeBinanceService(),
      startupScanner: _FakeStartupScannerService(_startupStageReport()),
      marketBottomDetector: _FakeMarketBottomDetectorService(
        MarketBottomAlert(
          generatedAt: DateTime(2026, 4, 8, 12),
          universeSize: 200,
          analyzedSymbols: 180,
          strategyLabel: '全市场恐慌见底',
          alertScore: 0.0,
          fearScore: 0.0,
          stabilizationScore: 0.0,
          redBreadth: 0.0,
          downBreadth: 0.0,
          capitulationBreadth: 0.0,
          nearLowBreadth: 0.0,
          reboundBreadth: 0.0,
          recoveryBreadth: 0.0,
          volumeBreadth: 0.0,
          avg24hChange: 0.0,
          avg7dChange: 0.0,
          shouldNotify: false,
          notes: '无',
          candidates: const [],
        ),
      ),
      httpClient: client,
    );

    final first = await service.runMarketStartupScan(
      reportPath: '${tempDir.path}/report.json',
      buyLogPath: '${tempDir.path}/startup_buy_log.json',
      pushProvider: PushProvider.feishu,
      feishuWebhookUrl:
          'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      dedupePush: false,
    );
    final second = await service.runMarketStartupScan(
      reportPath: '${tempDir.path}/report.json',
      buyLogPath: '${tempDir.path}/startup_buy_log.json',
      pushProvider: PushProvider.feishu,
      feishuWebhookUrl:
          'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      dedupePush: false,
    );

    expect(first.pushResult.sent, isTrue);
    expect(first.pushResult.message, contains('观察提醒'));
    expect(pushedTexts.first, contains('观察提醒'));
    expect(pushedTexts.first, isNot(contains('正式买入:')));

    expect(second.pushResult.sent, isTrue);
    expect(second.pushResult.message, contains('正式买入'));
    expect(pushedTexts.last, contains('正式买入:'));
    expect(pushedTexts.last, contains('FET'));

    final rawLog = jsonDecode(
      await File('${tempDir.path}/startup_buy_log.json').readAsString(),
    ) as Map<String, dynamic>;
    final records = rawLog['records'] as List<dynamic>;
    expect(
      records.any((item) =>
          (item as Map<String, dynamic>)['signalType'] == 'startup_watch'),
      isTrue,
    );
    expect(
      records.any((item) =>
          (item as Map<String, dynamic>)['signalType'] == 'startup_buy'),
      isTrue,
    );
  });

  test('runMarketStartupScan loads optimized startup policy from artifact',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final pushedTexts = <String>[];
    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      pushedTexts
          .add((payload['content'] as Map<String, dynamic>)['text'] as String);
      return http.Response('{"code":0,"msg":"success"}', 200);
    });

    final optimizedPolicy =
        StartupScanPolicy.defaultPolicy.copyWith(label: '稳健轮动');
    final scanner = _FakeStartupScannerService(_startupStageReport());
    final reportPath = '${tempDir.path}/startup_strategy_optimization.json';
    await File(reportPath).writeAsString(
      jsonEncode(
        _startupOptimizationArtifact(
          policy: optimizedPolicy,
          roundId: 'round_stable',
          roundLabel: '稳健轮动',
        ),
      ),
    );

    final service = SignalRunnerService(
      binance: _FakeBinanceService(),
      startupScanner: scanner,
      marketBottomDetector: _FakeMarketBottomDetectorService(
        MarketBottomAlert(
          generatedAt: DateTime(2026, 4, 8, 12),
          universeSize: 200,
          analyzedSymbols: 180,
          strategyLabel: '全市场恐慌见底',
          alertScore: 0.0,
          fearScore: 0.0,
          stabilizationScore: 0.0,
          redBreadth: 0.0,
          downBreadth: 0.0,
          capitulationBreadth: 0.0,
          nearLowBreadth: 0.0,
          reboundBreadth: 0.0,
          recoveryBreadth: 0.0,
          volumeBreadth: 0.0,
          avg24hChange: 0.0,
          avg7dChange: 0.0,
          shouldNotify: false,
          notes: '无',
          candidates: const [],
        ),
      ),
      httpClient: client,
    );

    final result = await service.runMarketStartupScan(
      reportPath: '${tempDir.path}/report.json',
      buyLogPath: '${tempDir.path}/startup_buy_log.json',
      startupStrategyReportPath: reportPath,
      pushProvider: PushProvider.feishu,
      feishuWebhookUrl:
          'https://open.feishu.cn/open-apis/bot/v2/hook/test-webhook',
      dedupePush: false,
    );

    expect(scanner.lastPolicy?.label, '稳健轮动');
    expect(result.policySelection.source, 'report_stable');
    expect(result.payload['policy'], isA<Map<String, dynamic>>());
    expect(
      (result.payload['policy'] as Map<String, dynamic>)['label'],
      '稳健轮动',
    );
    expect(
      (result.payload['policySelection'] as Map<String, dynamic>)['source'],
      'report_stable',
    );
    expect(
      (result.payload['policySelection'] as Map<String, dynamic>)['windowDays'],
      [45, 90, 180],
    );
    expect(pushedTexts.single, contains('策略来源: 多窗口稳定策略'));
    expect(pushedTexts.single, contains('稳健轮动'));

    final predictionPayload = jsonDecode(
      await File('${tempDir.path}/startup_buy_log.json').readAsString(),
    ) as Map<String, dynamic>;
    final firstRecord = (predictionPayload['records'] as List<dynamic>).first
        as Map<String, dynamic>;
    expect(firstRecord['startupPolicySource'], 'report_stable');
    expect(firstRecord['startupPolicySummary'], contains('多窗口稳定策略'));
  });

  test(
      'refreshStartupPredictionLog settles matured predictions and updates accuracy',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('signal-runner-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final logPath = '${tempDir.path}/startup_buy_log.json';
    final recordedAt =
        DateTime.now().subtract(const Duration(hours: 25)).toIso8601String();
    await File(logPath).writeAsString(
      jsonEncode({
        'updatedAt': DateTime.now().toIso8601String(),
        'records': [
          {
            'id': '$recordedAt|FET',
            'recordedAt': recordedAt,
            'status': 'pending',
            'signalType': 'startup_buy',
            'pushProvider': 'feishu',
            'symbol': 'FET',
            'entryPrice': 1.00,
            'score': 0.81,
            'volumeRatio': 1.8,
            'dailyBreakoutDistance': 0.6,
            'reason': '测试记录',
          }
        ],
      }),
    );

    final service = SignalRunnerService();
    final payload = await service.refreshStartupPredictionLog(
      path: logPath,
      currentCoins: [
        CoinData(
          symbol: 'FETUSDT',
          lastPrice: 1.15,
          priceChange: 0.05,
          priceChangePercent: 4.0,
          highPrice: 1.20,
          lowPrice: 0.98,
          openPrice: 1.10,
          quoteVolume: 1234567,
          volume: 1000000,
          count: 3210,
        ),
      ],
    );

    final records = payload['records'] as List<dynamic>;
    final summary = payload['summary'] as Map<String, dynamic>;
    final record = records.single as Map<String, dynamic>;

    expect(record['status'], 'settled');
    expect(record['isWin'], isTrue);
    expect(record['settlementPrice'], closeTo(1.15, 0.0001));
    expect(record['returnPercent'], closeTo(15.0, 0.0001));

    expect(summary['totalPredictions'], 1);
    expect(summary['pending'], 0);
    expect(summary['settled'], 1);
    expect(summary['wins'], 1);
    expect(summary['losses'], 0);
    expect(summary['winRate'], closeTo(1.0, 0.0001));
    expect(summary['avgReturnPercent'], closeTo(15.0, 0.0001));
    expect(
      (summary['bySignalType'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .first['signalType'],
      'startup_buy',
    );
  });

  test('recordClientSignalAction writes summary and dedupes same signal',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('signal-action-log-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final path = '${tempDir.path}/client_signal_actions.json';
    final service = SignalRunnerService();

    final created = await service.recordClientSignalAction(
      path: path,
      signalId: '2026-04-09|buy|FET|可入场',
      symbol: 'FET',
      signalType: 'buy',
      signalSource: 'feishu',
      actionType: 'confirm',
      price: 1.23,
      timingLabel: '可入场',
      timingReason: '突破后回踩稳住',
      totalScore: 0.88,
      entryScore: 0.79,
    );
    final duplicate = await service.recordClientSignalAction(
      path: path,
      signalId: '2026-04-09|buy|FET|可入场',
      symbol: 'FET',
      signalType: 'buy',
      signalSource: 'feishu',
      actionType: 'confirm',
      price: 1.23,
      timingLabel: '可入场',
      timingReason: '突破后回踩稳住',
      totalScore: 0.88,
      entryScore: 0.79,
    );
    final payload = await service.loadClientSignalActionLog(path: path);

    expect(created['created'], isTrue);
    expect(duplicate['created'], isFalse);
    expect(payload['summary'], isA<Map<String, dynamic>>());
    expect((payload['summary'] as Map<String, dynamic>)['totalRecords'], 1);
    expect((payload['summary'] as Map<String, dynamic>)['confirmCount'], 1);
    expect((payload['records'] as List<dynamic>).single['signalId'],
        '2026-04-09|buy|FET|可入场');
  });

  test('recordClientSignalAction syncs execution cycles and stats', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('execution-cycle-log-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final actionPath = '${tempDir.path}/client_signal_actions.json';
    final executionPath = '${tempDir.path}/client_execution_cycles.json';
    final service = SignalRunnerService();

    await service.recordClientSignalAction(
      path: actionPath,
      executionPath: executionPath,
      signalId: '2026-04-09|buy|FET|可入场',
      symbol: 'FET',
      signalType: 'buy',
      signalSource: 'feishu',
      actionType: 'confirm',
      price: 1.00,
      timingLabel: '可入场',
      timingReason: '首次突破确认',
      totalScore: 0.86,
      entryScore: 0.78,
    );
    await service.recordClientSignalAction(
      path: actionPath,
      executionPath: executionPath,
      signalId: '2026-04-09|buy|FET|二次确认',
      symbol: 'FET',
      signalType: 'buy',
      signalSource: 'feishu',
      actionType: 'confirm',
      price: 1.05,
      timingLabel: '二次确认',
      timingReason: '重复开仓应忽略',
      totalScore: 0.83,
      entryScore: 0.74,
    );
    await service.recordClientSignalAction(
      path: actionPath,
      executionPath: executionPath,
      signalId: '2026-04-09|sell|LINK|止损',
      symbol: 'LINK',
      signalType: 'sell',
      signalSource: 'feishu',
      actionType: 'cancel',
      price: 8.8,
      timingLabel: '止损',
      timingReason: '无持仓平仓应计入未匹配',
      totalScore: 0.52,
      entryScore: 0.41,
    );
    final sellResult = await service.recordClientSignalAction(
      path: actionPath,
      executionPath: executionPath,
      signalId: '2026-04-09|sell|FET|止盈',
      symbol: 'FET',
      signalType: 'sell',
      signalSource: 'feishu',
      actionType: 'cancel',
      price: 1.10,
      timingLabel: '止盈',
      timingReason: '达到目标位',
      totalScore: 0.78,
      entryScore: 0.69,
    );

    final execution = await service.loadClientExecutionLog(path: executionPath);
    final summary = execution['summary'] as Map<String, dynamic>;
    final records = execution['records'] as List<dynamic>;
    final cycle = Map<String, dynamic>.from(records.single as Map);

    expect(
        (sellResult['executionSummary']
            as Map<String, dynamic>)['closedCycles'],
        1);
    expect(summary['totalCycles'], 1);
    expect(summary['openCycles'], 0);
    expect(summary['closedCycles'], 1);
    expect(summary['wins'], 1);
    expect(summary['losses'], 0);
    expect(summary['winRate'], closeTo(1.0, 0.0001));
    expect(summary['avgReturnPercent'], closeTo(10.0, 0.0001));
    expect(summary['ignoredOpenSignals'], 1);
    expect(summary['unmatchedCloseSignals'], 1);
    expect(cycle['status'], ClientExecutionCycleStatus.closed);
    expect(cycle['symbol'], 'FET');
    expect(cycle['isWin'], isTrue);
    expect(cycle['realizedReturnPercent'], closeTo(10.0, 0.0001));
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

MarketBottomAlert _marketBottomFixture() {
  return MarketBottomAlert(
    generatedAt: DateTime(2026, 4, 8, 12),
    universeSize: 200,
    analyzedSymbols: 180,
    strategyLabel: '全市场恐慌见底',
    alertScore: 0.76,
    fearScore: 0.82,
    stabilizationScore: 0.68,
    redBreadth: 0.86,
    downBreadth: 0.52,
    capitulationBreadth: 0.31,
    nearLowBreadth: 0.24,
    reboundBreadth: 0.19,
    recoveryBreadth: 0.16,
    volumeBreadth: 0.22,
    avg24hChange: -5.6,
    avg7dChange: -11.4,
    shouldNotify: true,
    notes: '全市场已出现普跌后的止跌回抽，适合关注高流动性币的底部反转。',
    candidates: [
      const MarketBottomCandidate(
        symbol: 'BTC',
        currentPrice: 81234,
        score: 0.74,
        oversoldScore: 0.71,
        reboundScore: 0.76,
        liquidityScore: 1.0,
        drawdownFrom30dHigh: 18.4,
        distanceTo45dLow: 3.1,
        bounceFrom12hLow: 3.7,
        volumeRatio: 1.42,
        hourlyTrendScore: 0.72,
        sevenDayChange: -9.8,
        thirtyDayChange: -14.2,
        reason: '24h额 1.20B；30日回撤 18.4%；距45日低点 3.1%；12h反弹 3.7%；量比 1.42x；1h结构转强',
        shouldNotify: true,
      ),
    ],
  );
}

StartupScanReport _startupStageReport() {
  return StartupScanReport(
    generatedAt: DateTime(2026, 4, 8, 12),
    universeSize: 200,
    analyzedSymbols: 180,
    strategyLabel: '全市场启动扫描',
    marketRegime: _riskOnRegime(),
    candidates: const [
      StartupScanCandidate(
        symbol: 'FET',
        currentPrice: 1.23,
        score: 0.82,
        setupScore: 0.82,
        confirmationScore: 0.79,
        trendScore: 0.78,
        compressionScore: 0.58,
        momentumScore: 0.62,
        liquidityScore: 0.88,
        volumeRatio: 1.65,
        dailyBreakoutDistance: 0.7,
        hourlyBreakoutDistance: 0.4,
        nearTermPivotDistance: 0.6,
        marketTrendBreadth: 0.68,
        marketMomentumBreadth: 0.61,
        sevenDayMomentum: 6.2,
        thirtyDayMomentum: 18.4,
        reason:
            '24h额 12.3M；量比 1.65x；距20日突破位 +0.70%；距10日枢轴 +0.60%；7日动量 +6.2%；30日动量 +18.4%；日线/小时线趋势同步',
        signalStage: 'buy',
        shouldWatch: true,
        blockedByMarket: false,
        shouldNotify: true,
      ),
    ],
    notes: '当前共发现 1 个满足正式买入阈值的币，已按总分和量能排序。',
  );
}

StartupMarketRegime _riskOnRegime() {
  return const StartupMarketRegime(
    allowEntries: true,
    status: 'risk_on',
    reason: '市场环境允许试仓，启动信号可继续跟踪确认。',
    marketTrendBreadth: 0.68,
    marketMomentumBreadth: 0.61,
    marketVolumeBreadth: 0.44,
    redBreadth: 0.36,
    deepRedBreadth: 0.12,
  );
}

class _FakeBinanceService extends BinanceService {
  final List<CoinData> _coins = [
    CoinData(
      symbol: 'FETUSDT',
      lastPrice: 1.23,
      priceChange: 0.12,
      priceChangePercent: 4.8,
      highPrice: 1.26,
      lowPrice: 1.15,
      openPrice: 1.11,
      quoteVolume: 12345678,
      volume: 10000000,
      count: 32100,
    ),
  ];

  @override
  Future<List<CoinData>> fetchTickers({List<String>? symbols}) async => _coins;

  @override
  Future<List<CoinData>> fetchTradableUsdtTickers({int? limit}) async => _coins;

  @override
  Future<Map<String, List<Kline>>> fetchWatchlistKlines({
    List<String>? symbols,
    String interval = '1h',
    int limit = 100,
    bool forceRefresh = false,
    Duration? ttl,
    bool allowFailures = true,
    int chunkSize = 8,
  }) async {
    return {
      'FETUSDT': const [],
    };
  }
}

class _FakeStartupScannerService extends StartupScannerService {
  final StartupScanReport report;
  StartupScanPolicy? lastPolicy;

  _FakeStartupScannerService(this.report);

  @override
  StartupScanReport analyzeMarket({
    required List<CoinData> currentCoins,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    StartupScanPolicy policy = StartupScanPolicy.defaultPolicy,
  }) {
    lastPolicy = policy;
    return report;
  }
}

Map<String, dynamic> _startupOptimizationArtifact({
  required StartupScanPolicy policy,
  required String roundId,
  required String roundLabel,
}) {
  return {
    'generatedAt': DateTime(2026, 4, 9, 12).toIso8601String(),
    'windowDays': [45, 90, 180],
    'optimization': {
      'generatedAt': DateTime(2026, 4, 9, 12).toIso8601String(),
      'windowDays': [45, 90, 180],
      'selectionNote': '已按多窗口稳定性筛选最稳策略。',
      'stableBestRound': {
        'id': roundId,
        'label': roundLabel,
        'meetsStabilityGate': true,
        'policy': policy.toJson(),
      },
      'bestRound': {
        'id': 'round_best_only',
        'label': '短期激进',
        'policy':
            StartupScanPolicy.defaultPolicy.copyWith(label: '短期激进').toJson(),
      },
    },
  };
}

class _FakeMarketBottomDetectorService extends MarketBottomDetectorService {
  final MarketBottomAlert alert;

  _FakeMarketBottomDetectorService(this.alert);

  @override
  MarketBottomAlert analyzeMarket({
    required List<CoinData> currentCoins,
    required Map<String, List<Kline>> dailyHistory,
    required Map<String, List<Kline>> hourlyHistory,
    MarketBottomPolicy policy = MarketBottomPolicy.defaultPolicy,
  }) {
    return alert;
  }
}
