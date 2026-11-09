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
///   开源站页面才有广告；
/// - 直链拿不到 / 直链播不起来 / 直链是预览 → 自动切 App 内嵌官方播放器
///   （WebView，源站播放页在 App 里打开，不踢出到外部浏览器），
///   原因写在播放器上方，附“重试直链”按钮；有广告的站如实说，
///   没广告的（niacg、lianzu11）直接嵌官方播；
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
  // 降权状态（持久保存）：点了图标要亮起，再点取消。之前只有动作、没有状态，
  // 点了图标不亮、再点也不会恢复，用户以为按钮坏了。
  bool _disliked = false;
  WebViewController? _webController;
  // 画质档位（全屏分辨率菜单用）：当前在播的是哪一档。
  List<StreamVariant> _variants = [];
  String? _variantLabel;
  // 无画面看门狗：原生播放器播出声音但画面纹理一直没出帧时自动切官方播放器。
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    _current = widget.item;
    _liked = widget.store.likedIds.contains(_current.id);
    _disliked = widget.store.isDisliked(_current);
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
      _disliked = widget.store.isDisliked(item);
      _variants = [];
      _variantLabel = null;
    });
    await _controller?.dispose();
    _controller = null;
    _webController = null;
    _prefetchNeighbors();
    final stream = await StreamResolver.resolve(item);
    if (!mounted) return;
    _currentStreamUrl = stream?.url;
    if (stream == null) {
      // 没直链：自动切 App 内嵌官方播放器（WebView），不只给外跳按钮当唯一出路。
      // 用户 2026-11-09 原话：能在本站看就在本站看，不要跑来跑去。
      _embedOfficial('这段拿不到直链，改用源站官方播放器看');
      return;
    }
    if (stream.isPreview) {
      // 解析时已核出是短预览（比如 Eporner 1 分钟带水印预览）：不标成“能直接播”，
      // 自动切官方播放器并写明是预览。
      _embedOfficial(_previewText(item, stream.durationSec));
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
      // 真实不到列表一半就是预览，不播，切官方播放器并写明。
      final actualSec = c.value.duration.inSeconds;
      if (StreamResolver.isPreviewDuration(listedSec: item.durationSec, actualSec: actualSec)) {
        await c.dispose();
        if (!mounted) return;
        _embedOfficial(_previewText(item, actualSec));
        return;
      }
      if (actualSec > 0 && item.durationSec > 0 && actualSec > item.durationSec * 2) {
        // 真实时长比列表时长长一倍以上：列表写错了（比如列表写 156:52 这种
        // 离谱值），显示改成真实时长，别让用户以为是另一条片。
        _current = item.copyWith(durationSec: actualSec);
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
      // 无画面看门狗 + 画质档位：播起来之后 3 秒再看一眼——
      // 声音在放、但视频轨道一直没给尺寸（宽/高为 0），说明画面纹理没出帧
      // （用户 2026-11-09 截图：灰框只有声音没画面），别让用户对着灰框干等，
      // 自动切 App 内嵌官方播放器；控制条里也常驻“官方播放器”按钮，一点就切。
      _startWatchdog(c);
      unawaited(_loadVariants());
    } catch (e) {
      if (!mounted) return;
      _embedOfficial('直链播不起来：${_shortReason(e)}');
    }
  }

  /// 无画面看门狗：播起来 3 秒后检查一次——视频轨道没尺寸（宽/高为 0）
  /// 或报了错，说明画面出不来，自动切官方播放器。
  /// 正常视频 initialize 完就有尺寸，不会误判。
  void _startWatchdog(VideoPlayerController c) {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 3), () {
      if (!mounted || _controller != c || _webController != null) return;
      final v = c.value;
      if (v.hasError || v.size.width <= 0 || v.size.height <= 0) {
        _embedOfficial('原生播放器出不来画面（只有声音），已切官方播放器');
      }
    });
  }

  /// 当前条目的画质档位（全屏分辨率菜单用）；当前在播的那一档标出来。
  Future<void> _loadVariants() async {
    final vs = await StreamResolver.variantsFor(_current);
    if (!mounted) return;
    String? current;
    for (final v in vs) {
      if (v.url == _currentStreamUrl) current = v.label;
    }
    setState(() {
      _variants = vs;
      _variantLabel = current;
    });
  }

  // 当前在播的直链地址（切档位时用来标出当前档；resolve 时记下来）。
  String? _currentStreamUrl;

  /// 切画质档位：不断流重进——记下当前位置/倍速，换新地址重建播放器，
  /// 回到原位置继续播。同一档不重复切。
  Future<void> _switchVariant(StreamVariant v) async {
    final old = _controller;
    if (old == null || v.url == _currentStreamUrl) return;
    final pos = old.value.position;
    final wasPlaying = old.value.isPlaying;
    _watchdog?.cancel();
    await old.dispose();
    if (!mounted) return;
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(v.url), httpHeaders: v.headers);
      await c.initialize();
      if (!mounted) return;
      setState(() {
        _controller = c;
        _currentStreamUrl = v.url;
        _variantLabel = v.label;
        _loading = false;
      });
      await c.seekTo(pos);
      await c.setPlaybackSpeed(_speed);
      if (wasPlaying) await c.play();
      _startWatchdog(c);
    } catch (e) {
      if (!mounted) return;
      _embedOfficial('切画质失败：${_shortReason(e)}');
    }
  }

  /// 内嵌官方播放器（WebView 兜底）：源站播放页在 App 里打开，
  /// 不踢出到外部浏览器；有广告的源站页面里有广告（写清楚），
  /// niacg/lianzu11 官方站本身没广告。
  /// 注意之前这里有个死代码 bug：_error 非空时 _buildVideoArea 永远走报错分支，
  /// WebView 永远渲染不出来，点“在源站看”什么都没发生。
  /// 现在 _webController 优先渲染（见 _buildVideoArea），_error 只当原因横幅。
  void _embedOfficial(String reason) {
    final embed = _current.embedUrl;
    if (embed.isEmpty) {
      setState(() {
        _loading = false;
        _error = '$reason；这段也没有官方播放页可嵌';
      });
      return;
    }
    final wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          // 官方播放器页内跳转放行；点到站外广告/下载链接时拦住，别把人带走。
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
    _webController = wc;
    setState(() {
      _loading = false;
      _error = reason;
    });
  }

  /// 重试直链：清掉解析缓存（直链地址可能已过期），关掉官方播放器，重新解析播。
  Future<void> _retryDirect() async {
    StreamResolver.clearCacheFor(_current.id);
    _webController = null;
    await _play(_current);
  }

  /// 关掉官方播放器，回到报错界面（可以再重试直链或重新嵌官方）。
  void _closeWeb() {
    _webController = null;
    setState(() {
      _error = _error ?? '已关掉官方播放器';
    });
  }

  /// 播放器报错的简短原因（PlatformException 的 message 太长，截到一行）。
  String _shortReason(Object e) {
    final s = e.toString().replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  /// 预览提示：直链实际时长 + 列表时长都写出来，不假装是正片。
  String _previewText(VideoItem item, int? actualSec) {
    final actual = actualSec != null && actualSec > 0 ? _fmt(Duration(seconds: actualSec)) : '1 分钟左右';
    final listed = item.durationText.isEmpty ? '未知' : item.durationText;
    return '这条直链只有 $actual，是带水印的预览，不是正片（列表写 $listed）';
  }

  /// 备选按钮文案（通用规则）：有广告的站如实说，没广告的直接说官方播放器。
  /// 按钮点开是在 App 里嵌官方播放器，不踢出到外部浏览器。
  String get _fallbackButtonLabel => StreamResolver.sourcePageHasAds(_current.source)
      ? '用官方播放器看（源站页面有广告）'
      : '用官方播放器看（无广告）';

  /// 报错区里的一行版说明（视频框只有约 220px 高，放不下两行说明）。
  String get _fallbackNoteShort => StreamResolver.sourcePageHasAds(_current.source)
      ? '广告是源站页面加的，视频本身没广告。'
      : '官方站本身没广告，直接嵌官方播放器播。';

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
    _watchdog?.cancel();
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
                  icon: Icon(
                      _disliked ? Icons.thumb_down : Icons.thumb_down_outlined,
                      color: _disliked ? Colors.pinkAccent : Colors.white70),
                  tooltip: '不喜欢这类推荐',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final now = await widget.store.toggleDislike(_current);
                    if (!mounted) return;
                    setState(() => _disliked = now);
                    messenger.showSnackBar(
                      SnackBar(
                          content:
                              Text(now ? '已降权这类推荐' : '已取消降权')),
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
              // 报错内容超高时裁掉，不许溢出画到下面的标题上（v3 截图里
              // “在源站看”按钮就压在标题文字上了，就是这里没裁剪）。
              clipBehavior: Clip.hardEdge,
              child: _buildVideoArea(c),
            ),
          ),
          if (!_isFullscreen) Expanded(child: _buildInfo()),
        ],
      ),
    );
  }

  Widget _buildVideoArea(VideoPlayerController? c) {
    // 内嵌官方播放器优先渲染（修死代码 bug：之前 _error 非空就永远走报错分支，
    // WebView 永远渲染不出来，点“在源站看”什么都没发生）。
    if (_webController != null) {
      return Column(
        children: [
          Expanded(child: WebViewWidget(controller: _webController!)),
          Container(
            width: double.infinity,
            color: const Color(0xFF2A2A35),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _error ?? '正在用源站官方播放器播',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _retryDirect,
                        child: const Text('重试直链'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _closeWeb,
                        child: const Text('关掉官方播放器'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.pinkAccent));
    }
    if (_error != null) {
      // 报错区必须塞进 16:9 的视频框里（手机上约 220px 高）：图标、文字、
      // 按钮全部收紧，超长报错截两行，说明只留一行。之前图标 48 + 三行报错 +
      // 两行说明 + 大按钮，内容比框高，居中溢出后按钮直接画到下面的标题上。
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white54, size: 32),
              const SizedBox(height: 6),
              Text(_error!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              if (_current.embedUrl.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(_fallbackNoteShort,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _retryDirect,
                        child: const Text('重试'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _embedOfficial('已切换到源站官方播放器'),
                        child: Text(_fallbackButtonLabel),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (c == null || !c.value.isInitialized) {
      return const Center(child: Text('播放器还没准备好', style: TextStyle(color: Colors.white54)));
    }
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        // 画面：按视频比例居中适配（contain），不撑大外框。
        // 之前内层 AspectRatio 直接当 Stack 的尺寸锚：竖屏/4:3 视频会把
        // Stack 撑出 16:9 的框，底部控制条被 Clip.hardEdge 裁到框外——
        // 用户截图就是灰框 + 一个控制键都没有。现在控制条是 Stack 的直接子项，
        // 钉在 16:9 框的底部，跟视频比例无关，裁不掉。
        Center(
          child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
        ),
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
                    // 画质：多档才显示，当前档标 ✓。切档不断流重进（记位置、倍速）。
                    if (_variants.length > 1) _qualityButton(),
                    // 画面出不来时一键切官方播放器（灰框自救，不用退出重进）。
                    TextButton(
                      onPressed: () => _embedOfficial('已切换到源站官方播放器'),
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      child: const Text('官方播', style: TextStyle(color: Colors.white, fontSize: 12)),
                    ),
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

  /// 画质菜单：当前档标 ✓，点别的档不断流重进。
  Widget _qualityButton() {
    final label = _variantLabel ?? '画质';
    return PopupMenuButton<StreamVariant>(
      tooltip: '分辨率',
      onSelected: _switchVariant,
      itemBuilder: (_) => _variants
          .map((v) => PopupMenuItem<StreamVariant>(
              value: v,
              child: Text('${v.label}${v.label == _variantLabel ? ' ✓' : ''}')))
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ),
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
          // 备选只在加载中出现：报错时视频区里已经有 [重试] [用官方播放器看]
          // 两个按钮，这里再放一个同样的按钮纯属重复（v3 里两个“在源站看”
          // 上下叠着，上面那个还压住了标题）。
          // 点开是在 App 里嵌官方播放器，不踢出到外部浏览器。
          if (_error == null && _current.embedUrl.isNotEmpty && _controller == null && _webController == null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _embedOfficial('已切换到源站官方播放器'),
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
