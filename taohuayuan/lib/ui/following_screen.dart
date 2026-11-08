import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../models/video_item.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 追番页：关注的作者 + 喜欢的视频。
/// 点作者名只看他的片；取消关注也在这里。
class FollowingScreen extends StatefulWidget {
  final Store store;
  final void Function(String author) onAuthorTap;
  const FollowingScreen({super.key, required this.store, required this.onAuthorTap});

  @override
  State<FollowingScreen> createState() => _FollowingScreenState();
}

class _FollowingScreenState extends State<FollowingScreen> {
  List<VideoItem> _catalog = [];
  List<VideoItem> _liked = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await Catalog.load();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _liked = widget.store.likedItems();
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
    final followVideos = _catalog.where((v) => follows.contains(v.author)).toList();
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
            if (followVideos.isNotEmpty) ...[
              const SectionTitle('关注作者的新片'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                  ),
                  itemCount: followVideos.length,
                  itemBuilder: (_, i) => VideoCard(item: followVideos[i], onTap: () => _open(followVideos[i])),
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
