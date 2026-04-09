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
  final Duration marketSnapshotTtl;
  final Duration newsCacheTtl;
  final Duration pushDedupeWindow;
  final bool enableMarketStartupScanner;
  final int? marketSymbolLimit;
  final bool runOnStartup;
  final bool runOnce;
  final bool enableInternalScheduler;
  final bool refreshReplayBeforeRun;
  final bool publishPush;
  final bool dedupePush;
  final PushProvider pushProvider;
  final String? runnerToken;
  final String? feishuWebhookUrl;
  final String? ntfyTopic;
  final String? ntfyServer;
  final String dailyReportPath;
  final String replayReportPath;
  final String buyLogPath;
  final String schedulerStatePath;
  final String pushStatePath;
  final List<String>? watchlistSymbols;

  const CloudSchedulerConfig({
    required this.port,
    required this.interval,
    required this.replayMaxAge,
    required this.marketSnapshotTtl,
    required this.newsCacheTtl,
    required this.pushDedupeWindow,
    required this.enableMarketStartupScanner,
    required this.marketSymbolLimit,
    required this.runOnStartup,
    required this.runOnce,
    required this.enableInternalScheduler,
    required this.refreshReplayBeforeRun,
    required this.publishPush,
    required this.dedupePush,
    required this.pushProvider,
    required this.runnerToken,
    required this.feishuWebhookUrl,
    required this.ntfyTopic,
    required this.ntfyServer,
    required this.dailyReportPath,
    required this.replayReportPath,
    required this.buyLogPath,
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
      marketSnapshotTtl: Duration(
        seconds: int.tryParse(env['MARKET_SNAPSHOT_TTL_SECONDS'] ?? '90') ?? 90,
      ),
      newsCacheTtl: Duration(
        seconds: int.tryParse(env['NEWS_CACHE_TTL_SECONDS'] ?? '180') ?? 180,
      ),
      pushDedupeWindow:
          Duration(hours: int.tryParse(env['PUSH_DEDUPE_HOURS'] ?? '6') ?? 6),
      enableMarketStartupScanner: _boolFromEnv(
        env['ENABLE_MARKET_STARTUP_SCANNER'],
        fallback: true,
      ),
      marketSymbolLimit: _intFromEnv(env['MARKET_SYMBOL_LIMIT']),
      runOnStartup: _boolFromEnv(env['RUN_ON_STARTUP'], fallback: true),
      runOnce: runOnce,
      enableInternalScheduler: _boolFromEnv(
        env['ENABLE_INTERNAL_SCHEDULER'],
        fallback: !runOnce,
      ),
      refreshReplayBeforeRun:
          _boolFromEnv(env['REFRESH_REPLAY_BEFORE_RUN'], fallback: true),
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
      buyLogPath:
          env['BUY_LOG_PATH'] ?? SignalRunnerService.defaultStartupBuyLogPath,
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
  PushDeliveryResult? _lastPush;

  _CloudSignalSchedulerApp(this.config);

  Future<void> start() async {
    await _loadArtifacts();

    stdout.writeln(
      'Push config: publish=${config.publishPush} '
      'mode=${config.enableMarketStartupScanner ? 'market_startup' : 'watchlist_rotation'} '
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
    _latestReport = await _loadIfPresent(config.dailyReportPath);
    _latestReplay = await _loadIfPresent(config.replayReportPath);
    _latestPredictionLog = await _loadIfPresent(config.buyLogPath);
    _lastRunAt = DateTime.tryParse(state['lastRunAt'] as String? ?? '');
    _lastStatus = state['lastStatus'] as String? ?? _lastStatus;
    _lastError = state['lastError'] as String?;
    _lastTrigger = state['lastTrigger'] as String?;
    _runCount = state['runCount'] as int? ?? 0;

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
          'runEndpoint': '/run',
          'pushTestEndpoint': '/push-test',
          'internalScheduler': config.enableInternalScheduler,
          'manualRunRequiresToken': (config.runnerToken?.isNotEmpty ?? false),
          'marketSnapshotCacheSeconds': config.marketSnapshotTtl.inSeconds,
          'newsCacheSeconds': config.newsCacheTtl.inSeconds,
          'pushProvider': config.pushProvider.name,
          'effectivePushProvider': _effectivePushProviderName(),
        });
        return;
      }

      if (request.method == 'GET' && path == '/health') {
        await _writeJson(request.response, HttpStatus.ok, _healthPayload());
        return;
      }

      if (request.method == 'GET' && path == '/latest') {
        final payload =
            _latestReport ?? await _loadIfPresent(config.dailyReportPath);
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
        final payload = forceRefresh || _latestPredictionLog?['summary'] == null
            ? await _service.refreshStartupPredictionLog(
                path: config.buyLogPath)
            : (_latestPredictionLog ?? await _loadIfPresent(config.buyLogPath));
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
        final result = await _service.runMarketStartupScan(
          requestedSymbols: config.watchlistSymbols,
          symbolLimit: config.marketSymbolLimit,
          reportPath: config.dailyReportPath,
          buyLogPath: config.buyLogPath,
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
        _latestPredictionLog = result.predictionLog;

        stdout.writeln(
          '[${result.generatedAt.toIso8601String()}] $trigger '
          'mode=market_startup '
          'candidates=${result.report.actionableCandidates.length} '
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
      'mode': config.enableMarketStartupScanner
          ? 'market_startup'
          : 'watchlist_rotation',
      'dailyReportPath': config.dailyReportPath,
      'replayReportPath': config.replayReportPath,
      'buyLogPath': config.buyLogPath,
      'marketSnapshotCacheSeconds': config.marketSnapshotTtl.inSeconds,
      'newsCacheSeconds': config.newsCacheTtl.inSeconds,
      'latestSnapshotAt': _latestSnapshot?.updatedAt.toIso8601String(),
      'latestSnapshotSymbols': _latestSnapshot?.watchlistSymbols,
      'latestNewsAt': _latestNewsAt?.toIso8601String(),
      'latestNewsCount': _latestNews?.length,
      'startupPredictionSummary': _latestPredictionLog?['summary'],
      'startupPredictionUpdatedAt': _latestPredictionLog?['updatedAt'],
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

    final nestedReport = _latestReport?['report'];
    if (nestedReport is Map) {
      final candidates = nestedReport['candidates'];
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
        'mode': config.enableMarketStartupScanner
            ? 'market_startup'
            : 'watchlist_rotation',
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
}
