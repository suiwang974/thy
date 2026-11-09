import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
    final feed = await SearchService(disabledSources: widget.store.disabledSources).homeFeed();
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
  WebViewController? _webController;
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
      _embedOfficial('这段拿不到直链，用官方播放器看');
      return;
    }
    if (stream.isPreview) {
      // 解析时已核出是短预览：不播直链，嵌官方播放器看正片。
      _embedOfficial('这段直链只有预览，用官方播放器看');
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
        _embedOfficial('这段直链只有预览，用官方播放器看');
        return;
      }
      if (actualSec > 0 && _displayItem.durationSec > 0 && actualSec > _displayItem.durationSec * 2) {
        // 真实时长比列表时长长一倍以上：列表写错了，显示改成真实时长。
        _displayItem = _displayItem.copyWith(durationSec: actualSec);
      }
      setState(() => _controller = c);
      await c.setLooping(true);
      await c.play();
    } catch (e) {
      if (mounted) {
        final s = e.toString().replaceAll(RegExp(r'\s+'), ' ');
        _embedOfficial('播不起来：${s.length > 90 ? '${s.substring(0, 90)}…' : s}');
      }
    }
  }

  /// 内嵌官方播放器（WebView 兜底）：源站播放页在 App 里打开，不踢出到外部浏览器。
  /// 原因写在顶部横幅，附“重试直链”按钮。
  void _embedOfficial(String reason) {
    final embed = _displayItem.embedUrl;
    if (embed.isEmpty) {
      setState(() => _error = '$reason；这段也没有官方播放页可嵌，滑走看下一段');
      return;
    }
    final wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          final u = req.url;
          if (u.contains('eporner.com') ||
              u.contains('rule34-videos.com') ||
              u.contains('niacg.com') ||
              u.contains('lianzu11.com') ||
              u.contains('hanime1.me') ||
              u.contains('hanimeone.me') ||
              u.contains('xvideos.com') ||
              u.contains('xhamster.com') ||
              u.contains('pornhub.com') ||
              u.contains('spankbang.com') ||
              u.startsWith('about:blank') ||
              u.startsWith('data:')) {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
      ))
      ..loadRequest(Uri.parse(embed));
    setState(() {
      _webController = wc;
      _error = reason;
    });
  }

  /// 重试直链：清掉解析缓存，关掉官方播放器，重新解析播。
  Future<void> _retryDirect() async {
    StreamResolver.clearCacheFor(widget.item.id);
    _webController = null;
    _error = null;
    await _controller?.dispose();
    _controller = null;
    setState(() {});
    await _init();
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
            child: _webController != null
                ? WebViewWidget(controller: _webController!)
                : c != null && c.value.isInitialized
                    ? Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)))
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_error!, textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.white70, fontSize: 15)),
                                  const SizedBox(height: 16),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ElevatedButton(
                                        onPressed: _retryDirect,
                                        child: const Text('重试直链'),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton(
                                        onPressed: () => _embedOfficial('已切换到源站官方播放器'),
                                        child: const Text('官方播放器'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          )
                        : const Center(child: CircularProgressIndicator(color: Colors.pinkAccent)),
          ),
          if (_webController != null)
            Positioned(
              left: 12, right: 12, top: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error ?? '正在用源站官方播放器播',
                        style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: _retryDirect,
                          child: const Text('重试直链'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => setState(() {
                            _webController = null;
                            _error = '已关掉官方播放器，可重试直链或滑走';
                          }),
                          child: const Text('关掉官方播放器'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
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
