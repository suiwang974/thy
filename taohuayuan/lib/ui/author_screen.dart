import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../models/video_item.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 作者页：点作者名只看他的片；可以关注/取关。
class AuthorScreen extends StatefulWidget {
  final String author;
  final Store store;
  const AuthorScreen({super.key, required this.author, required this.store});

  @override
  State<AuthorScreen> createState() => _AuthorScreenState();
}

class _AuthorScreenState extends State<AuthorScreen> {
  List<VideoItem> _videos = [];
  bool _followed = false;

  @override
  void initState() {
    super.initState();
    _followed = widget.store.followedAuthors.contains(widget.author);
    _load();
  }

  Future<void> _load() async {
    final catalog = await Catalog.load();
    if (!mounted) return;
    setState(() => _videos = catalog.where((v) => v.author == widget.author).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text('👤 ${widget.author}', style: const TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () async {
              await widget.store.toggleFollow(widget.author);
              setState(() => _followed = !_followed);
            },
            child: Text(_followed ? '已关注 ✓' : '+ 关注',
                style: const TextStyle(color: Colors.pinkAccent, fontSize: 15)),
          ),
        ],
      ),
      body: _videos.isEmpty
          ? const Center(child: Text('这个作者在片库里没有片', style: TextStyle(color: Colors.white54)))
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
              ),
              itemCount: _videos.length,
              itemBuilder: (_, i) => VideoCard(
                item: _videos[i],
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PlayerScreen(item: _videos[i], playlist: _videos, store: widget.store),
                )),
              ),
            ),
    );
  }
}
