import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/news_item.dart';
import '../services/backend_api_service.dart';
import '../services/news_service.dart';
import '../services/binance_service.dart';
import '../theme/app_theme.dart';

/// 资讯页 —— 加密货币新闻 + 币安公告
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen>
    with AutomaticKeepAliveClientMixin {
  final _svc = NewsService();
  final _backend = BackendApiService();
  List<NewsItem> _news = [];
  List<NewsItem> _filtered = [];
  bool _loading = true;
  String? _error;
  DateTime? _lastUpdated;
  Timer? _refreshTimer;

  // 筛选
  String _selectedTag = '全部';
  static const List<String> _fixedTags = ['全部', 'Binance', '热点'];

  @override
  bool get wantKeepAlive => true; // Tab 切换不销毁

  @override
  void initState() {
    super.initState();
    _load();
    // 每 3 分钟自动刷新
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 3),
      (_) => _load(silent: true),
    );
  }

  Future<void> _openBackendSettings() async {
    final controller = TextEditingController(
      text: _backend.resolvedBaseUrl ?? '',
    );
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppTheme.cardDark,
          title: const Text(
            '配置后台地址',
            style: TextStyle(color: AppTheme.textPrimary),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(
              hintText: '例如 http://你的服务器IP',
              hintStyle: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                await BackendApiService.clearBaseUrl();
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop('');
                }
              },
              child: const Text('清空'),
            ),
            FilledButton(
              onPressed: () async {
                final raw = controller.text.trim();
                if (raw.isEmpty) {
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop('');
                  }
                  return;
                }
                await BackendApiService.saveBaseUrl(raw);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(raw);
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.binanceYellow,
                foregroundColor: AppTheme.binanceDark,
              ),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (!mounted || saved == null) return;
    if (saved.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清空后台地址，将使用本地资讯')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('后台地址已保存')),
      );
    }
    await _load();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  // ── 自选币名（用于过滤相关新闻）─────────────────────────
  List<String> get _watchlistNames => BinanceService.watchlistSymbols
      .map((s) => s.replaceAll('USDT', ''))
      .toList();

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final categories = _watchlistNames.take(10).toList(); // 限制请求参数长度
      final forceRefresh = !silent && _lastUpdated != null;
      final news = _backend.isConfigured
          ? await _backend.fetchNewsFeed(
              limit: 40,
              categories: categories,
              forceRefresh: forceRefresh,
            )
          : await _svc.fetchNews(limit: 40, categories: categories);

      if (mounted) {
        setState(() {
          _news = news;
          _lastUpdated = DateTime.now();
          _loading = false;
          _error = null;
          _applyFilter();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _applyFilter() {
    switch (_selectedTag) {
      case '全部':
        _filtered = List.from(_news);
        break;
      case 'Binance':
        _filtered = _news.where((n) => n.source == 'Binance').toList();
        break;
      case '热点':
        _filtered = _news.where((n) => n.isHot).toList();
        break;
      default:
        _filtered = _news
            .where((n) => n.tags
                .any((t) => t.toLowerCase() == _selectedTag.toLowerCase()))
            .toList();
    }
  }

  // ── 动态 tag 列表（从新闻内容中提取热门 tag） ─────────────
  List<String> get _allTags {
    final tagCount = <String, int>{};
    for (final item in _news) {
      for (final tag in item.tags) {
        if (tag.isEmpty || tag.length > 8) continue;
        tagCount[tag] = (tagCount[tag] ?? 0) + 1;
      }
    }
    final sorted = tagCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(8).map((e) => e.key).toList();
    return [..._fixedTags, ...top.where((t) => !_fixedTags.contains(t))];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: AppTheme.binanceDark,
      appBar: _buildAppBar(),
      body: _loading
          ? const _LoadingView()
          : _error != null && _news.isEmpty
              ? _ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.binanceYellow,
                  backgroundColor: AppTheme.cardDark,
                  child: _buildBody(),
                ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: AppTheme.binanceDark,
      elevation: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('加密资讯',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          if (_lastUpdated != null)
            Text(
              '更新于 ${_formatTime(_lastUpdated!)} · 下次3分钟后',
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 10),
            ),
        ],
      ),
      actions: [
        IconButton(
          onPressed: _openBackendSettings,
          icon: Icon(
            _backend.isConfigured
                ? Icons.cloud_done_rounded
                : Icons.cloud_off_rounded,
            color:
                _backend.isConfigured ? AppTheme.green : AppTheme.textPrimary,
          ),
        ),
        IconButton(
          onPressed: _load,
          icon: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.binanceYellow))
              : const Icon(Icons.refresh_rounded, color: AppTheme.textPrimary),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(44),
        child: _buildTagBar(),
      ),
    );
  }

  Widget _buildTagBar() {
    final tags = _allTags;
    return Container(
      height: 44,
      color: AppTheme.binanceDark,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: tags.length,
        itemBuilder: (ctx, i) {
          final tag = tags[i];
          final selected = tag == _selectedTag;
          return GestureDetector(
            onTap: () => setState(() {
              _selectedTag = tag;
              _applyFilter();
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? AppTheme.binanceYellow : AppTheme.cardDark,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color:
                        selected ? AppTheme.binanceYellow : AppTheme.cardLight),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  color:
                      selected ? AppTheme.binanceDark : AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    final list =
        _filtered.isEmpty && _selectedTag != '全部' ? <NewsItem>[] : _filtered;

    if (list.isEmpty) {
      return const Center(
        child: Text('暂无相关资讯',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: list.length,
      itemBuilder: (ctx, i) {
        // 第一条放大显示
        if (i == 0 && _selectedTag == '全部') {
          return _HeroNewsCard(item: list[i]);
        }
        return _NewsCard(item: list[i]);
      },
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ── 头条新闻（大图卡）─────────────────────────────────────

class _HeroNewsCard extends StatelessWidget {
  final NewsItem item;
  const _HeroNewsCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showNewsDetailSheet(context, item),
      onLongPress: () => _copyUrl(context, item.url),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(16),
          border: item.isHot
              ? Border.all(
                  color: AppTheme.binanceYellow.withAlpha(100), width: 1)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 图片
            if (item.imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: Image.network(
                  item.imageUrl,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _placeholderImage(),
                ),
              )
            else
              _placeholderImage(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16))),

            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 热点标签
                  if (item.isHot)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.red.withAlpha(40),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('🔥 热点',
                          style: TextStyle(
                              color: AppTheme.red,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  Text(
                    item.displayTitle,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        height: 1.4),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.displaySummary,
                    style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                        height: 1.5),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  _MetaRow(item: item),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholderImage({BorderRadius? borderRadius}) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: Container(
        height: 120,
        width: double.infinity,
        color: AppTheme.cardLight,
        child: const Center(
          child: Icon(Icons.article_rounded,
              color: AppTheme.textSecondary, size: 40),
        ),
      ),
    );
  }
}

// ── 普通新闻卡（横排缩略图）──────────────────────────────

class _NewsCard extends StatelessWidget {
  final NewsItem item;
  const _NewsCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showNewsDetailSheet(context, item),
      onLongPress: () => _copyUrl(context, item.url),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 文字部分
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.isHot)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Text('🔥 热点',
                          style: TextStyle(
                              color: AppTheme.red,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ),
                  Text(
                    item.displayTitle,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.4),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.displaySummary,
                    style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        height: 1.5),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  _MetaRow(item: item),
                ],
              ),
            ),

            // 右侧图片
            if (item.imageUrl.isNotEmpty) ...[
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  item.imageUrl,
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _smallPlaceholder(),
                ),
              ),
            ] else ...[
              const SizedBox(width: 12),
              _smallPlaceholder(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _smallPlaceholder() {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: AppTheme.cardLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.article_rounded,
          color: AppTheme.textSecondary, size: 28),
    );
  }
}

// ── 来源 + 时间 行 ─────────────────────────────────────────

class _MetaRow extends StatelessWidget {
  final NewsItem item;
  const _MetaRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.cardLight,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            item.source,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          item.timeAgo,
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
        ),
        const Spacer(),
        const Icon(Icons.notes_rounded,
            color: AppTheme.textSecondary, size: 13),
      ],
    );
  }
}

// ── 辅助函数 ────────────────────────────────────────────────

Future<void> _showNewsDetailSheet(BuildContext context, NewsItem item) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return FractionallySizedBox(
        heightFactor: 0.88,
        child: _NewsDetailSheet(item: item),
      );
    },
  );
}

Future<void> _copyUrl(BuildContext context, String url) async {
  if (url.trim().isEmpty) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('原文链接已复制'),
        backgroundColor: AppTheme.cardLight,
        duration: Duration(seconds: 1),
      ),
    );
  }
}

Future<void> _copyNewsBrief(BuildContext context, NewsItem item) async {
  final buffer = StringBuffer()
    ..writeln(item.displayTitle)
    ..writeln()
    ..writeln(item.displayDetailBody);

  if (item.url.trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('原文链接：${item.url}');
  }

  await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('资讯内容已复制'),
        backgroundColor: AppTheme.cardLight,
        duration: Duration(seconds: 1),
      ),
    );
  }
}

class _NewsDetailSheet extends StatelessWidget {
  final NewsItem item;
  const _NewsDetailSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    final tags =
        item.tags.where((tag) => tag.trim().isNotEmpty).take(6).toList();

    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.cardLight,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _DetailChip(
                                label: item.source,
                                color: AppTheme.cardLight,
                                textColor: AppTheme.textSecondary,
                              ),
                              _DetailChip(
                                label: item.timeAgo,
                                color: AppTheme.cardLight,
                                textColor: AppTheme.textSecondary,
                              ),
                              if (item.isHot)
                                const _DetailChip(
                                  label: '热点',
                                  color: AppTheme.red,
                                  textColor: AppTheme.textPrimary,
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded,
                              color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                    if (item.imageUrl.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.network(
                          item.imageUrl,
                          width: double.infinity,
                          height: 180,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _detailPlaceholder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      item.displayTitle,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        height: 1.45,
                      ),
                    ),
                    if (item.displayTitle != item.title) ...[
                      const SizedBox(height: 8),
                      Text(
                        '原文标题：${item.title}',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ],
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final tag in tags)
                            _DetailChip(
                              label: tag,
                              color: AppTheme.binanceYellow.withAlpha(28),
                              textColor: AppTheme.binanceYellow,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    const Text(
                      '中文内容',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.binanceDark,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.cardLight),
                      ),
                      child: Text(
                        item.displayDetailBody,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
                          height: 1.7,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _copyNewsBrief(context, item),
                            icon: const Icon(Icons.content_copy_rounded,
                                size: 16),
                            label: const Text('复制内容'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.textPrimary,
                              side: const BorderSide(color: AppTheme.cardLight),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: item.url.trim().isEmpty
                                ? null
                                : () => _copyUrl(context, item.url),
                            icon: const Icon(Icons.link_rounded, size: 16),
                            label: const Text('复制原文链接'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.binanceYellow,
                              foregroundColor: AppTheme.binanceDark,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailPlaceholder() {
    return Container(
      height: 180,
      width: double.infinity,
      color: AppTheme.cardLight,
      child: const Center(
        child: Icon(Icons.article_rounded,
            color: AppTheme.textSecondary, size: 44),
      ),
    );
  }
}

class _DetailChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;

  const _DetailChip({
    required this.label,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Loading / Error ────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        CircularProgressIndicator(color: AppTheme.binanceYellow),
        SizedBox(height: 16),
        Text('正在加载资讯...',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      ]),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.newspaper, color: AppTheme.textSecondary, size: 48),
          const SizedBox(height: 16),
          const Text('资讯加载失败',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            error.length > 200 ? '${error.substring(0, 200)}...' : error,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重新加载'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.binanceYellow,
              foregroundColor: AppTheme.binanceDark,
            ),
          ),
        ]),
      ),
    );
  }
}
