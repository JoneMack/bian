import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:binance_analyzer/models/market_snapshot.dart';
import 'package:binance_analyzer/models/news_item.dart';
import 'package:binance_analyzer/services/binance_service.dart';
import 'package:binance_analyzer/services/market_snapshot_service.dart';
import 'package:binance_analyzer/services/news_service.dart';
import 'package:binance_analyzer/services/signal_runner_service.dart';

Future<void> main() async {
  final config = CloudSchedulerConfig.fromEnv();
  final app = _CloudSignalSchedulerApp(config);
  await app.start();
}

class CloudSchedulerConfig {
  final int port;
  final Duration interval;
  final Duration replayMaxAge;
  final Duration startupStrategyMaxAge;
  final Duration marketSnapshotTtl;
  final Duration newsCacheTtl;
  final Duration newsSignalInterval;
  final Duration pushDedupeWindow;
  final bool enableMarketStartupScanner;
  final bool enableNewsSignalPush;
  final int? marketSymbolLimit;
  final int newsSignalFetchLimit;
  final bool runOnStartup;
  final bool runOnce;
  final bool enableInternalScheduler;
  final bool refreshReplayBeforeRun;
  final bool refreshStartupStrategyBeforeRun;
  final bool publishPush;
  final bool dedupePush;
  final PushProvider pushProvider;
  final String? runnerToken;
  final String? feishuWebhookUrl;
  final String? ntfyTopic;
  final String? ntfyServer;
  final String dailyReportPath;
  final String replayReportPath;
  final String startupStrategyReportPath;
  final String leaderPredictionReportPath;
  final String leaderPredictionLogPath;
  final String leaderPredictionStatsPath;
  final String buyLogPath;
  final String clientSignalActionPath;
  final String clientExecutionPath;
  final String newsPushStatePath;
  final String schedulerStatePath;
  final String pushStatePath;
  final List<String>? watchlistSymbols;

  const CloudSchedulerConfig({
    required this.port,
    required this.interval,
    required this.replayMaxAge,
    required this.startupStrategyMaxAge,
    required this.marketSnapshotTtl,
    required this.newsCacheTtl,
    required this.newsSignalInterval,
    required this.pushDedupeWindow,
    required this.enableMarketStartupScanner,
    required this.enableNewsSignalPush,
    required this.marketSymbolLimit,
    required this.newsSignalFetchLimit,
    required this.runOnStartup,
    required this.runOnce,
    required this.enableInternalScheduler,
    required this.refreshReplayBeforeRun,
    required this.refreshStartupStrategyBeforeRun,
    required this.publishPush,
    required this.dedupePush,
    required this.pushProvider,
    required this.runnerToken,
    required this.feishuWebhookUrl,
    required this.ntfyTopic,
    required this.ntfyServer,
    required this.dailyReportPath,
    required this.replayReportPath,
    required this.startupStrategyReportPath,
    required this.leaderPredictionReportPath,
    required this.leaderPredictionLogPath,
    required this.leaderPredictionStatsPath,
    required this.buyLogPath,
    required this.clientSignalActionPath,
    required this.clientExecutionPath,
    required this.newsPushStatePath,
    required this.schedulerStatePath,
    required this.pushStatePath,
    required this.watchlistSymbols,
  });

  factory CloudSchedulerConfig.fromEnv() {
    final env = Platform.environment;
    final runOnce = _boolFromEnv(env['RUN_ONCE'], fallback: false);

    return CloudSchedulerConfig(
      port: int.tryParse(env['PORT'] ?? '8080') ?? 8080,
      interval: Duration(
          minutes: int.tryParse(env['SIGNAL_INTERVAL_MINUTES'] ?? '30') ?? 30),
      replayMaxAge: Duration(
          hours: int.tryParse(env['REPLAY_REFRESH_HOURS'] ?? '12') ?? 12),
      startupStrategyMaxAge: Duration(
          hours: int.tryParse(env['STARTUP_STRATEGY_REFRESH_HOURS'] ?? '24') ??
              24),
      marketSnapshotTtl: Duration(
        seconds: int.tryParse(env['MARKET_SNAPSHOT_TTL_SECONDS'] ?? '90') ?? 90,
      ),
      newsCacheTtl: Duration(
        seconds: int.tryParse(env['NEWS_CACHE_TTL_SECONDS'] ?? '180') ?? 180,
      ),
      newsSignalInterval: Duration(
        minutes:
            int.tryParse(env['NEWS_SIGNAL_INTERVAL_MINUTES'] ?? '120') ?? 120,
      ),
      pushDedupeWindow:
          Duration(hours: int.tryParse(env['PUSH_DEDUPE_HOURS'] ?? '6') ?? 6),
      enableMarketStartupScanner: _boolFromEnv(
        env['ENABLE_MARKET_STARTUP_SCANNER'],
        fallback: true,
      ),
      enableNewsSignalPush:
          _boolFromEnv(env['ENABLE_NEWS_SIGNAL_PUSH'], fallback: true),
      marketSymbolLimit: _intFromEnv(env['MARKET_SYMBOL_LIMIT']),
      newsSignalFetchLimit:
          (int.tryParse(env['NEWS_SIGNAL_FETCH_LIMIT'] ?? '16') ?? 16)
              .clamp(4, 40)
              .toInt(),
      runOnStartup: _boolFromEnv(env['RUN_ON_STARTUP'], fallback: true),
      runOnce: runOnce,
      enableInternalScheduler: _boolFromEnv(
        env['ENABLE_INTERNAL_SCHEDULER'],
        fallback: !runOnce,
      ),
      refreshReplayBeforeRun:
          _boolFromEnv(env['REFRESH_REPLAY_BEFORE_RUN'], fallback: true),
      refreshStartupStrategyBeforeRun: _boolFromEnv(
        env['REFRESH_STARTUP_STRATEGY_BEFORE_RUN'],
        fallback: true,
      ),
      publishPush: _boolFromEnv(env['PUBLISH_PUSH'], fallback: true),
      dedupePush: _boolFromEnv(env['DEDUPE_PUSH'], fallback: true),
      pushProvider: parsePushProvider(env['PUSH_PROVIDER']),
      runnerToken: env['RUNNER_TOKEN'],
      feishuWebhookUrl: env['FEISHU_WEBHOOK_URL'],
      ntfyTopic: env['NTFY_TOPIC'],
      ntfyServer: env['NTFY_SERVER'],
      dailyReportPath: env['DAILY_REPORT_PATH'] ??
          SignalRunnerService.defaultDailyReportPath,
      replayReportPath: env['REPLAY_REPORT_PATH'] ??
          SignalRunnerService.defaultReplayReportPath,
      startupStrategyReportPath: env['STARTUP_STRATEGY_REPORT_PATH'] ??
          SignalRunnerService.defaultStartupStrategyReportPath,
      leaderPredictionReportPath: env['LEADER_PREDICTION_REPORT_PATH'] ??
          SignalRunnerService.defaultLeaderPredictionReportPath,
      leaderPredictionLogPath: env['LEADER_PREDICTION_LOG_PATH'] ??
          SignalRunnerService.defaultLeaderPredictionLogPath,
      leaderPredictionStatsPath: env['LEADER_PREDICTION_STATS_PATH'] ??
          SignalRunnerService.defaultLeaderPredictionStatsPath,
      buyLogPath:
          env['BUY_LOG_PATH'] ?? SignalRunnerService.defaultStartupBuyLogPath,
      clientSignalActionPath: env['CLIENT_SIGNAL_ACTION_PATH'] ??
          SignalRunnerService.defaultClientSignalActionLogPath,
      clientExecutionPath: env['CLIENT_EXECUTION_PATH'] ??
          SignalRunnerService.defaultClientExecutionCyclePath,
      newsPushStatePath:
          env['NEWS_PUSH_STATE_PATH'] ?? 'build/reports/news_push_state.json',
      schedulerStatePath: env['SCHEDULER_STATE_PATH'] ??
          'build/reports/cloud_scheduler_state.json',
      pushStatePath:
          env['PUSH_STATE_PATH'] ?? SignalRunnerService.defaultPushStatePath,
      watchlistSymbols: _loadSymbols(env['WATCHLIST']),
    );
  }

  static bool _boolFromEnv(String? value, {required bool fallback}) {
    if (value == null || value.trim().isEmpty) return fallback;
    final normalized = value.trim().toLowerCase();
    if (normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on') {
      return true;
    }
    if (normalized == '0' ||
        normalized == 'false' ||
        normalized == 'no' ||
        normalized == 'off') {
      return false;
    }
    return fallback;
  }

  static List<String>? _loadSymbols(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return raw
        .split(',')
        .map(BinanceService.toSymbol)
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  static int? _intFromEnv(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = int.tryParse(raw.trim());
    if (value == null || value <= 0) return null;
    return value;
  }
}

class _CloudSignalSchedulerApp {
  final CloudSchedulerConfig config;
  final SignalRunnerService _service = SignalRunnerService();
  final MarketSnapshotService _snapshotService = MarketSnapshotService();
  final NewsService _newsService = NewsService();

  HttpServer? _server;
  bool _running = false;
  int _runCount = 0;
  final DateTime _startedAt = DateTime.now();

  DateTime? _lastRunAt;
  DateTime? _nextRunAt;
  String _lastStatus = 'idle';
  String? _lastError;
  String? _lastTrigger;
  Map<String, dynamic>? _latestReport;
  Map<String, dynamic>? _latestReplay;
  MarketSnapshot? _latestSnapshot;
  String? _latestSnapshotKey;
  List<NewsItem>? _latestNews;
  String? _latestNewsKey;
  DateTime? _latestNewsAt;
  Map<String, dynamic>? _latestPredictionLog;
  Map<String, dynamic>? _latestClientSignalActionLog;
  Map<String, dynamic>? _latestClientExecutionLog;
  Map<String, dynamic>? _lastNewsSignal;
  DateTime? _lastNewsSignalAt;
  PushDeliveryResult? _lastPush;

  _CloudSignalSchedulerApp(this.config);

  String _modeName() {
    return config.enableMarketStartupScanner
        ? 'leader_prediction'
        : 'watchlist_rotation';
  }

  String _primaryReportPath() {
    return config.enableMarketStartupScanner
        ? config.leaderPredictionReportPath
        : config.dailyReportPath;
  }

  String _predictionStatsPath() {
    return config.enableMarketStartupScanner
        ? config.leaderPredictionStatsPath
        : config.buyLogPath;
  }

  Future<void> start() async {
    await _loadArtifacts();

    stdout.writeln(
      'Push config: publish=${config.publishPush} '
      'mode=${_modeName()} '
      'provider=${config.pushProvider.name} '
      'effective=${_effectivePushProviderName() ?? 'none'} '
      'feishuConfigured=${_hasFeishuWebhook()} '
      'ntfyConfigured=${_hasNtfyTopic()} '
      'dedupe=${config.dedupePush}',
    );

    if (config.runOnce) {
      await _runCycle(trigger: 'run_once');
      return;
    }

    _server = await HttpServer.bind(InternetAddress.anyIPv4, config.port);
    stdout.writeln(
      'Cloud scheduler listening on 0.0.0.0:${config.port} '
      '(interval ${config.interval.inMinutes}m)',
    );

    if (config.enableInternalScheduler) {
      _nextRunAt = DateTime.now().add(config.interval);
      Timer.periodic(config.interval, (_) {
        _nextRunAt = DateTime.now().add(config.interval);
        unawaited(_runCycle(trigger: 'schedule'));
      });
    }

    if (config.runOnStartup) {
      unawaited(_runCycle(trigger: 'startup'));
    } else {
      await _saveState();
    }

    await for (final request in _server!) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _loadArtifacts() async {
    final state = await _service.loadJsonArtifact(config.schedulerStatePath);
    _latestReport = await _loadIfPresent(_primaryReportPath());
    _latestReplay = await _loadIfPresent(config.replayReportPath);
    _latestPredictionLog = await _loadIfPresent(_predictionStatsPath());
    _latestClientSignalActionLog =
        await _loadIfPresent(config.clientSignalActionPath);
    _latestClientExecutionLog =
        await _loadIfPresent(config.clientExecutionPath);
    _lastRunAt = DateTime.tryParse(state['lastRunAt'] as String? ?? '');
    _lastStatus = state['lastStatus'] as String? ?? _lastStatus;
    _lastError = state['lastError'] as String?;
    _lastTrigger = state['lastTrigger'] as String?;
    _runCount = state['runCount'] as int? ?? 0;
    _lastNewsSignalAt =
        DateTime.tryParse(state['lastNewsSignalAt'] as String? ?? '');
    final newsSignal = state['lastNewsSignal'];
    if (newsSignal is Map) {
      _lastNewsSignal = Map<String, dynamic>.from(newsSignal);
    }

    final push = state['lastPush'];
    if (push is Map) {
      final map = Map<String, dynamic>.from(push);
      _lastPush = PushDeliveryResult(
        attempted: map['attempted'] as bool? ?? false,
        sent: map['sent'] as bool? ?? false,
        provider: map['provider'] as String? ?? 'unknown',
        status: map['status'] as String? ?? 'unknown',
        message: map['message'] as String? ?? '',
        digest: map['digest'] as String?,
        recordedAt: DateTime.tryParse(map['recordedAt'] as String? ?? '') ??
            DateTime.now(),
      );
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path.isEmpty ? '/' : request.uri.path;

      if (request.method == 'GET' && path == '/') {
        await _writeJson(request.response, HttpStatus.ok, {
          'service': 'binance-analyzer-cloud-scheduler',
          'statusEndpoint': '/health',
          'latestEndpoint': '/latest',
          'replayEndpoint': '/replay',
          'marketSnapshotEndpoint': '/market-snapshot',
          'newsEndpoint': '/news',
          'predictionStatsEndpoint': '/prediction-stats',
          'signalActionEndpoint': '/signal-action',
          'signalActionsEndpoint': '/signal-actions',
          'executionStatsEndpoint': '/execution-stats',
          'runEndpoint': '/run',
          'pushTestEndpoint': '/push-test',
          'internalScheduler': config.enableInternalScheduler,
          'manualRunRequiresToken': (config.runnerToken?.isNotEmpty ?? false),
          'marketSnapshotCacheSeconds': config.marketSnapshotTtl.inSeconds,
          'newsCacheSeconds': config.newsCacheTtl.inSeconds,
          'pushProvider': config.pushProvider.name,
          'effectivePushProvider': _effectivePushProviderName(),
          'startupStrategyReportPath': config.startupStrategyReportPath,
          'leaderPredictionReportPath': config.leaderPredictionReportPath,
          'leaderPredictionStatsPath': config.leaderPredictionStatsPath,
        });
        return;
      }

      if (request.method == 'GET' && path == '/health') {
        await _writeJson(request.response, HttpStatus.ok, _healthPayload());
        return;
      }

      if (request.method == 'GET' && path == '/latest') {
        final payload =
            _latestReport ?? await _loadIfPresent(_primaryReportPath());
        if (payload == null || payload.isEmpty) {
          await _writeJson(request.response, HttpStatus.notFound, {
            'error': 'latest report not found',
          });
          return;
        }
        _latestReport = payload;
        await _writeJson(request.response, HttpStatus.ok, payload);
        return;
      }

      if (request.method == 'GET' && path == '/replay') {
        final payload =
            _latestReplay ?? await _loadIfPresent(config.replayReportPath);
        if (payload == null || payload.isEmpty) {
          await _writeJson(request.response, HttpStatus.notFound, {
            'error': 'replay report not found',
          });
          return;
        }
        _latestReplay = payload;
        await _writeJson(request.response, HttpStatus.ok, payload);
        return;
      }

      if (request.method == 'GET' && path == '/market-snapshot') {
        final requestedSymbols = _requestedSymbolsFrom(request);
        final forceRefresh = request.uri.queryParameters['refresh'] == '1';
        final snapshot = await _loadMarketSnapshot(
          requestedSymbols: requestedSymbols,
          forceRefresh: forceRefresh,
        );
        await _writeJson(request.response, HttpStatus.ok, snapshot.toJson());
        return;
      }

      if (request.method == 'GET' && path == '/news') {
        final limit = _requestedNewsLimitFrom(request);
        final requestedCategories = _requestedNewsCategoriesFrom(request);
        final forceRefresh = request.uri.queryParameters['refresh'] == '1';
        final items = await _loadNewsFeed(
          limit: limit,
          requestedCategories: requestedCategories,
          forceRefresh: forceRefresh,
        );
        await _writeJson(request.response, HttpStatus.ok, {
          'items': items.map((item) => item.toJson()).toList(),
          'limit': limit,
          'categories': requestedCategories,
          'updatedAt': _latestNewsAt?.toIso8601String(),
          'cacheTtlSeconds': config.newsCacheTtl.inSeconds,
        });
        return;
      }

      if (request.method == 'GET' && path == '/prediction-stats') {
        final forceRefresh = request.uri.queryParameters['refresh'] == '1';
        Map<String, dynamic>? payload;
        if (config.enableMarketStartupScanner) {
          payload = forceRefresh || _latestPredictionLog?['summary'] == null
              ? await _service.refreshLeaderPredictionStats(
                  requestedSymbols: config.watchlistSymbols,
                  logPath: config.leaderPredictionLogPath,
                  statsPath: config.leaderPredictionStatsPath,
                )
              : (_latestPredictionLog ??
                  await _loadIfPresent(config.leaderPredictionStatsPath));
        } else {
          payload = forceRefresh || _latestPredictionLog?['summary'] == null
              ? await _service.refreshStartupPredictionLog(
                  path: config.buyLogPath,
                )
              : (_latestPredictionLog ??
                  await _loadIfPresent(config.buyLogPath));
        }
        if (payload == null || payload.isEmpty) {
          await _writeJson(request.response, HttpStatus.notFound, {
            'error': 'prediction stats not found',
          });
          return;
        }
        _latestPredictionLog = payload;
        await _writeJson(request.response, HttpStatus.ok, payload);
        return;
      }

      if (request.method == 'GET' && path == '/signal-actions') {
        final limit = _requestedSignalActionLimitFrom(request);
        final payload = await _service.loadClientSignalActionLog(
          path: config.clientSignalActionPath,
          limit: limit,
        );
        _latestClientSignalActionLog = payload;
        await _writeJson(request.response, HttpStatus.ok, payload);
        return;
      }

      if (request.method == 'GET' && path == '/execution-stats') {
        final limit = _requestedSignalActionLimitFrom(request);
        final payload = await _service.loadClientExecutionLog(
          path: config.clientExecutionPath,
          limit: limit,
        );
        _latestClientExecutionLog = payload;
        await _writeJson(request.response, HttpStatus.ok, payload);
        return;
      }

      if (request.method == 'POST' && path == '/signal-action') {
        final body = await _readJsonBody(request);
        final signalId = body['signalId']?.toString().trim() ?? '';
        final symbol = body['symbol']?.toString().trim() ?? '';
        final signalType =
            body['signalType']?.toString().trim().toLowerCase() ?? '';
        final actionType =
            body['actionType']?.toString().trim().toLowerCase() ?? '';
        final signalSource =
            body['signalSource']?.toString().trim().toLowerCase() ?? 'feishu';

        if (signalId.isEmpty ||
            symbol.isEmpty ||
            signalType.isEmpty ||
            (actionType != 'confirm' && actionType != 'cancel')) {
          await _writeJson(request.response, HttpStatus.badRequest, {
            'error': 'invalid payload',
            'required': [
              'signalId',
              'symbol',
              'signalType',
              'actionType(confirm/cancel)',
            ],
          });
          return;
        }

        final payload = await _service.recordClientSignalAction(
          path: config.clientSignalActionPath,
          executionPath: config.clientExecutionPath,
          signalId: signalId,
          symbol: symbol,
          signalType: signalType,
          signalSource: signalSource,
          actionType: actionType,
          price: (body['price'] as num?)?.toDouble() ?? 0,
          timingLabel: body['timingLabel']?.toString() ?? '',
          timingReason: body['timingReason']?.toString() ?? '',
          totalScore: (body['totalScore'] as num?)?.toDouble() ?? 0,
          entryScore: (body['entryScore'] as num?)?.toDouble() ?? 0,
          note: body['note']?.toString() ?? '',
          client: body['client']?.toString() ?? 'app',
        );
        _latestClientSignalActionLog = await _service.loadClientSignalActionLog(
          path: config.clientSignalActionPath,
        );
        _latestClientExecutionLog = await _service.loadClientExecutionLog(
          path: config.clientExecutionPath,
        );
        final created = payload['created'] == true;
        await _writeJson(
          request.response,
          created ? HttpStatus.created : HttpStatus.ok,
          payload,
        );
        return;
      }

      if ((request.method == 'GET' || request.method == 'POST') &&
          path == '/run') {
        if (!_isAuthorized(request)) {
          await _writeJson(request.response, HttpStatus.forbidden, {
            'error': 'manual run disabled or invalid RUNNER_TOKEN',
          });
          return;
        }

        if (_running) {
          await _writeJson(request.response, HttpStatus.conflict, {
            'error': 'run already in progress',
            ..._healthPayload(),
          });
          return;
        }

        final sync = request.uri.queryParameters['sync'] == '1';
        if (sync) {
          await _runCycle(trigger: 'manual_sync');
          await _writeJson(request.response, HttpStatus.ok, _healthPayload());
          return;
        }

        unawaited(_runCycle(trigger: 'manual_async'));
        await _writeJson(request.response, HttpStatus.accepted, {
          'status': 'accepted',
          'message': 'manual run started',
          ..._healthPayload(),
        });
        return;
      }

      if ((request.method == 'GET' || request.method == 'POST') &&
          path == '/push-test') {
        if (!_isAuthorized(request)) {
          await _writeJson(request.response, HttpStatus.forbidden, {
            'error': 'manual push test disabled or invalid RUNNER_TOKEN',
          });
          return;
        }

        final queryProvider = request.uri.queryParameters['provider'];
        final provider = (queryProvider == null || queryProvider.trim().isEmpty)
            ? config.pushProvider
            : parsePushProvider(queryProvider);

        final result = await _service.publishTestMessage(
          provider: provider,
          feishuWebhookUrl: config.feishuWebhookUrl,
          topic: config.ntfyTopic,
          server: config.ntfyServer,
          message: request.uri.queryParameters['message'],
        );

        final statusCode = result.sent ? HttpStatus.ok : HttpStatus.badRequest;
        await _writeJson(request.response, statusCode, {
          'status': result.sent ? 'ok' : 'skipped',
          'result': result.toJson(),
          ..._pushConfigPayload(),
        });
        return;
      }

      await _writeJson(request.response, HttpStatus.notFound, {
        'error': 'not found',
      });
    } catch (error) {
      await _writeJson(request.response, HttpStatus.internalServerError, {
        'error': error.toString(),
      });
    }
  }

  Future<void> _runCycle({required String trigger}) async {
    if (_running) return;

    _running = true;
    _lastStatus = 'running';
    _lastTrigger = trigger;
    _lastError = null;
    await _saveState();

    try {
      if (!config.enableMarketStartupScanner && config.refreshReplayBeforeRun) {
        final replay = await _service.ensureFreshReplayReport(
          requestedSymbols: config.watchlistSymbols,
          replayReportPath: config.replayReportPath,
          maxAge: config.replayMaxAge,
        );
        _latestReplay = await _loadIfPresent(config.replayReportPath);
        stdout.writeln(
          '[${DateTime.now().toIso8601String()}] replay '
          '${replay.refreshed ? 'refreshed' : 'reused'} '
          '-> ${replay.report.optimizedPolicy.summary}',
        );
      }

      if (config.enableMarketStartupScanner) {
        final result = await _service.runLeaderPrediction(
          requestedSymbols: config.watchlistSymbols,
          reportPath: config.leaderPredictionReportPath,
          logPath: config.leaderPredictionLogPath,
          statsPath: config.leaderPredictionStatsPath,
          pushProvider: config.pushProvider,
          feishuWebhookUrl: config.feishuWebhookUrl,
          ntfyTopic: config.ntfyTopic,
          ntfyServer: config.ntfyServer,
          publishPush: config.publishPush,
          dedupePush: config.dedupePush,
          pushStatePath: config.pushStatePath,
          pushDedupeWindow: config.pushDedupeWindow,
        );

        _latestReport = result.payload;
        _lastPush = result.pushResult;
        _lastRunAt = result.generatedAt;
        _lastStatus = 'ok';
        _lastError = null;
        _runCount += 1;
        _latestSnapshot = null;
        _latestSnapshotKey = null;
        _latestPredictionLog =
            await _loadIfPresent(config.leaderPredictionStatsPath);
        final top1 = (result.payload['top1'] as Map?)?['symbol']?.toString();
        final top3 = (result.payload['top3'] as List<dynamic>? ?? const [])
            .map((item) => (item as Map)['symbol']?.toString() ?? '')
            .where((item) => item.isNotEmpty)
            .take(3)
            .toList();

        stdout.writeln(
          '[${result.generatedAt.toIso8601String()}] $trigger '
          'mode=leader_prediction '
          'regime=${result.result.regimeStatus} '
          'top1=${top1 ?? 'none'} '
          'top3=${top3.join(',')} '
          'push=${result.pushResult.status} '
          'provider=${result.pushResult.provider} '
          'message=${result.pushResult.message}',
        );
      } else {
        final result = await _service.runDailySignal(
          requestedSymbols: config.watchlistSymbols,
          dailyReportPath: config.dailyReportPath,
          replayReportPath: config.replayReportPath,
          pushProvider: config.pushProvider,
          feishuWebhookUrl: config.feishuWebhookUrl,
          ntfyTopic: config.ntfyTopic,
          ntfyServer: config.ntfyServer,
          publishPush: config.publishPush,
          dedupePush: config.dedupePush,
          pushStatePath: config.pushStatePath,
          pushDedupeWindow: config.pushDedupeWindow,
        );

        _latestReport = result.payload;
        _lastPush = result.pushResult;
        _lastRunAt = result.generatedAt;
        _lastStatus = 'ok';
        _lastError = null;
        _runCount += 1;
        _latestSnapshot = null;
        _latestSnapshotKey = null;

        stdout.writeln(
          '[${result.generatedAt.toIso8601String()}] $trigger '
          'preset=${result.engine.report.presetLabel} '
          'push=${result.pushResult.status} '
          'provider=${result.pushResult.provider} '
          'message=${result.pushResult.message}',
        );
      }

      await _maybePublishNewsSignals(trigger: trigger);
    } catch (error, stackTrace) {
      _lastRunAt = DateTime.now();
      _lastStatus = 'error';
      _lastError = error.toString();
      stderr.writeln(
        '[${DateTime.now().toIso8601String()}] $trigger failed: $error',
      );
      stderr.writeln(stackTrace);
    } finally {
      _running = false;
      if (config.enableInternalScheduler) {
        _nextRunAt = DateTime.now().add(config.interval);
      }
      await _saveState();
    }
  }

  bool _isAuthorized(HttpRequest request) {
    final token = config.runnerToken?.trim() ?? '';
    if (token.isEmpty) return false;

    final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
    if (authHeader != null) {
      final normalized = authHeader.trim();
      if (normalized == 'Bearer $token') {
        return true;
      }
    }

    return request.uri.queryParameters['token'] == token;
  }

  Map<String, dynamic> _healthPayload() {
    final leaderTop3 = (_latestReport?['top3'] as List<dynamic>? ?? const [])
        .map((item) => (item as Map)['symbol']?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .take(3)
        .toList();
    dynamic startupMarketRegime;
    if (config.enableMarketStartupScanner) {
      startupMarketRegime = _latestReport?['regimeStatus'];
    } else {
      final nestedReport = _latestReport?['report'];
      startupMarketRegime =
          nestedReport is Map ? nestedReport['marketRegime'] : null;
    }

    return {
      'status': _lastStatus,
      'running': _running,
      'startedAt': _startedAt.toIso8601String(),
      'lastRunAt': _lastRunAt?.toIso8601String(),
      'lastTrigger': _lastTrigger,
      'lastError': _lastError,
      'nextRunAt': _nextRunAt?.toIso8601String(),
      'runCount': _runCount,
      'intervalMinutes': config.interval.inMinutes,
      'mode': _modeName(),
      'dailyReportPath': config.dailyReportPath,
      'replayReportPath': config.replayReportPath,
      'startupStrategyReportPath': config.startupStrategyReportPath,
      'leaderPredictionReportPath': config.leaderPredictionReportPath,
      'leaderPredictionLogPath': config.leaderPredictionLogPath,
      'leaderPredictionStatsPath': config.leaderPredictionStatsPath,
      'buyLogPath': config.buyLogPath,
      'clientSignalActionPath': config.clientSignalActionPath,
      'clientExecutionPath': config.clientExecutionPath,
      'marketSnapshotCacheSeconds': config.marketSnapshotTtl.inSeconds,
      'newsCacheSeconds': config.newsCacheTtl.inSeconds,
      'latestSnapshotAt': _latestSnapshot?.updatedAt.toIso8601String(),
      'latestSnapshotSymbols': _latestSnapshot?.watchlistSymbols,
      'latestNewsAt': _latestNewsAt?.toIso8601String(),
      'latestNewsCount': _latestNews?.length,
      'newsSignalIntervalMinutes': config.newsSignalInterval.inMinutes,
      'enableNewsSignalPush': config.enableNewsSignalPush,
      'lastNewsSignalAt': _lastNewsSignalAt?.toIso8601String(),
      'lastNewsSignal': _lastNewsSignal,
      'leaderPredictionSummary': _latestPredictionLog?['summary'],
      'leaderPredictionUpdatedAt': _latestPredictionLog?['updatedAt'],
      'leaderPredictionRegime': _latestReport?['regimeStatus'] ??
          (_latestReport?['summary'] as Map?)?['regimeStatus'],
      'leaderPredictionRotationConfirmed':
          (_latestReport?['summary'] as Map?)?['rotationConfirmed'] ??
              (_latestPredictionLog?['summary'] as Map?)?['rotationConfirmed'],
      'leaderPredictionConfidence': _latestReport?['confidence'] ??
          (_latestReport?['summary'] as Map?)?['confidence'] ??
          (_latestPredictionLog?['summary'] as Map?)?['currentConfidence'],
      'leaderPredictionCorePoolSymbols':
          _latestReport?['corePoolSymbols'] ??
              (_latestReport?['summary'] as Map?)?['corePoolSymbols'] ??
              (_latestPredictionLog?['summary'] as Map?)?['currentCorePoolSymbols'],
      'leaderPredictionModelVersion': _latestReport?['modelVersion'] ??
          (_latestReport?['summary'] as Map?)?['modelVersion'] ??
          (_latestPredictionLog?['summary'] as Map?)?['currentModelVersion'],
      'leaderPredictionSelectedExperimentId':
          _latestReport?['selectedExperimentId'] ??
              (_latestReport?['summary'] as Map?)?['selectedExperimentId'] ??
              (_latestPredictionLog?['summary'] as Map?)?['selectedExperimentId'],
      'leaderPredictionSelectedExperimentLabel':
          _latestReport?['selectedExperimentLabel'] ??
              (_latestReport?['summary'] as Map?)?['selectedExperimentLabel'] ??
              (_latestPredictionLog?['summary'] as Map?)?['selectedExperimentLabel'],
      'leaderPredictionTop1': (_latestReport?['top1'] as Map?)?['symbol'] ??
          (_latestReport?['summary'] as Map?)?['top1Symbol'],
      'leaderPredictionTop3': leaderTop3,
      'startupPredictionSummary': _latestPredictionLog?['summary'],
      'startupPredictionUpdatedAt': _latestPredictionLog?['updatedAt'],
      'startupPolicySelection': config.enableMarketStartupScanner
          ? null
          : _latestReport?['policySelection'],
      'clientSignalActionSummary': _latestClientSignalActionLog?['summary'],
      'clientSignalActionUpdatedAt': _latestClientSignalActionLog?['updatedAt'],
      'clientExecutionSummary': _latestClientExecutionLog?['summary'],
      'clientExecutionUpdatedAt': _latestClientExecutionLog?['updatedAt'],
      'startupMarketRegime': startupMarketRegime,
      'lastPush': _lastPush?.toJson(),
      'latestTop3': _latestSummaryItems(),
      ..._pushConfigPayload(),
    };
  }

  List<dynamic> _latestSummaryItems() {
    final top3 = _latestReport?['top3'];
    if (top3 is List) return top3.take(3).toList();

    final actionable = _latestReport?['actionableCandidates'];
    if (actionable is List) return actionable.take(3).toList();

    final observations = _latestReport?['observationCandidates'];
    if (observations is List) return observations.take(3).toList();

    final marketBottomActionable =
        _latestReport?['marketBottomActionableCandidates'];
    if (marketBottomActionable is List) {
      return marketBottomActionable.take(3).toList();
    }

    final nestedReport = _latestReport?['report'];
    if (nestedReport is Map) {
      final candidates = nestedReport['candidates'];
      if (candidates is List) return candidates.take(3).toList();
    }

    final bottomAlert = _latestReport?['marketBottomAlert'];
    if (bottomAlert is Map) {
      final candidates = bottomAlert['candidates'];
      if (candidates is List) return candidates.take(3).toList();
    }

    return const [];
  }

  Map<String, dynamic> _pushConfigPayload() {
    return {
      'publishPush': config.publishPush,
      'dedupePush': config.dedupePush,
      'pushProvider': config.pushProvider.name,
      'effectivePushProvider': _effectivePushProviderName(),
      'newsPushStatePath': config.newsPushStatePath,
      'hasRunnerToken': (config.runnerToken?.trim().isNotEmpty ?? false),
      'hasFeishuWebhook': _hasFeishuWebhook(),
      'hasNtfyTopic': _hasNtfyTopic(),
      'feishuWebhookHost': _feishuWebhookHost(),
    };
  }

  bool _hasFeishuWebhook() =>
      config.feishuWebhookUrl?.trim().isNotEmpty ?? false;

  bool _hasNtfyTopic() => config.ntfyTopic?.trim().isNotEmpty ?? false;

  String? _effectivePushProviderName() {
    switch (config.pushProvider) {
      case PushProvider.feishu:
        return _hasFeishuWebhook() ? PushProvider.feishu.name : null;
      case PushProvider.ntfy:
        return _hasNtfyTopic() ? PushProvider.ntfy.name : null;
      case PushProvider.auto:
        if (_hasFeishuWebhook()) return PushProvider.feishu.name;
        if (_hasNtfyTopic()) return PushProvider.ntfy.name;
        return null;
    }
  }

  String? _feishuWebhookHost() {
    final raw = config.feishuWebhookUrl?.trim() ?? '';
    if (raw.isEmpty) return null;
    return Uri.tryParse(raw)?.host;
  }

  Future<void> _maybePublishNewsSignals({required String trigger}) async {
    if (!config.enableNewsSignalPush) {
      return;
    }

    final now = DateTime.now();
    final isManualTrigger = trigger.startsWith('manual');
    if (!isManualTrigger &&
        _lastNewsSignalAt != null &&
        now.difference(_lastNewsSignalAt!) < config.newsSignalInterval) {
      return;
    }

    try {
      final items = await _loadNewsFeed(
        limit: config.newsSignalFetchLimit,
        requestedCategories: const [],
        forceRefresh: true,
      );
      final summary = _newsService.buildPredictiveSignalSummary(items);
      final bullishSymbols =
          summary['bullishSymbols'] as List<dynamic>? ?? const [];
      final bearishSymbols =
          summary['bearishSymbols'] as List<dynamic>? ?? const [];
      final actionable = summary['actionable'] == true;
      PushDeliveryResult pushResult;
      if (config.publishPush && actionable && _hasFeishuWebhook()) {
        pushResult = await _service.publishTextMessage(
          provider: PushProvider.feishu,
          feishuWebhookUrl: config.feishuWebhookUrl,
          body: _buildNewsSignalPushBody(summary),
          title: 'Binance Analyzer News Prediction',
          dedupe: config.dedupePush,
          statePath: config.newsPushStatePath,
          dedupeWindow: config.pushDedupeWindow,
          dedupeKey: 'major_news_prediction',
          successMessage: '已推送新闻影响预测',
        );
      } else {
        pushResult = PushDeliveryResult(
          attempted: false,
          sent: false,
          provider: _hasFeishuWebhook() ? 'feishu' : 'none',
          status: actionable ? 'disabled' : 'skipped_no_actionable',
          message: actionable
              ? (_hasFeishuWebhook()
                  ? '新闻推送已关闭，未发送预测结果'
                  : '未配置飞书 webhook，跳过新闻预测推送')
              : '当前没有高确信度的新闻方向预测',
          recordedAt: now,
        );
      }

      _lastNewsSignalAt = now;
      _lastNewsSignal = {
        'checkedAt': now.toIso8601String(),
        'trigger': trigger,
        'marketDirection': summary['marketDirection'],
        'marketScore': summary['marketScore'],
        'bullishCount': bullishSymbols.length,
        'bearishCount': bearishSymbols.length,
        'summary': summary,
        'pushResult': pushResult.toJson(),
      };

      stdout.writeln(
        '[${now.toIso8601String()}] news_signal '
        'market=${summary['marketDirection']} '
        'bullish=${bullishSymbols.length} '
        'bearish=${bearishSymbols.length} '
        'push=${pushResult.status} '
        'provider=${pushResult.provider}',
      );
    } catch (error, stackTrace) {
      _lastNewsSignalAt = now;
      _lastNewsSignal = {
        'checkedAt': now.toIso8601String(),
        'trigger': trigger,
        'status': 'error',
        'message': error.toString(),
      };
      stderr.writeln(
        '[${now.toIso8601String()}] news_signal failed: $error',
      );
      stderr.writeln(stackTrace);
    }
  }

  String _buildNewsSignalPushBody(Map<String, dynamic> summary) {
    final buffer = StringBuffer()..writeln('Binance 新闻影响预测');
    final marketDirection = summary['marketDirection']?.toString() ?? 'neutral';
    final marketReason = summary['marketReason']?.toString() ?? '';
    final marketScore = (summary['marketScore'] as num?)?.toDouble() ?? 0.0;
    final bullishSymbols =
        (summary['bullishSymbols'] as List<dynamic>? ?? const [])
            .cast<Map<dynamic, dynamic>>();
    final bearishSymbols =
        (summary['bearishSymbols'] as List<dynamic>? ?? const [])
            .cast<Map<dynamic, dynamic>>();
    final topSignals = (summary['topSignals'] as List<dynamic>? ?? const [])
        .cast<Map<dynamic, dynamic>>();

    buffer
      ..writeln(
        '市场方向: ${marketDirection == 'bullish' ? '偏多' : marketDirection == 'bearish' ? '偏空' : '中性'} '
        '| 强度 ${marketScore.toStringAsFixed(2)}',
      )
      ..writeln('市场原因: $marketReason');

    if (bullishSymbols.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('利好多币:');
      for (final item in bullishSymbols.take(4)) {
        final symbol = item['symbol']?.toString() ?? '';
        final score = (item['score'] as num?)?.toDouble() ?? 0.0;
        final reasons = (item['reasons'] as List<dynamic>? ?? const [])
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .take(2)
            .join('、');
        buffer.writeln(
          '$symbol | ${score.toStringAsFixed(2)} | ${reasons.isEmpty ? '新闻偏利多' : reasons}',
        );
      }
    }

    if (bearishSymbols.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('利空币:');
      for (final item in bearishSymbols.take(4)) {
        final symbol = item['symbol']?.toString() ?? '';
        final score = (item['score'] as num?)?.toDouble() ?? 0.0;
        final reasons = (item['reasons'] as List<dynamic>? ?? const [])
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .take(2)
            .join('、');
        buffer.writeln(
          '$symbol | ${score.toStringAsFixed(2)} | ${reasons.isEmpty ? '新闻偏利空' : reasons}',
        );
      }
    }

    if (topSignals.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('重点新闻:');
      for (final raw in topSignals.take(3)) {
        final item = Map<String, dynamic>.from(raw);
        final title =
            item['translatedTitle']?.toString().trim().isNotEmpty == true
                ? item['translatedTitle']?.toString().trim()
                : item['title']?.toString().trim() ?? '';
        final impactSummary = item['impactSummary']?.toString() ?? '';
        buffer.writeln('• $title');
        if (impactSummary.isNotEmpty) {
          buffer.writeln('  $impactSummary');
        }
      }
    }

    return buffer.toString().trim();
  }

  List<String> _requestedSymbolsFrom(HttpRequest request) {
    final raw = request.uri.queryParameters['symbols'];
    final source = raw == null || raw.trim().isEmpty
        ? (config.watchlistSymbols ?? BinanceService.defaultWatchlistSymbols)
        : raw.split(',');
    return _normalizeSymbols(source);
  }

  int _requestedNewsLimitFrom(HttpRequest request) {
    final parsed = int.tryParse(request.uri.queryParameters['limit'] ?? '');
    if (parsed == null || parsed <= 0) {
      return 40;
    }
    if (parsed > 80) {
      return 80;
    }
    return parsed;
  }

  int _requestedSignalActionLimitFrom(HttpRequest request) {
    final parsed = int.tryParse(request.uri.queryParameters['limit'] ?? '');
    if (parsed == null || parsed <= 0) {
      return 200;
    }
    if (parsed > 500) {
      return 500;
    }
    return parsed;
  }

  List<String> _requestedNewsCategoriesFrom(HttpRequest request) {
    final raw = request.uri.queryParameters['categories'];
    final source = raw == null || raw.trim().isEmpty
        ? (config.watchlistSymbols ?? BinanceService.defaultWatchlistSymbols)
            .map((symbol) => symbol.replaceAll('USDT', ''))
            .toList()
        : raw.split(',');
    return _normalizeCategories(source);
  }

  List<String> _normalizeSymbols(List<String> symbols) {
    final unique = <String>{};
    for (final symbol in symbols) {
      final normalized = BinanceService.toSymbol(symbol);
      if (normalized.isNotEmpty) {
        unique.add(normalized);
      }
    }
    final ordered = unique.toList();
    ordered.sort();
    return ordered;
  }

  List<String> _normalizeCategories(List<String> categories) {
    final unique = <String>{};
    for (final category in categories) {
      final normalized = category.trim().toUpperCase();
      if (normalized.isNotEmpty) {
        unique.add(normalized);
      }
    }
    final ordered = unique.toList();
    ordered.sort();
    return ordered;
  }

  Future<MarketSnapshot> _loadMarketSnapshot({
    required List<String> requestedSymbols,
    bool forceRefresh = false,
  }) async {
    final normalizedSymbols = requestedSymbols.isEmpty
        ? (config.watchlistSymbols ?? BinanceService.defaultWatchlistSymbols)
        : requestedSymbols;
    final cacheKey = normalizedSymbols.join(',');
    final cached = _latestSnapshot;

    if (!forceRefresh &&
        cached != null &&
        _latestSnapshotKey == cacheKey &&
        DateTime.now().difference(cached.updatedAt) <=
            config.marketSnapshotTtl) {
      return cached;
    }

    final replaySymbols = config.watchlistSymbols ?? normalizedSymbols;
    if (config.refreshReplayBeforeRun) {
      final replay = await _service.ensureFreshReplayReport(
        requestedSymbols: replaySymbols,
        replayReportPath: config.replayReportPath,
        maxAge: config.replayMaxAge,
      );
      _latestReplay = await _loadIfPresent(config.replayReportPath);
      stdout.writeln(
        '[${DateTime.now().toIso8601String()}] market snapshot policy '
        '${replay.refreshed ? 'refreshed' : 'reused'}',
      );
    }

    final policy = await _service.loadOptimizedPolicy(
      replayReportPath: config.replayReportPath,
    );
    final snapshot = await _snapshotService.buildSnapshot(
      requestedSymbols: normalizedSymbols,
      policy: policy,
      forceRefresh: forceRefresh,
    );

    _latestSnapshot = snapshot;
    _latestSnapshotKey = cacheKey;
    return snapshot;
  }

  Future<List<NewsItem>> _loadNewsFeed({
    required int limit,
    required List<String> requestedCategories,
    bool forceRefresh = false,
  }) async {
    final cacheKey = '$limit|${requestedCategories.join(',')}';
    final cached = _latestNews;

    if (!forceRefresh &&
        cached != null &&
        _latestNewsAt != null &&
        _latestNewsKey == cacheKey &&
        DateTime.now().difference(_latestNewsAt!) <= config.newsCacheTtl) {
      return cached;
    }

    final items = await _newsService.fetchNews(
      limit: limit,
      categories: requestedCategories,
    );

    _latestNews = items;
    _latestNewsKey = cacheKey;
    _latestNewsAt = DateTime.now();
    return items;
  }

  Future<Map<String, dynamic>?> _loadIfPresent(String path) async {
    final payload = await _service.loadJsonArtifact(path);
    return payload.isEmpty ? null : payload;
  }

  Future<void> _saveState() async {
    await _service.saveJsonArtifact(
      config.schedulerStatePath,
      {
        'startedAt': _startedAt.toIso8601String(),
        'lastRunAt': _lastRunAt?.toIso8601String(),
        'lastStatus': _lastStatus,
        'lastError': _lastError,
        'lastTrigger': _lastTrigger,
        'running': _running,
        'nextRunAt': _nextRunAt?.toIso8601String(),
        'runCount': _runCount,
        'intervalMinutes': config.interval.inMinutes,
        'mode': _modeName(),
        'lastNewsSignalAt': _lastNewsSignalAt?.toIso8601String(),
        'lastNewsSignal': _lastNewsSignal,
        'lastPush': _lastPush?.toJson(),
      },
    );
  }

  Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> payload,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(const JsonEncoder.withIndent('  ').convert(payload));
    await response.close();
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const FormatException('request body must be a JSON object');
  }
}
