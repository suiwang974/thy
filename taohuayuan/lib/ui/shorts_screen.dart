import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../data/catalog.dart';
import '../models/video_item.dart';
import '../services/store.dart';
import '../services/stream_resolver.dart';

/// 短视频页：竖屏上下滑，滑到哪段就真播哪段的视频（不是只放封面图）。
/// 点一下放大横屏；再点一下暂停/继续。
class ShortsScreen extends StatefulWidget {
  final Store store;
  const ShortsScreen({super.key, required this.store});

  @override
  State<ShortsScreen> createState() => _ShortsScreenState();
}

class _ShortsScreenState extends State<ShortsScreen> {
  List<VideoItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await Catalog.load();
    if (!mounted) return;
    setState(() {
      // 只放能直接播的段（03 批 5 条直链待补的不进短视频流）。
      _items = catalog.where((v) => v.playable).toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.pinkAccent));
    }
    if (_items.isEmpty) {
      return const Center(child: Text('短视频流是空的', style: TextStyle(color: Colors.white70)));
    }
    return PageView.builder(
      scrollDirection: Axis.vertical,
      itemCount: _items.length,
      itemBuilder: (_, i) => _ShortPage(item: _items[i], index: i, total: _items.length, store: widget.store),
    );
  }
}

class _ShortPage extends StatefulWidget {
  final VideoItem item;
  final int index;
  final int total;
  final Store store;
  const _ShortPage({required this.item, required this.index, required this.total, required this.store});

  @override
  State<_ShortPage> createState() => _ShortPageState();
}

class _ShortPageState extends State<_ShortPage> {
  VideoPlayerController? _controller;
  String? _error;
  bool _liked = false;

  @override
  void initState() {
    super.initState();
    _liked = widget.store.likedIds.contains(widget.item.id);
    _init();
  }

  Future<void> _init() async {
    final stream = await StreamResolver.resolve(widget.item);
    if (!mounted) return;
    if (stream == null) {
      setState(() => _error = '这段暂时播不了');
      return;
    }
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(stream.url), httpHeaders: stream.headers);
      await c.initialize();
      if (!mounted) return;
      setState(() => _controller = c);
      await c.setLooping(true);
      await c.play();
    } catch (e) {
      if (mounted) setState(() => _error = '播不起来');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _fullscreen() async {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: _FullscreenShorts(controller: _controller, item: widget.item),
      ),
    );
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () {
              if (c == null) return;
              setState(() => c.value.isPlaying ? c.pause() : c.play());
            },
            child: c != null && c.value.isInitialized
                ? Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)))
                : _error != null
                    ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
                    : const Center(child: CircularProgressIndicator(color: Colors.pinkAccent)),
          ),
          if (c != null && !c.value.isPlaying)
            const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 80)),
          Positioned(
            left: 12, right: 70, bottom: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('${widget.item.author.isEmpty ? widget.item.source : '👤 ${widget.item.author}'} · ${widget.item.batch}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                Text('第 ${widget.index + 1} / ${widget.total} 段', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          Positioned(
            right: 12, bottom: 24,
            child: Column(
              children: [
                IconButton(
                  icon: Icon(_liked ? Icons.favorite : Icons.favorite_border,
                      color: _liked ? Colors.red : Colors.white, size: 30),
                  onPressed: () async {
                    await widget.store.toggleLike(widget.item);
                    setState(() => _liked = !_liked);
                  },
                ),
                const SizedBox(height: 8),
                IconButton(
                  icon: const Icon(Icons.fullscreen, color: Colors.white, size: 30),
                  onPressed: _fullscreen,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 横屏放大播：同一份 controller，不重新加载。
class _FullscreenShorts extends StatelessWidget {
  final VideoPlayerController? controller;
  final VideoItem item;
  const _FullscreenShorts({required this.controller, required this.item});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null && c.value.isInitialized)
              Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
            Positioned(
              left: 16, top: 16,
              child: Text(item.title, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ),
            const Positioned(
              right: 16, top: 16,
              child: Icon(Icons.close, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
