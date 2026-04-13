import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/coin_data.dart';
import '../models/news_item.dart';
import '../models/strategy_snapshot.dart';
import 'binance_service.dart';
import 'hourly_replay_service.dart';
import 'leader_prediction_service.dart';
import 'market_bottom_detector_service.dart';
import 'news_service.dart';
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
  static const _leaderFallbackExperimentPrefix = 'fallback_';
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
  final NewsService _newsService;
  final http.Client _httpClient;

  SignalRunnerService({
    BinanceService? binance,
    HourlyReplayService? replay,
    LeaderPredictionService? leaderPrediction,
    StartupScannerService? startupScanner,
    MarketBottomDetectorService? marketBottomDetector,
    StartupStrategyBacktestService? startupStrategyBacktest,
    NewsService? newsService,
    http.Client? httpClient,
  })  : _binance = binance ?? BinanceService(),
        _replay = replay ?? HourlyReplayService(),
        _leaderPrediction = leaderPrediction ?? LeaderPredictionService(),
        _startupScanner = startupScanner ?? StartupScannerService(),
        _marketBottomDetector =
            marketBottomDetector ?? MarketBottomDetectorService(),
        _startupStrategyBacktest =
            startupStrategyBacktest ?? StartupStrategyBacktestService(),
        _newsService = newsService ?? NewsService(),
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
    final resolvedSymbols = _resolveLeaderPredictionSymbols(requestedSymbols);
    final coins = await _binance.fetchTickers(symbols: resolvedSymbols);
    final symbols = coins.map((coin) => coin.symbol).toList()..sort();
    if (symbols.isEmpty) {
      throw StateError('当前没有可用于次日收益模型的币种');
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
    final recentNews = await _safeFetchLeaderNews(symbols);
    final backtest = _buildLeaderPredictionBacktest(
      dailyHistory: dailyHistory,
      btcDailyHistory: btcDailyHistory,
      lookbackDays: lookbackDays,
    );
    final bestExperiment = _asJsonMap(backtest['bestExperiment']);
    final bestExperimentId = bestExperiment?['id']?.toString() ?? '';
    final result = bestExperimentId.startsWith(_leaderFallbackExperimentPrefix)
        ? _buildMomentumFallbackLiveResult(
            currentCoins: coins,
            dailyHistory: dailyHistory,
            btcDailyHistory: btcDailyHistory,
            days: _fallbackMomentumDays(bestExperiment),
            fallbackId: bestExperimentId,
            fallbackLabel:
                bestExperiment?['label']?.toString() ?? 'Fallback Momentum',
          )
        : _leaderPrediction.analyze(
            currentCoins: coins,
            dailyHistory: dailyHistory,
            btcDailyHistory: btcDailyHistory,
            recentNews: recentNews,
            experimentConfig: _resolveLeaderExperimentConfig(backtest),
            forcedCorePoolSymbols: _asStringList(
              (_asJsonMap(backtest['bestExperiment']) ??
                  const {})['corePoolSymbols'],
            ),
          );
    final payload = _buildLeaderPredictionReportPayload(
      generatedAt: generatedAt,
      result: result,
      lookbackDays: lookbackDays,
      activeSymbols: symbols,
    )..addAll({
        'bestExperiment': backtest['bestExperiment'],
        'experimentHistory': backtest['experimentHistory'],
        'experimentSelectionPolicy': backtest['experimentSelectionPolicy'],
      });
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
      precomputedBacktest: backtest,
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
    final resolvedSymbols = _resolveLeaderPredictionSymbols(requestedSymbols);
    final coins = await _binance.fetchTickers(symbols: resolvedSymbols);
    final symbols = coins.map((coin) => coin.symbol).toList()..sort();
    if (symbols.isEmpty) {
      final emptyPayload = {
        'updatedAt': DateTime.now().toIso8601String(),
        'lookbackDays': lookbackDays,
        'summary': {
          'windowDays': lookbackDays,
          'totalDays': 0,
          'recommendDays': 0,
          'watchOnlyDays': 0,
          'predictionDays': 0,
          'actionableDays': 0,
          'suppressedDays': 0,
          'suppressRate': 0.0,
          'top1HitRate': 0.0,
          'top3HitRate': 0.0,
          'actionableTop1HitRate': 0.0,
          'actionableTop3HitRate': 0.0,
          'recommendTop1HitRate': 0.0,
          'recommendTop3HitRate': 0.0,
          'avgPredictedReturn': 0.0,
          'avgLeaderReturn': 0.0,
          'avgExcessVsMedian': 0.0,
          'actionableAvgPredictedReturn': 0.0,
          'recommendAvgPredictedReturn': 0.0,
          'recent20Top1HitRate': 0.0,
          'recent20Top3HitRate': 0.0,
          'longestMissStreak': 0,
          'latestTop1': null,
          'latestTop3': const <String>[],
          'currentRegimeStatus': 'stand_aside',
        },
        'benchmarks': const <Map<String, dynamic>>[],
        'experimentHistory': const <Map<String, dynamic>>[],
        'bestExperiment': null,
        'experimentSelectionPolicy': const <String, dynamic>{},
        'liveSummary': {
          'totalRecords': 0,
          'pending': 0,
          'settled': 0,
          'suppressed': 0,
          'recommend': 0,
          'watchOnly': 0,
          'actionable': 0,
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
    final backtest = _buildLeaderPredictionBacktest(
      dailyHistory: histories[0],
      btcDailyHistory: histories[1]['BTCUSDT'] ?? const <Kline>[],
      lookbackDays: lookbackDays,
    );
    return refreshLeaderPredictionLog(
      path: logPath,
      statsPath: statsPath,
      dailyHistory: histories[0],
      btcDailyHistory: histories[1]['BTCUSDT'] ?? const <Kline>[],
      lookbackDays: lookbackDays,
      precomputedBacktest: backtest,
    );
  }

  Future<Map<String, dynamic>> refreshLeaderPredictionLog({
    String path = defaultLeaderPredictionLogPath,
    String statsPath = defaultLeaderPredictionStatsPath,
    required Map<String, List<Kline>> dailyHistory,
    required List<Kline> btcDailyHistory,
    int lookbackDays = defaultLeaderPredictionBacktestDays,
    Map<String, dynamic>? precomputedBacktest,
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
    final backtest = precomputedBacktest ??
        _buildLeaderPredictionBacktest(
          dailyHistory: dailyHistory,
          btcDailyHistory: btcDailyHistory,
          lookbackDays: lookbackDays,
        );
    final payload = {
      'updatedAt': DateTime.now().toIso8601String(),
      'lookbackDays': lookbackDays,
      'summary': backtest['summary'],
      'benchmarks': backtest['benchmarks'],
      'experimentHistory': backtest['experimentHistory'],
      'bestExperiment': backtest['bestExperiment'],
      'experimentSelectionPolicy': backtest['experimentSelectionPolicy'],
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

  Future<List<NewsItem>> _safeFetchLeaderNews(List<String> symbols) async {
    try {
      return await _newsService.fetchNews(
        limit: 24,
        categories: symbols
            .map((item) => item.replaceAll('USDT', '').toUpperCase())
            .toList(),
      );
    } catch (_) {
      return const <NewsItem>[];
    }
  }

  LeaderPredictionExperimentConfig _resolveLeaderExperimentConfig(
    Map<String, dynamic> backtest,
  ) {
    final best = _asJsonMap(backtest['bestExperiment']);
    final experimentId = best?['id']?.toString() ?? '';
    if (experimentId.isEmpty) {
      return LeaderPredictionService.defaultExperimentConfig;
    }
    return _leaderPrediction.configById(experimentId);
  }

  List<String> _resolveLeaderPredictionSymbols(List<String>? requestedSymbols) {
    final base = (requestedSymbols == null || requestedSymbols.isEmpty)
        ? BinanceService.defaultLeaderPredictionSymbols
        : requestedSymbols;
    final excluded = BinanceService.excludedLeaderPredictionSymbols.toSet();
    return base
        .map(BinanceService.toSymbol)
        .where((item) => item.isNotEmpty && !excluded.contains(item))
        .toSet()
        .toList()
      ..sort();
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
    if (result.top3.isEmpty || !_isLeaderPredictionPushable(result)) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: provider.name,
        status: 'skipped_no_actionable',
        message:
            '当前状态为$regimeLabel，且置信度为${_leaderPredictionConfidenceLabel(result.confidence)}，仅记录预测，不发送飞书',
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
      title: 'Binance Rotation Top1',
      dedupe: dedupe,
      statePath: statePath,
      dedupeWindow: dedupeWindow,
      dedupeKey: dedupeKey,
      successMessage: '已推送明日轮动 Top1 预测',
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
      'modelVersion': result.modelVersion,
      'confidence': result.confidence,
      'rotationConfirmed': result.rotationConfirmed,
      'corePoolSymbols': result.corePoolSymbols,
      'selectedExperimentId': result.selectedExperimentId,
      'selectedExperimentLabel': result.selectedExperimentLabel,
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
      ..writeln('Binance 明日轮动 Top1 预测')
      ..writeln('状态: ${_leaderPredictionRegimeLabel(result.regimeStatus)}')
      ..writeln('结算窗口: 下一根币安日线（UTC 00:00）')
      ..writeln('模型: ${result.selectedExperimentLabel}')
      ..writeln('置信度: ${_leaderPredictionConfidenceLabel(result.confidence)}')
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
        ..writeln(
          '核心池: ${result.corePoolSymbols.take(8).join(', ')}',
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
    final rotation = ((_asDouble(components['rotation'])) * 100).round();
    final trend = ((_asDouble(components['trend'])) * 100).round();
    final compression = ((_asDouble(components['compression'])) * 100).round();
    final lowVol = ((_asDouble(components['lowVol'])) * 100).round();
    final volume = ((_asDouble(components['volume'])) * 100).round();
    final risk = ((_asDouble(components['risk'])) * 100).round();
    final corePool = ((_asDouble(components['corePool'])) * 100).round();
    final confidence = _leaderPredictionConfidenceLabel(
      summary['confidence']?.toString() ?? 'low',
    );
    final daysSinceLeader = _asDouble(components['daysSinceLeader']).round();
    final ret5 = _asDouble(components['ret5']);
    final ret14 = _asDouble(components['ret14']);
    final volumeRatio = _asDouble(components['volumeRatio']);
    final compressionRatio = _asDouble(components['compressionRatio']);
    final distanceToHigh10 = _asDouble(components['distanceToHigh10']);
    final distanceToLow10 = _asDouble(components['distanceToLow10']);
    return [
      '1. ${top1.displayName} 当前位于核心轮动池，距上次领涨 $daysSinceLeader 天，轮动分 $rotation，核心池分 $corePool，说明已脱离刚领涨后的拥挤段。',
      '2. 5日动量 ${ret5 >= 0 ? '+' : ''}${ret5.toStringAsFixed(1)}%，14日 ${ret14 >= 0 ? '+' : ''}${ret14.toStringAsFixed(1)}%，趋势分 $trend，压缩分 $compression，压缩比 ${compressionRatio.toStringAsFixed(2)}。',
      '3. 量能分 $volume，低波动分 $lowVol，风控分 $risk，量比 ${volumeRatio.toStringAsFixed(2)}x，距10日高点 ${distanceToHigh10.toStringAsFixed(2)}%，距10日低点 ${distanceToLow10.toStringAsFixed(2)}%，当前置信度 $confidence。',
    ];
  }

  String _leaderPredictionRegimeLabel(String status) {
    switch (status) {
      case 'recommend':
        return '可出手';
      case 'watch_only':
        return '轻仓观察';
      default:
        return '只做预测';
    }
  }

  String _leaderPredictionConfidenceLabel(String value) {
    switch (value) {
      case 'high':
        return '高';
      case 'medium':
        return '中';
      default:
        return '低';
    }
  }

  bool _isLeaderPredictionActionable(String status) {
    return status == 'recommend';
  }

  bool _isLeaderPredictionPushable(LeaderPredictionResult result) {
    return result.regimeStatus == 'recommend' && result.confidence != 'low';
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
      'modelVersion': result.modelVersion,
      'confidence': result.confidence,
      'rotationConfirmed': result.rotationConfirmed,
      'corePoolSymbols': result.corePoolSymbols,
      'selectedExperimentId': result.selectedExperimentId,
      'selectedExperimentLabel': result.selectedExperimentLabel,
      'actionable': _isLeaderPredictionActionable(result.regimeStatus),
      'strongActionable': result.regimeStatus == 'recommend',
      'status': 'pending',
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
      final regimeStatus = record['regimeStatus']?.toString() ?? 'stand_aside';
      final actionable = record['actionable'] == true ||
          _isLeaderPredictionActionable(regimeStatus);

      record['actualLeader'] = actualLeader;
      record['actualTop3'] = actualTop3;
      record['leaderReturn'] = sorted.first.value;
      record['predictedCoinReturn'] = predictedReturn;
      record['excessVsMedian'] =
          predictedReturn == null ? null : predictedReturn - medianReturn;
      record['settledAt'] = DateTime.now().toIso8601String();
      record['actionable'] = actionable;
      record['strongActionable'] = regimeStatus == 'recommend';
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
    var recommend = 0;
    var watchOnly = 0;
    var actionable = 0;
    var wins = 0;
    var top3Wins = 0;
    var totalPredictedReturn = 0.0;
    var totalExcess = 0.0;
    var actionableSettled = 0;
    var actionableWins = 0;
    var actionableTop3Wins = 0;
    var actionableReturn = 0.0;
    var recommendSettled = 0;
    var recommendWins = 0;
    var recommendTop3Wins = 0;
    var recommendReturn = 0.0;
    DateTime? latestRecordedAt;

    for (final record in records) {
      final status = record['status']?.toString() ?? '';
      final regimeStatus = record['regimeStatus']?.toString() ?? 'stand_aside';
      final recordedAt =
          DateTime.tryParse(record['recordedAt']?.toString() ?? '');
      if (recordedAt != null &&
          (latestRecordedAt == null || recordedAt.isAfter(latestRecordedAt))) {
        latestRecordedAt = recordedAt;
      }

      if (status == 'pending') pending += 1;
      switch (regimeStatus) {
        case 'recommend':
          recommend += 1;
          break;
        case 'watch_only':
          watchOnly += 1;
          break;
        default:
          suppressed += 1;
          break;
      }
      if (record['actionable'] == true ||
          _isLeaderPredictionActionable(regimeStatus)) {
        actionable += 1;
      }
      if (status != 'settled') continue;
      settled += 1;
      if (record['top1Hit'] == true) wins += 1;
      if (record['top3Hit'] == true) top3Wins += 1;
      totalPredictedReturn += _asDouble(record['predictedCoinReturn']);
      totalExcess += _asDouble(record['excessVsMedian']);

      final isActionable = record['actionable'] == true ||
          _isLeaderPredictionActionable(regimeStatus);
      if (isActionable) {
        actionableSettled += 1;
        if (record['top1Hit'] == true) actionableWins += 1;
        if (record['top3Hit'] == true) actionableTop3Wins += 1;
        actionableReturn += _asDouble(record['predictedCoinReturn']);
      }
      if (regimeStatus == 'recommend') {
        recommendSettled += 1;
        if (record['top1Hit'] == true) recommendWins += 1;
        if (record['top3Hit'] == true) recommendTop3Wins += 1;
        recommendReturn += _asDouble(record['predictedCoinReturn']);
      }
    }

    return {
      'totalRecords': records.length,
      'pending': pending,
      'suppressed': suppressed,
      'settled': settled,
      'recommend': recommend,
      'watchOnly': watchOnly,
      'actionable': actionable,
      'top1Wins': wins,
      'top3Wins': top3Wins,
      'top1HitRate': settled == 0 ? 0.0 : wins / settled,
      'top3HitRate': settled == 0 ? 0.0 : top3Wins / settled,
      'avgPredictedReturn': settled == 0 ? 0.0 : totalPredictedReturn / settled,
      'avgExcessVsMedian': settled == 0 ? 0.0 : totalExcess / settled,
      'actionableTop1HitRate':
          actionableSettled == 0 ? 0.0 : actionableWins / actionableSettled,
      'actionableTop3HitRate':
          actionableSettled == 0 ? 0.0 : actionableTop3Wins / actionableSettled,
      'actionableAvgPredictedReturn':
          actionableSettled == 0 ? 0.0 : actionableReturn / actionableSettled,
      'recommendTop1HitRate':
          recommendSettled == 0 ? 0.0 : recommendWins / recommendSettled,
      'recommendTop3HitRate':
          recommendSettled == 0 ? 0.0 : recommendTop3Wins / recommendSettled,
      'recommendAvgPredictedReturn':
          recommendSettled == 0 ? 0.0 : recommendReturn / recommendSettled,
      'latestRecordedAt': latestRecordedAt?.toIso8601String(),
      'latestModelVersion':
          records.isEmpty ? null : records.first['modelVersion'],
      'latestConfidence': records.isEmpty ? null : records.first['confidence'],
      'latestCorePoolSymbols':
          records.isEmpty ? const <String>[] : records.first['corePoolSymbols'],
      'latestSelectedExperimentId':
          records.isEmpty ? null : records.first['selectedExperimentId'],
      'latestSelectedExperimentLabel':
          records.isEmpty ? null : records.first['selectedExperimentLabel'],
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
          'watchOnlyDays': 0,
          'predictionDays': 0,
          'actionableDays': 0,
          'suppressedDays': 0,
          'suppressRate': 0.0,
          'top1HitRate': 0.0,
          'top3HitRate': 0.0,
          'actionableTop1HitRate': 0.0,
          'actionableTop3HitRate': 0.0,
          'recommendTop1HitRate': 0.0,
          'recommendTop3HitRate': 0.0,
          'avgPredictedReturn': 0.0,
          'avgLeaderReturn': 0.0,
          'avgExcessVsMedian': 0.0,
          'actionableAvgPredictedReturn': 0.0,
          'recommendAvgPredictedReturn': 0.0,
          'recent20Top1HitRate': 0.0,
          'recent20Top3HitRate': 0.0,
          'longestMissStreak': 0,
          'latestTop1': null,
          'latestTop3': const <String>[],
          'currentRegimeStatus': 'stand_aside',
        },
        'benchmarks': const <Map<String, dynamic>>[],
        'experimentHistory': const <Map<String, dynamic>>[],
        'bestExperiment': null,
        'experimentSelectionPolicy': const <String, dynamic>{},
        'records': const <Map<String, dynamic>>[],
      };
    }

    final scenarios = _buildLeaderBacktestScenarios(
      dailyHistory: dailyHistory,
      btcDailyHistory: btcBars,
      lookbackDays: lookbackDays,
    );
    if (scenarios.isEmpty) {
      return {
        'summary': {
          'windowDays': lookbackDays,
          'totalDays': 0,
          'recommendDays': 0,
          'watchOnlyDays': 0,
          'predictionDays': 0,
          'actionableDays': 0,
          'suppressedDays': 0,
          'suppressRate': 0.0,
          'top1HitRate': 0.0,
          'top3HitRate': 0.0,
          'actionableTop1HitRate': 0.0,
          'actionableTop3HitRate': 0.0,
          'recommendTop1HitRate': 0.0,
          'recommendTop3HitRate': 0.0,
          'avgPredictedReturn': 0.0,
          'avgLeaderReturn': 0.0,
          'avgExcessVsMedian': 0.0,
          'actionableAvgPredictedReturn': 0.0,
          'recommendAvgPredictedReturn': 0.0,
          'recent20Top1HitRate': 0.0,
          'recent20Top3HitRate': 0.0,
          'longestMissStreak': 0,
          'latestTop1': null,
          'latestTop3': const <String>[],
          'currentRegimeStatus': 'stand_aside',
        },
        'benchmarks': const <Map<String, dynamic>>[],
        'experimentHistory': const <Map<String, dynamic>>[],
        'bestExperiment': null,
        'experimentSelectionPolicy': const <String, dynamic>{},
        'records': const <Map<String, dynamic>>[],
      };
    }

    final recordsByExperiment = <String, List<Map<String, dynamic>>>{};
    final experimentSummaries = <Map<String, dynamic>>[];
    for (final config in LeaderPredictionService.experimentConfigs) {
      final records = scenarios.map((scenario) {
        final result = _leaderPrediction.analyze(
          currentCoins: scenario.currentCoins,
          dailyHistory: scenario.slicedHistory,
          btcDailyHistory: scenario.btcSlice,
          experimentConfig: config,
        );
        return _leaderModelRecord(
          result: result,
          scenario: scenario,
        );
      }).toList();
      recordsByExperiment[config.id] = records;
      experimentSummaries.add(
        _summarizeLeaderExperimentConfig(config, records),
      );
    }

    experimentSummaries.sort((a, b) => (_asDouble(b['selectionScore']))
        .compareTo(_asDouble(a['selectionScore'])));
    Map<String, dynamic>? bestExperiment = experimentSummaries.isEmpty
        ? null
        : Map<String, dynamic>.from(experimentSummaries.first);

    final baselineBuckets = <String, List<Map<String, dynamic>>>{
      'yesterday_leader_continue': [],
      'momentum_7d': [],
      'momentum_14d': [],
      'random': [],
    };
    String? previousActualLeader;

    for (final scenario in scenarios) {
      final sortedSymbols = scenario.actualReturns.keys.toList()..sort();
      final randomSymbol = sortedSymbols.isEmpty
          ? null
          : sortedSymbols[scenario.currentDate % sortedSymbols.length]
              .replaceAll('USDT', '');
      baselineBuckets['yesterday_leader_continue']!.add(
        _leaderBenchmarkRecord(
          name: 'yesterday_leader_continue',
          targetDate: scenario.nextDate,
          predictedSymbol: previousActualLeader,
          actualLeader: scenario.actualLeader,
          actualTop3: scenario.actualTop3,
          actualReturns: scenario.actualReturns,
          medianReturn: scenario.medianReturn,
        ),
      );
      baselineBuckets['momentum_7d']!.add(
        _leaderBenchmarkRecord(
          name: 'momentum_7d',
          targetDate: scenario.nextDate,
          predictedSymbol: _pickMomentumLeader(scenario.slicedHistory, 7),
          actualLeader: scenario.actualLeader,
          actualTop3: scenario.actualTop3,
          actualReturns: scenario.actualReturns,
          medianReturn: scenario.medianReturn,
        ),
      );
      baselineBuckets['momentum_14d']!.add(
        _leaderBenchmarkRecord(
          name: 'momentum_14d',
          targetDate: scenario.nextDate,
          predictedSymbol: _pickMomentumLeader(scenario.slicedHistory, 14),
          actualLeader: scenario.actualLeader,
          actualTop3: scenario.actualTop3,
          actualReturns: scenario.actualReturns,
          medianReturn: scenario.medianReturn,
        ),
      );
      baselineBuckets['random']!.add(
        _leaderBenchmarkRecord(
          name: 'random',
          targetDate: scenario.nextDate,
          predictedSymbol: randomSymbol,
          actualLeader: scenario.actualLeader,
          actualTop3: scenario.actualTop3,
          actualReturns: scenario.actualReturns,
          medianReturn: scenario.medianReturn,
        ),
      );

      previousActualLeader = scenario.actualLeader;
    }

    final benchmarks = baselineBuckets.entries
        .map((entry) => _summarizeLeaderBenchmark(entry.key, entry.value))
        .toList();

    var modelRecords = _selectLeaderExperimentRecords(
      scenarios: scenarios,
      recordsByExperiment: recordsByExperiment,
    );
    final fallbackBenchmark = _selectMomentumBenchmarkFallback(
      bestExperiment: bestExperiment,
      benchmarks: benchmarks,
    );
    if (fallbackBenchmark != null) {
      final fallbackName =
          fallbackBenchmark['name']?.toString() ?? 'momentum_7d';
      final fallbackDays = fallbackName == 'momentum_14d' ? 14 : 7;
      final fallbackId = 'fallback_$fallbackName';
      final fallbackLabel =
          fallbackDays == 14 ? 'Fallback Momentum 14d' : 'Fallback Momentum 7d';
      bestExperiment = {
        'round': 0,
        'id': fallbackId,
        'label': fallbackLabel,
        'family': 'benchmark_fallback',
        'corePoolSize': 0,
        'selectionScore': _leaderExperimentSelectionScore(fallbackBenchmark),
        'tradeableDays': fallbackBenchmark['totalDays'] ?? 0,
        'corePoolSymbols': const <String>[],
        ...fallbackBenchmark,
      };
      modelRecords = scenarios
          .map((scenario) => _buildMomentumFallbackRecord(
                scenario: scenario,
                days: fallbackDays,
                fallbackId: fallbackId,
                fallbackLabel: fallbackLabel,
              ))
          .toList();
    }

    modelRecords.sort((a, b) => (a['targetCandleAt'] as String)
        .compareTo(b['targetCandleAt'] as String));
    final summary = _summarizeLeaderPredictionRecords(
      modelRecords,
      experimentHistory: experimentSummaries,
      bestExperiment: bestExperiment,
    );

    return {
      'summary': summary,
      'benchmarks': benchmarks,
      'experimentHistory': experimentSummaries,
      'bestExperiment': bestExperiment,
      'experimentSelectionPolicy': {
        'mode': 'walk_forward_meta',
        'trainingWindowDays': 30,
        'minTrainingDays': 10,
      },
      'records': modelRecords,
    };
  }

  List<_LeaderBacktestScenario> _buildLeaderBacktestScenarios({
    required Map<String, List<Kline>> dailyHistory,
    required List<Kline> btcDailyHistory,
    required int lookbackDays,
  }) {
    final symbolBars = <String, List<Kline>>{};
    for (final entry in dailyHistory.entries) {
      final normalized = BinanceService.toSymbol(entry.key);
      final bars = _completeDailyBars(entry.value);
      if (bars.length >= 46) {
        symbolBars[normalized] = bars;
      }
    }

    final candidateDates = btcDailyHistory
        .skip(45)
        .take(max(0, btcDailyHistory.length - 46))
        .map((item) => item.openTime)
        .toList();
    final selectedDates = candidateDates.length <= lookbackDays
        ? candidateDates
        : candidateDates.sublist(candidateDates.length - lookbackDays);
    final scenarios = <_LeaderBacktestScenario>[];

    for (final currentDate in selectedDates) {
      final nextDate = currentDate + const Duration(days: 1).inMilliseconds;
      final currentCoins = <CoinData>[];
      final slicedHistory = <String, List<Kline>>{};
      final actualReturns = <String, double>{};

      for (final entry in symbolBars.entries) {
        final bars = entry.value;
        final upto = _barsUpToDate(bars, currentDate);
        if (upto.length < 45) continue;

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

      final btcSlice = _barsUpToDate(btcDailyHistory, currentDate);
      if (currentCoins.length < 4 ||
          btcSlice.length < 45 ||
          actualReturns.length < 4) {
        continue;
      }

      final sortedActual = actualReturns.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      scenarios.add(
        _LeaderBacktestScenario(
          currentDate: currentDate,
          nextDate: nextDate,
          currentCoins: currentCoins,
          slicedHistory: slicedHistory,
          btcSlice: btcSlice,
          actualReturns: actualReturns,
          actualLeader: sortedActual.first.key.replaceAll('USDT', ''),
          actualTop3: sortedActual
              .take(3)
              .map((item) => item.key.replaceAll('USDT', ''))
              .toList(),
          medianReturn: _safeMedian(actualReturns.values.toList()),
          leaderReturn: sortedActual.first.value,
        ),
      );
    }

    return scenarios;
  }

  Map<String, dynamic> _leaderModelRecord({
    required LeaderPredictionResult result,
    required _LeaderBacktestScenario scenario,
  }) {
    final top1 = result.top3.isEmpty ? null : result.top3.first.displayName;
    final top3 = result.top3.map((item) => item.displayName).toList();
    final predictedReturn = top1 == null
        ? null
        : scenario.actualReturns[BinanceService.toSymbol(top1)];
    return {
      'id': _leaderPredictionRecordId(
        DateTime.fromMillisecondsSinceEpoch(scenario.nextDate, isUtc: true),
      ),
      'recordedAt':
          DateTime.fromMillisecondsSinceEpoch(scenario.currentDate, isUtc: true)
              .toIso8601String(),
      'predictionWindow': 'next_binance_daily_candle',
      'targetCandleAt':
          DateTime.fromMillisecondsSinceEpoch(scenario.nextDate, isUtc: true)
              .toIso8601String(),
      'signalType': 'leader_prediction',
      'top1Symbol': top1,
      'top3Symbols': top3,
      'totalScore': result.top3.isEmpty ? 0.0 : result.top3.first.score,
      'componentScores': _top1ComponentScoresFromResult(result.summary),
      'regimeStatus': result.regimeStatus,
      'regimeLabel': _leaderPredictionRegimeLabel(result.regimeStatus),
      'regimeReason': result.regimeReason,
      'modelVersion': result.modelVersion,
      'confidence': result.confidence,
      'rotationConfirmed': result.rotationConfirmed,
      'corePoolSymbols': result.corePoolSymbols,
      'selectedExperimentId': result.selectedExperimentId,
      'selectedExperimentLabel': result.selectedExperimentLabel,
      'actionable': _isLeaderPredictionActionable(result.regimeStatus),
      'strongActionable': result.regimeStatus == 'recommend',
      'status': 'settled',
      'settledAt':
          DateTime.fromMillisecondsSinceEpoch(scenario.nextDate, isUtc: true)
              .toIso8601String(),
      'actualLeader': scenario.actualLeader,
      'actualTop3': scenario.actualTop3,
      'top1Hit': top1 == scenario.actualLeader,
      'top3Hit': top3.contains(scenario.actualLeader),
      'predictedCoinReturn': predictedReturn,
      'leaderReturn': scenario.leaderReturn,
      'excessVsMedian': predictedReturn == null
          ? null
          : predictedReturn - scenario.medianReturn,
    };
  }

  Map<String, dynamic> _buildMomentumFallbackRecord({
    required _LeaderBacktestScenario scenario,
    required int days,
    required String fallbackId,
    required String fallbackLabel,
  }) {
    final result = _buildMomentumFallbackLiveResult(
      currentCoins: scenario.currentCoins,
      dailyHistory: scenario.slicedHistory,
      btcDailyHistory: scenario.btcSlice,
      days: days,
      fallbackId: fallbackId,
      fallbackLabel: fallbackLabel,
    );
    return _leaderModelRecord(
      result: result,
      scenario: scenario,
    );
  }

  LeaderPredictionResult _buildMomentumFallbackLiveResult({
    required List<CoinData> currentCoins,
    required Map<String, List<Kline>> dailyHistory,
    required List<Kline> btcDailyHistory,
    int days = 7,
    String fallbackId = 'fallback_momentum_7d',
    String fallbackLabel = 'Fallback Momentum 7d',
  }) {
    final generatedAt = DateTime.now();
    final primaryMomentumLabel = '$days日动量';
    final primaryKey = days == 14 ? 'ret14' : 'ret7';
    final secondaryKey = days == 14 ? 'ret7' : 'ret14';
    final normalizedHistory = <String, List<Kline>>{
      for (final entry in dailyHistory.entries)
        BinanceService.toSymbol(entry.key): _completeDailyBars(entry.value),
    };
    final candidates = <Map<String, dynamic>>[];

    for (final coin in currentCoins) {
      final symbol = BinanceService.toSymbol(coin.symbol);
      final bars = normalizedHistory[symbol] ?? const <Kline>[];
      if (bars.length < max(days + 1, 21)) continue;

      final closes = bars.map((item) => item.close).toList();
      final quotes = bars.map((item) => item.quoteVolume).toList();
      final recent = bars.sublist(max(0, bars.length - 10));
      final high10 = recent.map((item) => item.high).reduce(max);
      final low10 = recent.map((item) => item.low).reduce(min);
      final close = closes.last;
      final sma10 = _averageDoubles(closes.sublist(max(0, closes.length - 10)));
      final sma20 = _averageDoubles(closes.sublist(max(0, closes.length - 20)));
      final volumeRatio = _averageDoubles(
            quotes.sublist(max(0, quotes.length - 3)),
          ) /
          max(
            _averageDoubles(quotes.sublist(max(0, quotes.length - 10))),
            1,
          );
      final ret1 = _periodReturnFromBars(bars, 1);
      final ret3 = _periodReturnFromBars(bars, 3);
      final ret5 = _periodReturnFromBars(bars, 5);
      final ret7 = _periodReturnFromBars(bars, 7);
      final ret14 = _periodReturnFromBars(bars, 14);
      final ret30 = _periodReturnFromBars(bars, 30);
      final closeReturns = <double>[];
      for (var index = 1; index < closes.length; index += 1) {
        final previous = closes[index - 1];
        if (previous <= 0) continue;
        closeReturns.add(((closes[index] - previous) / previous) * 100);
      }
      final vol20 = _realizedVolatilityValues(
        closeReturns.sublist(max(0, closeReturns.length - 20)),
      );
      final compressionRatio = vol20 <= 0
          ? 1.0
          : _realizedVolatilityValues(
                  closeReturns.sublist(max(0, closeReturns.length - 5))) /
              max(vol20, 0.0001);
      final distanceToHigh10 =
          high10 <= 0 ? 0.0 : ((close - high10) / high10) * 100;
      final distanceToLow10 =
          low10 <= 0 ? 0.0 : ((close - low10) / low10) * 100;
      candidates.add({
        'base': coin,
        'symbol': coin.displayName,
        'ret1': ret1,
        'ret3': ret3,
        'ret5': ret5,
        'ret7': ret7,
        'ret14': ret14,
        'ret30': ret30,
        'close': close,
        'sma10': sma10,
        'sma20': sma20,
        'trend': close > sma10 && sma10 > sma20
            ? 1.0
            : (close > sma20 ? 0.68 : 0.28),
        'volumeRatio': volumeRatio,
        'volumeScore': (1 - ((volumeRatio - 1.2).abs() / 1.2)).clamp(0.0, 1.0),
        'vol20': vol20,
        'compressionRatio': compressionRatio,
        'compression': (1 - (compressionRatio - 0.8).abs()).clamp(0.0, 1.0),
        'distanceToHigh10': distanceToHigh10,
        'distanceToLow10': distanceToLow10,
        'heatPenalty': ret1 > 8 || ret3 > 15 ? 0.22 : 0.0,
      });
    }

    if (candidates.isEmpty) {
      return LeaderPredictionResult(
        generatedAt: generatedAt,
        rankedCoins: const <CoinData>[],
        top3: const <CoinData>[],
        regimeStatus: 'stand_aside',
        regimeReason: '$primaryMomentumLabel回退模型当前没有足够的有效币种。',
        marketBreadth: 0,
        medianSevenDayReturn: 0,
        btcDistanceToSma20: 0,
        modelVersion:
            '${LeaderPredictionService.modelVersion}+fallback_momentum$days',
        confidence: 'low',
        rotationConfirmed: false,
        corePoolSymbols: const <String>[],
        selectedExperimentId: fallbackId,
        selectedExperimentLabel: fallbackLabel,
        summary: const {
          'mode': 'leader_prediction',
          'top3Symbols': <String>[],
          'top1ComponentScores': <String, double>{},
        },
      );
    }

    final byRet7 = [...candidates]
      ..sort((a, b) => (_asDouble(b['ret7'])).compareTo(_asDouble(a['ret7'])));
    final byRet14 = [
      ...candidates
    ]..sort((a, b) => (_asDouble(b['ret14'])).compareTo(_asDouble(a['ret14'])));
    final byVol20 = [
      ...candidates
    ]..sort((a, b) => (_asDouble(a['vol20'])).compareTo(_asDouble(b['vol20'])));

    final rank7 = _normalizedRankMap(byRet7);
    final rank14 = _normalizedRankMap(byRet14);
    final lowVolRank = _normalizedRankMap(byVol20);
    final primaryRank = days == 14 ? rank14 : rank7;
    final secondaryRank = days == 14 ? rank7 : rank14;

    for (final candidate in candidates) {
      final symbol = candidate['symbol']?.toString() ?? '';
      final lowVol = lowVolRank[symbol] ?? 0.0;
      final trend = _asDouble(candidate['trend']);
      final volumeScore = _asDouble(candidate['volumeScore']);
      final compression = _asDouble(candidate['compression']);
      final heatPenalty = _asDouble(candidate['heatPenalty']);
      final score = ((primaryRank[symbol] ?? 0.0) * 0.72) +
          ((secondaryRank[symbol] ?? 0.0) * 0.16) +
          (trend * 0.10) +
          (volumeScore * 0.01) +
          (lowVol * 0.02) +
          (compression * 0.01) -
          (heatPenalty * 0.5);
      candidate['lowVol'] = lowVol;
      candidate['rotation'] = primaryRank[symbol] ?? 0.0;
      candidate['corePool'] = ((primaryRank[symbol] ?? 0.0) * 0.7) +
          ((secondaryRank[symbol] ?? 0.0) * 0.3);
      candidate['risk'] = (1 - heatPenalty).clamp(0.0, 1.0);
      candidate['score'] = score.clamp(0.0, 1.0);
    }

    final sorted = [...candidates]..sort((a, b) {
        final byPrimary =
            _asDouble(b[primaryKey]).compareTo(_asDouble(a[primaryKey]));
        if (byPrimary != 0) return byPrimary;
        final bySecondary =
            _asDouble(b[secondaryKey]).compareTo(_asDouble(a[secondaryKey]));
        if (bySecondary != 0) return bySecondary;
        return ((b['base'] as CoinData).quoteVolume)
            .compareTo((a['base'] as CoinData).quoteVolume);
      });
    final topCandidates = sorted.take(3).toList();
    final top1 = topCandidates.first;
    final top2Score =
        topCandidates.length >= 2 ? _asDouble(topCandidates[1]['score']) : 0.0;
    final scoreGap = _asDouble(top1['score']) - top2Score;
    final topCompression = _asDouble(top1['compression']);
    final topTrend = _asDouble(top1['trend']);
    final topRet14 = _asDouble(top1['ret14']);

    final breadth = candidates.isEmpty
        ? 0.0
        : candidates.where((item) => _asDouble(item['ret7']) > 0).length /
            candidates.length;
    final medianSevenDayReturn =
        _safeMedian(candidates.map((item) => _asDouble(item['ret7'])).toList());
    final btcBars = _completeDailyBars(btcDailyHistory);
    final btcClose = btcBars.isEmpty ? 0.0 : btcBars.last.close;
    final btcSma20 = btcBars.length < 20
        ? btcClose
        : _averageDoubles(
            btcBars
                .sublist(max(0, btcBars.length - 20))
                .map((item) => item.close)
                .toList(),
          );
    final btcDistanceToSma20 =
        btcSma20 <= 0 ? 0.0 : ((btcClose - btcSma20) / btcSma20) * 100;
    final confidence =
        scoreGap >= 0.12 ? 'high' : (scoreGap >= 0.05 ? 'medium' : 'low');
    final strongMarket = btcDistanceToSma20 >= -1.0 && breadth >= 0.45;
    final neutralMarket = btcDistanceToSma20 >= -2.5 && breadth >= 0.30;
    final recommendSetup = topCompression >= 0.75 && topRet14 >= 18;
    final watchSetup = topTrend >= 0.8 || topCompression >= 0.72;
    final regimeStatus = strongMarket && recommendSetup
        ? 'recommend'
        : (neutralMarket && watchSetup ? 'watch_only' : 'stand_aside');
    final regimeReason = regimeStatus == 'recommend'
        ? '$primaryMomentumLabel基线当前优于轮动实验，且第一候选保留压缩结构，允许继续给出更克制的 Top1 出手信号。'
        : (regimeStatus == 'watch_only'
            ? '$primaryMomentumLabel基线领先，但当前只满足观察条件，继续等待更完整的压缩与确认。'
            : '$primaryMomentumLabel基线虽可排序，但市场状态或结构质量不够，本轮只记录不出手。');

    final rankedCoins = sorted.map((candidate) {
      final base = candidate['base'] as CoinData;
      final score = _asDouble(candidate['score']);
      final symbol = candidate['symbol']?.toString() ?? base.displayName;
      final recommendation = regimeStatus == 'recommend'
          ? '可出手'
          : (regimeStatus == 'watch_only' ? '轻仓观察' : '只做预测');
      return CoinData(
        symbol: base.symbol,
        lastPrice: base.lastPrice,
        priceChange: base.priceChange,
        priceChangePercent: base.priceChangePercent,
        highPrice: base.highPrice,
        lowPrice: base.lowPrice,
        openPrice: base.openPrice,
        quoteVolume: base.quoteVolume,
        volume: base.volume,
        count: base.count,
        score: score,
        historicalScore: score,
        entryScore: score,
        expectedEdge: _asDouble(candidate['ret7']),
        thirtyDayChange: _asDouble(candidate['ret30']),
        sevenDayChange: _asDouble(candidate['ret7']),
        daysSinceSurge: 0,
        level: regimeStatus == 'recommend'
            ? RecommendationLevel.buy
            : RecommendationLevel.hold,
        recommendation: recommendation,
        reason:
            '7日动量 ${_signedPercent(_asDouble(candidate['ret7']))}，14日 ${_signedPercent(_asDouble(candidate['ret14']))}，当前按$primaryMomentumLabel排序，量比 ${_asDouble(candidate['volumeRatio']).toStringAsFixed(2)}x。',
        timingLabel: regimeStatus == 'recommend'
            ? '$days日动量领先'
            : (regimeStatus == 'watch_only' ? '候选观察' : '只记录'),
        timingReason:
            '$symbol 在 7d/14d 横截面动量中靠前，当前使用$primaryMomentumLabel基线回退模型进行排序。',
      );
    }).toList();

    final corePoolSymbols = sorted
        .take(min(6, sorted.length))
        .map((item) => item['symbol']?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .toList();
    final top3 = rankedCoins.take(3).toList();
    final componentScores = <String, double>{
      'rotation': _asDouble(top1['rotation']),
      'trend': _asDouble(top1['trend']),
      'compression': _asDouble(top1['compression']),
      'volume': _asDouble(top1['volumeScore']),
      'lowVol': _asDouble(top1['lowVol']),
      'risk': _asDouble(top1['risk']),
      'corePool': _asDouble(top1['corePool']),
      'ret5': _asDouble(top1['ret5']),
      'ret14': _asDouble(top1['ret14']),
      'volumeRatio': _asDouble(top1['volumeRatio']),
      'compressionRatio': _asDouble(top1['compressionRatio']),
      'daysSinceLeader': 0.0,
      'distanceToLow10': _asDouble(top1['distanceToLow10']),
      'distanceToHigh10': _asDouble(top1['distanceToHigh10']),
    };

    return LeaderPredictionResult(
      generatedAt: generatedAt,
      rankedCoins: rankedCoins,
      top3: top3,
      regimeStatus: regimeStatus,
      regimeReason: regimeReason,
      marketBreadth: breadth,
      medianSevenDayReturn: medianSevenDayReturn,
      btcDistanceToSma20: btcDistanceToSma20,
      modelVersion:
          '${LeaderPredictionService.modelVersion}+fallback_momentum$days',
      confidence: confidence,
      rotationConfirmed: false,
      corePoolSymbols: corePoolSymbols,
      selectedExperimentId: fallbackId,
      selectedExperimentLabel: fallbackLabel,
      summary: {
        'mode': 'leader_prediction',
        'modelVersion':
            '${LeaderPredictionService.modelVersion}+fallback_momentum$days',
        'regimeStatus': regimeStatus,
        'reason': regimeReason,
        'confidence': confidence,
        'marketBreadth': breadth,
        'medianSevenDayReturn': medianSevenDayReturn,
        'btcDistanceToSma20': btcDistanceToSma20,
        'rotationConfirmed': false,
        'corePoolSymbols': corePoolSymbols,
        'selectedExperimentId': fallbackId,
        'selectedExperimentLabel': fallbackLabel,
        'top1Symbol': top3.isEmpty ? null : top3.first.displayName,
        'top1Score': top3.isEmpty ? 0.0 : top3.first.score,
        'top1ComponentScores': componentScores,
        'top3Symbols': top3.map((item) => item.displayName).toList(),
      },
    );
  }

  Map<String, dynamic>? _selectMomentumBenchmarkFallback({
    required Map<String, dynamic>? bestExperiment,
    required List<Map<String, dynamic>> benchmarks,
  }) {
    final candidates = benchmarks
        .where((item) =>
            item['name'] == 'momentum_7d' || item['name'] == 'momentum_14d')
        .toList();
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final byTop1 =
          _asDouble(b['top1HitRate']).compareTo(_asDouble(a['top1HitRate']));
      if (byTop1 != 0) return byTop1;
      final byExcess = _asDouble(b['avgExcessVsMedian'])
          .compareTo(_asDouble(a['avgExcessVsMedian']));
      if (byExcess != 0) return byExcess;
      return _asDouble(b['avgPredictedReturn'])
          .compareTo(_asDouble(a['avgPredictedReturn']));
    });

    final bestBenchmark = candidates.first;
    if (bestExperiment == null) return bestBenchmark;

    final benchmarkTop1 = _asDouble(bestBenchmark['top1HitRate']);
    final benchmarkReturn = _asDouble(bestBenchmark['avgPredictedReturn']);
    final benchmarkExcess = _asDouble(bestBenchmark['avgExcessVsMedian']);
    final experimentTop1 = _asDouble(bestExperiment['top1HitRate']);
    final experimentReturn = _asDouble(bestExperiment['avgPredictedReturn']);
    final experimentExcess = _asDouble(bestExperiment['avgExcessVsMedian']);

    if (benchmarkTop1 > experimentTop1 + 0.015) return bestBenchmark;
    if ((benchmarkTop1 - experimentTop1).abs() <= 0.015 &&
        benchmarkExcess > experimentExcess + 0.12) {
      return bestBenchmark;
    }
    if ((benchmarkTop1 - experimentTop1).abs() <= 0.005 &&
        benchmarkReturn > experimentReturn + 0.15) {
      return bestBenchmark;
    }
    return null;
  }

  int _fallbackMomentumDays(Map<String, dynamic>? bestExperiment) {
    final name = bestExperiment?['name']?.toString() ?? '';
    if (name == 'momentum_14d') return 14;
    return 7;
  }

  List<Map<String, dynamic>> _selectLeaderExperimentRecords({
    required List<_LeaderBacktestScenario> scenarios,
    required Map<String, List<Map<String, dynamic>>> recordsByExperiment,
  }) {
    final modelRecords = <Map<String, dynamic>>[];
    for (var index = 0; index < scenarios.length; index += 1) {
      final chosenConfig = _chooseLeaderExperimentConfig(
        index: index,
        recordsByExperiment: recordsByExperiment,
      );
      final source = Map<String, dynamic>.from(
          recordsByExperiment[chosenConfig.id]![index]);
      source['selectedByMeta'] = true;
      modelRecords.add(source);
    }
    return modelRecords;
  }

  LeaderPredictionExperimentConfig _chooseLeaderExperimentConfig({
    required int index,
    required Map<String, List<Map<String, dynamic>>> recordsByExperiment,
  }) {
    if (index < 10) {
      return LeaderPredictionService.defaultExperimentConfig;
    }

    LeaderPredictionExperimentConfig? bestConfig;
    double? bestScore;
    for (final config in LeaderPredictionService.experimentConfigs) {
      final allRecords = recordsByExperiment[config.id] ?? const [];
      if (allRecords.isEmpty) continue;
      final upper = min(index, allRecords.length);
      final start = max(0, upper - 30);
      final training = allRecords.sublist(start, upper);
      if (training.length < 10) continue;
      final score = _leaderExperimentSelectionScore(
        _summarizeLeaderPredictionRecords(training),
      );
      if (bestScore == null || score > bestScore) {
        bestScore = score;
        bestConfig = config;
      }
    }

    return bestConfig ?? LeaderPredictionService.defaultExperimentConfig;
  }

  double _leaderExperimentSelectionScore(Map<String, dynamic> summary) {
    final top1 = _asDouble(summary['top1HitRate']);
    final recent20 = _asDouble(summary['recent20Top1HitRate']);
    final avgReturn = _asDouble(summary['avgPredictedReturn']);
    final avgExcess = _asDouble(summary['avgExcessVsMedian']);
    final missPenalty = (_asDouble(summary['longestMissStreak']) /
            max(1, _asDouble(summary['totalDays'])))
        .clamp(0.0, 1.0);
    return (top1 * 0.58) +
        (recent20 * 0.22) +
        (_normalize(avgExcess, -2.0, 2.5) * 0.12) +
        (_normalize(avgReturn, -2.0, 2.5) * 0.08) -
        (missPenalty * 0.10);
  }

  Map<String, dynamic> _summarizeLeaderExperimentConfig(
    LeaderPredictionExperimentConfig config,
    List<Map<String, dynamic>> records,
  ) {
    final summary = _summarizeLeaderPredictionRecords(records);
    return {
      'round': config.round,
      'id': config.id,
      'label': config.label,
      'family': config.family,
      'corePoolSize': config.corePoolSize,
      'selectionScore': _leaderExperimentSelectionScore(summary),
      'tradeableDays': summary['predictionDays'] ?? 0,
      'corePoolSymbols': records.isEmpty
          ? const <String>[]
          : _asStringList(records.last['corePoolSymbols']),
      ...summary,
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
    List<Map<String, dynamic>> records, {
    List<Map<String, dynamic>> experimentHistory = const [],
    Map<String, dynamic>? bestExperiment,
  }) {
    final settled = records
        .where((record) => record['status']?.toString() == 'settled')
        .toList();
    final recommendRecords = settled
        .where((record) => record['regimeStatus']?.toString() == 'recommend')
        .toList();
    final watchOnlyRecords = settled
        .where((record) => record['regimeStatus']?.toString() == 'watch_only')
        .toList();
    final suppressed = records
        .where((record) => record['regimeStatus']?.toString() == 'stand_aside')
        .length;
    final actionableRecords = settled
        .where((record) =>
            record['actionable'] == true ||
            _isLeaderPredictionActionable(
              record['regimeStatus']?.toString() ?? 'stand_aside',
            ))
        .toList();
    final recent20 =
        settled.length <= 20 ? settled : settled.sublist(settled.length - 20);

    var top1Hits = 0;
    var top3Hits = 0;
    var totalPredictedReturn = 0.0;
    var totalLeaderReturn = 0.0;
    var totalExcess = 0.0;
    var actionableTop1Hits = 0;
    var actionableTop3Hits = 0;
    var actionableReturn = 0.0;
    var recommendTop1Hits = 0;
    var recommendTop3Hits = 0;
    var recommendReturn = 0.0;
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

    for (final record in actionableRecords) {
      if (record['top1Hit'] == true) actionableTop1Hits += 1;
      if (record['top3Hit'] == true) actionableTop3Hits += 1;
      actionableReturn += _asDouble(record['predictedCoinReturn']);
    }

    for (final record in recommendRecords) {
      if (record['top1Hit'] == true) recommendTop1Hits += 1;
      if (record['top3Hit'] == true) recommendTop3Hits += 1;
      recommendReturn += _asDouble(record['predictedCoinReturn']);
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
      'predictionDays': settled.length,
      'recommendDays': recommendRecords.length,
      'watchOnlyDays': watchOnlyRecords.length,
      'actionableDays': actionableRecords.length,
      'suppressedDays': suppressed,
      'suppressRate': records.isEmpty ? 0.0 : suppressed / records.length,
      'top1HitRate': settled.isEmpty ? 0.0 : top1Hits / settled.length,
      'top3HitRate': settled.isEmpty ? 0.0 : top3Hits / settled.length,
      'actionableTop1HitRate': actionableRecords.isEmpty
          ? 0.0
          : actionableTop1Hits / actionableRecords.length,
      'actionableTop3HitRate': actionableRecords.isEmpty
          ? 0.0
          : actionableTop3Hits / actionableRecords.length,
      'recommendTop1HitRate': recommendRecords.isEmpty
          ? 0.0
          : recommendTop1Hits / recommendRecords.length,
      'recommendTop3HitRate': recommendRecords.isEmpty
          ? 0.0
          : recommendTop3Hits / recommendRecords.length,
      'avgPredictedReturn':
          settled.isEmpty ? 0.0 : totalPredictedReturn / settled.length,
      'avgLeaderReturn':
          settled.isEmpty ? 0.0 : totalLeaderReturn / settled.length,
      'avgExcessVsMedian': settled.isEmpty ? 0.0 : totalExcess / settled.length,
      'actionableAvgPredictedReturn': actionableRecords.isEmpty
          ? 0.0
          : actionableReturn / actionableRecords.length,
      'recommendAvgPredictedReturn': recommendRecords.isEmpty
          ? 0.0
          : recommendReturn / recommendRecords.length,
      'recent20Top1HitRate':
          recent20.isEmpty ? 0.0 : recent20Top1Hits / recent20.length,
      'recent20Top3HitRate':
          recent20.isEmpty ? 0.0 : recent20Top3Hits / recent20.length,
      'longestMissStreak': longestMissStreak,
      'latestTop1': latest?['top1Symbol'],
      'latestTop3': latest?['top3Symbols'] ?? const <String>[],
      'currentRegimeStatus': latest?['regimeStatus'] ?? 'stand_aside',
      'currentModelVersion': latest?['modelVersion'],
      'currentConfidence': latest?['confidence'],
      'currentCorePoolSymbols': latest?['corePoolSymbols'] ?? const <String>[],
      'selectedExperimentId': latest?['selectedExperimentId'],
      'selectedExperimentLabel': latest?['selectedExperimentLabel'],
      'bestExperimentId': bestExperiment?['id'],
      'bestExperimentLabel': bestExperiment?['label'],
      'experimentCount': experimentHistory.length,
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
    var missStreak = 0;
    var longestMissStreak = 0;
    final recent20 =
        records.length <= 20 ? records : records.sublist(records.length - 20);
    var recent20Top1Hits = 0;

    for (final record in records) {
      if (record['top1Hit'] == true) {
        top1Hits += 1;
        missStreak = 0;
      } else {
        missStreak += 1;
        if (missStreak > longestMissStreak) {
          longestMissStreak = missStreak;
        }
      }
      if (record['top3Hit'] == true) top3Hits += 1;
      final predictedReturn = record['predictedReturn'];
      if (predictedReturn != null) {
        validPredictions += 1;
        totalPredictedReturn += _asDouble(predictedReturn);
        totalExcess += _asDouble(record['excessVsMedian']);
      }
    }
    for (final record in recent20) {
      if (record['top1Hit'] == true) recent20Top1Hits += 1;
    }

    return {
      'name': name,
      'totalDays': records.length,
      'top1HitRate': top1Hits / records.length,
      'top3HitRate': top3Hits / records.length,
      'recent20Top1HitRate':
          recent20.isEmpty ? 0.0 : recent20Top1Hits / recent20.length,
      'longestMissStreak': longestMissStreak,
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

  double _averageDoubles(List<double> values) {
    if (values.isEmpty) return 0.0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double _realizedVolatilityValues(List<double> values) {
    if (values.length < 2) return 0.0;
    final mean = _averageDoubles(values);
    var total = 0.0;
    for (final value in values) {
      final delta = value - mean;
      total += delta * delta;
    }
    return sqrt(total / values.length);
  }

  Map<String, double> _normalizedRankMap(List<Map<String, dynamic>> ordered) {
    if (ordered.isEmpty) return const <String, double>{};
    if (ordered.length == 1) {
      final only = ordered.first['symbol']?.toString() ?? '';
      return only.isEmpty ? const <String, double>{} : {only: 1.0};
    }

    final map = <String, double>{};
    final denominator = max(1, ordered.length - 1).toDouble();
    for (var index = 0; index < ordered.length; index += 1) {
      final symbol = ordered[index]['symbol']?.toString() ?? '';
      if (symbol.isEmpty) continue;
      map[symbol] = (ordered.length - 1 - index) / denominator;
    }
    return map;
  }

  String _signedPercent(double value) {
    return '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}%';
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

  double _normalize(double value, double minValue, double maxValue) {
    if (maxValue <= minValue) return 0.0;
    return ((value - minValue) / (maxValue - minValue)).clamp(0.0, 1.0);
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

class _LeaderBacktestScenario {
  final int currentDate;
  final int nextDate;
  final List<CoinData> currentCoins;
  final Map<String, List<Kline>> slicedHistory;
  final List<Kline> btcSlice;
  final Map<String, double> actualReturns;
  final String actualLeader;
  final List<String> actualTop3;
  final double medianReturn;
  final double leaderReturn;

  const _LeaderBacktestScenario({
    required this.currentDate,
    required this.nextDate,
    required this.currentCoins,
    required this.slicedHistory,
    required this.btcSlice,
    required this.actualReturns,
    required this.actualLeader,
    required this.actualTop3,
    required this.medianReturn,
    required this.leaderReturn,
  });
}
