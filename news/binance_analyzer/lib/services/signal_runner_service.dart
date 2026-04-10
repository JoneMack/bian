import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/coin_data.dart';
import '../models/strategy_snapshot.dart';
import 'binance_service.dart';
import 'hourly_replay_service.dart';
import 'leader_prediction_service.dart';
import 'market_bottom_detector_service.dart';
import 'recommendation_engine.dart';
import 'startup_scanner_service.dart';
import 'startup_strategy_backtest_service.dart';

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

class StartupStrategyRefreshResult {
  final Map<String, dynamic> payload;
  final bool refreshed;
  final String outputPath;
  final List<String> activeSymbols;
  final List<int> windowDays;
  final String? stableRoundLabel;

  const StartupStrategyRefreshResult({
    required this.payload,
    required this.refreshed,
    required this.outputPath,
    required this.activeSymbols,
    required this.windowDays,
    required this.stableRoundLabel,
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

class ClientExecutionCycleStatus {
  static const String open = 'open';
  static const String closed = 'closed';
}

class StartupPolicySelection {
  final StartupScanPolicy policy;
  final String source;
  final String reportPath;
  final DateTime? reportGeneratedAt;
  final List<int> windowDays;
  final String? roundId;
  final String? roundLabel;
  final bool meetsStabilityGate;
  final String? selectionNote;

  const StartupPolicySelection({
    required this.policy,
    required this.source,
    required this.reportPath,
    required this.reportGeneratedAt,
    required this.windowDays,
    required this.roundId,
    required this.roundLabel,
    required this.meetsStabilityGate,
    required this.selectionNote,
  });

  factory StartupPolicySelection.defaultPolicy({
    required String reportPath,
    String? selectionNote,
  }) {
    return StartupPolicySelection(
      policy: StartupScanPolicy.defaultPolicy,
      source: 'default',
      reportPath: reportPath,
      reportGeneratedAt: null,
      windowDays: const [],
      roundId: null,
      roundLabel: StartupScanPolicy.defaultPolicy.label,
      meetsStabilityGate: false,
      selectionNote: selectionNote,
    );
  }

  factory StartupPolicySelection.overridePolicy({
    required StartupScanPolicy policy,
    required String reportPath,
  }) {
    return StartupPolicySelection(
      policy: policy,
      source: 'override',
      reportPath: reportPath,
      reportGeneratedAt: null,
      windowDays: const [],
      roundId: null,
      roundLabel: policy.label,
      meetsStabilityGate: false,
      selectionNote: '本轮使用手动传入策略，未读取优化报告。',
    );
  }

  String get sourceLabel {
    switch (source) {
      case 'report_stable':
        return '多窗口稳定策略';
      case 'report_best':
        return '优化报告候选策略';
      case 'override':
        return '手动覆盖策略';
      default:
        return '默认策略';
    }
  }

  String get summary {
    final details = <String>[
      sourceLabel,
      if (windowDays.isNotEmpty) '${windowDays.join('/')}天',
      if ((roundLabel ?? '').trim().isNotEmpty) roundLabel!.trim(),
      if (source == 'report_stable') meetsStabilityGate ? '稳定门槛通过' : '稳定分回退',
    ];
    if (details.isNotEmpty) {
      return details.join(' | ');
    }
    return sourceLabel;
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'sourceLabel': sourceLabel,
        'summary': summary,
        'reportPath': reportPath,
        'reportGeneratedAt': reportGeneratedAt?.toIso8601String(),
        'windowDays': windowDays,
        'roundId': roundId,
        'roundLabel': roundLabel,
        'meetsStabilityGate': meetsStabilityGate,
        'selectionNote': selectionNote,
      };
}

class StartupScanRunResult {
  final DateTime generatedAt;
  final StartupPolicySelection policySelection;
  final StartupScanReport report;
  final MarketBottomAlert marketBottomAlert;
  final Map<String, dynamic> payload;
  final String outputPath;
  final String buyLogPath;
  final Map<String, dynamic> predictionLog;
  final PushDeliveryResult pushResult;

  const StartupScanRunResult({
    required this.generatedAt,
    required this.policySelection,
    required this.report,
    required this.marketBottomAlert,
    required this.payload,
    required this.outputPath,
    required this.buyLogPath,
    required this.predictionLog,
    required this.pushResult,
  });
}

class LeaderPredictionRunResult {
  final DateTime generatedAt;
  final LeaderPredictionResult result;
  final Map<String, dynamic> payload;
  final String reportPath;
  final String logPath;
  final String statsPath;
  final PushDeliveryResult pushResult;

  const LeaderPredictionRunResult({
    required this.generatedAt,
    required this.result,
    required this.payload,
    required this.reportPath,
    required this.logPath,
    required this.statsPath,
    required this.pushResult,
  });
}

class SignalRunnerService {
  static const defaultDailyReportPath =
      'build/reports/daily_signal_report.json';
  static const defaultReplayReportPath =
      'build/reports/hourly_replay_report.json';
  static const defaultStartupStrategyReportPath =
      'build/reports/startup_strategy_optimization_45d.json';
  static const defaultPushStatePath = 'build/reports/cloud_push_state.json';
  static const defaultStartupBuyLogPath = 'build/reports/startup_buy_log.json';
  static const defaultClientSignalActionLogPath =
      'build/reports/client_signal_actions.json';
  static const defaultClientExecutionCyclePath =
      'build/reports/client_execution_cycles.json';
  static const defaultLeaderPredictionReportPath =
      'build/reports/leader_prediction_report.json';
  static const defaultLeaderPredictionLogPath =
      'build/reports/leader_prediction_log.json';
  static const defaultLeaderPredictionStatsPath =
      'build/reports/leader_prediction_stats.json';
  static const defaultLeaderPredictionBacktestDays = 60;
  static const defaultStartupPredictionEvaluationHours = 24;
  static const Set<String> _trackedPredictionSignalTypes = {
    'startup_buy',
    'market_bottom_buy',
  };

  final BinanceService _binance;
  final HourlyReplayService _replay;
  final LeaderPredictionService _leaderPrediction;
  final StartupScannerService _startupScanner;
  final MarketBottomDetectorService _marketBottomDetector;
  final StartupStrategyBacktestService _startupStrategyBacktest;
  final http.Client _httpClient;

  SignalRunnerService({
    BinanceService? binance,
    HourlyReplayService? replay,
    LeaderPredictionService? leaderPrediction,
    StartupScannerService? startupScanner,
    MarketBottomDetectorService? marketBottomDetector,
    StartupStrategyBacktestService? startupStrategyBacktest,
    http.Client? httpClient,
  })  : _binance = binance ?? BinanceService(),
        _replay = replay ?? HourlyReplayService(),
        _leaderPrediction = leaderPrediction ?? LeaderPredictionService(),
        _startupScanner = startupScanner ?? StartupScannerService(),
        _marketBottomDetector =
            marketBottomDetector ?? MarketBottomDetectorService(),
        _startupStrategyBacktest =
            startupStrategyBacktest ?? StartupStrategyBacktestService(),
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

  Future<StartupScanPolicy> loadOptimizedStartupPolicy({
    String startupStrategyReportPath = defaultStartupStrategyReportPath,
  }) async {
    final selection = await loadOptimizedStartupPolicySelection(
      startupStrategyReportPath: startupStrategyReportPath,
    );
    return selection.policy;
  }

  Future<StartupPolicySelection> loadOptimizedStartupPolicySelection({
    String startupStrategyReportPath = defaultStartupStrategyReportPath,
  }) async {
    final file = File(startupStrategyReportPath);
    if (!await file.exists()) {
      return StartupPolicySelection.defaultPolicy(
        reportPath: startupStrategyReportPath,
        selectionNote: '未找到启动策略优化报告，已回退默认启动扫描策略。',
      );
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return StartupPolicySelection.defaultPolicy(
          reportPath: startupStrategyReportPath,
          selectionNote: '启动策略优化报告格式无效，已回退默认启动扫描策略。',
        );
      }

      final root = Map<String, dynamic>.from(decoded);
      final optimization = _asJsonMap(root['optimization']) ?? root;
      final stableRound = _asJsonMap(optimization['stableBestRound']);
      final bestRound = _asJsonMap(optimization['bestRound']);
      final windowDays =
          _asIntList(optimization['windowDays'] ?? root['windowDays']);
      final reportGeneratedAt = DateTime.tryParse(
        (optimization['generatedAt'] ?? root['generatedAt'])
                ?.toString()
                .trim() ??
            '',
      );
      final selectionNote =
          optimization['selectionNote']?.toString().trim().isNotEmpty == true
              ? optimization['selectionNote']?.toString().trim()
              : null;

      final stablePolicy = _policyFromRound(stableRound);
      if (stablePolicy != null) {
        return StartupPolicySelection(
          policy: stablePolicy,
          source: 'report_stable',
          reportPath: startupStrategyReportPath,
          reportGeneratedAt: reportGeneratedAt,
          windowDays: windowDays,
          roundId: stableRound?['id']?.toString(),
          roundLabel: stableRound?['label']?.toString(),
          meetsStabilityGate: stableRound?['meetsStabilityGate'] == true,
          selectionNote: selectionNote,
        );
      }

      final bestPolicy = _policyFromRound(bestRound);
      if (bestPolicy != null) {
        return StartupPolicySelection(
          policy: bestPolicy,
          source: 'report_best',
          reportPath: startupStrategyReportPath,
          reportGeneratedAt: reportGeneratedAt,
          windowDays: windowDays,
          roundId: bestRound?['id']?.toString(),
          roundLabel: bestRound?['label']?.toString(),
          meetsStabilityGate: false,
          selectionNote: selectionNote,
        );
      }
    } catch (_) {
      return StartupPolicySelection.defaultPolicy(
        reportPath: startupStrategyReportPath,
        selectionNote: '启动策略优化报告解析失败，已回退默认启动扫描策略。',
      );
    }

    return StartupPolicySelection.defaultPolicy(
      reportPath: startupStrategyReportPath,
      selectionNote: '启动策略优化报告缺少可用策略，已回退默认启动扫描策略。',
    );
  }

  Future<Map<String, dynamic>?> loadStartupStrategyReportArtifact({
    String startupStrategyReportPath = defaultStartupStrategyReportPath,
  }) async {
    final file = File(startupStrategyReportPath);
    if (!await file.exists()) return null;
    final payload = await _readJsonFile(startupStrategyReportPath);
    return payload.isEmpty ? null : payload;
  }

  Future<StartupStrategyRefreshResult> ensureFreshStartupStrategyReport({
    String startupStrategyReportPath = defaultStartupStrategyReportPath,
    Duration maxAge = const Duration(hours: 24),
    int? symbolLimit,
    List<int>? windowDays,
  }) async {
    final existing = await loadStartupStrategyReportArtifact(
      startupStrategyReportPath: startupStrategyReportPath,
    );
    if (existing != null) {
      final existingGeneratedAt =
          DateTime.tryParse(existing['generatedAt']?.toString() ?? '');
      final existingOptimization = _asJsonMap(existing['optimization']);
      if (existingOptimization != null &&
          existingGeneratedAt != null &&
          DateTime.now().difference(existingGeneratedAt) <= maxAge) {
        return StartupStrategyRefreshResult(
          payload: existing,
          refreshed: false,
          outputPath: startupStrategyReportPath,
          activeSymbols: _asStringList(existing['activeSymbols']),
          windowDays: _asIntList(
              existingOptimization['windowDays'] ?? existing['windowDays']),
          stableRoundLabel:
              _asJsonMap(existingOptimization['stableBestRound'])?['label']
                  ?.toString(),
        );
      }
    }

    final normalizedWindowDays =
        _startupStrategyBacktest.normalizeWindowDays(windowDays);
    final maxWindowDays = normalizedWindowDays.reduce(max);
    final hourlyBars = maxWindowDays * 24 +
        StartupStrategyBacktestService.replayLookbackHours +
        24;
    const dailyWarmupBars = 70;
    final dailyBars = maxWindowDays + dailyWarmupBars;

    final coins = await _binance.fetchTradableUsdtTickers(limit: symbolLimit);
    final activeSymbols = coins.map((coin) => coin.symbol).toList()..sort();
    final histories = await Future.wait([
      _binance.fetchWatchlistKlines(
        symbols: activeSymbols,
        interval: '1d',
        limit: dailyBars,
        forceRefresh: true,
        chunkSize: 18,
      ),
      _binance.fetchWatchlistKlines(
        symbols: activeSymbols,
        interval: '1h',
        limit: hourlyBars,
        forceRefresh: true,
        chunkSize: 18,
      ),
    ]);

    final report = _startupStrategyBacktest.optimize(
      dailyHistory: histories[0],
      hourlyHistory: histories[1],
      windowDays: normalizedWindowDays,
    );

    final payload = {
      'generatedAt': DateTime.now().toIso8601String(),
      'symbolLimit': symbolLimit,
      'windowDays': normalizedWindowDays,
      'activeSymbols': activeSymbols,
      'dailyBarsRequested': dailyBars,
      'hourlyBarsRequested': hourlyBars,
      'dailyHistoryCount': histories[0].length,
      'hourlyHistoryCount': histories[1].length,
      'optimization': report.toJson(),
    };
    await _writeJsonFile(startupStrategyReportPath, payload);

    final file = File(startupStrategyReportPath);
    final aliasPath =
        file.path.endsWith('startup_strategy_optimization_45d.json')
            ? '${file.parent.path}${Platform.pathSeparator}'
                'startup_strategy_optimization_multi_window.json'
            : null;
    if (aliasPath != null && aliasPath != startupStrategyReportPath) {
      await _writeJsonFile(aliasPath, payload);
    }

    return StartupStrategyRefreshResult(
      payload: payload,
      refreshed: true,
      outputPath: startupStrategyReportPath,
      activeSymbols: activeSymbols,
      windowDays: normalizedWindowDays,
      stableRoundLabel: report.stableBestRound.label,
    );
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
    String startupStrategyReportPath = defaultStartupStrategyReportPath,
    PushProvider? pushProvider,
    String? feishuWebhookUrl,
    String? ntfyTopic,
    String? ntfyServer,
    bool publishPush = true,
    bool dedupePush = false,
    String pushStatePath = defaultPushStatePath,
    Duration pushDedupeWindow = const Duration(hours: 6),
    StartupScanPolicy? policy,
    MarketBottomPolicy marketBottomPolicy = MarketBottomPolicy.defaultPolicy,
  }) async {
    final generatedAt = DateTime.now();
    final policySelection = policy == null
        ? await loadOptimizedStartupPolicySelection(
            startupStrategyReportPath: startupStrategyReportPath,
          )
        : StartupPolicySelection.overridePolicy(
            policy: policy,
            reportPath: startupStrategyReportPath,
          );
    final resolvedPolicy = policySelection.policy;
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
      policy: resolvedPolicy,
    );
    final marketBottomAlert = _marketBottomDetector.analyzeMarket(
      currentCoins: coins,
      dailyHistory: histories[0],
      hourlyHistory: histories[1],
      policy: marketBottomPolicy,
    );

    final startupStageSelection = await _selectStartupSignalStages(
      path: buyLogPath,
      report: report,
      policy: resolvedPolicy,
    );
    final actionableBottomCandidates =
        await _filterPredictionCandidatesByCooldown(
      path: buyLogPath,
      candidates: marketBottomAlert.actionableCandidates,
      cooldownHours: marketBottomPolicy.cooldownHours,
      signalTypes: const {'market_bottom_buy'},
      symbolOf: (candidate) => candidate.symbol,
    );

    final payload = {
      'generatedAt': generatedAt.toIso8601String(),
      'mode': 'market_startup',
      'policy': resolvedPolicy.toJson(),
      'policySelection': policySelection.toJson(),
      'marketBottomPolicy': marketBottomPolicy.toJson(),
      'report': report.toJson(),
      'marketBottomAlert': marketBottomAlert.toJson(),
      'rawActionableCount': report.actionableCandidates.length,
      'actionableCandidates': startupStageSelection.buyCandidates
          .map((item) => item.toJson())
          .toList(),
      'rawObservationCount': report.observationCandidates.length,
      'observationCandidates': startupStageSelection.observationCandidates
          .map((item) => item.toJson())
          .toList(),
      'rawBottomActionableCount': marketBottomAlert.actionableCandidates.length,
      'marketBottomActionableCandidates':
          actionableBottomCandidates.map((item) => item.toJson()).toList(),
      'cooldownHours': resolvedPolicy.cooldownHours,
      'cooldownFilteredCount': report.actionableCandidates.length -
          startupStageSelection.buyCandidates.length,
      'observationCooldownHours': resolvedPolicy.observationCooldownHours,
      'observationFilteredCount':
          startupStageSelection.observationSuppressedCount,
      'awaitingObservationCount':
          startupStageSelection.awaitingObservationConfirmationCount,
      'marketBottomCooldownHours': marketBottomPolicy.cooldownHours,
      'marketBottomCooldownFilteredCount':
          marketBottomAlert.actionableCandidates.length -
              actionableBottomCandidates.length,
    };

    await _writeJsonFile(reportPath, payload);

    final pushResult = publishPush
        ? await publishStartupScan(
            report: report,
            policy: resolvedPolicy,
            policySelection: policySelection,
            actionableCandidates: startupStageSelection.buyCandidates,
            observationCandidates: startupStageSelection.observationCandidates,
            marketBottomAlert: marketBottomAlert,
            marketBottomPolicy: marketBottomPolicy,
            actionableBottomCandidates: actionableBottomCandidates,
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
      await _appendPredictionLogEntries(
        path: buyLogPath,
        observationCandidates: startupStageSelection.observationCandidates
            .take(resolvedPolicy.maxObservationCandidates)
            .toList(),
        startupCandidates: startupStageSelection.buyCandidates
            .take(resolvedPolicy.maxPushCandidates)
            .toList(),
        marketBottomCandidates: actionableBottomCandidates
            .take(marketBottomPolicy.maxPushCandidates)
            .toList(),
        recordedAt: generatedAt,
        pushProvider: pushResult.provider,
        startupPolicySelection: policySelection,
      );
    }

    final predictionLog = await refreshStartupPredictionLog(
      path: buyLogPath,
      currentCoins: coins,
    );

    return StartupScanRunResult(
      generatedAt: generatedAt,
      policySelection: policySelection,
      report: report,
      marketBottomAlert: marketBottomAlert,
      payload: payload,
      outputPath: reportPath,
      buyLogPath: buyLogPath,
      predictionLog: predictionLog,
      pushResult: pushResult,
    );
  }

  Future<LeaderPredictionRunResult> runLeaderPrediction({
    List<String>? requestedSymbols,
    String reportPath = defaultLeaderPredictionReportPath,
    String logPath = defaultLeaderPredictionLogPath,
    String statsPath = defaultLeaderPredictionStatsPath,
    int lookbackDays = defaultLeaderPredictionBacktestDays,
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
    final coins = await _binance.fetchTickers(symbols: requestedSymbols);
    final symbols = coins.map((coin) => coin.symbol).toList()..sort();
    if (symbols.isEmpty) {
      throw StateError('当前没有可用于领涨预测的币种');
    }

    final historyBars = max(lookbackDays + 45, 120);
    final histories = await Future.wait([
      _binance.fetchWatchlistKlines(
        symbols: symbols,
        interval: '1d',
        limit: historyBars,
        forceRefresh: true,
        chunkSize: 18,
      ),
      _binance.fetchWatchlistKlines(
        symbols: const ['BTCUSDT'],
        interval: '1d',
        limit: historyBars,
        forceRefresh: true,
      ),
    ]);

    final dailyHistory = histories[0];
    final btcDailyHistory = histories[1]['BTCUSDT'] ?? const <Kline>[];
    final result = _leaderPrediction.analyze(
      currentCoins: coins,
      dailyHistory: dailyHistory,
      btcDailyHistory: btcDailyHistory,
    );
    final payload = _buildLeaderPredictionReportPayload(
      generatedAt: generatedAt,
      result: result,
      lookbackDays: lookbackDays,
      activeSymbols: symbols,
    );
    await _writeJsonFile(reportPath, payload);

    await _upsertLeaderPredictionRecord(
      path: logPath,
      generatedAt: generatedAt,
      result: result,
    );
    await refreshLeaderPredictionLog(
      path: logPath,
      statsPath: statsPath,
      dailyHistory: dailyHistory,
      btcDailyHistory: btcDailyHistory,
      lookbackDays: lookbackDays,
    );

    final pushResult = publishPush
        ? await publishLeaderPrediction(
            result: result,
            provider: pushProvider ??
                parsePushProvider(Platform.environment['PUSH_PROVIDER']),
            feishuWebhookUrl:
                feishuWebhookUrl ?? Platform.environment['FEISHU_WEBHOOK_URL'],
            server: ntfyServer ?? Platform.environment['NTFY_SERVER'],
            topic: ntfyTopic ?? Platform.environment['NTFY_TOPIC'],
            dedupe: dedupePush,
            statePath: pushStatePath,
            dedupeWindow: pushDedupeWindow,
            dedupeKey:
                'leader_prediction|${_leaderPredictionTargetDate(generatedAt).toIso8601String()}',
          )
        : PushDeliveryResult(
            attempted: false,
            sent: false,
            provider: 'disabled',
            status: 'disabled',
            message: '云端运行已关闭远程推送',
            recordedAt: DateTime.now(),
          );

    return LeaderPredictionRunResult(
      generatedAt: generatedAt,
      result: result,
      payload: payload,
      reportPath: reportPath,
      logPath: logPath,
      statsPath: statsPath,
      pushResult: pushResult,
    );
  }

  Future<Map<String, dynamic>> refreshLeaderPredictionStats({
    List<String>? requestedSymbols,
    String logPath = defaultLeaderPredictionLogPath,
    String statsPath = defaultLeaderPredictionStatsPath,
    int lookbackDays = defaultLeaderPredictionBacktestDays,
  }) async {
    final coins = await _binance.fetchTickers(symbols: requestedSymbols);
    final symbols = coins.map((coin) => coin.symbol).toList()..sort();
    if (symbols.isEmpty) {
      final emptyPayload = {
        'updatedAt': DateTime.now().toIso8601String(),
        'lookbackDays': lookbackDays,
        'summary': {
          'windowDays': lookbackDays,
          'totalDays': 0,
          'recommendDays': 0,
          'suppressedDays': 0,
          'suppressRate': 0.0,
          'top1HitRate': 0.0,
          'top3HitRate': 0.0,
          'avgPredictedReturn': 0.0,
          'avgLeaderReturn': 0.0,
          'avgExcessVsMedian': 0.0,
          'recent20Top1HitRate': 0.0,
          'recent20Top3HitRate': 0.0,
          'longestMissStreak': 0,
          'latestTop1': null,
          'latestTop3': const <String>[],
          'currentRegimeStatus': 'stand_aside',
        },
        'benchmarks': const <Map<String, dynamic>>[],
        'liveSummary': {
          'totalRecords': 0,
          'pending': 0,
          'settled': 0,
          'suppressed': 0,
        },
        'records': const <Map<String, dynamic>>[],
      };
      await _writeJsonFile(statsPath, emptyPayload);
      return emptyPayload;
    }

    final historyBars = max(lookbackDays + 45, 120);
    final histories = await Future.wait([
      _binance.fetchWatchlistKlines(
        symbols: symbols,
        interval: '1d',
        limit: historyBars,
        forceRefresh: true,
        chunkSize: 18,
      ),
      _binance.fetchWatchlistKlines(
        symbols: const ['BTCUSDT'],
        interval: '1d',
        limit: historyBars,
        forceRefresh: true,
      ),
    ]);
    return refreshLeaderPredictionLog(
      path: logPath,
      statsPath: statsPath,
      dailyHistory: histories[0],
      btcDailyHistory: histories[1]['BTCUSDT'] ?? const <Kline>[],
      lookbackDays: lookbackDays,
    );
  }

  Future<Map<String, dynamic>> refreshLeaderPredictionLog({
    String path = defaultLeaderPredictionLogPath,
    String statsPath = defaultLeaderPredictionStatsPath,
    required Map<String, List<Kline>> dailyHistory,
    required List<Kline> btcDailyHistory,
    int lookbackDays = defaultLeaderPredictionBacktestDays,
  }) async {
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    _settleLeaderPredictionRecords(
      records: records,
      dailyHistory: dailyHistory,
    );

    final liveSummary = _buildLeaderPredictionLiveSummary(records);
    final backtest = _buildLeaderPredictionBacktest(
      dailyHistory: dailyHistory,
      btcDailyHistory: btcDailyHistory,
      lookbackDays: lookbackDays,
    );
    final payload = {
      'updatedAt': DateTime.now().toIso8601String(),
      'lookbackDays': lookbackDays,
      'summary': backtest['summary'],
      'benchmarks': backtest['benchmarks'],
      'liveSummary': liveSummary,
      'records': records.take(240).toList(),
      'backtestRecords': (backtest['records'] as List<dynamic>? ?? const [])
          .take(120)
          .toList(),
    };

    await _writeJsonFile(path, {
      'updatedAt': payload['updatedAt'],
      'liveSummary': liveSummary,
      'records': records.take(240).toList(),
    });
    await _writeJsonFile(statsPath, payload);
    return payload;
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
      final signalType = record['signalType']?.toString() ?? '';
      if (!_trackedPredictionSignalTypes.contains(signalType)) {
        continue;
      }
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
      final signalType = record['signalType']?.toString() ?? '';
      if (!_trackedPredictionSignalTypes.contains(signalType)) {
        record['status'] = record['status']?.toString() ?? 'watch_only';
        continue;
      }
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

  Future<PushDeliveryResult> publishLeaderPrediction({
    required LeaderPredictionResult result,
    PushProvider provider = PushProvider.auto,
    String? feishuWebhookUrl,
    String? server,
    String? topic,
    bool dedupe = false,
    String statePath = defaultPushStatePath,
    Duration dedupeWindow = const Duration(hours: 6),
    String dedupeKey = 'leader_prediction',
  }) async {
    final regimeLabel = _leaderPredictionRegimeLabel(result.regimeStatus);
    if (result.top3.isEmpty || result.regimeStatus != 'recommend') {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: provider.name,
        status: 'skipped_no_actionable',
        message: '当前状态为$regimeLabel，仅记录领涨预测，不发送飞书',
        recordedAt: DateTime.now(),
      );
    }

    final body = _buildLeaderPredictionPushBody(result: result);
    return publishTextMessage(
      provider: provider,
      feishuWebhookUrl: feishuWebhookUrl,
      server: server,
      topic: topic,
      body: body,
      title: 'Binance Leader Prediction',
      dedupe: dedupe,
      statePath: statePath,
      dedupeWindow: dedupeWindow,
      dedupeKey: dedupeKey,
      successMessage: '已推送下一根日线领涨预测',
    );
  }

  Future<PushDeliveryResult> publishStartupScan({
    required StartupScanReport report,
    required StartupScanPolicy policy,
    StartupPolicySelection? policySelection,
    List<StartupScanCandidate>? actionableCandidates,
    List<StartupScanCandidate> observationCandidates = const [],
    MarketBottomAlert? marketBottomAlert,
    MarketBottomPolicy marketBottomPolicy = MarketBottomPolicy.defaultPolicy,
    List<MarketBottomCandidate>? actionableBottomCandidates,
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
    final observations =
        observationCandidates.take(policy.maxObservationCandidates).toList();
    final actionableBottom = (marketBottomAlert != null &&
            marketBottomAlert.shouldNotify)
        ? (actionableBottomCandidates ?? marketBottomAlert.actionableCandidates)
            .take(marketBottomPolicy.maxPushCandidates)
            .toList()
        : const <MarketBottomCandidate>[];
    if (actionable.isEmpty &&
        observations.isEmpty &&
        actionableBottom.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: provider.name,
        status: 'skipped_no_actionable',
        message: '当前没有满足全市场启动观察、正式买入或恐慌见底阈值的信号，不推送',
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

    final digest = _buildStartupPushDigest(
      startupCandidates: actionable,
      observationCandidates: observations,
      marketBottomCandidates: actionableBottom,
    );
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
      policySelection: policySelection,
      actionable: actionable,
      observations: observations,
      marketBottomAlert: marketBottomAlert,
      marketBottomPolicy: marketBottomPolicy,
      actionableBottom: actionableBottom,
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
      message: _buildStartupPushMessage(
        provider: resolvedProvider,
        hasObservation: observations.isNotEmpty,
        hasStartup: actionable.isNotEmpty,
        hasMarketBottom: actionableBottom.isNotEmpty,
      ),
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

  Future<PushDeliveryResult> publishTextMessage({
    PushProvider provider = PushProvider.auto,
    String? feishuWebhookUrl,
    String? server,
    String? topic,
    required String body,
    String title = 'Binance Analyzer',
    bool dedupe = false,
    String statePath = defaultPushStatePath,
    Duration dedupeWindow = const Duration(hours: 6),
    String dedupeKey = 'text_message',
    String successMessage = '已发送文本消息',
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
        message: '未配置飞书 webhook 或 ntfy topic，无法发送消息',
        recordedAt: DateTime.now(),
      );
    }

    final trimmedBody = body.trim();
    if (trimmedBody.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: resolvedProvider.name,
        status: 'skipped_empty',
        message: '消息内容为空，已跳过',
        recordedAt: DateTime.now(),
      );
    }

    final providerName = resolvedProvider.name;
    final digest = '$dedupeKey|$trimmedBody';
    final duplicate = await _checkDuplicatePush(
      digest: digest,
      dedupe: dedupe,
      statePath: statePath,
      dedupeWindow: dedupeWindow,
      provider: providerName,
    );
    if (duplicate != null) {
      return duplicate;
    }

    final now = DateTime.now();
    switch (resolvedProvider) {
      case PushProvider.feishu:
        final resolvedWebhook = feishuWebhookUrl?.trim() ?? '';
        await _sendTextToFeishu(
          webhookUrl: resolvedWebhook,
          body: trimmedBody,
        );
        await _recordPushState(
          digest: digest,
          provider: providerName,
          statePath: statePath,
          recordedAt: now,
          target: resolvedWebhook,
        );
        return PushDeliveryResult(
          attempted: true,
          sent: true,
          provider: providerName,
          status: 'sent',
          message: successMessage,
          digest: digest,
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
          body: trimmedBody,
          title: title,
        );
        await _recordPushState(
          digest: digest,
          provider: providerName,
          statePath: statePath,
          recordedAt: now,
          target: '$resolvedServer/$trimmedTopic',
        );
        return PushDeliveryResult(
          attempted: true,
          sent: true,
          provider: providerName,
          status: 'sent',
          message: successMessage,
          digest: digest,
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

  Future<Map<String, dynamic>> loadClientSignalActionLog({
    String path = defaultClientSignalActionLogPath,
    int limit = 200,
  }) async {
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final summary = existing['summary'] is Map
        ? Map<String, dynamic>.from(existing['summary'] as Map)
        : _buildClientSignalActionSummary(records);
    return {
      'updatedAt': existing['updatedAt'] ?? DateTime.now().toIso8601String(),
      'summary': summary,
      'records': records.take(limit).toList(),
    };
  }

  Future<Map<String, dynamic>> loadClientExecutionLog({
    String path = defaultClientExecutionCyclePath,
    int limit = 200,
  }) async {
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final summary = existing['summary'] is Map
        ? Map<String, dynamic>.from(existing['summary'] as Map)
        : _buildClientExecutionSummary(records);
    return {
      'updatedAt': existing['updatedAt'] ?? DateTime.now().toIso8601String(),
      'summary': summary,
      'records': records.take(limit).toList(),
    };
  }

  Future<Map<String, dynamic>> recordClientSignalAction({
    String path = defaultClientSignalActionLogPath,
    String executionPath = defaultClientExecutionCyclePath,
    required String signalId,
    required String symbol,
    required String signalType,
    required String signalSource,
    required String actionType,
    double price = 0,
    String timingLabel = '',
    String timingReason = '',
    double totalScore = 0,
    double entryScore = 0,
    String note = '',
    String client = 'app',
  }) async {
    final normalizedSignalId = signalId.trim();
    final normalizedSymbol = _normalizeActionSymbol(symbol);
    final normalizedSignalType = signalType.trim().toLowerCase();
    final normalizedSignalSource = signalSource.trim().isEmpty
        ? 'feishu'
        : signalSource.trim().toLowerCase();
    final normalizedActionType = actionType.trim().toLowerCase();
    final now = DateTime.now();
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    for (final record in records) {
      final existingSignalId = record['signalId']?.toString().trim() ?? '';
      final existingActionType =
          record['actionType']?.toString().trim().toLowerCase() ?? '';
      if (existingSignalId == normalizedSignalId &&
          existingActionType == normalizedActionType) {
        final summary = _buildClientSignalActionSummary(records);
        return {
          'created': false,
          'status': 'duplicate',
          'message': '这条信号动作已经记录过了',
          'record': record,
          'summary': summary,
          'updatedAt': existing['updatedAt'] ?? now.toIso8601String(),
        };
      }
    }

    final record = <String, dynamic>{
      'id': '$normalizedSignalId|$normalizedActionType',
      'signalId': normalizedSignalId,
      'symbol': normalizedSymbol,
      'signalType': normalizedSignalType,
      'signalSource': normalizedSignalSource,
      'actionType': normalizedActionType,
      'actionLabel': _clientActionLabel(normalizedActionType),
      'price': price,
      'timingLabel': timingLabel.trim(),
      'timingReason': timingReason.trim(),
      'totalScore': totalScore,
      'entryScore': entryScore,
      'note': note.trim(),
      'client': client.trim().isEmpty ? 'app' : client.trim(),
      'recordedAt': now.toIso8601String(),
    };
    records.insert(0, record);

    final payload = {
      'updatedAt': now.toIso8601String(),
      'summary': _buildClientSignalActionSummary(records),
      'records': records.take(500).toList(),
    };
    await _writeJsonFile(path, payload);
    final executionPayload = await _syncClientExecutionCycles(
      records: records,
      path: executionPath,
    );

    return {
      'created': true,
      'status': 'created',
      'message': '已记录客户端信号动作',
      'record': record,
      'summary': payload['summary'],
      'executionSummary': executionPayload['summary'],
      'executionPath': executionPath,
      'updatedAt': payload['updatedAt'],
    };
  }

  Future<Map<String, dynamic>> _syncClientExecutionCycles({
    required List<Map<String, dynamic>> records,
    required String path,
  }) async {
    final ordered = [...records]..sort((a, b) {
        final aAt = DateTime.tryParse(a['recordedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = DateTime.tryParse(b['recordedAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });

    final cycles = <Map<String, dynamic>>[];
    final openBySymbol = <String, Map<String, dynamic>>{};
    var ignoredOpenSignals = 0;
    var unmatchedCloseSignals = 0;

    for (final record in ordered) {
      final actionType =
          record['actionType']?.toString().trim().toLowerCase() ?? '';
      final signalType =
          record['signalType']?.toString().trim().toLowerCase() ?? '';
      final symbol = _normalizeActionSymbol(record['symbol']?.toString() ?? '');
      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');
      final price = _asDouble(record['price']);
      final signalId = record['signalId']?.toString().trim() ?? '';
      final signalSource =
          record['signalSource']?.toString().trim().toLowerCase() ?? '';
      if (symbol.isEmpty || recordedAt == null || price <= 0) {
        continue;
      }

      if (signalType == 'buy' && actionType == 'confirm') {
        if (openBySymbol.containsKey(symbol)) {
          ignoredOpenSignals += 1;
          continue;
        }
        final cycle = <String, dynamic>{
          'id': '$symbol|${recordedAt.toIso8601String()}',
          'symbol': symbol,
          'status': ClientExecutionCycleStatus.open,
          'signalSource': signalSource,
          'entrySignalId': signalId,
          'entryActionType': actionType,
          'entrySignalType': signalType,
          'entryPrice': price,
          'openedAt': recordedAt.toIso8601String(),
          'entryTimingLabel': record['timingLabel']?.toString() ?? '',
          'entryTimingReason': record['timingReason']?.toString() ?? '',
          'entryTotalScore': _asDouble(record['totalScore']),
          'entryScore': _asDouble(record['entryScore']),
          'entryNote': record['note']?.toString() ?? '',
        };
        openBySymbol[symbol] = cycle;
        cycles.add(cycle);
        continue;
      }

      if (signalType == 'sell' && actionType == 'cancel') {
        final openCycle = openBySymbol[symbol];
        if (openCycle == null) {
          unmatchedCloseSignals += 1;
          continue;
        }

        final entryPrice = _asDouble(openCycle['entryPrice']);
        final returnPercent =
            entryPrice <= 0 ? 0.0 : ((price - entryPrice) / entryPrice) * 100;
        openCycle.addAll({
          'status': ClientExecutionCycleStatus.closed,
          'exitSignalId': signalId,
          'exitActionType': actionType,
          'exitSignalType': signalType,
          'exitPrice': price,
          'closedAt': recordedAt.toIso8601String(),
          'exitTimingLabel': record['timingLabel']?.toString() ?? '',
          'exitTimingReason': record['timingReason']?.toString() ?? '',
          'exitTotalScore': _asDouble(record['totalScore']),
          'exitScore': _asDouble(record['entryScore']),
          'exitNote': record['note']?.toString() ?? '',
          'holdingHours': recordedAt
                  .difference(
                    DateTime.tryParse(
                            openCycle['openedAt']?.toString() ?? '') ??
                        recordedAt,
                  )
                  .inMinutes /
              Duration.minutesPerHour,
          'realizedReturnPercent': returnPercent,
          'isWin': returnPercent > 0,
        });
        openBySymbol.remove(symbol);
      }
    }

    final payload = {
      'updatedAt': DateTime.now().toIso8601String(),
      'summary': _buildClientExecutionSummary(
        cycles,
        ignoredOpenSignals: ignoredOpenSignals,
        unmatchedCloseSignals: unmatchedCloseSignals,
      ),
      'records': cycles.reversed.take(500).toList(),
    };
    await _writeJsonFile(path, payload);
    return payload;
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
    StartupPolicySelection? policySelection,
    required List<StartupScanCandidate> actionable,
    List<StartupScanCandidate> observations = const [],
    MarketBottomAlert? marketBottomAlert,
    MarketBottomPolicy marketBottomPolicy = MarketBottomPolicy.defaultPolicy,
    List<MarketBottomCandidate> actionableBottom = const [],
  }) {
    final buffer = StringBuffer()..writeln('Binance 全市场机会提醒');

    if (observations.isNotEmpty || actionable.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('启动预警:')
        ..writeln(
            '范围: ${report.analyzedSymbols}/${report.universeSize} 个 USDT 现货币种')
        ..writeln('策略: ${report.strategyLabel}')
        ..writeln('策略来源: ${policySelection?.summary ?? '默认策略'}')
        ..writeln(
          '市场过滤: ${report.marketRegime.status} | ${report.marketRegime.reason}',
        )
        ..writeln(
          '阈值: 观察>=${(policy.minWatchScore * 100).round()} '
          '| 正式>=${(policy.minScore * 100).round()} '
          '| 量比>=${policy.minVolumeRatio.toStringAsFixed(2)}x',
        );

      if (observations.isNotEmpty) {
        buffer.writeln('观察提醒:');
        for (final candidate in observations) {
          buffer.writeln(
            '${candidate.symbol} 观察参考 ${candidate.currentPrice.toStringAsFixed(6)} '
            '| 预备 ${(candidate.setupScore * 100).round()}分 '
            '| 确认 ${(candidate.confirmationScore * 100).round()}分 '
            '| ${candidate.reason}',
          );
        }
      }

      if (actionable.isNotEmpty) {
        buffer.writeln('正式买入:');
        for (final candidate in actionable) {
          buffer.writeln(
            '${candidate.symbol} 入场参考 ${candidate.currentPrice.toStringAsFixed(6)} '
            '| 预备 ${(candidate.setupScore * 100).round()}分 '
            '| 确认 ${(candidate.confirmationScore * 100).round()}分 '
            '| ${candidate.reason}',
          );
        }
      }

      if (report.candidates.isNotEmpty) {
        buffer
          ..writeln('')
          ..writeln('启动观察名单:');
        for (final candidate in report.candidates.take(5)) {
          buffer.writeln(
            '${candidate.symbol} ${(candidate.score * 100).round()}分 '
            '| 量比 ${candidate.volumeRatio.toStringAsFixed(2)}x '
            '| 距20日突破位 ${candidate.dailyBreakoutDistance >= 0 ? '+' : ''}${candidate.dailyBreakoutDistance.toStringAsFixed(2)}%',
          );
        }
      }
    }

    if (marketBottomAlert != null) {
      buffer
        ..writeln('')
        ..writeln('恐慌见底监控:')
        ..writeln('策略: ${marketBottomAlert.strategyLabel}')
        ..writeln(
          '警报分 ${(marketBottomAlert.alertScore * 100).round()} '
          '| 红盘占比 ${(marketBottomAlert.redBreadth * 100).round()}% '
          '| 大跌占比 ${(marketBottomAlert.downBreadth * 100).round()}% '
          '| 近低位占比 ${(marketBottomAlert.nearLowBreadth * 100).round()}% '
          '| 反弹确认 ${(marketBottomAlert.reboundBreadth * 100).round()}%',
        )
        ..writeln(
          '阈值: ${marketBottomPolicy.summary}',
        )
        ..writeln(
          '均值: 24h ${marketBottomAlert.avg24hChange >= 0 ? '+' : ''}${marketBottomAlert.avg24hChange.toStringAsFixed(1)}% '
          '| 7d ${marketBottomAlert.avg7dChange >= 0 ? '+' : ''}${marketBottomAlert.avg7dChange.toStringAsFixed(1)}%',
        )
        ..writeln('结论: ${marketBottomAlert.notes}');

      if (actionableBottom.isNotEmpty) {
        buffer.writeln('抄底观察:');
        for (final candidate in actionableBottom) {
          buffer.writeln(
            '${candidate.symbol} 参考 ${candidate.currentPrice.toStringAsFixed(6)} '
            '| ${(candidate.score * 100).round()}分 '
            '| ${candidate.reason}',
          );
        }
      } else if (marketBottomAlert.candidates.isNotEmpty) {
        buffer.writeln('底部观察名单:');
        for (final candidate in marketBottomAlert.candidates.take(5)) {
          buffer.writeln(
            '${candidate.symbol} ${(candidate.score * 100).round()}分 '
            '| 12h反弹 ${candidate.bounceFrom12hLow.toStringAsFixed(1)}% '
            '| 距45日低点 ${candidate.distanceTo45dLow.toStringAsFixed(1)}%',
          );
        }
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

  String _buildStartupPushDigest({
    required List<StartupScanCandidate> startupCandidates,
    required List<StartupScanCandidate> observationCandidates,
    required List<MarketBottomCandidate> marketBottomCandidates,
  }) {
    final parts = <String>[
      ...observationCandidates.map((item) => 'watch:${item.symbol}'),
      ...startupCandidates.map((item) => 'startup:${item.symbol}'),
      ...marketBottomCandidates.map((item) => 'bottom:${item.symbol}'),
    ];
    return parts.join('|');
  }

  String _buildStartupPushMessage({
    required PushProvider provider,
    required bool hasObservation,
    required bool hasStartup,
    required bool hasMarketBottom,
  }) {
    final target = provider == PushProvider.feishu ? '飞书' : 'ntfy';
    if (hasObservation && hasStartup && hasMarketBottom) {
      return '已推送观察提醒、正式买入和恐慌见底信号到$target';
    }
    if (hasObservation && hasStartup) {
      return '已推送观察提醒和正式买入信号到$target';
    }
    if (hasStartup && hasMarketBottom) {
      return '已推送全市场正式买入和恐慌见底信号到$target';
    }
    if (hasObservation && hasMarketBottom) {
      return '已推送观察提醒和恐慌见底信号到$target';
    }
    if (hasObservation) {
      return '已推送全市场启动观察提醒到$target';
    }
    if (hasMarketBottom) {
      return '已推送全市场恐慌见底信号到$target';
    }
    return '已推送全市场正式买入信号到$target';
  }

  Future<void> _appendPredictionLogEntries({
    required String path,
    List<StartupScanCandidate> observationCandidates = const [],
    List<StartupScanCandidate> startupCandidates = const [],
    List<MarketBottomCandidate> marketBottomCandidates = const [],
    required DateTime recordedAt,
    required String pushProvider,
    required StartupPolicySelection startupPolicySelection,
  }) async {
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    for (final candidate in observationCandidates) {
      records.insert(0, {
        'id':
            '${recordedAt.toIso8601String()}|startup_watch|${candidate.symbol}',
        'recordedAt': recordedAt.toIso8601String(),
        'status': 'watch_only',
        'signalType': 'startup_watch',
        'signalLabel': '启动观察',
        'pushProvider': pushProvider,
        'startupPolicySource': startupPolicySelection.source,
        'startupPolicySummary': startupPolicySelection.summary,
        'startupPolicyLabel': startupPolicySelection.policy.label,
        'startupPolicyRoundId': startupPolicySelection.roundId,
        'startupPolicyRoundLabel': startupPolicySelection.roundLabel,
        'startupPolicyWindowDays': startupPolicySelection.windowDays,
        'startupPolicyMeetsStabilityGate':
            startupPolicySelection.meetsStabilityGate,
        'startupPolicyReportPath': startupPolicySelection.reportPath,
        'symbol': candidate.symbol,
        'entryPrice': candidate.currentPrice,
        'score': candidate.score,
        'setupScore': candidate.setupScore,
        'confirmationScore': candidate.confirmationScore,
        'volumeRatio': candidate.volumeRatio,
        'dailyBreakoutDistance': candidate.dailyBreakoutDistance,
        'hourlyBreakoutDistance': candidate.hourlyBreakoutDistance,
        'sevenDayMomentum': candidate.sevenDayMomentum,
        'thirtyDayMomentum': candidate.thirtyDayMomentum,
        'reason': candidate.reason,
      });
    }

    for (final candidate in startupCandidates) {
      records.insert(0, {
        'id': '${recordedAt.toIso8601String()}|startup_buy|${candidate.symbol}',
        'recordedAt': recordedAt.toIso8601String(),
        'status': 'pending',
        'signalType': 'startup_buy',
        'signalLabel': '全市场启动',
        'pushProvider': pushProvider,
        'startupPolicySource': startupPolicySelection.source,
        'startupPolicySummary': startupPolicySelection.summary,
        'startupPolicyLabel': startupPolicySelection.policy.label,
        'startupPolicyRoundId': startupPolicySelection.roundId,
        'startupPolicyRoundLabel': startupPolicySelection.roundLabel,
        'startupPolicyWindowDays': startupPolicySelection.windowDays,
        'startupPolicyMeetsStabilityGate':
            startupPolicySelection.meetsStabilityGate,
        'startupPolicyReportPath': startupPolicySelection.reportPath,
        'symbol': candidate.symbol,
        'entryPrice': candidate.currentPrice,
        'score': candidate.score,
        'setupScore': candidate.setupScore,
        'confirmationScore': candidate.confirmationScore,
        'volumeRatio': candidate.volumeRatio,
        'dailyBreakoutDistance': candidate.dailyBreakoutDistance,
        'hourlyBreakoutDistance': candidate.hourlyBreakoutDistance,
        'sevenDayMomentum': candidate.sevenDayMomentum,
        'thirtyDayMomentum': candidate.thirtyDayMomentum,
        'reason': candidate.reason,
      });
    }

    for (final candidate in marketBottomCandidates) {
      records.insert(0, {
        'id':
            '${recordedAt.toIso8601String()}|market_bottom_buy|${candidate.symbol}',
        'recordedAt': recordedAt.toIso8601String(),
        'status': 'pending',
        'signalType': 'market_bottom_buy',
        'signalLabel': '恐慌见底',
        'pushProvider': pushProvider,
        'symbol': candidate.symbol,
        'entryPrice': candidate.currentPrice,
        'score': candidate.score,
        'volumeRatio': candidate.volumeRatio,
        'drawdownFrom30dHigh': candidate.drawdownFrom30dHigh,
        'distanceTo45dLow': candidate.distanceTo45dLow,
        'bounceFrom12hLow': candidate.bounceFrom12hLow,
        'sevenDayChange': candidate.sevenDayChange,
        'thirtyDayChange': candidate.thirtyDayChange,
        'reason': candidate.reason,
      });
    }

    await _writeJsonFile(path, {
      'updatedAt': DateTime.now().toIso8601String(),
      'evaluationHours': defaultStartupPredictionEvaluationHours,
      'records': records.take(300).toList(),
    });
  }

  Future<List<T>> _filterPredictionCandidatesByCooldown<T>({
    required String path,
    required List<T> candidates,
    required int cooldownHours,
    required Set<String> signalTypes,
    required String Function(T candidate) symbolOf,
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
      final signalType = record['signalType']?.toString() ?? '';
      if (!signalTypes.contains(signalType)) continue;
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

    return candidates.where((candidate) {
      return !blocked.contains(symbolOf(candidate).trim().toUpperCase());
    }).toList();
  }

  Map<String, dynamic> _buildStartupPredictionSummary(
    List<Map<String, dynamic>> records,
  ) {
    final trackedRecords = records.where((record) {
      final signalType = record['signalType']?.toString() ?? '';
      return _trackedPredictionSignalTypes.contains(signalType);
    }).toList();
    final watchSignals = records
        .where((record) => record['signalType']?.toString() == 'startup_watch')
        .length;
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
    final bySignalType = <String, List<Map<String, dynamic>>>{};
    final byStartupPolicy = <String, List<Map<String, dynamic>>>{};

    for (final record in trackedRecords) {
      final symbol = (record['symbol']?.toString() ?? '').toUpperCase();
      if (symbol.isNotEmpty) {
        bySymbol.putIfAbsent(symbol, () => []).add(record);
      }
      final signalType = record['signalType']?.toString() ?? 'unknown';
      bySignalType.putIfAbsent(signalType, () => []).add(record);
      final policySummary =
          record['startupPolicySummary']?.toString().trim() ?? '';
      if (policySummary.isNotEmpty) {
        byStartupPolicy.putIfAbsent(policySummary, () => []).add(record);
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

    final bySignalTypeSummary = bySignalType.entries.map((entry) {
      final typeRecords = entry.value;
      var typeSettled = 0;
      var typeWins = 0;
      var typeReturn = 0.0;
      DateTime? latestAt;

      for (final record in typeRecords) {
        final recordedAt =
            DateTime.tryParse(record['recordedAt']?.toString() ?? '');
        if (recordedAt != null &&
            (latestAt == null || recordedAt.isAfter(latestAt))) {
          latestAt = recordedAt;
        }
        if ((record['status']?.toString() ?? 'pending') != 'settled') continue;
        typeSettled += 1;
        if (record['isWin'] == true) {
          typeWins += 1;
        }
        typeReturn += _asDouble(record['returnPercent']);
      }

      return {
        'signalType': entry.key,
        'total': typeRecords.length,
        'settled': typeSettled,
        'pending': typeRecords.length - typeSettled,
        'wins': typeWins,
        'winRate': typeSettled == 0 ? 0.0 : typeWins / typeSettled,
        'avgReturnPercent': typeSettled == 0 ? 0.0 : typeReturn / typeSettled,
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

    final byStartupPolicySummary = byStartupPolicy.entries.map((entry) {
      final policyRecords = entry.value;
      var policySettled = 0;
      var policyWins = 0;
      var policyReturn = 0.0;
      DateTime? latestAt;

      for (final record in policyRecords) {
        final recordedAt =
            DateTime.tryParse(record['recordedAt']?.toString() ?? '');
        if (recordedAt != null &&
            (latestAt == null || recordedAt.isAfter(latestAt))) {
          latestAt = recordedAt;
        }
        if ((record['status']?.toString() ?? 'pending') != 'settled') continue;
        policySettled += 1;
        if (record['isWin'] == true) {
          policyWins += 1;
        }
        policyReturn += _asDouble(record['returnPercent']);
      }

      return {
        'policySummary': entry.key,
        'total': policyRecords.length,
        'settled': policySettled,
        'pending': policyRecords.length - policySettled,
        'wins': policyWins,
        'winRate': policySettled == 0 ? 0.0 : policyWins / policySettled,
        'avgReturnPercent':
            policySettled == 0 ? 0.0 : policyReturn / policySettled,
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
      'totalPredictions': trackedRecords.length,
      'watchSignals': watchSignals,
      'pending': trackedRecords.length - settled,
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
      'bySignalType': bySignalTypeSummary,
      'byStartupPolicy': byStartupPolicySummary,
    };
  }

  Map<String, dynamic> _buildLeaderPredictionReportPayload({
    required DateTime generatedAt,
    required LeaderPredictionResult result,
    required int lookbackDays,
    required List<String> activeSymbols,
  }) {
    final top1 = result.top3.isEmpty ? null : result.top3.first;
    return {
      'generatedAt': generatedAt.toIso8601String(),
      'mode': 'leader_prediction',
      'predictionWindow': 'next_binance_daily_candle',
      'lookbackDays': lookbackDays,
      'activeSymbols': activeSymbols,
      'regimeStatus': result.regimeStatus,
      'regimeLabel': _leaderPredictionRegimeLabel(result.regimeStatus),
      'regimeReason': result.regimeReason,
      'marketBreadth': result.marketBreadth,
      'medianSevenDayReturn': result.medianSevenDayReturn,
      'btcDistanceToSma20': result.btcDistanceToSma20,
      'summary': result.summary,
      'top1': top1 == null
          ? null
          : {
              'symbol': top1.displayName,
              'score': top1.score,
              'recommendation': top1.recommendation,
              'price': top1.lastPrice,
              'dayChangePercent': top1.priceChangePercent,
              'thirtyDayChange': top1.thirtyDayChange,
              'sevenDayChange': top1.sevenDayChange,
              'timingLabel': top1.timingLabel,
              'timingReason': top1.timingReason,
              'reason': top1.reason,
              'componentScores': _top1ComponentScoresFromResult(result.summary),
            },
      'top3': result.top3
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
    };
  }

  String _buildLeaderPredictionPushBody({
    required LeaderPredictionResult result,
  }) {
    final buffer = StringBuffer()
      ..writeln('Binance 下一根日线领涨预测')
      ..writeln('状态: ${_leaderPredictionRegimeLabel(result.regimeStatus)}')
      ..writeln('结算窗口: 下一根币安日线（UTC 00:00）')
      ..writeln('市场判断: ${result.regimeReason}');

    final top1 = result.top3.isEmpty ? null : result.top3.first;
    if (top1 != null) {
      buffer
        ..writeln('')
        ..writeln(
          'Top1: ${top1.displayName} | ${(top1.score * 100).round()}分 | ${top1.recommendation}',
        )
        ..writeln(
          'Top3: ${result.top3.map((item) => item.displayName).join(', ')}',
        )
        ..writeln('核心原因:');
      for (final line in _leaderPredictionReasonLines(top1, result.summary)) {
        buffer.writeln(line);
      }
    }

    return buffer.toString().trim();
  }

  List<String> _leaderPredictionReasonLines(
    CoinData top1,
    Map<String, dynamic> summary,
  ) {
    final components = _top1ComponentScoresFromResult(summary);
    final momentum = ((_asDouble(components['momentum'])) * 100).round();
    final trend = ((_asDouble(components['trend'])) * 100).round();
    final lowVol = ((_asDouble(components['lowVol'])) * 100).round();
    final volumeHealth =
        ((_asDouble(components['volumeHealth'])) * 100).round();
    final ret14 = _asDouble(components['ret14']);
    final ret7 = _asDouble(components['ret7']);
    final volumeRatio = _asDouble(components['volumeRatio']);
    final distanceToHigh10 = _asDouble(components['distanceToHigh10']);
    return [
      '1. ${top1.displayName} 的 14d/7d 相对动量靠前，动量分 $momentum，14d ${ret14 >= 0 ? '+' : ''}${ret14.toStringAsFixed(1)}%，7d ${ret7 >= 0 ? '+' : ''}${ret7.toStringAsFixed(1)}%。',
      '2. 趋势确认分 $trend，当前结构配合 ${top1.timingLabel}，${top1.timingReason}',
      '3. 风险过滤后仍保留优势，低波动 $lowVol，量能健康 $volumeHealth，3d/10d 量比 ${volumeRatio.toStringAsFixed(2)}x，距 10d 高点 ${distanceToHigh10.toStringAsFixed(2)}%。',
    ];
  }

  String _leaderPredictionRegimeLabel(String status) {
    switch (status) {
      case 'recommend':
        return '可推荐';
      case 'watch_only':
        return '仅观察';
      default:
        return '不出手';
    }
  }

  Map<String, dynamic> _top1ComponentScoresFromResult(
    Map<String, dynamic> summary,
  ) {
    final raw = summary['top1ComponentScores'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return <String, dynamic>{};
  }

  Future<void> _upsertLeaderPredictionRecord({
    required String path,
    required DateTime generatedAt,
    required LeaderPredictionResult result,
  }) async {
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final targetDate = _leaderPredictionTargetDate(generatedAt);
    final id = _leaderPredictionRecordId(targetDate);
    records.removeWhere((record) =>
        record['id']?.toString() == id &&
        record['status']?.toString() != 'settled');

    final top1 = result.top3.isEmpty ? null : result.top3.first;
    final status =
        result.regimeStatus == 'recommend' ? 'pending' : 'suppressed';
    records.insert(0, {
      'id': id,
      'recordedAt': generatedAt.toIso8601String(),
      'predictionWindow': 'next_binance_daily_candle',
      'signalType': 'leader_prediction',
      'targetCandleAt': targetDate.toIso8601String(),
      'top1Symbol': top1?.displayName,
      'top3Symbols': result.top3.map((item) => item.displayName).toList(),
      'totalScore': top1?.score ?? 0.0,
      'componentScores': _top1ComponentScoresFromResult(result.summary),
      'regimeStatus': result.regimeStatus,
      'regimeLabel': _leaderPredictionRegimeLabel(result.regimeStatus),
      'regimeReason': result.regimeReason,
      'status': status,
      'settledAt': null,
      'actualLeader': null,
      'actualTop3': const <String>[],
      'top1Hit': null,
      'top3Hit': null,
      'predictedCoinReturn': null,
      'leaderReturn': null,
      'excessVsMedian': null,
      'marketBreadth': result.marketBreadth,
      'medianSevenDayReturn': result.medianSevenDayReturn,
      'btcDistanceToSma20': result.btcDistanceToSma20,
    });

    await _writeJsonFile(path, {
      'updatedAt': DateTime.now().toIso8601String(),
      'records': records.take(240).toList(),
    });
  }

  void _settleLeaderPredictionRecords({
    required List<Map<String, dynamic>> records,
    required Map<String, List<Kline>> dailyHistory,
  }) {
    if (records.isEmpty || dailyHistory.isEmpty) return;

    final symbolBars = <String, List<Kline>>{};
    for (final entry in dailyHistory.entries) {
      final normalized = BinanceService.toSymbol(entry.key);
      symbolBars[normalized] = _completeDailyBars(entry.value);
    }

    final actualReturnByDate = <int, Map<String, double>>{};
    for (final entry in symbolBars.entries) {
      final bars = entry.value;
      for (var i = 1; i < bars.length; i += 1) {
        final previous = bars[i - 1];
        final current = bars[i];
        if (previous.close <= 0) continue;
        actualReturnByDate.putIfAbsent(
                current.openTime, () => <String, double>{})[entry.key] =
            ((current.close - previous.close) / previous.close) * 100;
      }
    }

    for (final record in records) {
      final status = record['status']?.toString() ?? '';
      if (status == 'settled') continue;

      final targetDate =
          DateTime.tryParse(record['targetCandleAt']?.toString() ?? '');
      if (targetDate == null) continue;
      final returns = actualReturnByDate[targetDate.millisecondsSinceEpoch];
      if (returns == null || returns.isEmpty) continue;

      final sorted = returns.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final actualLeader = sorted.first.key.replaceAll('USDT', '');
      final actualTop3 = sorted
          .take(3)
          .map((item) => item.key.replaceAll('USDT', ''))
          .toList();
      final predictedTop1 = record['top1Symbol']?.toString();
      final predictedTop3 =
          (record['top3Symbols'] as List<dynamic>? ?? const [])
              .map((item) => item.toString())
              .toList();
      final predictedReturn = predictedTop1 == null
          ? null
          : returns[BinanceService.toSymbol(predictedTop1)];
      final medianReturn = _safeMedian(returns.values.toList());

      record['actualLeader'] = actualLeader;
      record['actualTop3'] = actualTop3;
      record['leaderReturn'] = sorted.first.value;
      record['predictedCoinReturn'] = predictedReturn;
      record['excessVsMedian'] =
          predictedReturn == null ? null : predictedReturn - medianReturn;
      record['settledAt'] = DateTime.now().toIso8601String();

      if (status == 'suppressed') {
        continue;
      }

      record['status'] = 'settled';
      record['top1Hit'] = predictedTop1 == actualLeader;
      record['top3Hit'] = predictedTop3.contains(actualLeader);
    }
  }

  Map<String, dynamic> _buildLeaderPredictionLiveSummary(
    List<Map<String, dynamic>> records,
  ) {
    var settled = 0;
    var pending = 0;
    var suppressed = 0;
    var wins = 0;
    var top3Wins = 0;
    var totalPredictedReturn = 0.0;
    var totalExcess = 0.0;
    DateTime? latestRecordedAt;

    for (final record in records) {
      final status = record['status']?.toString() ?? '';
      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');
      if (recordedAt != null &&
          (latestRecordedAt == null || recordedAt.isAfter(latestRecordedAt))) {
        latestRecordedAt = recordedAt;
      }

      if (status == 'pending') pending += 1;
      if (status == 'suppressed') suppressed += 1;
      if (status != 'settled') continue;
      settled += 1;
      if (record['top1Hit'] == true) wins += 1;
      if (record['top3Hit'] == true) top3Wins += 1;
      totalPredictedReturn += _asDouble(record['predictedCoinReturn']);
      totalExcess += _asDouble(record['excessVsMedian']);
    }

    return {
      'totalRecords': records.length,
      'pending': pending,
      'suppressed': suppressed,
      'settled': settled,
      'top1Wins': wins,
      'top3Wins': top3Wins,
      'top1HitRate': settled == 0 ? 0.0 : wins / settled,
      'top3HitRate': settled == 0 ? 0.0 : top3Wins / settled,
      'avgPredictedReturn': settled == 0 ? 0.0 : totalPredictedReturn / settled,
      'avgExcessVsMedian': settled == 0 ? 0.0 : totalExcess / settled,
      'latestRecordedAt': latestRecordedAt?.toIso8601String(),
    };
  }

  Map<String, dynamic> _buildLeaderPredictionBacktest({
    required Map<String, List<Kline>> dailyHistory,
    required List<Kline> btcDailyHistory,
    required int lookbackDays,
  }) {
    final btcBars = _completeDailyBars(btcDailyHistory);
    if (btcBars.length < 35) {
      return {
        'summary': {
          'windowDays': lookbackDays,
          'totalDays': 0,
          'recommendDays': 0,
          'suppressedDays': 0,
          'suppressRate': 0.0,
          'top1HitRate': 0.0,
          'top3HitRate': 0.0,
          'avgPredictedReturn': 0.0,
          'avgLeaderReturn': 0.0,
          'avgExcessVsMedian': 0.0,
          'recent20Top1HitRate': 0.0,
          'recent20Top3HitRate': 0.0,
          'longestMissStreak': 0,
          'latestTop1': null,
          'latestTop3': const <String>[],
          'currentRegimeStatus': 'stand_aside',
        },
        'benchmarks': const <Map<String, dynamic>>[],
        'records': const <Map<String, dynamic>>[],
      };
    }

    final symbolBars = <String, List<Kline>>{};
    for (final entry in dailyHistory.entries) {
      final normalized = BinanceService.toSymbol(entry.key);
      final bars = _completeDailyBars(entry.value);
      if (bars.length >= 31) {
        symbolBars[normalized] = bars;
      }
    }

    final btcDateSet = btcBars.map((item) => item.openTime).toSet();
    final candidateDates = btcBars
        .skip(30)
        .take(max(0, btcBars.length - 31))
        .map((item) => item.openTime)
        .where(btcDateSet.contains)
        .toList();
    final selectedDates = candidateDates.length <= lookbackDays
        ? candidateDates
        : candidateDates.sublist(candidateDates.length - lookbackDays);

    final modelRecords = <Map<String, dynamic>>[];
    final baselineBuckets = <String, List<Map<String, dynamic>>>{
      'yesterday_leader_continue': [],
      'momentum_7d': [],
      'momentum_14d': [],
      'random': [],
    };
    String? previousActualLeader;

    for (final currentDate in selectedDates) {
      final currentCoins = <CoinData>[];
      final slicedHistory = <String, List<Kline>>{};
      final actualReturns = <String, double>{};
      final nextDate = currentDate + const Duration(days: 1).inMilliseconds;

      for (final entry in symbolBars.entries) {
        final bars = entry.value;
        final upto = _barsUpToDate(bars, currentDate);
        if (upto.length < 30) continue;

        final currentBar = bars.firstWhere(
          (item) => item.openTime == currentDate,
          orElse: () => const Kline(
            openTime: 0,
            open: 0,
            high: 0,
            low: 0,
            close: 0,
            volume: 0,
            closeTime: 0,
          ),
        );
        final nextBar = bars.firstWhere(
          (item) => item.openTime == nextDate,
          orElse: () => const Kline(
            openTime: 0,
            open: 0,
            high: 0,
            low: 0,
            close: 0,
            volume: 0,
            closeTime: 0,
          ),
        );
        if (currentBar.openTime == 0 || nextBar.openTime == 0) continue;

        slicedHistory[entry.key] = upto;
        currentCoins.add(_coinFromBar(entry.key, currentBar));
        if (currentBar.close > 0) {
          actualReturns[entry.key] =
              ((nextBar.close - currentBar.close) / currentBar.close) * 100;
        }
      }

      final btcSlice = _barsUpToDate(btcBars, currentDate);
      if (currentCoins.length < 3 ||
          btcSlice.length < 30 ||
          actualReturns.isEmpty) {
        continue;
      }

      final result = _leaderPrediction.analyze(
        currentCoins: currentCoins,
        dailyHistory: slicedHistory,
        btcDailyHistory: btcSlice,
      );
      final sortedActual = actualReturns.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final actualLeader = sortedActual.first.key.replaceAll('USDT', '');
      final actualTop3 = sortedActual
          .take(3)
          .map((item) => item.key.replaceAll('USDT', ''))
          .toList();
      final medianReturn = _safeMedian(actualReturns.values.toList());
      final top1 = result.top3.isEmpty ? null : result.top3.first.displayName;
      final top3 = result.top3.map((item) => item.displayName).toList();
      final suppressed = result.regimeStatus != 'recommend';
      final predictedReturn =
          top1 == null ? null : actualReturns[BinanceService.toSymbol(top1)];

      modelRecords.add({
        'id': _leaderPredictionRecordId(
          DateTime.fromMillisecondsSinceEpoch(nextDate, isUtc: true),
        ),
        'recordedAt':
            DateTime.fromMillisecondsSinceEpoch(currentDate, isUtc: true)
                .toIso8601String(),
        'predictionWindow': 'next_binance_daily_candle',
        'targetCandleAt':
            DateTime.fromMillisecondsSinceEpoch(nextDate, isUtc: true)
                .toIso8601String(),
        'top1Symbol': top1,
        'top3Symbols': top3,
        'totalScore': result.top3.isEmpty ? 0.0 : result.top3.first.score,
        'componentScores': _top1ComponentScoresFromResult(result.summary),
        'regimeStatus': result.regimeStatus,
        'status': suppressed ? 'suppressed' : 'settled',
        'settledAt': DateTime.fromMillisecondsSinceEpoch(nextDate, isUtc: true)
            .toIso8601String(),
        'actualLeader': actualLeader,
        'actualTop3': actualTop3,
        'top1Hit': !suppressed && top1 == actualLeader,
        'top3Hit': !suppressed && top3.contains(actualLeader),
        'predictedCoinReturn': predictedReturn,
        'leaderReturn': sortedActual.first.value,
        'excessVsMedian':
            predictedReturn == null ? null : predictedReturn - medianReturn,
      });

      final sortedSymbols = actualReturns.keys.toList()..sort();
      final randomSymbol = sortedSymbols.isEmpty
          ? null
          : sortedSymbols[currentDate % sortedSymbols.length]
              .replaceAll('USDT', '');
      baselineBuckets['yesterday_leader_continue']!.add(
        _leaderBenchmarkRecord(
          name: 'yesterday_leader_continue',
          targetDate: nextDate,
          predictedSymbol: previousActualLeader,
          actualLeader: actualLeader,
          actualTop3: actualTop3,
          actualReturns: actualReturns,
          medianReturn: medianReturn,
        ),
      );
      baselineBuckets['momentum_7d']!.add(
        _leaderBenchmarkRecord(
          name: 'momentum_7d',
          targetDate: nextDate,
          predictedSymbol: _pickMomentumLeader(slicedHistory, 7),
          actualLeader: actualLeader,
          actualTop3: actualTop3,
          actualReturns: actualReturns,
          medianReturn: medianReturn,
        ),
      );
      baselineBuckets['momentum_14d']!.add(
        _leaderBenchmarkRecord(
          name: 'momentum_14d',
          targetDate: nextDate,
          predictedSymbol: _pickMomentumLeader(slicedHistory, 14),
          actualLeader: actualLeader,
          actualTop3: actualTop3,
          actualReturns: actualReturns,
          medianReturn: medianReturn,
        ),
      );
      baselineBuckets['random']!.add(
        _leaderBenchmarkRecord(
          name: 'random',
          targetDate: nextDate,
          predictedSymbol: randomSymbol,
          actualLeader: actualLeader,
          actualTop3: actualTop3,
          actualReturns: actualReturns,
          medianReturn: medianReturn,
        ),
      );

      previousActualLeader = actualLeader;
    }

    modelRecords.sort((a, b) => (a['targetCandleAt'] as String)
        .compareTo(b['targetCandleAt'] as String));
    final summary = _summarizeLeaderPredictionRecords(modelRecords);
    final benchmarks = baselineBuckets.entries
        .map((entry) => _summarizeLeaderBenchmark(entry.key, entry.value))
        .toList();

    return {
      'summary': summary,
      'benchmarks': benchmarks,
      'records': modelRecords,
    };
  }

  Map<String, dynamic> _leaderBenchmarkRecord({
    required String name,
    required int targetDate,
    required String? predictedSymbol,
    required String actualLeader,
    required List<String> actualTop3,
    required Map<String, double> actualReturns,
    required double medianReturn,
  }) {
    final predictedReturn = predictedSymbol == null
        ? null
        : actualReturns[BinanceService.toSymbol(predictedSymbol)];
    return {
      'name': name,
      'targetCandleAt':
          DateTime.fromMillisecondsSinceEpoch(targetDate, isUtc: true)
              .toIso8601String(),
      'predictedSymbol': predictedSymbol,
      'actualLeader': actualLeader,
      'top1Hit': predictedSymbol != null && predictedSymbol == actualLeader,
      'top3Hit':
          predictedSymbol != null && actualTop3.contains(predictedSymbol),
      'predictedReturn': predictedReturn,
      'leaderReturn':
          actualReturns[BinanceService.toSymbol(actualLeader)] ?? 0.0,
      'excessVsMedian':
          predictedReturn == null ? null : predictedReturn - medianReturn,
    };
  }

  Map<String, dynamic> _summarizeLeaderPredictionRecords(
    List<Map<String, dynamic>> records,
  ) {
    final settled = records
        .where((record) => record['status']?.toString() == 'settled')
        .toList();
    final suppressed = records.length - settled.length;
    final recent20 =
        settled.length <= 20 ? settled : settled.sublist(settled.length - 20);

    var top1Hits = 0;
    var top3Hits = 0;
    var totalPredictedReturn = 0.0;
    var totalLeaderReturn = 0.0;
    var totalExcess = 0.0;
    var missStreak = 0;
    var longestMissStreak = 0;

    for (final record in settled) {
      if (record['top1Hit'] == true) {
        top1Hits += 1;
        missStreak = 0;
      } else {
        missStreak += 1;
        if (missStreak > longestMissStreak) {
          longestMissStreak = missStreak;
        }
      }
      if (record['top3Hit'] == true) {
        top3Hits += 1;
      }
      totalPredictedReturn += _asDouble(record['predictedCoinReturn']);
      totalLeaderReturn += _asDouble(record['leaderReturn']);
      totalExcess += _asDouble(record['excessVsMedian']);
    }

    var recent20Top1Hits = 0;
    var recent20Top3Hits = 0;
    for (final record in recent20) {
      if (record['top1Hit'] == true) recent20Top1Hits += 1;
      if (record['top3Hit'] == true) recent20Top3Hits += 1;
    }

    final latest = records.isEmpty ? null : records.last;
    return {
      'windowDays': records.length,
      'totalDays': records.length,
      'recommendDays': settled.length,
      'suppressedDays': suppressed,
      'suppressRate': records.isEmpty ? 0.0 : suppressed / records.length,
      'top1HitRate': settled.isEmpty ? 0.0 : top1Hits / settled.length,
      'top3HitRate': settled.isEmpty ? 0.0 : top3Hits / settled.length,
      'avgPredictedReturn':
          settled.isEmpty ? 0.0 : totalPredictedReturn / settled.length,
      'avgLeaderReturn':
          settled.isEmpty ? 0.0 : totalLeaderReturn / settled.length,
      'avgExcessVsMedian': settled.isEmpty ? 0.0 : totalExcess / settled.length,
      'recent20Top1HitRate':
          recent20.isEmpty ? 0.0 : recent20Top1Hits / recent20.length,
      'recent20Top3HitRate':
          recent20.isEmpty ? 0.0 : recent20Top3Hits / recent20.length,
      'longestMissStreak': longestMissStreak,
      'latestTop1': latest?['top1Symbol'],
      'latestTop3': latest?['top3Symbols'] ?? const <String>[],
      'currentRegimeStatus': latest?['regimeStatus'] ?? 'stand_aside',
    };
  }

  Map<String, dynamic> _summarizeLeaderBenchmark(
    String name,
    List<Map<String, dynamic>> records,
  ) {
    if (records.isEmpty) {
      return {
        'name': name,
        'totalDays': 0,
        'top1HitRate': 0.0,
        'top3HitRate': 0.0,
        'avgPredictedReturn': 0.0,
        'avgExcessVsMedian': 0.0,
      };
    }

    var top1Hits = 0;
    var top3Hits = 0;
    var totalPredictedReturn = 0.0;
    var totalExcess = 0.0;
    var validPredictions = 0;

    for (final record in records) {
      if (record['top1Hit'] == true) top1Hits += 1;
      if (record['top3Hit'] == true) top3Hits += 1;
      final predictedReturn = record['predictedReturn'];
      if (predictedReturn != null) {
        validPredictions += 1;
        totalPredictedReturn += _asDouble(predictedReturn);
        totalExcess += _asDouble(record['excessVsMedian']);
      }
    }

    return {
      'name': name,
      'totalDays': records.length,
      'top1HitRate': top1Hits / records.length,
      'top3HitRate': top3Hits / records.length,
      'avgPredictedReturn':
          validPredictions == 0 ? 0.0 : totalPredictedReturn / validPredictions,
      'avgExcessVsMedian':
          validPredictions == 0 ? 0.0 : totalExcess / validPredictions,
    };
  }

  String? _pickMomentumLeader(
    Map<String, List<Kline>> slicedHistory,
    int days,
  ) {
    String? bestSymbol;
    double? bestReturn;
    for (final entry in slicedHistory.entries) {
      final value = _periodReturnFromBars(entry.value, days);
      if (bestReturn == null || value > bestReturn) {
        bestReturn = value;
        bestSymbol = entry.key.replaceAll('USDT', '');
      }
    }
    return bestSymbol;
  }

  List<Kline> _completeDailyBars(List<Kline> bars) {
    if (bars.isEmpty) return const <Kline>[];
    final ordered = [...bars]..sort((a, b) => a.openTime.compareTo(b.openTime));
    final last = ordered.last;
    if (_isCurrentUtcDailyBar(last.openTime)) {
      return ordered.sublist(0, max(0, ordered.length - 1));
    }
    return ordered;
  }

  bool _isCurrentUtcDailyBar(int openTime) {
    final nowUtc = DateTime.now().toUtc();
    final todayUtcStart = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    return openTime >= todayUtcStart.millisecondsSinceEpoch;
  }

  List<Kline> _barsUpToDate(List<Kline> bars, int currentDate) {
    return bars.where((item) => item.openTime <= currentDate).toList();
  }

  CoinData _coinFromBar(String symbol, Kline bar) {
    final priceChange = bar.close - bar.open;
    final priceChangePercent =
        bar.open <= 0 ? 0.0 : ((bar.close - bar.open) / bar.open) * 100;
    return CoinData(
      symbol: symbol,
      lastPrice: bar.close,
      priceChange: priceChange,
      priceChangePercent: priceChangePercent,
      highPrice: bar.high,
      lowPrice: bar.low,
      openPrice: bar.open,
      quoteVolume: bar.quoteVolume,
      volume: bar.volume,
      count: bar.tradeCount,
    );
  }

  double _periodReturnFromBars(List<Kline> bars, int period) {
    if (bars.length <= period) return 0.0;
    final start = bars[bars.length - period - 1].close;
    final end = bars.last.close;
    if (start <= 0) return 0.0;
    return ((end - start) / start) * 100;
  }

  double _safeMedian(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  DateTime _leaderPredictionTargetDate(DateTime recordedAt) {
    final utc = recordedAt.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day)
        .add(const Duration(days: 1));
  }

  String _leaderPredictionRecordId(DateTime targetDateUtc) {
    final value = targetDateUtc.toIso8601String();
    return 'leader_prediction|${value.substring(0, 10)}';
  }

  Future<_StartupStageSelection> _selectStartupSignalStages({
    required String path,
    required StartupScanReport report,
    required StartupScanPolicy policy,
  }) async {
    final existing = await _readJsonFile(path);
    final records = (existing['records'] as List<dynamic>? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final recentBuySymbols = _recentSymbols(
      records,
      signalTypes: const {'startup_buy'},
      withinHours: policy.cooldownHours,
    );
    final recentWatchSymbols = _recentSymbols(
      records,
      signalTypes: const {'startup_watch'},
      withinHours: policy.observationCooldownHours,
    );
    final confirmationSymbols = _recentSymbols(
      records,
      signalTypes: const {'startup_watch'},
      withinHours: policy.confirmationWindowHours,
    );

    final buys = <StartupScanCandidate>[];
    final observations = <StartupScanCandidate>[];
    var observationSuppressedCount = 0;
    var awaitingObservationConfirmationCount = 0;

    for (final candidate in report.candidates) {
      final symbol = candidate.symbol.trim().toUpperCase();
      if (symbol.isEmpty) continue;

      if (candidate.shouldNotify) {
        if (recentBuySymbols.contains(symbol)) {
          continue;
        }
        if (confirmationSymbols.contains(symbol)) {
          buys.add(candidate);
          continue;
        }
        awaitingObservationConfirmationCount += 1;
        if (recentWatchSymbols.contains(symbol)) {
          observationSuppressedCount += 1;
          continue;
        }
        observations.add(candidate);
        continue;
      }

      if (candidate.signalStage == 'watch') {
        if (recentBuySymbols.contains(symbol)) {
          continue;
        }
        if (recentWatchSymbols.contains(symbol)) {
          observationSuppressedCount += 1;
          continue;
        }
        observations.add(candidate);
      }
    }

    return _StartupStageSelection(
      buyCandidates: buys.take(policy.maxPushCandidates).toList(),
      observationCandidates:
          observations.take(policy.maxObservationCandidates).toList(),
      observationSuppressedCount: observationSuppressedCount,
      awaitingObservationConfirmationCount:
          awaitingObservationConfirmationCount,
    );
  }

  Set<String> _recentSymbols(
    List<Map<String, dynamic>> records, {
    required Set<String> signalTypes,
    required int withinHours,
  }) {
    if (withinHours <= 0) return const <String>{};
    final now = DateTime.now();
    final symbols = <String>{};
    for (final record in records) {
      final signalType = record['signalType']?.toString() ?? '';
      if (!signalTypes.contains(signalType)) continue;
      final symbol = (record['symbol']?.toString() ?? '').trim().toUpperCase();
      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');
      if (symbol.isEmpty || recordedAt == null) continue;
      if (now.difference(recordedAt) < Duration(hours: withinHours)) {
        symbols.add(symbol);
      }
    }
    return symbols;
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

  Map<String, dynamic>? _asJsonMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  List<int> _asIntList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((item) => item is num ? item.toInt() : int.tryParse('$item'))
        .whereType<int>()
        .toList();
  }

  List<String> _asStringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList();
  }

  StartupScanPolicy? _policyFromRound(Map<String, dynamic>? round) {
    final policyMap = _asJsonMap(round?['policy']);
    if (policyMap == null) return null;
    return StartupScanPolicy.fromJson(policyMap);
  }

  Map<String, dynamic> _buildClientSignalActionSummary(
    List<Map<String, dynamic>> records,
  ) {
    final byActionType = <String, int>{};
    final bySignalType = <String, int>{};
    final bySymbol = <String, int>{};
    DateTime? latestRecordedAt;

    for (final record in records) {
      final actionType = record['actionType']?.toString().trim().toLowerCase();
      final signalType = record['signalType']?.toString().trim().toLowerCase();
      final symbol = _normalizeActionSymbol(record['symbol']?.toString() ?? '');
      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');

      if (actionType != null && actionType.isNotEmpty) {
        byActionType[actionType] = (byActionType[actionType] ?? 0) + 1;
      }
      if (signalType != null && signalType.isNotEmpty) {
        bySignalType[signalType] = (bySignalType[signalType] ?? 0) + 1;
      }
      if (symbol.isNotEmpty) {
        bySymbol[symbol] = (bySymbol[symbol] ?? 0) + 1;
      }
      if (recordedAt != null &&
          (latestRecordedAt == null || recordedAt.isAfter(latestRecordedAt))) {
        latestRecordedAt = recordedAt;
      }
    }

    List<Map<String, dynamic>> sortedEntries(Map<String, int> source,
        {required String keyName}) {
      final rows = source.entries
          .map((entry) => {
                keyName: entry.key,
                'total': entry.value,
              })
          .toList();
      rows.sort((a, b) {
        final byCount =
            ((b['total'] as num?) ?? 0).compareTo((a['total'] as num?) ?? 0);
        if (byCount != 0) return byCount;
        return (a[keyName] as String).compareTo(b[keyName] as String);
      });
      return rows;
    }

    return {
      'totalRecords': records.length,
      'confirmCount': byActionType['confirm'] ?? 0,
      'cancelCount': byActionType['cancel'] ?? 0,
      'latestRecordedAt': latestRecordedAt?.toIso8601String(),
      'byActionType': sortedEntries(byActionType, keyName: 'actionType'),
      'bySignalType': sortedEntries(bySignalType, keyName: 'signalType'),
      'bySymbol': sortedEntries(bySymbol, keyName: 'symbol'),
    };
  }

  Map<String, dynamic> _buildClientExecutionSummary(
    List<Map<String, dynamic>> records, {
    int ignoredOpenSignals = 0,
    int unmatchedCloseSignals = 0,
  }) {
    var closed = 0;
    var open = 0;
    var wins = 0;
    var losses = 0;
    var totalReturnPercent = 0.0;
    var totalHoldingHours = 0.0;
    DateTime? latestOpenedAt;
    DateTime? latestClosedAt;
    final bySymbol = <String, List<Map<String, dynamic>>>{};
    final bySource = <String, List<Map<String, dynamic>>>{};

    for (final record in records) {
      final status = record['status']?.toString() ?? '';
      final symbol = _normalizeActionSymbol(record['symbol']?.toString() ?? '');
      final source =
          record['signalSource']?.toString().trim().toLowerCase() ?? '';
      final openedAt = DateTime.tryParse(record['openedAt']?.toString() ?? '');
      final closedAt = DateTime.tryParse(record['closedAt']?.toString() ?? '');

      if (openedAt != null &&
          (latestOpenedAt == null || openedAt.isAfter(latestOpenedAt))) {
        latestOpenedAt = openedAt;
      }
      if (closedAt != null &&
          (latestClosedAt == null || closedAt.isAfter(latestClosedAt))) {
        latestClosedAt = closedAt;
      }
      if (symbol.isNotEmpty) {
        bySymbol.putIfAbsent(symbol, () => []).add(record);
      }
      if (source.isNotEmpty) {
        bySource.putIfAbsent(source, () => []).add(record);
      }

      if (status == ClientExecutionCycleStatus.closed) {
        closed += 1;
        final isWin = record['isWin'] == true;
        if (isWin) {
          wins += 1;
        } else {
          losses += 1;
        }
        totalReturnPercent += _asDouble(record['realizedReturnPercent']);
        totalHoldingHours += _asDouble(record['holdingHours']);
      } else if (status == ClientExecutionCycleStatus.open) {
        open += 1;
      }
    }

    List<Map<String, dynamic>> summarizeBuckets(
      Map<String, List<Map<String, dynamic>>> source, {
      required String keyName,
    }) {
      final rows = source.entries.map((entry) {
        var settled = 0;
        var bucketWins = 0;
        var bucketReturn = 0.0;
        for (final record in entry.value) {
          if ((record['status']?.toString() ?? '') !=
              ClientExecutionCycleStatus.closed) {
            continue;
          }
          settled += 1;
          if (record['isWin'] == true) {
            bucketWins += 1;
          }
          bucketReturn += _asDouble(record['realizedReturnPercent']);
        }
        return {
          keyName: entry.key,
          'total': entry.value.length,
          'closed': settled,
          'open': entry.value.length - settled,
          'wins': bucketWins,
          'winRate': settled == 0 ? 0.0 : bucketWins / settled,
          'avgReturnPercent': settled == 0 ? 0.0 : bucketReturn / settled,
        };
      }).toList();
      rows.sort((a, b) {
        final byTotal =
            ((b['total'] as num?) ?? 0).compareTo((a['total'] as num?) ?? 0);
        if (byTotal != 0) return byTotal;
        return ((b['winRate'] as num?) ?? 0)
            .compareTo((a['winRate'] as num?) ?? 0);
      });
      return rows;
    }

    return {
      'totalCycles': records.length,
      'openCycles': open,
      'closedCycles': closed,
      'wins': wins,
      'losses': losses,
      'winRate': closed == 0 ? 0.0 : wins / closed,
      'avgReturnPercent': closed == 0 ? 0.0 : totalReturnPercent / closed,
      'avgHoldingHours': closed == 0 ? 0.0 : totalHoldingHours / closed,
      'ignoredOpenSignals': ignoredOpenSignals,
      'unmatchedCloseSignals': unmatchedCloseSignals,
      'latestOpenedAt': latestOpenedAt?.toIso8601String(),
      'latestClosedAt': latestClosedAt?.toIso8601String(),
      'bySymbol': summarizeBuckets(bySymbol, keyName: 'symbol'),
      'bySource': summarizeBuckets(bySource, keyName: 'signalSource'),
    };
  }

  String _normalizeActionSymbol(String raw) {
    final normalized = raw.trim().toUpperCase();
    if (normalized.endsWith('USDT')) {
      return normalized.substring(0, normalized.length - 4);
    }
    return normalized;
  }

  String _clientActionLabel(String actionType) {
    return actionType == 'cancel' ? '取消' : '确定';
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

class _StartupStageSelection {
  final List<StartupScanCandidate> buyCandidates;
  final List<StartupScanCandidate> observationCandidates;
  final int observationSuppressedCount;
  final int awaitingObservationConfirmationCount;

  const _StartupStageSelection({
    required this.buyCandidates,
    required this.observationCandidates,
    required this.observationSuppressedCount,
    required this.awaitingObservationConfirmationCount,
  });
}
