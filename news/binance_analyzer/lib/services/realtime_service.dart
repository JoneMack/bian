import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 实时价格推送（Binance WebSocket miniTicker 流）
///
/// 连接后每秒收到所有自选币的最新价格与涨跌幅，
/// 通过 [priceStream] 广播给 UI 层。
///
/// 节点优先级：
///   1. wss://data-stream.binance.vision （官方公开数据流）
///   2. wss://stream.binance.com:9443
///   3. wss://stream.binance.com:443
class RealtimeService {
  static const List<String> _wsHosts = [
    'wss://data-stream.binance.vision',
    'wss://stream.binance.com:9443',
    'wss://stream.binance.com:443',
  ];

  // 向外广播的价格更新事件
  final _controller = StreamController<PriceUpdate>.broadcast();
  Stream<PriceUpdate> get priceStream => _controller.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _disposed = false;
  bool _connected = false;
  String? _connectedHost;
  List<String> _symbols = const [];

  bool get isConnected => _connected;
  String? get connectedHost => _connectedHost;

  // ── 连接 ────────────────────────────────────────────────
  Future<void> connect({
    required List<String> symbols,
  }) async {
    if (_disposed) return;
    final normalized = symbols
        .map((item) => item.trim().toUpperCase())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    if (_sameSymbols(normalized, _symbols) && (_connected || _sub != null)) {
      return;
    }

    _symbols = normalized;
    await _closeChannel();
    _connected = false;
    if (_symbols.isEmpty) return;
    await _tryConnect();
  }

  Future<void> _tryConnect() async {
    if (_symbols.isEmpty) return;
    // 构造 combined stream 路径：btcusdt@miniTicker/ethusdt@miniTicker/...
    final streams =
        _symbols.map((s) => '${s.toLowerCase()}@miniTicker').join('/');

    for (final host in _wsHosts) {
      if (_disposed) return;
      try {
        final uri = Uri.parse('$host/stream?streams=$streams');
        _channel = WebSocketChannel.connect(uri);

        // 等 1 秒确认连接未立即失败
        await Future.delayed(const Duration(milliseconds: 800));

        _sub = _channel!.stream.listen(
          _onData,
          onError: (_) => _onDisconnected(),
          onDone: _onDisconnected,
          cancelOnError: true,
        );

        _connected = true;
        _connectedHost = host;
        return; // 连接成功，退出循环
      } catch (_) {
        await _closeChannel();
        continue; // 尝试下一个节点
      }
    }

    // 所有节点都失败
    _connected = false;
    // 5 秒后自动重连
    if (!_disposed) {
      await Future.delayed(const Duration(seconds: 5));
      await _tryConnect();
    }
  }

  void _onData(dynamic raw) {
    if (_disposed) return;
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      // combined stream 外层有 stream + data
      final data = (json['data'] ?? json) as Map<String, dynamic>;

      final symbol = data['s'] as String? ?? '';
      if (symbol.isEmpty) return;

      final lastPrice = double.tryParse(data['c']?.toString() ?? '') ?? 0;
      final openPrice = double.tryParse(data['o']?.toString() ?? '') ?? 0;
      final highPrice = double.tryParse(data['h']?.toString() ?? '') ?? 0;
      final lowPrice = double.tryParse(data['l']?.toString() ?? '') ?? 0;
      final volume =
          double.tryParse(data['q']?.toString() ?? '') ?? 0; // quote volume

      // 计算实时涨跌幅
      final changePct =
          openPrice > 0 ? ((lastPrice - openPrice) / openPrice) * 100 : 0.0;

      _controller.add(PriceUpdate(
        symbol: symbol,
        lastPrice: lastPrice,
        openPrice: openPrice,
        highPrice: highPrice,
        lowPrice: lowPrice,
        quoteVolume: volume,
        changePercent: changePct,
      ));
    } catch (_) {}
  }

  void _onDisconnected() {
    _connected = false;
    _connectedHost = null;
    if (!_disposed && _symbols.isNotEmpty) {
      // 3 秒后重连
      Future.delayed(const Duration(seconds: 3), _tryConnect);
    }
  }

  Future<void> _closeChannel() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  // ── 断开 ────────────────────────────────────────────────
  Future<void> disconnect() async {
    _disposed = true;
    _connected = false;
    await _closeChannel();
    await _controller.close();
  }

  bool _sameSymbols(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

/// 单次价格推送数据
class PriceUpdate {
  final String symbol;
  final double lastPrice;
  final double openPrice;
  final double highPrice;
  final double lowPrice;
  final double quoteVolume;
  final double changePercent;

  const PriceUpdate({
    required this.symbol,
    required this.lastPrice,
    required this.openPrice,
    required this.highPrice,
    required this.lowPrice,
    required this.quoteVolume,
    required this.changePercent,
  });
}
