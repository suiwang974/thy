import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import '../services/stream_resolver.dart';

/// 短视频页：竖屏上下滑，滑到哪段就真播哪段的视频（不是只放封面图）。
/// 数据走 8 个在线源的实时热门（没有本地目录）；滑到下一段前先预探它的直链。
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
    final feed = await SearchService().homeFeed();
    if (!mounted) return;
    setState(() {
      // 实时热门流：直接拿来竖滑真播（解析不到直链的段，进页后显示“暂时播不了”，可继续滑走）。
      _items = feed.take(60).toList();
      _loading = false;
    });
    if (_items.isNotEmpty) {
      // 预探第 2 段的直链，滑过去不用等。
      unawaited(StreamResolver.prefetch(_items[1 % _items.length]));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.pinkAccent));
    }
    if (_items.isEmpty) {
      return const Center(child: Text('短视频流是空的，检查网络后切到推荐页下拉刷新再试', style: TextStyle(color: Colors.white70)));
    }
    return PageView.builder(
      scrollDirection: Axis.vertical,
      itemCount: _items.length,
      onPageChanged: (i) {
        // 滑到第 i 段，预探第 i+1 段的直链。
        if (i + 1 < _items.length) unawaited(StreamResolver.prefetch(_items[i + 1]));
      },
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
  late VideoItem _displayItem; // 预探补全后的条目（封面/时长补上了就用补全版）

  @override
  void initState() {
    super.initState();
    _displayItem = widget.item;
    _liked = widget.store.likedIds.contains(widget.item.id);
    _init();
  }

  Future<void> _init() async {
    final stream = await StreamResolver.resolve(widget.item);
    if (!mounted) return;
    // 解析完用补全后的条目显示和核时长（详情页预探时顺带补了封面/时长）。
    _displayItem = StreamResolver.enrich(widget.item);
    if (stream == null) {
      setState(() => _error = '这段拿不到直链，滑走看下一段');
      return;
    }
    if (stream.isPreview) {
      // 解析时已核出是短预览：不播，滑走看下一段。
      setState(() => _error = '这段只有预览，滑走看下一段');
      return;
    }
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(stream.url), httpHeaders: stream.headers);
      await c.initialize();
      if (!mounted) return;
      // mp4 靠播放器初始化后的真实时长再核一次：是预览就不播。
      // 时长用补全后的条目（详情页预探时可能补了真实时长）。
      final actualSec = c.value.duration.inSeconds;
      if (StreamResolver.isPreviewDuration(listedSec: _displayItem.durationSec, actualSec: actualSec)) {
        await c.dispose();
        if (!mounted) return;
        setState(() => _error = '这段只有预览，滑走看下一段');
        return;
      }
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
        child: _FullscreenShorts(controller: _controller, item: _displayItem),
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
                Text(_displayItem.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('${_displayItem.author.isEmpty ? _displayItem.source : '👤 ${_displayItem.author}'}${_displayItem.durationText.isEmpty ? '' : ' · ${_displayItem.durationText}'}',
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
