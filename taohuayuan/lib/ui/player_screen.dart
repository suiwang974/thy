import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_item.dart';
import '../services/store.dart';
import '../services/stream_resolver.dart';

/// 播放页：点开直接在线播。
/// - 有直链就用 ExoPlayer 播（HLS/mp4 都行；niacg 的链带 Referer 头）；
/// - 没直链（03 批 5 条待补、或 xvideos 等站解析不到）就显示“在源站看”，App 内嵌网页打开源站视频页；
/// - 只有一套控制条 + 倍速选择；片库批次内有上一段/下一段。
class PlayerScreen extends StatefulWidget {
  final VideoItem item;
  final List<VideoItem>? playlist; // 同一批的段列表（有就显示上一段/下一段）
  final Store store;
  const PlayerScreen({super.key, required this.item, this.playlist, required this.store});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _controller;
  String? _error;
  bool _loading = true;
  bool _isFullscreen = false;
  double _speed = 1.0;
  late VideoItem _current;
  bool _liked = false;
  WebViewController? _webController;

  @override
  void initState() {
    super.initState();
    _current = widget.item;
    _liked = widget.store.likedIds.contains(_current.id);
    _play(_current);
    widget.store.addHistory(_current);
  }

  Future<void> _play(VideoItem item) async {
    setState(() {
      _loading = true;
      _error = null;
      _current = item;
      _liked = widget.store.likedIds.contains(item.id);
    });
    await _controller?.dispose();
    _controller = null;
    final stream = await StreamResolver.resolve(item);
    if (!mounted) return;
    if (stream == null) {
      // 没直链：如果有源站页就内嵌打开，否则直接报错。
      if (item.pageUrl != null && item.pageUrl!.isNotEmpty) {
        setState(() {
          _loading = false;
          _error = null;
          _webController = WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..loadRequest(Uri.parse(item.pageUrl!));
        });
      } else {
        setState(() {
          _loading = false;
          _error = item.needsRelink ? '这段直链待补，暂时播不了' : '找不到能直接播的地址，请点“在源站看”';
        });
      }
      return;
    }
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(stream.url),
        httpHeaders: stream.headers,
      );
      await c.initialize();
      if (!mounted) return;
      setState(() {
        _controller = c;
        _loading = false;
      });
      await c.setPlaybackSpeed(_speed);
      await c.play();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '播不起来：$e';
      });
    }
  }

  void _playNext(int delta) {
    final list = widget.playlist;
    if (list == null || list.isEmpty) return;
    final idx = list.indexWhere((v) => v.id == _current.id);
    final next = idx + delta;
    if (next >= 0 && next < list.length) _play(list[next]);
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    setState(() => _isFullscreen = !_isFullscreen);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _isFullscreen
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              iconTheme: const IconThemeData(color: Colors.white),
              title: Text(_current.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
              actions: [
                IconButton(
                  icon: Icon(_liked ? Icons.favorite : Icons.favorite_border, color: _liked ? Colors.red : Colors.white),
                  onPressed: () async {
                    await widget.store.toggleLike(_current);
                    setState(() => _liked = !_liked);
                  },
                ),
              ],
            ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: _isFullscreen ? 16 / 9 : 16 / 9,
            child: Container(
              color: Colors.black,
              child: _buildVideoArea(c),
            ),
          ),
          if (!_isFullscreen) Expanded(child: _buildInfo()),
        ],
      ),
    );
  }

  Widget _buildVideoArea(VideoPlayerController? c) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.pinkAccent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white54, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              if (_current.pageUrl != null)
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _webController = WebViewController()
                        ..setJavaScriptMode(JavaScriptMode.unrestricted)
                        ..loadRequest(Uri.parse(_current.pageUrl!));
                    });
                  },
                  child: const Text('在源站看 ↗'),
                ),
            ],
          ),
        ),
      );
    }
    if (_webController != null) {
      return Stack(
        children: [
          WebViewWidget(controller: _webController!),
          Positioned(
            right: 8, top: 8,
            child: ElevatedButton(
              onPressed: () => setState(() => _webController = null),
              child: const Text('返回'),
            ),
          ),
        ],
      );
    }
    if (c == null || !c.value.isInitialized) {
      return const Center(child: Text('播放器还没准备好', style: TextStyle(color: Colors.white54)));
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
        GestureDetector(
          onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
          child: Container(color: Colors.transparent),
        ),
        if (!c.value.isPlaying)
          const Icon(Icons.play_circle_fill, color: Colors.white70, size: 72),
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87]),
            ),
            child: Column(
              children: [
                VideoProgressIndicator(c, allowScrubbing: true,
                    colors: const VideoProgressColors(playedColor: Colors.pinkAccent, bufferedColor: Colors.white30, backgroundColor: Colors.white24)),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                      onPressed: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
                    ),
                    Text(
                      '${_fmt(c.value.position)} / ${_fmt(c.value.duration)}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const Spacer(),
                    _speedButton(),
                    IconButton(
                      icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
                      onPressed: _toggleFullscreen,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _speedButton() {
    const speeds = [0.5, 1.0, 1.25, 1.5, 2.0];
    return PopupMenuButton<double>(
      icon: Text('${_speed}x', style: const TextStyle(color: Colors.white, fontSize: 13)),
      onSelected: (v) async {
        setState(() => _speed = v);
        await _controller?.setPlaybackSpeed(v);
      },
      itemBuilder: (_) => speeds
          .map((s) => PopupMenuItem<double>(value: s, child: Text('${s}x${s == _speed ? ' ✓' : ''}')))
          .toList(),
    );
  }

  Widget _buildInfo() {
    final list = widget.playlist;
    final idx = list == null ? -1 : list.indexWhere((v) => v.id == _current.id);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_current.title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _chip(_current.source),
              if (_current.author.isNotEmpty) _chip('作者：${_current.author}'),
              if (_current.batch.isNotEmpty) _chip(_current.batch),
              if (_current.resolution.isNotEmpty) _chip(_current.resolution),
              if (_current.durationText.isNotEmpty) _chip('时长 ${_current.durationText}'),
            ],
          ),
          const SizedBox(height: 16),
          if (list != null && list.length > 1)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: idx > 0 ? () => _playNext(-1) : null,
                    child: const Text('上一段'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: idx >= 0 && idx < list.length - 1 ? () => _playNext(1) : null,
                    child: const Text('下一段'),
                  ),
                ),
              ],
            ),
          if (_current.pageUrl != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _webController = WebViewController()
                      ..setJavaScriptMode(JavaScriptMode.unrestricted)
                      ..loadRequest(Uri.parse(_current.pageUrl!));
                  });
                },
                child: const Text('在源站看 ↗'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '第 ${idx >= 0 ? idx + 1 : 1} / ${list?.length ?? 1} 段',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFF2A2A35), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      );

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
