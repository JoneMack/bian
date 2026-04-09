import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/market_snapshot.dart';
import '../models/news_item.dart';
import 'binance_service.dart';

class BackendApiService {
  static const String _rawBaseUrl =
      String.fromEnvironment('BACKEND_BASE_URL', defaultValue: '');

  final http.Client _client;
  final String? _baseUrlOverride;

  BackendApiService({
    http.Client? client,
    String? baseUrlOverride,
  })  : _client = client ?? http.Client(),
        _baseUrlOverride = _normalizeBaseUrl(baseUrlOverride);

  static String? get baseUrl {
    return _normalizeBaseUrl(_rawBaseUrl);
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

  static String? _normalizeBaseUrl(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}
