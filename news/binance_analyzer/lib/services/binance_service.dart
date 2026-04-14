import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/coin_data.dart';

class BinanceService {
  static const int maxKlineRequestLimit = 1000;

  // ── 多节点轮询 ──────────────────────────────────────────
  // data-api.binance.vision = 官方公开行情节点（无需 API Key，对国内更友好）
  static const List<String> _hosts = [
    'https://data-api.binance.vision',
    'https://api.binance.com',
    'https://api1.binance.com',
    'https://api2.binance.com',
    'https://api3.binance.com',
    'https://api4.binance.com',
  ];

  String? _activeHost; // 缓存上次探活成功的节点
  final Map<String, _KlineCacheEntry> _klineCache = {};

  // ── 自选币列表 ──────────────────────────────────────────
  static const List<String> defaultWatchlistRaw = [
    'ssv',
    'apt',
    'nfp',
    'fet',
    'luna',
    'ftt',
    'stg',
    'api3',
    'mask',
    'link',
    'lqty',
    'icx',
    'ldo',
  ];

  static const List<String> _symbolBlacklistKeywords = [
    'UPUSDT',
    'DOWNUSDT',
    'BULLUSDT',
    'BEARUSDT',
  ];

  static String toSymbol(String raw) {
    final s = raw.toUpperCase();
    return s.endsWith('USDT') ? s : '${s}USDT';
  }

  static List<String> get watchlistSymbols =>
      defaultWatchlistRaw.map(toSymbol).toList();

  static List<String> get defaultWatchlistSymbols => watchlistSymbols;

  // ── 主入口 ──────────────────────────────────────────────
  Future<List<CoinData>> fetchTickers({
    List<String>? symbols,
  }) async {
    await _findWorkingHost();
    final targets =
        (symbols == null || symbols.isEmpty) ? watchlistSymbols : symbols;

    return _withHostFallback<List<CoinData>>(
      (host) async {
        try {
          final coins = await _fetchBatch(host, targets);
          if (coins.isNotEmpty) return coins;
        } catch (_) {
          // 某些 symbol 无效或当前节点对 batch 不稳定，降级到逐个请求
        }
        final fallback = await _fetchIndividual(host, targets);
        return fallback.isEmpty ? null : fallback;
      },
      debugLabel: 'ticker',
    );
  }

  // ── 探活：并行 ping 所有节点，取最快响应的 ──────────────
  Future<String> _findWorkingHost() async {
    // 优先用缓存节点
    if (_activeHost != null) {
      try {
        final resp = await http
            .get(Uri.parse('$_activeHost/api/v3/ping'))
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) return _activeHost!;
      } catch (_) {
        _activeHost = null;
      }
    }

    // 并行 ping 所有节点
    final completer = Completer<String>();

    for (final host in _hosts) {
      () async {
        try {
          final resp = await http
              .get(Uri.parse('$host/api/v3/ping'))
              .timeout(const Duration(seconds: 8));
          if (resp.statusCode == 200 && !completer.isCompleted) {
            completer.complete(host);
          }
        } catch (_) {}
      }();
    }

    // 等待最多 10 秒
    try {
      final host = await completer.future.timeout(const Duration(seconds: 10));
      _activeHost = host;
      return host;
    } on TimeoutException {
      throw Exception(
        '无法连接币安服务器，已尝试所有节点：\n'
        '${_hosts.join("\n")}\n\n'
        '排查建议：\n'
        '① 检查手机/电脑是否联网\n'
        '② 国内用户可能需要开启 VPN\n'
        '③ 如在浏览器(Flutter Web)运行，存在跨域限制，建议改用手机 App',
      );
    }
  }

  Iterable<String> _orderedHosts() sync* {
    if (_activeHost != null) {
      yield _activeHost!;
    }
    for (final host in _hosts) {
      if (host != _activeHost) {
        yield host;
      }
    }
  }

  Future<T> _withHostFallback<T>(
    Future<T?> Function(String host) loader, {
    required String debugLabel,
  }) async {
    final errors = <String>[];

    for (final host in _orderedHosts()) {
      try {
        final result = await loader(host);
        if (result != null) {
          _activeHost = host;
          return result;
        }
      } catch (error) {
        errors.add('$host -> $error');
      }
    }

    throw Exception(
      'Binance $debugLabel 接口请求失败，已尝试所有节点：\n${errors.join('\n')}',
    );
  }

  // ── 批量请求（symbols 参数，1 次拿所有行情） ─────────────
  Future<List<CoinData>> _fetchBatch(String host, List<String> symbols) async {
    // Binance 要求 symbols 参数为 JSON 数组字符串
    // 例：symbols=["BTCUSDT","ETHUSDT"]
    final symbolsJson = jsonEncode(symbols);

    final uri = Uri.parse('$host/api/v3/ticker/24hr')
        .replace(queryParameters: {'symbols': symbolsJson});

    final resp = await http.get(uri).timeout(const Duration(seconds: 20));

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      if (data is! List) {
        throw Exception('Unexpected response type: ${data.runtimeType}');
      }
      return data
          .map((item) {
            try {
              return CoinData.fromJson(item as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<CoinData>()
          .toList();
    }

    // 400 通常是某个 symbol 无效，交调用方降级
    throw Exception(
        'Batch ${resp.statusCode}: ${resp.body.length > 300 ? resp.body.substring(0, 300) : resp.body}');
  }

  // ── 逐个并行请求（降级方案，跳过无效 symbol） ───────────
  Future<List<CoinData>> _fetchIndividual(
      String host, List<String> symbols) async {
    final futures = symbols.map((s) => _fetchOne(host, s));
    final results = await Future.wait(futures);
    final coins = results.whereType<CoinData>().toList();

    if (coins.isEmpty) {
      throw Exception('所有 symbol 单独请求均失败，节点: $host\n请检查网络或更换节点');
    }
    return coins;
  }

  Future<List<String>> fetchTradableUsdtSymbols({
    int? limit,
  }) async {
    await _findWorkingHost();

    return _withHostFallback<List<String>>(
      (host) => _fetchTradableUsdtSymbolsOnHost(host, limit: limit),
      debugLabel: 'exchangeInfo',
    );
  }

  Future<List<CoinData>> fetchAllTickers() async {
    await _findWorkingHost();

    return _withHostFallback<List<CoinData>>(
      (host) => _fetchAllTickersOnHost(host),
      debugLabel: 'ticker/all',
    );
  }

  Future<List<CoinData>> fetchTradableUsdtTickers({
    int? limit,
  }) async {
    final tradableSymbols = await fetchTradableUsdtSymbols(limit: limit);
    final tradableSet = tradableSymbols.toSet();
    final tickers = await fetchAllTickers();

    final filtered = tickers
        .where((coin) => tradableSet.contains(coin.symbol))
        .toList()
      ..sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
    return filtered;
  }

  Future<CoinData?> _fetchOne(String host, String symbol) async {
    try {
      final uri = Uri.parse('$host/api/v3/ticker/24hr')
          .replace(queryParameters: {'symbol': symbol});

      final resp = await http.get(uri).timeout(const Duration(seconds: 12));

      if (resp.statusCode == 200) {
        return CoinData.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      }
      return null; // 400 = symbol 不存在
    } catch (_) {
      return null;
    }
  }

  // ── K 线数据 ────────────────────────────────────────────
  Future<List<Kline>> fetchKlines(
    String symbol, {
    String interval = '1h',
    int limit = 48,
    Duration? ttl,
    bool forceRefresh = false,
  }) async {
    final cacheKey = '$symbol|$interval|$limit';
    final cacheTtl = ttl ?? _defaultCacheTtl(interval);
    final cached = _klineCache[cacheKey];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < cacheTtl) {
      return cached.bars;
    }

    final bars = await _withHostFallback<List<Kline>>(
      (host) => limit <= maxKlineRequestLimit
          ? _fetchKlinesOnHost(
              host,
              symbol,
              interval: interval,
              limit: limit,
            )
          : _fetchExtendedKlinesOnHost(
              host,
              symbol,
              interval: interval,
              limit: limit,
            ),
      debugLabel: 'klines($symbol/$interval)',
    );

    _klineCache[cacheKey] = _KlineCacheEntry(
      fetchedAt: DateTime.now(),
      bars: bars,
    );
    return bars;
  }

  Future<Map<String, List<Kline>>> fetchWatchlistKlines({
    List<String>? symbols,
    String interval = '1d',
    int limit = 60,
    Duration? ttl,
    bool forceRefresh = false,
    bool allowFailures = true,
    int chunkSize = 6,
  }) async {
    final targets = symbols ?? watchlistSymbols;
    final result = <String, List<Kline>>{};

    for (final chunk in _chunk(targets, max(1, chunkSize))) {
      final bars = await Future.wait(
        chunk.map((symbol) async {
          try {
            final list = await fetchKlines(
              symbol,
              interval: interval,
              limit: limit,
              ttl: ttl,
              forceRefresh: forceRefresh,
            );
            return MapEntry(symbol, list);
          } catch (_) {
            if (!allowFailures) rethrow;
            return const MapEntry<String, List<Kline>>('', []);
          }
        }),
      );

      for (final entry in bars) {
        if (entry.key.isNotEmpty) {
          result[entry.key] = entry.value;
        }
      }
    }

    return result;
  }

  Future<List<Kline>?> _fetchKlinesOnHost(
    String host,
    String symbol, {
    required String interval,
    required int limit,
    int? endTime,
  }) async {
    final queryParameters = <String, String>{
      'symbol': symbol,
      'interval': interval,
      'limit': limit.toString(),
    };
    if (endTime != null && endTime > 0) {
      queryParameters['endTime'] = '$endTime';
    }

    final uri = Uri.parse('$host/api/v3/klines')
        .replace(queryParameters: queryParameters);

    final resp = await http.get(uri).timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;

    final list = jsonDecode(resp.body) as List<dynamic>;
    return list.map((k) {
      final row = k as List<dynamic>;
      return Kline(
        openTime: row[0] as int,
        open: double.parse(row[1].toString()),
        high: double.parse(row[2].toString()),
        low: double.parse(row[3].toString()),
        close: double.parse(row[4].toString()),
        volume: double.parse(row[5].toString()),
        closeTime: row[6] as int,
        quoteVolume: double.parse(row[7].toString()),
        tradeCount: row[8] as int? ?? 0,
      );
    }).toList();
  }

  Future<List<Kline>?> _fetchExtendedKlinesOnHost(
    String host,
    String symbol, {
    required String interval,
    required int limit,
  }) async {
    final all = <Kline>[];
    int? endTime;

    while (all.length < limit) {
      final remaining = limit - all.length;
      final batchSize = min(maxKlineRequestLimit, remaining);
      final batch = await _fetchKlinesOnHost(
        host,
        symbol,
        interval: interval,
        limit: batchSize,
        endTime: endTime,
      );
      if (batch == null || batch.isEmpty) {
        break;
      }

      all.insertAll(0, batch);

      if (batch.length < batchSize) {
        break;
      }

      final earliestOpenTime = batch.first.openTime;
      if (earliestOpenTime <= 0) {
        break;
      }
      endTime = earliestOpenTime - 1;
    }

    if (all.isEmpty) return null;

    final deduped = <int, Kline>{};
    for (final bar in all) {
      deduped[bar.openTime] = bar;
    }
    final ordered = deduped.values.toList()
      ..sort((a, b) => a.openTime.compareTo(b.openTime));

    if (ordered.length <= limit) {
      return ordered;
    }
    return ordered.sublist(ordered.length - limit);
  }

  Future<List<String>?> _fetchTradableUsdtSymbolsOnHost(
    String host, {
    required int? limit,
  }) async {
    final resp = await http
        .get(Uri.parse('$host/api/v3/exchangeInfo'))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final symbols = (body['symbols'] as List<dynamic>? ?? [])
        .map((item) => item as Map<String, dynamic>)
        .where((item) =>
            (item['status'] as String?) == 'TRADING' &&
            (item['quoteAsset'] as String?) == 'USDT' &&
            (item['isSpotTradingAllowed'] as bool? ?? false))
        .map((item) => item['symbol']?.toString().toUpperCase() ?? '')
        .where((symbol) =>
            symbol.isNotEmpty && !_symbolBlacklistKeywords.any(symbol.contains))
        .toSet()
        .toList()
      ..sort();

    if (symbols.isEmpty) return null;
    if (limit == null || limit <= 0) {
      return symbols;
    }
    return symbols.take(limit).toList();
  }

  Future<List<CoinData>?> _fetchAllTickersOnHost(String host) async {
    final resp = await http
        .get(Uri.parse('$host/api/v3/ticker/24hr'))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) return null;

    final data = jsonDecode(resp.body);
    if (data is! List) return null;

    final coins = data
        .map((item) {
          try {
            return CoinData.fromJson(item as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<CoinData>()
        .toList();

    return coins.isEmpty ? null : coins;
  }

  Duration _defaultCacheTtl(String interval) {
    if (interval.endsWith('d')) return const Duration(hours: 6);
    if (interval.endsWith('h')) return const Duration(minutes: 20);
    return const Duration(minutes: 5);
  }

  List<List<String>> _chunk(List<String> items, int size) {
    final chunks = <List<String>>[];
    for (var i = 0; i < items.length; i += size) {
      chunks.add(
          items.sublist(i, i + size > items.length ? items.length : i + size));
    }
    return chunks;
  }
}

class Kline {
  final int openTime;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final int closeTime;
  final double quoteVolume;
  final int tradeCount;

  const Kline({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.closeTime,
    this.quoteVolume = 0,
    this.tradeCount = 0,
  });
}

class _KlineCacheEntry {
  final DateTime fetchedAt;
  final List<Kline> bars;

  const _KlineCacheEntry({
    required this.fetchedAt,
    required this.bars,
  });
}
