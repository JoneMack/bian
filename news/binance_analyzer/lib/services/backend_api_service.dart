import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/market_snapshot.dart';
import '../models/news_item.dart';
import 'binance_service.dart';

class SignalActionSubmissionResult {
  final bool created;
  final String status;
  final String message;
  final Map<String, dynamic>? record;

  const SignalActionSubmissionResult({
    required this.created,
    required this.status,
    required this.message,
    this.record,
  });

  factory SignalActionSubmissionResult.fromJson(Map<String, dynamic> json) {
    return SignalActionSubmissionResult(
      created: json['created'] == true,
      status: json['status']?.toString() ?? 'unknown',
      message: json['message']?.toString() ?? '',
      record: json['record'] is Map
          ? Map<String, dynamic>.from(json['record'] as Map)
          : null,
    );
  }
}

class BackendApiService {
  static const String _rawBaseUrl =
      String.fromEnvironment(
        'BACKEND_BASE_URL',
        defaultValue: 'http://124.221.66.75',
      );
  static const String _prefsKey = 'backend_base_url_v1';
  static String? _cachedBaseUrl;

  final http.Client _client;
  final String? _baseUrlOverride;

  BackendApiService({
    http.Client? client,
    String? baseUrlOverride,
  })  : _client = client ?? http.Client(),
        _baseUrlOverride = _normalizeBaseUrl(baseUrlOverride);

  static String? get baseUrl {
    return _cachedBaseUrl ?? _normalizeBaseUrl(_rawBaseUrl);
  }

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedBaseUrl = _normalizeBaseUrl(prefs.getString(_prefsKey));
  }

  static Future<void> saveBaseUrl(String value) async {
    final normalized = _normalizeBaseUrl(value);
    final prefs = await SharedPreferences.getInstance();
    if (normalized == null) {
      _cachedBaseUrl = null;
      await prefs.remove(_prefsKey);
      return;
    }
    _cachedBaseUrl = normalized;
    await prefs.setString(_prefsKey, normalized);
  }

  static Future<void> clearBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedBaseUrl = null;
    await prefs.remove(_prefsKey);
  }

  String? get resolvedBaseUrl => _baseUrlOverride ?? baseUrl;

  bool get isConfigured => resolvedBaseUrl != null;

  Future<MarketSnapshot> fetchMarketSnapshot({
    required List<String> symbols,
    bool forceRefresh = false,
  }) async {
    final resolvedBaseUrl = this.resolvedBaseUrl;
    if (resolvedBaseUrl == null) {
      throw StateError('BACKEND_BASE_URL 未配置');
    }

    final normalized = symbols
        .map(BinanceService.toSymbol)
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final queryParameters = <String, String>{};
    if (normalized.isNotEmpty) {
      queryParameters['symbols'] = normalized.join(',');
    }
    if (forceRefresh) {
      queryParameters['refresh'] = '1';
    }

    final uri = Uri.parse('$resolvedBaseUrl/market-snapshot')
        .replace(queryParameters: queryParameters);
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw Exception(
        '后台快照请求失败(${response.statusCode})：${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('后台返回的 market snapshot 格式无效');
    }

    return MarketSnapshot.fromJson(decoded);
  }

  Future<List<NewsItem>> fetchNewsFeed({
    int limit = 40,
    List<String> categories = const [],
    bool forceRefresh = false,
  }) async {
    final resolvedBaseUrl = this.resolvedBaseUrl;
    if (resolvedBaseUrl == null) {
      throw StateError('BACKEND_BASE_URL 未配置');
    }

    final normalizedCategories = categories
        .map((item) => item.trim().toUpperCase())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final queryParameters = <String, String>{
      'limit': '$limit',
    };
    if (normalizedCategories.isNotEmpty) {
      queryParameters['categories'] = normalizedCategories.join(',');
    }
    if (forceRefresh) {
      queryParameters['refresh'] = '1';
    }

    final uri = Uri.parse('$resolvedBaseUrl/news')
        .replace(queryParameters: queryParameters);
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw Exception(
        '后台资讯请求失败(${response.statusCode})：${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('后台返回的 news 格式无效');
    }

    final items = (decoded['items'] as List<dynamic>? ?? const [])
        .map((item) => NewsItem.fromJson(item as Map<String, dynamic>))
        .toList();
    return items;
  }

  Future<SignalActionSubmissionResult> submitSignalAction({
    required String signalId,
    required String symbol,
    required String signalType,
    required String signalSource,
    required String actionType,
    required double price,
    String timingLabel = '',
    String timingReason = '',
    double totalScore = 0,
    double entryScore = 0,
    String note = '',
    String client = 'app',
  }) async {
    final resolvedBaseUrl = this.resolvedBaseUrl;
    if (resolvedBaseUrl == null) {
      throw StateError('BACKEND_BASE_URL 未配置');
    }

    final uri = Uri.parse('$resolvedBaseUrl/signal-action');
    final response = await _client
        .post(
          uri,
          headers: {
            'content-type': 'application/json; charset=utf-8',
          },
          body: jsonEncode({
            'signalId': signalId,
            'symbol': symbol.trim().toUpperCase(),
            'signalType': signalType.trim().toLowerCase(),
            'signalSource': signalSource.trim().toLowerCase(),
            'actionType': actionType.trim().toLowerCase(),
            'price': price,
            'timingLabel': timingLabel,
            'timingReason': timingReason,
            'totalScore': totalScore,
            'entryScore': entryScore,
            'note': note,
            'client': client,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
        '后台信号动作记录失败(${response.statusCode})：${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('后台返回的 signal-action 格式无效');
    }
    return SignalActionSubmissionResult.fromJson(decoded);
  }

  static String? _normalizeBaseUrl(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}
