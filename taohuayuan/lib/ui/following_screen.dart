import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 追番页：关注的作者 + 喜欢的视频。
/// 关注作者的新片走在线源实时搜作者名（最多同时搜 5 位作者，单个源 8 秒超时跳过）；
/// 点作者名只看他的片；取消关注也在这里。
class FollowingScreen extends StatefulWidget {
  final Store store;
  final void Function(String author) onAuthorTap;
  const FollowingScreen({super.key, required this.store, required this.onAuthorTap});

  @override
  State<FollowingScreen> createState() => _FollowingScreenState();
}

class _FollowingScreenState extends State<FollowingScreen> {
  List<VideoItem> _followVideos = [];
  List<VideoItem> _liked = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final follows = widget.store.followedAuthors.toList()..sort();
    final svc = SearchService();
    final found = <VideoItem>[];
    // 最多同时搜 5 位作者，避免关注太多时拖太久。
    await Future.wait(follows.take(5).map((author) async {
      final results = await svc.searchAll(author);
      final needle = author.toLowerCase();
      for (final r in results) {
        for (final v in r.items) {
          if (v.author.toLowerCase().contains(needle) ||
              v.title.toLowerCase().contains(needle)) {
            found.add(v);
          }
        }
      }
    }));
    if (!mounted) return;
    final seen = <String>{};
    setState(() {
      _followVideos = found.where((v) => seen.add(v.id)).take(30).toList();
      _liked = widget.store.likedItems();
      _loading = false;
    });
  }

  void _open(VideoItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, store: widget.store),
    )).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final follows = widget.store.followedAuthors.toList()..sort();
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        title: const Text('追番', style: TextStyle(color: Colors.white)),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            const SectionTitle('关注的作者', subtitle: '点名字只看他的片'),
            if (follows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('还没关注作者，在视频卡片上点作者名就能关注',
                    style: TextStyle(color: Colors.white54)),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: follows.map((a) => InputChip(
                    label: Text('👤 $a'),
                    backgroundColor: const Color(0xFF2A2A35),
                    labelStyle: const TextStyle(color: Colors.amber),
                    onPressed: () => widget.onAuthorTap(a),
                    deleteIcon: const Icon(Icons.close, size: 16, color: Colors.white54),
                    onDeleted: () async {
                      await widget.store.toggleFollow(a);
                      setState(() {});
                    },
                  )).toList(),
                ),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(color: Colors.pinkAccent),
              )
            else if (_followVideos.isNotEmpty) ...[
              const SectionTitle('关注作者的新片', subtitle: '8 个源实时搜出来的'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                  ),
                  itemCount: _followVideos.length,
                  itemBuilder: (_, i) => VideoCard(item: _followVideos[i], onTap: () => _open(_followVideos[i])),
                ),
              ),
            ],
            const SectionTitle('我喜欢的'),
            if (_liked.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('还没点过喜欢，在播放页点右上角的 ♥',
                    style: TextStyle(color: Colors.white54)),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                  ),
                  itemCount: _liked.length,
                  itemBuilder: (_, i) => VideoCard(item: _liked[i], onTap: () => _open(_liked[i])),
                ),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
