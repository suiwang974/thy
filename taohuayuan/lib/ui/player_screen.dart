import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_item.dart';
import '../services/store.dart';
import '../services/stream_resolver.dart';

/// 播放页：点开直接在线播。
/// - 播放一律走直链、原生播（ExoPlayer，HLS/mp4 都行；niacg 的链带 Referer 头）；
/// - 广告是源站页面和播放器周围加的，视频文件本身没广告；直链播就没广告，
///   开源站页面才有广告。所以 App 里不放源站页面、不弹广告；
/// - xvideos 优先直链，拿不到直链的才给“在源站看”当备选，备选页里有广告要如实说，
///   而且是用户点了才打开，不自动开；
/// - 只有一套控制条 + 倍速选择；同列表内有上一段/下一段；
/// - 打开时预探上一段/下一段的直链，点播放不用等；
/// - 退出/切段时记看完比例（进推荐画像，已看完的不再推）；
/// - 右上角“不喜欢”会把这条的标签降权。
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
    _prefetchNeighbors();
  }

  void _prefetchNeighbors() {
    final list = widget.playlist;
    if (list == null) return;
    final idx = list.indexWhere((v) => v.id == _current.id);
    if (idx < 0) return;
    if (idx > 0) unawaited(StreamResolver.prefetch(list[idx - 1]));
    if (idx < list.length - 1) unawaited(StreamResolver.prefetch(list[idx + 1]));
  }

  void _recordProgress() {
    final c = _controller;
    if (c != null && c.value.isInitialized && c.value.duration.inSeconds > 0) {
      unawaited(widget.store.recordWatch(_current, c.value.position.inSeconds));
    }
  }

  Future<void> _play(VideoItem item) async {
    _recordProgress();
    // 预探时补全过的条目（封面/时长补上了）就用补全版。
    item = StreamResolver.enrich(item);
    setState(() {
      _loading = true;
      _error = null;
      _current = item;
      _liked = widget.store.likedIds.contains(item.id);
    });
    await _controller?.dispose();
    _controller = null;
    _prefetchNeighbors();
    final stream = await StreamResolver.resolve(item);
    if (!mounted) return;
    if (stream == null) {
      // 没直链：不自动开源站页面。只给官方播放器/官方页当备选，用户点了才打开，
      // 有广告的站如实说，没广告的（niacg、lianzu11）直接嵌官方播。
      setState(() {
        _loading = false;
        _error = item.pageUrl != null && item.pageUrl!.isNotEmpty
            ? (StreamResolver.sourcePageHasAds(item.source)
                ? '这段拿不到直链，只能去源站看'
                : '这段拿不到直链，用官方播放器看（无广告）')
            : '找不到能直接播的地址';
      });
      return;
    }
    if (stream.isPreview) {
      // 解析时已核出是短预览（比如 Eporner 1 分钟带水印预览）：不标成“能直接播”，
      // 自动切备选并写明是预览。
      setState(() {
        _loading = false;
        _error = _previewText(item, stream.durationSec);
      });
      return;
    }
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(stream.url),
        httpHeaders: stream.headers,
      );
      await c.initialize();
      if (!mounted) return;
      // mp4 在解析时算不出时长，这里用播放器初始化后的真实时长再核一次：
      // 真实不到列表一半就是预览，不播，切备选并写明。
      final actualSec = c.value.duration.inSeconds;
      if (StreamResolver.isPreviewDuration(listedSec: item.durationSec, actualSec: actualSec)) {
        await c.dispose();
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = _previewText(item, actualSec);
        });
        return;
      }
      setState(() {
        _controller = c;
        _loading = false;
      });
      // 续播：上次看到一半的，点开接着看（开头 10 秒内和结尾 10 秒内不跳）。
      final resume = widget.store.watchPosition(item.id);
      final total = c.value.duration.inSeconds;
      if (resume > 10 && total - resume > 10) {
        await c.seekTo(Duration(seconds: resume));
      }
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

  /// 预览提示：直链实际时长 + 列表时长都写出来，不假装是正片。
  String _previewText(VideoItem item, int? actualSec) {
    final actual = actualSec != null && actualSec > 0 ? _fmt(Duration(seconds: actualSec)) : '1 分钟左右';
    final listed = item.durationText.isEmpty ? '未知' : item.durationText;
    return '这条直链只有 $actual，是带水印的预览，不是正片（列表写 $listed）';
  }

  /// 备选按钮文案（通用规则）：有广告的站如实说，没广告的直接说官方播放器。
  String get _fallbackButtonLabel => StreamResolver.sourcePageHasAds(_current.source)
      ? '在源站看 ↗（源站页面有广告）'
      : '在官方播放器看（无广告）';

  String get _fallbackNote => StreamResolver.sourcePageHasAds(_current.source)
      ? '广告是源站页面加的，视频本身没广告；直链播就没有广告。'
      : '${_current.source}官方站本身没广告，直接嵌官方播放器播。';

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
    _recordProgress();
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
                IconButton(
                  icon: const Icon(Icons.thumb_down_outlined, color: Colors.white70),
                  tooltip: '不喜欢这类推荐',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await widget.store.dislikeItem(_current);
                    messenger.showSnackBar(
                      const SnackBar(content: Text('已降权这类推荐')),
                    );
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
              if (_current.pageUrl != null) ...[
                const SizedBox(height: 8),
                Text(_fallbackNote,
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _webController = WebViewController()
                        ..setJavaScriptMode(JavaScriptMode.unrestricted)
                        ..loadRequest(Uri.parse(_current.pageUrl!));
                    });
                  },
                  child: Text(_fallbackButtonLabel),
                ),
              ],
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
          // 备选只在直链播不起来时出现（_controller 为空），播得起来就不给源站页面入口。
          if (_current.pageUrl != null && _controller == null) ...[
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
                child: Text(_fallbackButtonLabel),
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
