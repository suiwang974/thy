import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import '../services/web_search.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 作者页：点作者名只看他的片；可以关注/取关。
/// 数据走 10 个在线源实时搜作者名（第 41 条：niacg/lianzu11/hanime 也一起搜，
/// 靠隐藏 WebView 过验证），中文映射同样生效，再按标题/作者名过滤。
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
  bool _loading = true;

  // 第 41 条：WebView 内搜索用的隐藏 WebView（作者搜 niacg/lianzu11/hanime 也要它）。
  late final WebViewController _webController;
  late final WebSearchRunner _webRunner;

  @override
  void initState() {
    super.initState();
    _webController = WebViewController();
    _webRunner = WebSearchRunner(_webController);
    _followed = widget.store.followedAuthors.contains(widget.author);
    _load();
  }

  Future<void> _load() async {
    final results = await SearchService(
      disabledSources: widget.store.disabledSources,
      webSearch: _webRunner,
    ).searchAll(widget.author);
    if (!mounted) return;
    final needle = widget.author.toLowerCase();
    final all = results.expand((r) => r.items).toList();
    setState(() {
      _videos = all
          .where((v) =>
              v.author.toLowerCase().contains(needle) ||
              v.title.toLowerCase().contains(needle))
          .toList();
      _loading = false;
    });
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
      body: Stack(
        children: [
          // 第 41 条：WebView 内搜索用的隐藏 WebView（1x1 藏着）。
          Offstage(
            offstage: true,
            child: SizedBox(
              width: 1,
              height: 1,
              child: WebViewWidget(controller: _webController),
            ),
          ),
          _loading
              ? const Center(child: CircularProgressIndicator(color: Colors.pinkAccent))
              : _videos.isEmpty
                  ? const Center(child: Text('这个作者暂无在线结果，换个名字试试', style: TextStyle(color: Colors.white54)))
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
        ],
      ),
    );
  }
}
