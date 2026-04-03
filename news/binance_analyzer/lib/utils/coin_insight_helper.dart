import '../models/coin_data.dart';

class SectorSnapshot {
  final String name;
  final List<CoinData> coins;
  final double averageChange;
  final double averageScore;

  const SectorSnapshot({
    required this.name,
    required this.coins,
    required this.averageChange,
    required this.averageScore,
  });
}

class CoinInsightHelper {
  static const Map<String, String> _sectorMap = {
    'MYX': 'Perps',
    'TON': 'Layer 1',
    'SSV': 'ETH Staking',
    'GALA': 'Gaming',
    'NEIRO': 'Meme',
    'BOME': 'Meme',
    'APT': 'Layer 1',
    'ARK': 'Infrastructure',
    'CHR': 'Metaverse',
    'AVAX': 'Layer 1',
    'LTC': 'Payments',
    'XRP': 'Payments',
    'NFP': 'AI',
    'FET': 'AI',
    'OG': 'Fan Token',
    'PHB': 'AI',
    'HIGH': 'Metaverse',
    'LUNA': 'Layer 1',
    'FTT': 'Exchange',
    'STX': 'Bitcoin Ecosystem',
    'MAGIC': 'Gaming',
    'STG': 'Bridge',
    'API3': 'Oracle',
    'MANA': 'Metaverse',
    'MASK': 'SocialFi',
    'MDT': 'AI',
    'OP': 'Layer 2',
    'LINK': 'Oracle',
    'HFT': 'Exchange',
    'LQTY': 'DeFi',
    'ICX': 'Infrastructure',
    'LDO': 'ETH Staking',
    'ID': 'Identity',
  };

  static String sectorFor(CoinData coin) {
    return _sectorMap[coin.displayName] ?? 'Market Beta';
  }

  static bool isVolumeExpanding(CoinData coin, List<CoinData> peers) {
    if (peers.isEmpty) return false;
    final volumes = peers.map((item) => item.quoteVolume).toList()..sort();
    final pivot =
        volumes[(volumes.length * 0.65).floor().clamp(0, volumes.length - 1)];
    return coin.quoteVolume >= pivot || coin.count >= 120000;
  }

  static bool isPreparingBreakout(CoinData coin) {
    final positiveMomentum =
        coin.priceChangePercent >= -1.0 && coin.priceChangePercent <= 5.0;
    final stillHasRoom = coin.rangePosition <= 0.48;
    final scoreReady = coin.score >= 0.56;
    return positiveMomentum && stillHasRoom && scoreReady;
  }

  static String setupLabel(CoinData coin, List<CoinData> peers) {
    if (isPreparingBreakout(coin) && isVolumeExpanding(coin, peers)) {
      return '即将启动';
    }
    if (coin.score >= 0.72) {
      return '强趋势';
    }
    if (coin.priceChangePercent < -3) {
      return '观察回踩';
    }
    return '等待确认';
  }

  static List<SectorSnapshot> buildSectorSnapshots(List<CoinData> coins) {
    if (coins.isEmpty) return const [];
    final grouped = <String, List<CoinData>>{};
    for (final coin in coins) {
      grouped.putIfAbsent(sectorFor(coin), () => <CoinData>[]).add(coin);
    }

    final snapshots = grouped.entries.map((entry) {
      final items = entry.value;
      final avgChange =
          items.map((coin) => coin.priceChangePercent).reduce((a, b) => a + b) /
              items.length;
      final avgScore = items.map((coin) => coin.score).reduce((a, b) => a + b) /
          items.length;
      return SectorSnapshot(
        name: entry.key,
        coins: items,
        averageChange: avgChange,
        averageScore: avgScore,
      );
    }).toList();

    snapshots.sort((a, b) {
      final strengthA = a.averageScore * 0.65 + (a.averageChange / 10);
      final strengthB = b.averageScore * 0.65 + (b.averageChange / 10);
      return strengthB.compareTo(strengthA);
    });
    return snapshots;
  }

  static String formatPrice(double price) {
    if (price >= 1000) return price.toStringAsFixed(2);
    if (price >= 1) return price.toStringAsFixed(4);
    if (price >= 0.01) return price.toStringAsFixed(5);
    return price.toStringAsFixed(7);
  }

  static String formatPercent(double value) {
    final prefix = value >= 0 ? '+' : '';
    return '$prefix${value.toStringAsFixed(2)}%';
  }

  static String formatVolume(double volume) {
    if (volume >= 1e9) return '${(volume / 1e9).toStringAsFixed(1)}B';
    if (volume >= 1e6) return '${(volume / 1e6).toStringAsFixed(1)}M';
    if (volume >= 1e3) return '${(volume / 1e3).toStringAsFixed(1)}K';
    return volume.toStringAsFixed(0);
  }

  static String scoreLabel(double score) {
    if (score >= 0.75) return 'A+';
    if (score >= 0.68) return 'A';
    if (score >= 0.58) return 'B+';
    if (score >= 0.48) return 'B';
    return 'C';
  }

  static double marketAverageChange(List<CoinData> coins) {
    if (coins.isEmpty) return 0;
    return coins
            .map((coin) => coin.priceChangePercent)
            .reduce((a, b) => a + b) /
        coins.length;
  }

  static int gainersCount(List<CoinData> coins) {
    return coins.where((coin) => coin.priceChangePercent >= 0).length;
  }

  static int readyCount(List<CoinData> coins) {
    return coins.where(isPreparingBreakout).length;
  }
}
