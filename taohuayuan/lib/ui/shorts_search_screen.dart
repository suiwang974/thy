import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/search_map.dart';
import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import '../services/web_search.dart';
import 'player_screen.dart';
import 'shorts_screen.dart';
import 'widgets.dart';

/// 第 55 条：播放量格式化（抖音搜索结果页那样子：75.1万）。
/// 0 = 源站没给，不编一个，返回空字符串（调用方只显示作者/来源）。
String formatShortsViews(int views) {
  if (views <= 0) return '';
  if (views >= 100000000) return '${(views / 100000000).toStringAsFixed(1)}亿';
  if (views >= 10000) return '${(views / 10000).toStringAsFixed(1)}万';
  return '$views';
}

/// 短视频搜索页：搜索框在这一页里（短视频栏顶上只有一个小放大镜入口，
/// 不要输入框、不要文字——2026-11-09 用户补正）。
/// - 结果像抖音搜索结果页：网格，封面 + 标题 + 作者/播放量；
/// - 复用现有搜索：多源并行查、走已启用源、中文映射、流式上屏、搜过的词先读缓存；
/// - 点进一个结果 → 竖滑短视频流，上下刷到的全是该搜索词的结果（不混推荐流）；
/// - 从竖滑流返回，搜索页位置不变（路由 pop 回来，列表状态还在）。
class ShortsSearchScreen extends StatefulWidget {
  final Store store;
  const ShortsSearchScreen({super.key, required this.store});

  @override
  State<ShortsSearchScreen> createState() => _ShortsSearchScreenState();
}

class _ShortsSearchScreenState extends State<ShortsSearchScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  // 翻页也走开关：_loadMore 用的就是这个 service，之前没过开关，
  // 搜完翻页会把已关掉的源又翻回来（搜索页同款做法）。
  late final _service = SearchService(disabledSources: widget.store.disabledSources);
  // 第 41 条同款：WebView 内搜索用的隐藏 WebView（1x1 藏在页里，不占地方）：
  // niacg/lianzu11/hanime 的纯 HTTP 请求会被 WAF/Cloudflare 拦，
  // 只有真浏览器指纹能过验证，所以搜索页挂一个隐藏 WebView 替它们搜。
  late final WebViewController _webController;
  late final WebSearchRunner _webRunner;

  List<VideoItem> _items = [];
  bool _searching = false;
  bool _loadingMore = false;
  String _mappedQuery = '';
  String? _lastQuery;
  int _page = 1;
  bool _hasMore = false;
  // 搜索代际——两次 _doSearch 并发时，旧搜索的回调直接忽略，不许互相覆盖结果。
  int _searchGen = 0;

  @override
  void initState() {
    super.initState();
    _webController = WebViewController();
    _webRunner = WebSearchRunner(_webController);
    _service.webSearch = _webRunner;
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    final gen = ++_searchGen;
    await widget.store.recordSearchTerm(q);
    setState(() {
      _searching = true;
      _items = [];
      _mappedQuery = mapSearchQuery(q);
      _lastQuery = q;
      _page = 1;
      _hasMore = false;
    });
    // 先读缓存：搜过的词立刻显示，后台再刷新。
    final cached = widget.store.loadSearchCache(q);
    if (cached.isNotEmpty && mounted) {
      final visible = cached.where((v) => !widget.store.disabledSources.contains(v.source)).toList();
      setState(() => _items = visible);
    }
    final svc = SearchService(disabledSources: widget.store.disabledSources, webSearch: _webRunner);
    final results = await svc.searchAll(q, onResult: (partial) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _items = SearchService.dedupeById(partial.expand((r) => r.items).toList());
      });
    });
    if (!mounted || gen != _searchGen) return;
    final merged = SearchService.dedupeById(results.expand((r) => r.items).toList());
    if (merged.isNotEmpty) await widget.store.saveSearchCache(q, merged);
    setState(() {
      _items = merged;
      _searching = false;
      _hasMore = merged.isNotEmpty;
    });
  }

  Future<void> _loadMore() async {
    final q = _lastQuery;
    if (q == null || q.isEmpty || _loadingMore) return;
    setState(() => _loadingMore = true);
    final next = _page + 1;
    final more = await _service.searchPage(q, next);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (more.isNotEmpty) {
        _page = next;
        final seen = _items.map((v) => v.id).toSet();
        _items = [..._items, ...more.where((v) => !seen.contains(v.id))];
        _hasMore = true;
      } else {
        _hasMore = false;
      }
    });
  }

  void _open(int index) {
    final item = _items[index];
    final start = shortsSearchStartIndex(_items, index);
    if (start < 0) {
      // 点中的是超半小时的长片：不进竖滑流（第 16 条），进详情页看。
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(item: item, playlist: _items, store: widget.store),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ShortsScreen(
        store: widget.store,
        searchQuery: _lastQuery,
        searchItems: _items,
        searchStartIndex: start,
        webSearch: _webRunner,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        iconTheme: const IconThemeData(color: Colors.white),
        title: TextField(
          controller: _controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '搜作者名 / 足、足交、八重神子…',
            hintStyle: const TextStyle(color: Colors.white38),
            border: InputBorder.none,
            suffixIcon: IconButton(
              icon: const Icon(Icons.search, color: Colors.white54),
              onPressed: () => _doSearch(_controller.text),
            ),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: _doSearch,
        ),
      ),
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // 第 41 条：WebView 内搜索用的隐藏 WebView（1x1 藏着，不占地方不挡手）。
          SliverToBoxAdapter(
            child: Offstage(
              offstage: true,
              child: SizedBox(
                width: 1,
                height: 1,
                child: WebViewWidget(controller: _webController),
              ),
            ),
          ),
          if (_mappedQuery.isNotEmpty && _mappedQuery != _lastQuery)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text('已按“$_lastQuery → $_mappedQuery”去各源搜',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ),
          if (_searching)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.pinkAccent)),
                    SizedBox(width: 10),
                    Text('正在查全部源…先回来的先显示', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ),
          if (!_searching && _items.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text('共 ${_items.length} 条', style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
            ),
          if (_items.isEmpty && !_searching)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                    _lastQuery == null ? '输入关键词，搜全部源的短视频' : '没搜到结果，换个词试试',
                    style: const TextStyle(color: Colors.white38)),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _ShortsSearchCard(item: _items[i], onTap: () => _open(i)),
                  childCount: _items.length,
                ),
              ),
            ),
          if (_hasMore && !_searching && _items.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: _loadingMore
                      ? const CircularProgressIndicator(color: Colors.pinkAccent)
                      : OutlinedButton(
                          onPressed: _loadMore,
                          child: const Text('加载更多'),
                        ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }
}

/// 抖音搜索结果页那样的格子：封面 + 标题 + 作者/播放量。
/// 源站不给点赞数，显示的是播放量（眼睛图标），不是点赞数，不编。
/// 超半小时的长片右上角标“长片”，点它进详情页、不进竖滑流。
class _ShortsSearchCard extends StatelessWidget {
  final VideoItem item;
  final VoidCallback onTap;
  const _ShortsSearchCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final views = formatShortsViews(item.views);
    final isLong = item.durationSec > 1800;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              children: [
                Positioned.fill(child: PosterThumb(item: item)),
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                    child: Text(item.durationText.isEmpty ? '时长未知' : item.durationText,
                        style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ),
                if (isLong)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                      child: const Text('长片', style: TextStyle(color: Colors.orange, fontSize: 11)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: Text(
                    item.author.isEmpty ? item.source : '👤 ${item.author}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
              if (views.isNotEmpty) ...[
                const SizedBox(width: 6),
                const Icon(Icons.remove_red_eye, color: Colors.white54, size: 13),
                const SizedBox(width: 2),
                Text(views, style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
