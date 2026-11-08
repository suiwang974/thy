import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 推荐页：首页。
/// - 猜你喜欢：按口味加权（足控优先），每条写明推荐理由；
/// - 关注的作者置顶：关注过的作者的新片排在前面；
/// - 片库按批次列出；Eporner 热门在最后。
class HomeScreen extends StatefulWidget {
  final Store store;
  final void Function(String author) onAuthorTap;
  const HomeScreen({super.key, required this.store, required this.onAuthorTap});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<VideoItem> _catalog = [];
  List<VideoItem> _trending = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await Catalog.load();
    final feed = await SearchService().homeFeed();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _trending = feed.where((v) => v.source == 'eporner').toList();
      _loading = false;
    });
  }

  void _open(VideoItem item, {List<VideoItem>? playlist}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, playlist: playlist, store: widget.store),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.pinkAccent));
    }
    final follows = widget.store.followedAuthors;
    final likedAuthors = _catalog.where((v) => follows.contains(v.author)).toList();
    final footFirst = _catalog.where((v) => v.keywords.any((k) => k.contains('足') || k == 'foot' || k == 'footjob')).toList();
    final batches = <String, List<VideoItem>>{};
    for (final v in _catalog) {
      (batches[v.batch] ??= []).add(v);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('桃花源', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('猜你喜欢 · 按你的口味挑的', style: TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          if (likedAuthors.isNotEmpty) ...[
            const SectionTitle('关注的作者', subtitle: '你关注的作者排在最前面'),
            _horizontalList(likedAuthors, _catalog),
          ],
          const SectionTitle('猜你喜欢', subtitle: '理由：足控、足与做爱同框优先，亚洲/游戏角色也算'),
          _grid(footFirst.isEmpty ? _catalog.take(6).toList() : footFirst, _catalog),
          for (final entry in batches.entries) ...[
            SectionTitle('片库 · ${entry.key}', subtitle: '${entry.value.length} 段 · 点开直接在线播'),
            _grid(entry.value, entry.value),
          ],
          if (_trending.isNotEmpty) ...[
            const SectionTitle('Eporner 热门', subtitle: '全网热门，点开播源站直链'),
            _grid(_trending.take(10).toList(), _trending),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _grid(List<VideoItem> items, List<VideoItem> playlist) {
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
          item: items[i],
          onTap: () => _open(items[i], playlist: playlist),
          onAuthorTap: items[i].author.isEmpty ? null : () => widget.onAuthorTap(items[i].author),
        ),
      ),
    );
  }

  Widget _horizontalList(List<VideoItem> items, List<VideoItem> playlist) {
    return SizedBox(
      height: 190,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (_, i) => Container(
          width: 250,
          margin: const EdgeInsets.only(right: 12),
          child: VideoCard(item: items[i], onTap: () => _open(items[i], playlist: playlist)),
        ),
      ),
    );
  }
}
