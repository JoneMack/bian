import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/strategy_snapshot.dart';
import 'binance_service.dart';
import 'hourly_replay_service.dart';
import 'recommendation_engine.dart';

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

class SignalRunnerService {
  static const defaultDailyReportPath =
      'build/reports/daily_signal_report.json';
  static const defaultReplayReportPath =
      'build/reports/hourly_replay_report.json';
  static const defaultPushStatePath = 'build/reports/cloud_push_state.json';

  final BinanceService _binance;
  final HourlyReplayService _replay;
  final http.Client _httpClient;

  SignalRunnerService({
    BinanceService? binance,
    HourlyReplayService? replay,
    http.Client? httpClient,
  })  : _binance = binance ?? BinanceService(),
        _replay = replay ?? HourlyReplayService(),
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
        limit: 75,
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
    };

    await _writeJsonFile(dailyReportPath, payload);

    final pushResult = publishPush
        ? await publishSignal(
            engine: engine,
            policy: resolvedPolicy,
            provider:
                pushProvider ?? parsePushProvider(Platform.environment['PUSH_PROVIDER']),
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

    final actionable = _pickActionableAlerts(engine);
    if (actionable.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'ntfy',
        status: 'skipped_no_actionable',
        message: '当前没有满足阈值的买点信号，不推送',
        recordedAt: DateTime.now(),
      );
    }

    final digest = _buildPushDigest(actionable);
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
      actionable: actionable,
    );

    final uri = Uri.parse('$resolvedServer/$trimmedTopic');
    final response = await _httpClient.post(
      uri,
      headers: {
        HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
        'Title': 'Binance Analyzer Signal',
      },
      body: body,
    );
    if (response.statusCode >= 400) {
      throw HttpException(
        'ntfy push failed: ${response.statusCode} ${response.body}',
      );
    }

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

    final actionable = _pickActionableAlerts(engine);
    if (actionable.isEmpty) {
      return PushDeliveryResult(
        attempted: false,
        sent: false,
        provider: 'feishu',
        status: 'skipped_no_actionable',
        message: '当前没有满足阈值的买点信号，不推送',
        recordedAt: DateTime.now(),
      );
    }

    final digest = _buildPushDigest(actionable);
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
      actionable: actionable,
    );
    final response = await _httpClient.post(
      Uri.parse(resolvedWebhook),
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

    if (response.body.isNotEmpty) {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final code = _asInt(decoded['code'] ?? decoded['StatusCode']);
        if (code != 0) {
          final msg = decoded['msg'] ?? decoded['StatusMessage'] ?? response.body;
          throw HttpException('feishu push failed: $code $msg');
        }
      }
    }

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
        return (ntfyTopic?.trim().isNotEmpty ?? false) ? PushProvider.ntfy : null;
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

  List<EntryAlertSignal> _pickActionableAlerts(RecommendationEngineResult engine) {
    return engine.entryAlerts.where((alert) => alert.shouldNotify).take(3).toList();
  }

  String _buildPushBody({
    required RecommendationEngineResult engine,
    required EntrySignalPolicy policy,
    required List<EntryAlertSignal> actionable,
  }) {
    final buffer = StringBuffer()
      ..writeln('Binance Analyzer 信号提醒')
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
      )
      ..writeln('')
      ..writeln('时机提醒:')
      ..writeln(
        actionable
            .map((alert) =>
                '${alert.symbol} ${alert.timingLabel} | ${(alert.totalScore * 100).round()}分 | ${alert.timingReason}')
            .join('\n'),
      );
    return buffer.toString();
  }

  String _buildPushDigest(List<EntryAlertSignal> alerts) {
    return alerts
        .map((alert) => '${alert.symbol}:${alert.timingLabel}')
        .join('|');
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
    final previousAt = DateTime.tryParse(pushState['lastSentAt'] as String? ?? '');
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
