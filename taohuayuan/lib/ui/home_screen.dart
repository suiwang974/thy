import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/recommend.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'search_screen.dart';
import 'widgets.dart';

/// 推荐页：首页。
/// - 数据全部走 8 个在线源的实时热门（没有本地目录）；
/// - 开 App 先读缓存立刻显示，后台再刷新；
/// - 猜你喜欢按推荐算法排（标签重合 + 作者加权 + 新鲜度 + 来源偏好，
///   同一作者太多降权，80% 口味 + 20% 试新），每条写明推荐理由；
/// - 关注的作者置顶：关注过的作者的新片排在前面。
class HomeScreen extends StatefulWidget {
  final Store store;
  final void Function(String author) onAuthorTap;
  const HomeScreen({super.key, required this.store, required this.onAuthorTap});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ScoredItem> _ranked = [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<ScoredItem> _rank(List<VideoItem> items) {
    return rankRecommendations(items, TasteProfile.fromStore(widget.store));
  }

  Future<void> _load({bool forceRefresh = false}) async {
    // 先读缓存：有就立刻显示，不用等网络。缓存里可能有已关掉的源的旧条目，
    // 显示前先按开关过滤掉，关掉的源一条都不许出现。
    if (!forceRefresh) {
      final (cached, _) = widget.store.loadFeedCache();
      final visible = cached.where((v) => !widget.store.disabledSources.contains(v.source)).toList();
      if (visible.isNotEmpty) {
        setState(() {
          _ranked = _rank(visible);
          _loading = false;
        });
      }
    }
    setState(() => _refreshing = true);
    // 下拉刷新要真换一批：轮换计数 +1 再取（换词、换页取新结果），
    // 不是重取同一批最热；计数存本地，下次打开接着轮。
    final rotation = forceRefresh
        ? widget.store.feedRotation + 1
        : widget.store.feedRotation;
    if (forceRefresh) {
      await widget.store.setFeedRotation(rotation);
    }
    final svc = SearchService(disabledSources: widget.store.disabledSources);
    var gotAny = false;
    final feed = await svc.homeFeed(
      rotation: rotation,
      onResult: (partial) {
        if (!mounted) return;
        gotAny = true;
        setState(() {
          _ranked = _rank(partial);
          _loading = false;
        });
      },
      // 慢的源后台再试回来：去重后并进推荐流，重新排。
      onRetried: (extra) {
        if (!mounted || extra.isEmpty) return;
        final seen = _ranked.map((s) => s.item.id).toSet();
        final fresh = extra.where((v) => !seen.contains(v.id)).toList();
        if (fresh.isEmpty) return;
        final all = [..._ranked.map((s) => s.item), ...fresh];
        setState(() => _ranked = _rank(all));
      },
    );
    if (!mounted) return;
    if (feed.isNotEmpty) {
      await widget.store.saveFeedCache(feed);
    }
    setState(() {
      _refreshing = false;
      _loading = false;
      if (!gotAny && _ranked.isEmpty) _error = '所有源都没回来，检查网络后下拉刷新再试';
    });
  }

  void _open(VideoItem item, {List<VideoItem>? playlist}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, playlist: playlist, store: widget.store),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _ranked.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: Colors.pinkAccent));
    }
    final follows = widget.store.followedAuthors;
    final likedAuthors = _ranked.where((s) => s.item.author.isNotEmpty && follows.contains(s.item.author)).toList();
    final likedIds = likedAuthors.map((s) => s.item.id).toSet();
    final rest = _ranked.where((s) => !likedIds.contains(s.item.id)).toList();
    final playlist = _ranked.map((s) => s.item).toList();
    return RefreshIndicator(
      onRefresh: () => _load(forceRefresh: true),
      child: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('桃花源', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
          ),
          // 搜索放推荐页顶部：点一下进搜索页。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SearchScreen(store: widget.store),
              )),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A35),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.search, color: Colors.white54, size: 20),
                    SizedBox(width: 8),
                    Text('搜作者名 / 足、足交、八重神子…',
                        style: TextStyle(color: Colors.white38, fontSize: 14)),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('猜你喜欢 · 按你的口味挑的', style: TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('正在刷新热门…', style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_error!, style: const TextStyle(color: Colors.orange, fontSize: 13)),
            ),
          if (likedAuthors.isNotEmpty) ...[
            const SectionTitle('关注的作者', subtitle: '你关注的作者排在最前面'),
            _horizontalList(likedAuthors, playlist),
          ],
          const SectionTitle('猜你喜欢', subtitle: '理由写在每条下面：口味、关注的作者、新鲜热门、试新'),
          _grid(rest.take(30).toList(), playlist),
          if (rest.length > 30) ...[
            const SectionTitle('更多热门', subtitle: '各源的实时热门'),
            _grid(rest.skip(30).toList(), playlist),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _grid(List<ScoredItem> items, List<VideoItem> playlist) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
        ),
        itemCount: items.length,
        itemBuilder: (_, i) => VideoCard(
          item: items[i].item,
          reason: items[i].reason,
          onTap: () => _open(items[i].item, playlist: playlist),
          onAuthorTap: items[i].item.author.isEmpty ? null : () => widget.onAuthorTap(items[i].item.author),
        ),
      ),
    );
  }

  Widget _horizontalList(List<ScoredItem> items, List<VideoItem> playlist) {
    return SizedBox(
      height: 190,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (_, i) => Container(
          width: 250,
          margin: const EdgeInsets.only(right: 12),
          child: VideoCard(
            item: items[i].item,
            reason: items[i].reason,
            onTap: () => _open(items[i].item, playlist: playlist),
          ),
        ),
      ),
    );
  }
}
