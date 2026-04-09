import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/coin_data.dart';
import '../models/strategy_snapshot.dart';
import 'binance_service.dart';
import 'hourly_replay_service.dart';
import 'recommendation_engine.dart';
import 'startup_scanner_service.dart';

enum PushProvider { auto, feishu, ntfy }

PushProvider parsePushProvider(String? raw) {
  final normalized = raw?.trim().toLowerCase() ?? '';
  switch (normalized) {
    case 'feishu':
    case 'lark':
      return PushProvider.feishu;
    case 'ntfy':
      return PushProvider.ntfy;
    case 'auto':
    case '':
      return PushProvider.auto;
    default:
      return PushProvider.auto;
  }
}

class ReplayRefreshResult {
  final HourlyReplayReport report;
  final bool refreshed;
  final String outputPath;
  final List<String> activeSymbols;

  const ReplayRefreshResult({
    required this.report,
    required this.refreshed,
    required this.outputPath,
    required this.activeSymbols,
  });
}

class PushDeliveryResult {
  final bool attempted;
  final bool sent;
  final String provider;
  final String status;
  final String message;
  final String? digest;
  final DateTime recordedAt;

  const PushDeliveryResult({
    required this.attempted,
    required this.sent,
    required this.provider,
    required this.status,
    required this.message,
    required this.recordedAt,
    this.digest,
  });

  Map<String, dynamic> toJson() => {
        'attempted': attempted,
        'sent': sent,
        'provider': provider,
        'status': status,
        'message': message,
        'digest': digest,
        'recordedAt': recordedAt.toIso8601String(),
      };
}

class SignalRunResult {
  final DateTime generatedAt;
  final EntrySignalPolicy policy;
  final RecommendationEngineResult engine;
  final Map<String, dynamic> payload;
  final String outputPath;
  final PushDeliveryResult pushResult;

  const SignalRunResult({
    required this.generatedAt,
    required this.policy,
    required this.engine,
    required this.payload,
    required this.outputPath,
    required this.pushResult,
  });
}

class StartupScanRunResult {
  final DateTime generatedAt;
  final StartupScanReport report;
  final Map<String, dynamic> payload;
  final String outputPath;
  final String buyLogPath;
  final Map<String, dynamic> predictionLog;
  final PushDeliveryResult pushResult;

  const StartupScanRunResult({
    required this.generatedAt,
    required this.report,
    required this.payload,
    required this.outputPath,
    required this.buyLogPath,
    required this.predictionLog,
    required this.pushResult,
  });
}

class SignalRunnerService {
  static const defaultDailyReportPath =
      'build/reports/daily_signal_report.json';
  static const defaultReplayReportPath =
      'build/reports/hourly_replay_report.json';
  static const defaultPushStatePath = 'build/reports/cloud_push_state.json';
  static const defaultStartupBuyLogPath = 'build/reports/startup_buy_log.json';
  static const defaultStartupPredictionEvaluationHours = 24;

  final BinanceService _binance;
  final HourlyReplayService _replay;
  final StartupScannerService _startupScanner;
  final http.Client _httpClient;

  SignalRunnerService({
    BinanceService? binance,
    HourlyReplayService? replay,
    StartupScannerService? startupScanner,
    http.Client? httpClient,
  })  : _binance = binance ?? BinanceService(),
        _replay = replay ?? HourlyReplayService(),
        _startupScanner = startupScanner ?? StartupScannerService(),
        _httpClient = httpClient ?? http.Client();

  Future<EntrySignalPolicy> loadOptimizedPolicy({
    String replayReportPath = defaultReplayReportPath,
  }) async {
    final report = await loadReplayReport(replayReportPath: replayReportPath);
    return report?.optimizedPolicy ?? EntrySignalPolicy.defaultPolicy;
  }

  Future<HourlyReplayReport?> loadReplayReport({
    String replayReportPath = defaultReplayReportPath,
  }) async {
    final file = File(replayReportPath);
    if (!await file.exists()) return null;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;

      final direct = decoded['optimizedPolicy'];
      if (direct is Map) {
        return HourlyReplayReport.fromJson(Map<String, dynamic>.from(decoded));
      }

      final nested = decoded['report'];
      if (nested is Map) {
        return HourlyReplayReport.fromJson(Map<String, dynamic>.from(nested));
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  Future<ReplayRefreshResult> ensureFreshReplayReport({
    List<String>? requestedSymbols,
    String replayReportPath = defaultReplayReportPath,
    Duration maxAge = const Duration(hours: 12),
  }) async {
    final existing = await loadReplayReport(replayReportPath: replayReportPath);
    if (existing != null &&
        DateTime.now().difference(existing.generatedAt) <= maxAge) {
      return ReplayRefreshResult(
        report: existing,
        refreshed: false,
        outputPath: replayReportPath,
        activeSymbols: const [],
      );
    }

    final watchlist =
        requestedSymbols ?? BinanceService.defaultWatchlistSymbols;
    final activeSymbols = (await _binance.fetchTickers(symbols: watchlist))
        .map((coin) => coin.symbol)
        .toList();

    final histories = await Future.wait([
      _binance.fetchWatchlistKlines(
        symbols: activeSymbols,
        interval: '1d',
        limit: 90,
        forceRefresh: true,
      ),
      _binance.fetchWatchlistKlines(
        symbols: activeSymbols,
        interval: '1h',
        limit: 960,
        forceRefresh: true,
      ),
    ]);

    final report = await _replay.generateReport(
      dailyHistory: histories[0],
      hourlyHistory: histories[1],
    );

    await _writeJsonFile(
      replayReportPath,
      {
        'generatedAt': DateTime.now().toIso8601String(),
        'activeSymbols': activeSymbols,
        'report': report.toJson(),
      },
    );

    return ReplayRefreshResult(
      report: report,
      refreshed: true,
      outputPath: replayReportPath,
      activeSymbols: activeSymbols,
    );
  }

  Future<SignalRunResult> runDailySignal({
    List<String>? requestedSymbols,
    EntrySignalPolicy? policy,
    String dailyReportPath = defaultDailyReportPath,
    String replayReportPath = defaultReplayReportPath,
    PushProvider? pushProvider,
    String? feishuWebhookUrl,
    String? ntfyTopic,
    String? ntfyServer,
    bool publishPush = true,
    bool dedupePush = false,
    String pushStatePath = defaultPushStatePath,
    Duration pushDedupeWindow = const Duration(hours: 6),
  }) async {
    final generatedAt = DateTime.now();
    final resolvedPolicy =
        policy ?? await loadOptimizedPolicy(replayReportPath: replayReportPath);

    final coins = await _binance.fetchTickers(symbols: requestedSymbols);
    final symbols = coins.map((coin) => coin.symbol).toList();
    final histories = await Future.wait([
      _binance.fetchWatchlistKlines(
        symbols: symbols,
        interval: '1d',
        limit: 90,
        forceRefresh: true,
      ),
      _binance.fetchWatchlistKlines(
        symbols: symbols,
        interval: '1h',
        limit: 72,
        forceRefresh: true,
      ),
    ]);

    final engine = RecommendationEngine.analyze(
      currentCoins: coins,
      dailyHistory: histories[0],
      hourlyHistory: histories[1],
      policy: resolvedPolicy,
    );

    final payload = {
      'generatedAt': generatedAt.toIso8601String(),
      'analysisWindowDays': RecommendationEngine.historicalLookbackDays,
      'entrySignalPolicy': resolvedPolicy.toJson(),
      'backtest': engine.report.toJson(),
      'top3': engine.top3
          .map((coin) => {
                'symbol': coin.displayName,
                'score': coin.score,
                'recommendation': coin.recommendation,
                'price': coin.lastPrice,
                'dayChangePercent': coin.priceChangePercent,
                'thirtyDayChange': coin.thirtyDayChange,
                'sevenDayChange': coin.sevenDayChange,
                'timingLabel': coin.timingLabel,
                'timingReason': coin.timingReason,
                'reason': coin.reason,
              })
          .toList(),
      'alerts': engine.entryAlerts.map((alert) => alert.toJson()).toList(),
      'exitAlerts': engine.exitAlerts.map((alert) => alert.toJson()).toList(),
    };

    await _writeJsonFile(dailyReportPath, payload);

    final pushResult = publishPush
        ? await publishSignal(
            engine: engine,
            policy: resolvedPolicy,
            provider: pushProvider ??
                parsePushProvider(Platform.environment['PUSH_PROVIDER']),
            feishuWebhookUrl:
                feishuWebhookUrl ?? Platform.environment['FEISHU_WEBHOOK_URL'],
            server: ntfyServer ?? Platform.environment['NTFY_SERVER'],
            topic: ntfyTopic ?? Platform.environment['NTFY_TOPIC'],
            dedupe: dedupePush,
            statePath: pushStatePath,
            dedupeWindow: pushDedupeWindow,
          )
        : PushDeliveryResult(
            attempted: false,
            sent: false,
            provider: 'disabled',
            status: 'disabled',
            message: '云端运行已关闭远程推送',
            recordedAt: DateTime.now(),
          );

    return SignalRunResult(
      generatedAt: generatedAt,
      policy: resolvedPolicy,
      engine: engine,
      payload: payload,
      outputPath: dailyReportPath,
      pushResult: pushResult,
    );
  }

  Future<StartupScanRunResult> runMarketStartupScan({
    List<String>? requestedSymbols,
    int? symbolLimit,
    String reportPath = defaultDailyReportPath,
    String buyLogPath = defaultStartupBuyLogPath,
    PushProvider? pushProvider,
    String? feishuWebhookUrl,
    String? ntfyTopic,
    String? ntfyServer,
    bool publishPush = true,
    bool dedupePush = false,
    String pushStatePath = defaultPushStatePath,
    Duration pushDedupeWindow = const Duration(hours: 6),
    StartupScanPolicy policy = StartupScanPolicy.defaultPolicy,
  }) async {
    final generatedAt = DateTime.now();
    final coins = (requestedSymbols != null && requestedSymbols.isNotEmpty)
        ? await _binance.fetchTickers(symbols: requestedSymbols)
        : await _binance.fetchTradableUsdtTickers(limit: symbolLimit);

    final symbols = coins.map((coin) => coin.symbol).toList();
    final histories = await Future.wait([
      _binance.fetchWatchlistKlines(
        symbols: symbols,
        interval: '1d',
        limit: 90,
        forceRefresh: true,
        chunkSize: 18,
      ),
      _binance.fetchWatchlistKlines(
        symbols: symbols,
        interval: '1h',
        limit: 96,
        forceRefresh: true,
        chunkSize: 18,
      ),
    ]);

    final report = _startupScanner.analyzeMarket(
      currentCoins: coins,
      dailyHistory: histories[0],
      hourlyHistory: histories[1],
      policy: policy,
    );
    final actionableCandidates = await _filterStartupCandidatesByCooldown(
      path: buyLogPath,
      candidates: report.actionableCandidates,
      cooldownHours: policy.cooldownHours,
    );

    final payload = {
      'generatedAt': generatedAt.toIso8601String(),
      'mode': 'market_startup',
      'policy': policy.toJson(),
      'report': report.toJson(),
      'rawActionableCount': report.actionableCandidates.length,
      'actionableCandidates':
          actionableCandidates.map((item) => item.toJson()).toList(),
      'cooldownHours': policy.cooldownHours,
      'cooldownFilteredCount':
          report.actionableCandidates.length - actionableCandidates.length,
    };

    await _writeJsonFile(reportPath, payload);

    final pushResult = publishPush
        ? await publishStartupScan(
            report: report,
            policy: policy,
            actionableCandidates: actionableCandidates,
            provider: pushProvider ??
                parsePushProvider(Platform.environment['PUSH_PROVIDER']),
            feishuWebhookUrl:
                feishuWebhookUrl ?? Platform.environment['FEISHU_WEBHOOK_URL'],
            server: ntfyServer ?? Platform.environment['NTFY_SERVER'],
            topic: ntfyTopic ?? Platform.environment['NTFY_TOPIC'],
            dedupe: dedupePush,
            statePath: pushStatePath,
            dedupeWindow: pushDedupeWindow,
          )
        : PushDeliveryResult(
            attempted: false,
            sent: false,
            provider: 'disabled',
            status: 'disabled',
            message: '云端运行已关闭远程推送',
            recordedAt: DateTime.now(),
          );

    if (pushResult.sent) {
      await _appendStartupBuyLog(
        path: buyLogPath,
        candidates:
            actionableCandidates.take(policy.maxPushCandidates).toList(),
        recordedAt: generatedAt,
        pushProvider: pushResult.provider,
      );
    }

    final predictionLog = await refreshStartupPredictionLog(
      path: buyLogPath,
      currentCoins: coins,
    );

    return StartupScanRunResult(
      generatedAt: generatedAt,
      report: report,
      payload: payload,
      outputPath: reportPath,
      buyLogPath: buyLogPath,
      predictionLog: predictionLog,
      pushResult: pushResult,
    );
  }

  Future<Map<String, dynamic>> refreshStartupPredictionLog({
    String path = defaultStartupBuyLogPath,
    List<CoinData> currentCoins = const [],
    Duration evaluationWindow = const Duration(
      hours: defaultStartupPredictionEvaluationHours,
    ),
  }) async {
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final now = DateTime.now();

    final priceMap = <String, CoinData>{};
    for (final coin in currentCoins) {
      priceMap[coin.symbol.toUpperCase()] = coin;
      priceMap[coin.displayName.toUpperCase()] = coin;
    }

    final missingSymbols = <String>{};
    for (final record in records) {
      final status = record['status']?.toString() ?? 'pending';
      if (status == 'settled') continue;

      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');
      if (recordedAt == null || now.difference(recordedAt) < evaluationWindow) {
        continue;
      }

      final normalized =
          BinanceService.toSymbol(record['symbol']?.toString() ?? '');
      if (normalized.isEmpty) continue;
      if (!priceMap.containsKey(normalized)) {
        missingSymbols.add(normalized);
      }
    }

    if (missingSymbols.isNotEmpty) {
      try {
        final fetched =
            await _binance.fetchTickers(symbols: missingSymbols.toList());
        for (final coin in fetched) {
          priceMap[coin.symbol.toUpperCase()] = coin;
          priceMap[coin.displayName.toUpperCase()] = coin;
        }
      } catch (_) {
        // 统计结算不应影响主流程；本轮取价失败时保留 pending，等待下次再结算。
      }
    }

    for (final record in records) {
      final status = record['status']?.toString() ?? 'pending';
      if (status == 'settled') continue;

      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');
      if (recordedAt == null || now.difference(recordedAt) < evaluationWindow) {
        record['status'] = 'pending';
        continue;
      }

      final normalized =
          BinanceService.toSymbol(record['symbol']?.toString() ?? '');
      final coin =
          priceMap[normalized] ?? priceMap[normalized.replaceAll('USDT', '')];
      final entryPrice = _asDouble(record['entryPrice']);
      if (coin == null || entryPrice <= 0) {
        record['status'] = 'pending';
        continue;
      }

      final settlementPrice = coin.lastPrice;
      final returnPercent = ((settlementPrice - entryPrice) / entryPrice) * 100;
      record['status'] = 'settled';
      record['settledAt'] = now.toIso8601String();
      record['settlementPrice'] = settlementPrice;
      record['returnPercent'] = returnPercent;
      record['holdingHours'] =
          now.difference(recordedAt).inMinutes / Duration.minutesPerHour;
      record['isWin'] = returnPercent > 0;
    }

    final summary = _buildStartupPredictionSummary(records);
    final payload = {
      'updatedAt': now.toIso8601String(),
      'evaluationHours': evaluationWindow.inHours,
      'summary': summary,
      'records': records.take(300).toList(),
    };
    await _writeJsonFile(path, payload);
    return payload;
  }

  Future<PushDeliveryResult> publishSignal({
    required RecommendationEngineResult engine,
    required EntrySignalPolicy policy,
    PushProvider provider = PushProvider.auto,
    String? feishuWebhookUrl,
    String? server,
    String? topic,
    bool dedupe = false,
    String statePath = defaultPushStatePath,
    Duration dedupeWindow = const Duration(hours: 6),
  }) async {
    final resolvedProvider = _resolvePushProvider(
      provider: provider,
      feishuWebhookUrl: feishuWebhookUrl,
      ntfyTopic: topic,
    );

    if (resolvedProvider == null) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'none',
        status: 'skipped_unconfigured',
        message: '未配置飞书 webhook 或 ntfy topic，跳过远程推送',
        recordedAt: DateTime.now(),
      );
    }

    switch (resolvedProvider) {
      case PushProvider.feishu:
        return publishToFeishu(
          engine: engine,
          policy: policy,
          webhookUrl: feishuWebhookUrl,
          dedupe: dedupe,
          statePath: statePath,
          dedupeWindow: dedupeWindow,
        );
      case PushProvider.ntfy:
        return publishToNtfy(
          engine: engine,
          policy: policy,
          server: server,
          topic: topic,
          dedupe: dedupe,
          statePath: statePath,
          dedupeWindow: dedupeWindow,
        );
      case PushProvider.auto:
        return PushDeliveryResult(
          attempted: false,
          sent: false,
          provider: 'none',
          status: 'skipped_unconfigured',
          message: '未找到可用推送通道',
          recordedAt: DateTime.now(),
        );
    }
  }

  Future<PushDeliveryResult> publishStartupScan({
    required StartupScanReport report,
    required StartupScanPolicy policy,
    List<StartupScanCandidate>? actionableCandidates,
    PushProvider provider = PushProvider.auto,
    String? feishuWebhookUrl,
    String? server,
    String? topic,
    bool dedupe = false,
    String statePath = defaultPushStatePath,
    Duration dedupeWindow = const Duration(hours: 6),
  }) async {
    final actionable = (actionableCandidates ?? report.actionableCandidates)
        .take(policy.maxPushCandidates)
        .toList();
    if (actionable.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: provider.name,
        status: 'skipped_no_actionable',
        message: '当前没有满足全市场启动阈值的买入信号，不推送',
        recordedAt: DateTime.now(),
      );
    }

    final resolvedProvider = _resolvePushProvider(
      provider: provider,
      feishuWebhookUrl: feishuWebhookUrl,
      ntfyTopic: topic,
    );

    if (resolvedProvider == null) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'none',
        status: 'skipped_unconfigured',
        message: '未配置飞书 webhook 或 ntfy topic，跳过远程推送',
        recordedAt: DateTime.now(),
      );
    }

    final digest = _buildStartupPushDigest(actionable);
    final duplicate = await _checkDuplicatePush(
      digest: digest,
      dedupe: dedupe,
      statePath: statePath,
      dedupeWindow: dedupeWindow,
      provider: resolvedProvider.name,
    );
    if (duplicate != null) {
      return duplicate;
    }

    final body = _buildStartupPushBody(
      report: report,
      policy: policy,
      actionable: actionable,
    );

    switch (resolvedProvider) {
      case PushProvider.feishu:
        await _sendTextToFeishu(
          webhookUrl: feishuWebhookUrl!.trim(),
          body: body,
        );
        break;
      case PushProvider.ntfy:
        final resolvedServer = (server == null || server.trim().isEmpty)
            ? 'https://ntfy.sh'
            : server.trim();
        await _sendTextToNtfy(
          server: resolvedServer,
          topic: topic!.trim(),
          body: body,
          title: 'Binance Startup Scan',
        );
        break;
      case PushProvider.auto:
        break;
    }

    final now = DateTime.now();
    await _recordPushState(
      digest: digest,
      provider: resolvedProvider.name,
      statePath: statePath,
      recordedAt: now,
      target: resolvedProvider == PushProvider.feishu
          ? feishuWebhookUrl!.trim()
          : '${(server == null || server.trim().isEmpty) ? 'https://ntfy.sh' : server.trim()}/${topic!.trim()}',
    );

    return PushDeliveryResult(
      attempted: true,
      sent: true,
      provider: resolvedProvider.name,
      status: 'sent',
      message: resolvedProvider == PushProvider.feishu
          ? '已推送全市场启动买入信号到飞书'
          : '已推送全市场启动买入信号到 ntfy',
      digest: digest,
      recordedAt: now,
    );
  }

  Future<PushDeliveryResult> publishTestMessage({
    PushProvider provider = PushProvider.auto,
    String? feishuWebhookUrl,
    String? server,
    String? topic,
    String? message,
  }) async {
    final resolvedProvider = _resolvePushProvider(
      provider: provider,
      feishuWebhookUrl: feishuWebhookUrl,
      ntfyTopic: topic,
    );

    if (resolvedProvider == null) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'none',
        status: 'skipped_unconfigured',
        message: '未配置飞书 webhook 或 ntfy topic，无法发送测试推送',
        recordedAt: DateTime.now(),
      );
    }

    final body = (message == null || message.trim().isEmpty)
        ? _buildTestPushBody(provider: resolvedProvider)
        : message.trim();
    final now = DateTime.now();

    switch (resolvedProvider) {
      case PushProvider.feishu:
        final resolvedWebhook = feishuWebhookUrl?.trim() ?? '';
        await _sendTextToFeishu(
          webhookUrl: resolvedWebhook,
          body: body,
        );
        return PushDeliveryResult(
          attempted: true,
          sent: true,
          provider: 'feishu',
          status: 'sent_test',
          message: '已发送飞书测试消息',
          recordedAt: now,
        );
      case PushProvider.ntfy:
        final trimmedTopic = topic?.trim() ?? '';
        final resolvedServer = (server == null || server.trim().isEmpty)
            ? 'https://ntfy.sh'
            : server.trim();
        await _sendTextToNtfy(
          server: resolvedServer,
          topic: trimmedTopic,
          body: body,
          title: 'Binance Analyzer Test',
        );
        return PushDeliveryResult(
          attempted: true,
          sent: true,
          provider: 'ntfy',
          status: 'sent_test',
          message: '已发送 ntfy 测试消息到 $resolvedServer/$trimmedTopic',
          recordedAt: now,
        );
      case PushProvider.auto:
        return PushDeliveryResult(
          attempted: false,
          sent: false,
          provider: 'none',
          status: 'skipped_unconfigured',
          message: '未找到可用推送通道',
          recordedAt: now,
        );
    }
  }

  Future<PushDeliveryResult> publishToNtfy({
    required RecommendationEngineResult engine,
    required EntrySignalPolicy policy,
    String? server,
    String? topic,
    bool dedupe = false,
    String statePath = defaultPushStatePath,
    Duration dedupeWindow = const Duration(hours: 6),
  }) async {
    final trimmedTopic = topic?.trim() ?? '';
    if (trimmedTopic.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'ntfy',
        status: 'skipped_no_topic',
        message: '未配置 NTFY_TOPIC，跳过云端推送',
        recordedAt: DateTime.now(),
      );
    }

    final actionableEntry = _pickActionableAlerts(engine.entryAlerts);
    final actionableExit = _pickActionableAlerts(engine.exitAlerts);
    if (actionableEntry.isEmpty && actionableExit.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'ntfy',
        status: 'skipped_no_actionable',
        message: '当前没有满足阈值的买入或卖出信号，不推送',
        recordedAt: DateTime.now(),
      );
    }

    final digest = _buildPushDigest(
      entryAlerts: actionableEntry,
      exitAlerts: actionableExit,
    );
    final duplicate = await _checkDuplicatePush(
      digest: digest,
      dedupe: dedupe,
      statePath: statePath,
      dedupeWindow: dedupeWindow,
      provider: 'ntfy',
    );
    if (duplicate != null) {
      return duplicate;
    }

    final resolvedServer = (server == null || server.trim().isEmpty)
        ? 'https://ntfy.sh'
        : server.trim();

    final body = _buildPushBody(
      engine: engine,
      policy: policy,
      actionableEntry: actionableEntry,
      actionableExit: actionableExit,
    );
    await _sendTextToNtfy(
      server: resolvedServer,
      topic: trimmedTopic,
      body: body,
      title: 'Binance Analyzer Signal',
    );

    final now = DateTime.now();
    await _recordPushState(
      digest: digest,
      provider: 'ntfy',
      statePath: statePath,
      recordedAt: now,
      target: '$resolvedServer/$trimmedTopic',
    );

    return PushDeliveryResult(
      attempted: true,
      sent: true,
      provider: 'ntfy',
      status: 'sent',
      message: '已推送到 $resolvedServer/$trimmedTopic',
      digest: digest,
      recordedAt: now,
    );
  }

  Future<PushDeliveryResult> publishToFeishu({
    required RecommendationEngineResult engine,
    required EntrySignalPolicy policy,
    String? webhookUrl,
    bool dedupe = false,
    String statePath = defaultPushStatePath,
    Duration dedupeWindow = const Duration(hours: 6),
  }) async {
    final resolvedWebhook = webhookUrl?.trim() ?? '';
    if (resolvedWebhook.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'feishu',
        status: 'skipped_no_webhook',
        message: '未配置 FEISHU_WEBHOOK_URL，跳过飞书推送',
        recordedAt: DateTime.now(),
      );
    }

    final actionableEntry = _pickActionableAlerts(engine.entryAlerts);
    final actionableExit = _pickActionableAlerts(engine.exitAlerts);
    if (actionableEntry.isEmpty && actionableExit.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'feishu',
        status: 'skipped_no_actionable',
        message: '当前没有满足阈值的买入或卖出信号，不推送',
        recordedAt: DateTime.now(),
      );
    }

    final digest = _buildPushDigest(
      entryAlerts: actionableEntry,
      exitAlerts: actionableExit,
    );
    final duplicate = await _checkDuplicatePush(
      digest: digest,
      dedupe: dedupe,
      statePath: statePath,
      dedupeWindow: dedupeWindow,
      provider: 'feishu',
    );
    if (duplicate != null) {
      return duplicate;
    }

    final body = _buildPushBody(
      engine: engine,
      policy: policy,
      actionableEntry: actionableEntry,
      actionableExit: actionableExit,
    );
    await _sendTextToFeishu(
      webhookUrl: resolvedWebhook,
      body: body,
    );

    final now = DateTime.now();
    await _recordPushState(
      digest: digest,
      provider: 'feishu',
      statePath: statePath,
      recordedAt: now,
      target: resolvedWebhook,
    );

    return PushDeliveryResult(
      attempted: true,
      sent: true,
      provider: 'feishu',
      status: 'sent',
      message: '已推送到飞书机器人',
      digest: digest,
      recordedAt: now,
    );
  }

  Future<Map<String, dynamic>> loadJsonArtifact(String path) async {
    return _readJsonFile(path);
  }

  Future<void> saveJsonArtifact(
      String path, Map<String, dynamic> payload) async {
    await _writeJsonFile(path, payload);
  }

  PushProvider? _resolvePushProvider({
    required PushProvider provider,
    String? feishuWebhookUrl,
    String? ntfyTopic,
  }) {
    switch (provider) {
      case PushProvider.feishu:
        return (feishuWebhookUrl?.trim().isNotEmpty ?? false)
            ? PushProvider.feishu
            : null;
      case PushProvider.ntfy:
        return (ntfyTopic?.trim().isNotEmpty ?? false)
            ? PushProvider.ntfy
            : null;
      case PushProvider.auto:
        if (feishuWebhookUrl?.trim().isNotEmpty ?? false) {
          return PushProvider.feishu;
        }
        if (ntfyTopic?.trim().isNotEmpty ?? false) {
          return PushProvider.ntfy;
        }
        return null;
    }
  }

  List<EntryAlertSignal> _pickActionableAlerts(List<EntryAlertSignal> alerts) {
    return alerts.where((alert) => alert.shouldNotify).take(3).toList();
  }

  String _buildPushBody({
    required RecommendationEngineResult engine,
    required EntrySignalPolicy policy,
    required List<EntryAlertSignal> actionableEntry,
    required List<EntryAlertSignal> actionableExit,
  }) {
    final buffer = StringBuffer()
      ..writeln('Binance Analyzer 信号提醒')
      ..writeln('分析窗口: ${RecommendationEngine.historicalLookbackDays} 天')
      ..writeln('轮动策略: ${engine.report.presetLabel}')
      ..writeln('提醒阈值: ${policy.summary}')
      ..writeln(
        '回测胜率 ${(engine.report.winRate * 100).toStringAsFixed(1)}% | '
        'Top3均值 ${engine.report.avgTop3Return.toStringAsFixed(2)}%',
      )
      ..writeln('')
      ..writeln('Top3:')
      ..writeln(
        engine.top3
            .map((coin) =>
                '${coin.displayName} ${(coin.score * 100).round()}分 ${coin.timingLabel}')
            .join('\n'),
      );

    if (actionableEntry.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('买入信号:')
        ..writeln(
          actionableEntry
              .map((alert) =>
                  '${alert.symbol} ${alert.timingLabel} | ${(alert.totalScore * 100).round()}分 | ${alert.timingReason}')
              .join('\n'),
        );
    }

    if (actionableExit.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('卖出信号:')
        ..writeln(
          actionableExit
              .map((alert) =>
                  '${alert.symbol} ${alert.timingLabel} | ${(alert.entryScore * 100).round()}分 | ${alert.timingReason}')
              .join('\n'),
        );
    }

    return buffer.toString();
  }

  String _buildStartupPushBody({
    required StartupScanReport report,
    required StartupScanPolicy policy,
    required List<StartupScanCandidate> actionable,
  }) {
    final buffer = StringBuffer()
      ..writeln('Binance 全市场启动预警')
      ..writeln(
          '范围: ${report.analyzedSymbols}/${report.universeSize} 个 USDT 现货币种')
      ..writeln('策略: ${report.strategyLabel}')
      ..writeln(
        '阈值: 总分>=${(policy.minScore * 100).round()} '
        '| 趋势>=${(policy.minTrendScore * 100).round()} '
        '| 量比>=${policy.minVolumeRatio.toStringAsFixed(2)}x',
      )
      ..writeln('')
      ..writeln('买入记录:');

    for (final candidate in actionable) {
      buffer.writeln(
        '${candidate.symbol} 入场参考 ${candidate.currentPrice.toStringAsFixed(6)} '
        '| ${(candidate.score * 100).round()}分 '
        '| ${candidate.reason}',
      );
    }

    if (report.candidates.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('观察名单:');
      for (final candidate in report.candidates.take(5)) {
        buffer.writeln(
          '${candidate.symbol} ${(candidate.score * 100).round()}分 '
          '| 量比 ${candidate.volumeRatio.toStringAsFixed(2)}x '
          '| 距20日突破位 ${candidate.dailyBreakoutDistance >= 0 ? '+' : ''}${candidate.dailyBreakoutDistance.toStringAsFixed(2)}%',
        );
      }
    }

    return buffer.toString().trim();
  }

  String _buildTestPushBody({required PushProvider provider}) {
    return (StringBuffer()
          ..writeln('Binance Analyzer 测试推送')
          ..writeln('时间: ${DateTime.now().toIso8601String()}')
          ..writeln('通道: ${provider.name}')
          ..writeln('说明: 这是一条服务器连通性测试消息'))
        .toString();
  }

  String _buildPushDigest({
    required List<EntryAlertSignal> entryAlerts,
    required List<EntryAlertSignal> exitAlerts,
  }) {
    final parts = <String>[
      ...entryAlerts.map((alert) => 'buy:${alert.symbol}:${alert.timingLabel}'),
      ...exitAlerts.map((alert) => 'sell:${alert.symbol}:${alert.timingLabel}'),
    ];
    return parts.join('|');
  }

  String _buildStartupPushDigest(List<StartupScanCandidate> candidates) {
    return candidates.map((item) => 'startup:${item.symbol}').join('|');
  }

  Future<void> _appendStartupBuyLog({
    required String path,
    required List<StartupScanCandidate> candidates,
    required DateTime recordedAt,
    required String pushProvider,
  }) async {
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    for (final candidate in candidates) {
      records.insert(0, {
        'id': '${recordedAt.toIso8601String()}|${candidate.symbol}',
        'recordedAt': recordedAt.toIso8601String(),
        'status': 'pending',
        'signalType': 'startup_buy',
        'pushProvider': pushProvider,
        'symbol': candidate.symbol,
        'entryPrice': candidate.currentPrice,
        'score': candidate.score,
        'volumeRatio': candidate.volumeRatio,
        'dailyBreakoutDistance': candidate.dailyBreakoutDistance,
        'hourlyBreakoutDistance': candidate.hourlyBreakoutDistance,
        'sevenDayMomentum': candidate.sevenDayMomentum,
        'thirtyDayMomentum': candidate.thirtyDayMomentum,
        'reason': candidate.reason,
      });
    }

    await _writeJsonFile(path, {
      'updatedAt': DateTime.now().toIso8601String(),
      'evaluationHours': defaultStartupPredictionEvaluationHours,
      'records': records.take(300).toList(),
    });
  }

  Future<List<StartupScanCandidate>> _filterStartupCandidatesByCooldown({
    required String path,
    required List<StartupScanCandidate> candidates,
    required int cooldownHours,
  }) async {
    if (candidates.isEmpty || cooldownHours <= 0) {
      return candidates;
    }

    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final now = DateTime.now();
    final blocked = <String>{};

    for (final record in records) {
      final symbol = (record['symbol']?.toString() ?? '').trim().toUpperCase();
      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');
      if (symbol.isEmpty || recordedAt == null) continue;
      if (now.difference(recordedAt) < Duration(hours: cooldownHours)) {
        blocked.add(symbol);
      }
    }

    if (blocked.isEmpty) {
      return candidates;
    }

    return candidates
        .where((candidate) => !blocked.contains(candidate.symbol.toUpperCase()))
        .toList();
  }

  Map<String, dynamic> _buildStartupPredictionSummary(
    List<Map<String, dynamic>> records,
  ) {
    var settled = 0;
    var wins = 0;
    var losses = 0;
    var totalReturnPercent = 0.0;
    var totalHoldingHours = 0.0;
    double? bestReturnPercent;
    double? worstReturnPercent;
    DateTime? lastRecordedAt;
    DateTime? lastSettledAt;
    final bySymbol = <String, List<Map<String, dynamic>>>{};

    for (final record in records) {
      final symbol = (record['symbol']?.toString() ?? '').toUpperCase();
      if (symbol.isNotEmpty) {
        bySymbol.putIfAbsent(symbol, () => []).add(record);
      }

      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');
      if (recordedAt != null &&
          (lastRecordedAt == null || recordedAt.isAfter(lastRecordedAt))) {
        lastRecordedAt = recordedAt;
      }

      final status = record['status']?.toString() ?? 'pending';
      if (status != 'settled') continue;

      settled += 1;
      final isWin = record['isWin'] == true;
      if (isWin) {
        wins += 1;
      } else {
        losses += 1;
      }

      final returnPercent = _asDouble(record['returnPercent']);
      totalReturnPercent += returnPercent;
      bestReturnPercent = bestReturnPercent == null
          ? returnPercent
          : (returnPercent > bestReturnPercent
              ? returnPercent
              : bestReturnPercent);
      worstReturnPercent = worstReturnPercent == null
          ? returnPercent
          : (returnPercent < worstReturnPercent
              ? returnPercent
              : worstReturnPercent);

      totalHoldingHours += _asDouble(record['holdingHours']);
      final settledAt =
          DateTime.tryParse(record['settledAt']?.toString() ?? '');
      if (settledAt != null &&
          (lastSettledAt == null || settledAt.isAfter(lastSettledAt))) {
        lastSettledAt = settledAt;
      }
    }

    final bySymbolSummary = bySymbol.entries.map((entry) {
      final symbolRecords = entry.value;
      var symbolSettled = 0;
      var symbolWins = 0;
      var symbolReturn = 0.0;
      DateTime? latestAt;

      for (final record in symbolRecords) {
        final recordedAt =
            DateTime.tryParse(record['recordedAt']?.toString() ?? '');
        if (recordedAt != null &&
            (latestAt == null || recordedAt.isAfter(latestAt))) {
          latestAt = recordedAt;
        }
        if ((record['status']?.toString() ?? 'pending') != 'settled') continue;
        symbolSettled += 1;
        if (record['isWin'] == true) {
          symbolWins += 1;
        }
        symbolReturn += _asDouble(record['returnPercent']);
      }

      return {
        'symbol': entry.key,
        'total': symbolRecords.length,
        'settled': symbolSettled,
        'pending': symbolRecords.length - symbolSettled,
        'wins': symbolWins,
        'winRate': symbolSettled == 0 ? 0.0 : symbolWins / symbolSettled,
        'avgReturnPercent':
            symbolSettled == 0 ? 0.0 : symbolReturn / symbolSettled,
        'lastRecordedAt': latestAt?.toIso8601String(),
      };
    }).toList()
      ..sort((a, b) {
        final byTotal =
            ((b['total'] as num?) ?? 0).compareTo((a['total'] as num?) ?? 0);
        if (byTotal != 0) return byTotal;
        return ((b['winRate'] as num?) ?? 0)
            .compareTo((a['winRate'] as num?) ?? 0);
      });

    return {
      'totalPredictions': records.length,
      'pending': records.length - settled,
      'settled': settled,
      'wins': wins,
      'losses': losses,
      'winRate': settled == 0 ? 0.0 : wins / settled,
      'avgReturnPercent': settled == 0 ? 0.0 : totalReturnPercent / settled,
      'avgHoldingHours': settled == 0 ? 0.0 : totalHoldingHours / settled,
      'bestReturnPercent': bestReturnPercent ?? 0.0,
      'worstReturnPercent': worstReturnPercent ?? 0.0,
      'lastRecordedAt': lastRecordedAt?.toIso8601String(),
      'lastSettledAt': lastSettledAt?.toIso8601String(),
      'bySymbol': bySymbolSummary,
    };
  }

  Future<PushDeliveryResult?> _checkDuplicatePush({
    required String digest,
    required bool dedupe,
    required String statePath,
    required Duration dedupeWindow,
    required String provider,
  }) async {
    if (!dedupe) return null;

    final pushState = await _readJsonFile(statePath);
    final previousDigest = pushState['lastDigest'] as String?;
    final previousProvider = pushState['lastProvider'] as String?;
    final previousAt =
        DateTime.tryParse(pushState['lastSentAt'] as String? ?? '');
    final now = DateTime.now();

    if (previousDigest == digest &&
        previousProvider == provider &&
        previousAt != null &&
        now.difference(previousAt) < dedupeWindow) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: provider,
        status: 'skipped_duplicate',
        message: '与上次推送内容一致，且仍在冷却窗口内',
        digest: digest,
        recordedAt: now,
      );
    }

    return null;
  }

  Future<void> _recordPushState({
    required String digest,
    required String provider,
    required String statePath,
    required DateTime recordedAt,
    required String target,
  }) async {
    await _writeJsonFile(
      statePath,
      {
        'lastDigest': digest,
        'lastSentAt': recordedAt.toIso8601String(),
        'lastProvider': provider,
        'lastTarget': target,
      },
    );
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value == null) return 0;
    return int.tryParse(value.toString()) ?? 0;
  }

  double _asDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value == null) return 0.0;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  Future<void> _sendTextToNtfy({
    required String server,
    required String topic,
    required String body,
    required String title,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$server/$topic'),
      headers: {
        HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
        'Title': title,
      },
      body: body,
    );
    if (response.statusCode >= 400) {
      throw HttpException(
        'ntfy push failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  Future<void> _sendTextToFeishu({
    required String webhookUrl,
    required String body,
  }) async {
    final response = await _httpClient.post(
      Uri.parse(webhookUrl),
      headers: {
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
      body: jsonEncode({
        'msg_type': 'text',
        'content': {
          'text': body,
        },
      }),
    );

    if (response.statusCode >= 400) {
      throw HttpException(
        'feishu push failed: ${response.statusCode} ${response.body}',
      );
    }

    if (response.body.isEmpty) return;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return;

    final code = _asInt(decoded['code'] ?? decoded['StatusCode']);
    if (code == 0) return;

    final msg = decoded['msg'] ?? decoded['StatusMessage'] ?? response.body;
    throw HttpException('feishu push failed: $code $msg');
  }

  Future<Map<String, dynamic>> _readJsonFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  Future<void> _writeJsonFile(String path, Map<String, dynamic> payload) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }
}
