import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_item.dart';
import '../services/adblock_service.dart';
import '../services/fullscreen_controls.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import '../services/stream_resolver.dart';
import 'author_screen.dart';
import 'download_button.dart';

/// 短视频页：竖屏上下滑，滑到哪段就真播哪段的视频（不是只放封面图）。
/// 数据走已启用源的实时热门（没有本地目录）；滑到下一段前先预探它的直链。
/// 点一下放大横屏；再点一下暂停/继续。
/// - 超过 30 分钟的长片不进短视频流（2026-11-09 用户定）；
/// - 滑到底自动加载下一批（无限加载，不是 60 条就到底）；
/// - 默认静音自动播（打开 App 不许自动出声），点喇叭才出声，选择持久保存；
/// - 只有短视频栏可见、且这一段正显示时才播（App 一打开在推荐页时，
///   短视频在后台不许出声——之前 IndexedStack 五栏全建，短视频一加载就播）。
class ShortsScreen extends StatefulWidget {
  final Store store;
  final bool visible; // 短视频栏当前是不是显示的那一栏
  const ShortsScreen({super.key, required this.store, this.visible = true});

  @override
  State<ShortsScreen> createState() => _ShortsScreenState();
}

/// 短片才进短视频流：时长超过 30 分钟（1800 秒）的不要；
/// 时长未知的留着（没数据不能直接丢）。
bool isShortForShorts(VideoItem v) => v.durationSec <= 0 || v.durationSec <= 1800;

class _ShortsScreenState extends State<ShortsScreen> {
  List<VideoItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _noMore = false;
  int _morePage = 1;
  int _moreQueryIdx = 0;
  int _emptyBatches = 0;
  // 续批用的词：按各源默认偏好轮着搜（3d / asian / footjob）。
  static const _moreQueries = ['3d', 'asian', 'footjob'];
  // 当前是第几段 + 是不是静音：所有段共用，换段不重置。
  final ValueNotifier<int> _currentPage = ValueNotifier<int>(0);
  late final ValueNotifier<bool> _muted;

  @override
  void initState() {
    super.initState();
    _muted = ValueNotifier<bool>(widget.store.shortsMuted);
    _load();
  }

  @override
  void dispose() {
    _currentPage.dispose();
    _muted.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final feed = await SearchService(disabledSources: widget.store.disabledSources).homeFeed();
    if (!mounted) return;
    setState(() {
      // 实时热门流：直接拿来竖滑真播（解析不到直链的段，进页后显示“暂时播不了”，可继续滑走）。
      _items = feed.where(isShortForShorts).toList();
      _loading = false;
    });
    if (_items.isNotEmpty) {
      // 预探第 2 段的直链，滑过去不用等。
      unawaited(StreamResolver.prefetch(_items[1 % _items.length]));
    }
  }

  /// 滑到底自动加载下一批：各源按默认词翻页搜（只查已启用源、只留 30 分钟内的）。
  /// 连续 3 批都没新短片才认到底；加载中不重复触发。
  Future<void> _loadMore() async {
    if (_loadingMore || _noMore) return;
    setState(() => _loadingMore = true);
    final q = _moreQueries[_moreQueryIdx % _moreQueries.length];
    _moreQueryIdx++;
    final page = _morePage++;
    try {
      final more = await SearchService(disabledSources: widget.store.disabledSources)
          .searchPage(q, page);
      if (!mounted) return;
      final seen = _items.map((v) => v.id).toSet();
      final fresh = more.where((v) => isShortForShorts(v) && !seen.contains(v.id)).toList();
      setState(() {
        _loadingMore = false;
        if (fresh.isEmpty) {
          _emptyBatches++;
          if (_emptyBatches >= 3) _noMore = true;
        } else {
          _emptyBatches = 0;
          _items = [..._items, ...fresh];
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
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
        _currentPage.value = i;
        // 滑到第 i 段，预探第 i+1 段的直链。
        if (i + 1 < _items.length) unawaited(StreamResolver.prefetch(_items[i + 1]));
        // 快滑到底了，提前加载下一批。
        if (i >= _items.length - 3) unawaited(_loadMore());
      },
      itemBuilder: (_, i) => _ShortPage(
        item: _items[i],
        index: i,
        total: _items.length,
        store: widget.store,
        tabVisible: widget.visible,
        currentPage: _currentPage,
        muted: _muted,
      ),
    );
  }
}

class _ShortPage extends StatefulWidget {
  final VideoItem item;
  final int index;
  final int total;
  final Store store;
  final bool tabVisible;
  final ValueNotifier<int> currentPage;
  final ValueNotifier<bool> muted;
  const _ShortPage({
    required this.item,
    required this.index,
    required this.total,
    required this.store,
    required this.tabVisible,
    required this.currentPage,
    required this.muted,
  });

  @override
  State<_ShortPage> createState() => _ShortPageState();
}

class _ShortPageState extends State<_ShortPage> {
  VideoPlayerController? _controller;
  // 全屏对话框通过这个 notifier 拿当前播放器：切画质会重建播放器，
  // 对话框靠 notifier 跟着换，不会拿着旧的（已释放的）播。
  final ValueNotifier<VideoPlayerController?> _controllerNotifier =
      ValueNotifier<VideoPlayerController?>(null);
  WebViewController? _webController;
  String? _error;
  bool _liked = false;
  late VideoItem _displayItem; // 预探补全后的条目（封面/时长补上了就用补全版）
  bool _muted = true;
  double _speed = 1.0;
  List<StreamVariant> _variants = [];
  String? _variantLabel;
  String? _currentStreamUrl;

  bool get _isCurrent => widget.currentPage.value == widget.index;
  bool get _shouldPlay => widget.tabVisible && _isCurrent;

  @override
  void initState() {
    super.initState();
    _displayItem = widget.item;
    _liked = widget.store.likedIds.contains(widget.item.id);
    _muted = widget.muted.value;
    widget.currentPage.addListener(_onPageChanged);
    widget.muted.addListener(_onMutedChanged);
    _init();
  }

  @override
  void didUpdateWidget(covariant _ShortPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切栏（推荐 <-> 短视频）时重判播不播：短视频栏不可见时一律暂停。
    if (oldWidget.tabVisible != widget.tabVisible) _applyPlayState();
  }

  void _onPageChanged() => _applyPlayState();

  void _onMutedChanged() {
    final m = widget.muted.value;
    if (m != _muted) setState(() => _muted = m);
    _controller?.setVolume(m ? 0 : 1);
  }

  /// 只有“短视频栏可见 + 这一段正显示”才播，其他情况暂停。
  /// PageView 会提前建下一段（_init 照常跑、直链照常解析），但没轮到它就不出声。
  void _applyPlayState() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (_shouldPlay) {
      c.setVolume(_muted ? 0 : 1);
      c.play();
    } else {
      c.pause();
    }
  }

  Future<void> _toggleMute() async {
    final m = !widget.muted.value;
    widget.muted.value = m;
    await widget.store.setShortsMuted(m);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    widget.currentPage.removeListener(_onPageChanged);
    widget.muted.removeListener(_onMutedChanged);
    _controllerNotifier.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final stream = await StreamResolver.resolve(widget.item);
    if (!mounted) return;
    // 解析完用补全后的条目显示和核时长（详情页预探时顺带补了封面/时长）。
    _displayItem = StreamResolver.enrich(widget.item);
    _currentStreamUrl = stream?.url;
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
      // 第 37 条：先纠正离谱的列表时长（比如把图片尺寸当成时长），再判预览——
      // 15 分钟的正片不能因为列表写错就被当成预览切走。
      final actualSec = c.value.duration.inSeconds;
      var listedSec = _displayItem.durationSec;
      if (actualSec > 0 && listedSec > 0 && (listedSec > actualSec * 4 || actualSec > listedSec * 4)) {
        listedSec = actualSec;
        _displayItem = _displayItem.copyWith(durationSec: actualSec);
      }
      if (StreamResolver.isPreviewDuration(listedSec: listedSec, actualSec: actualSec)) {
        await c.dispose();
        if (!mounted) return;
        _embedOfficial('这段直链只有预览，用官方播放器看');
        return;
      }
      setState(() {
        _controller = c;
        _controllerNotifier.value = c;
      });
      await c.setLooping(true);
      await c.setVolume(_muted ? 0 : 1);
      await c.setPlaybackSpeed(_speed);
      // 只有轮到这一段、且短视频栏可见才出声播；没轮到它就只准备好、不播。
      if (_shouldPlay) await c.play();
      unawaited(_loadVariants());
    } catch (e) {
      if (mounted) {
        final s = e.toString().replaceAll(RegExp(r'\s+'), ' ');
        _embedOfficial('播不起来：${s.length > 90 ? '${s.substring(0, 90)}…' : s}');
      }
    }
  }

  /// 当前条目的画质档位（全屏分辨率菜单用）。
  Future<void> _loadVariants() async {
    final vs = await StreamResolver.variantsFor(_displayItem);
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

  /// 切画质档位：记下当前位置/倍速/静音，换新地址重建播放器，回到原位置继续播。
  Future<void> _switchVariant(StreamVariant v) async {
    final old = _controller;
    if (old == null || v.url == _currentStreamUrl) return;
    final pos = old.value.position;
    final wasPlaying = old.value.isPlaying;
    await old.dispose();
    if (!mounted) return;
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(v.url), httpHeaders: v.headers);
      await c.initialize();
      if (!mounted) return;
      setState(() {
        _controller = c;
        _controllerNotifier.value = c;
        _currentStreamUrl = v.url;
        _variantLabel = v.label;
      });
      await c.setLooping(true);
      await c.setVolume(_muted ? 0 : 1);
      await c.setPlaybackSpeed(_speed);
      await c.seekTo(pos);
      if (wasPlaying && _shouldPlay) await c.play();
    } catch (_) {
      if (!mounted) return;
      _embedOfficial('切画质失败，用官方播放器看');
    }
  }

  /// 内嵌官方播放器（WebView 兜底）：源站播放页在 App 里打开，不踢出到外部浏览器。
  /// 原因写在顶部横幅，附“重试直链”按钮。
  /// 注意：短视频默认静音——WebView 里的站内播放器也按静音处理（JS 把 video 静音），
  /// 不然官方播放器那段会在后台出声。
  void _embedOfficial(String reason) {
    final embed = _displayItem.embedUrl;
    if (embed.isEmpty) {
      setState(() => _error = '$reason；这段也没有官方播放页可嵌，滑走看下一段');
      return;
    }
    // 控制器先声明出来，再挂回调：回调里要调 _muteWebVideo(wc)，
    // 写成级联 (..setNavigationDelegate) 会在声明完成前引用 wc，编译不过。
    final wc = WebViewController();
    wc.setJavaScriptMode(JavaScriptMode.unrestricted);
    wc.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) async {
        if (_muted) {
          await _muteWebVideo(wc);
          await Future.delayed(const Duration(seconds: 4));
          if (mounted) await _muteWebVideo(wc);
        }
        // 广告拦截 JS 注入（第 26 条）：官方播放器页里也有广告。
        final svc = AdblockService.instance;
        if (svc.isReady) {
          try {
            await wc.runJavaScript(svc.injectionJs);
          } catch (_) {}
        }
      },
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
    ));
    wc.loadRequest(Uri.parse(embed));
    setState(() {
      _webController = wc;
      _error = reason;
    });
  }

  /// 把 WebView 里所有 video/audio 静音（短视频默认静音的规矩，官方播放器那段也算）。
  Future<void> _muteWebVideo(WebViewController wc) async {
    try {
      await wc.runJavaScript(
          "document.querySelectorAll('video,audio').forEach(function(e){e.muted=true;e.volume=0;});");
    } catch (_) {}
  }

  /// 重试直链：清掉解析缓存，关掉官方播放器，重新解析播。
  Future<void> _retryDirect() async {
    StreamResolver.clearCacheFor(widget.item.id);
    _webController = null;
    _error = null;
    await _controller?.dispose();
    _controller = null;
    _controllerNotifier.value = null;
    setState(() {});
    await _init();
  }

  Future<void> _fullscreen() async {
    if (_controller == null || _webController != null) return;
    await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: _FullscreenShorts(
          controllerNotifier: _controllerNotifier,
          item: _displayItem,
          speed: _speed,
          onSpeedChanged: (v) async {
            setState(() => _speed = v);
            await _controller?.setPlaybackSpeed(v);
          },
          mutedNotifier: widget.muted,
          variants: _variants,
          variantLabel: _variantLabel,
          onVariantSelected: _switchVariant,
        ),
      ),
    );
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _openAuthor(String author) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AuthorScreen(author: author, store: widget.store),
    ));
  }

  /// 第 42 条：右侧栏作者头像 + 关注（TikTok 那样）；点头像进作者页。
  Widget _authorAvatarButton() {
    final author = _displayItem.author;
    final followed = widget.store.followedAuthors.contains(author);
    return Column(
      children: [
        GestureDetector(
          onTap: () => _openAuthor(author),
          child: CircleAvatar(
            radius: 22,
            backgroundColor: Colors.pinkAccent,
            backgroundImage: _displayItem.authorAvatar.isNotEmpty
                ? NetworkImage(_displayItem.authorAvatar)
                : null,
            child: _displayItem.authorAvatar.isEmpty
                ? Text(author.isNotEmpty ? author[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                : null,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () async {
            await widget.store.toggleFollow(author);
            if (mounted) setState(() {});
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
                color: followed ? Colors.white24 : Colors.pinkAccent,
                borderRadius: BorderRadius.circular(999)),
            child: Text(followed ? '已关注' : '+ 关注',
                style: const TextStyle(color: Colors.white, fontSize: 11)),
          ),
        ),
      ],
    );
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
          if (c != null && !c.value.isPlaying && _webController == null)
            const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 80)),
          // 竖屏控制条（2026-11-09 用户反馈：竖屏也要进度条、倍速、分辨率，
          // 之前只有全屏才有）：进度条可拖、时间、倍速、分辨率菜单。
          // 只在直链原生播时显示；官方播放器（WebView）时不显示（控不了站内播放器）。
          // AnimatedBuilder 跟着播放器状态重建，时间和播放/暂停图标才实时更新。
          if (c != null && c.value.isInitialized && _webController == null)
            Positioned(
              left: 12, right: 12, bottom: 8,
              child: AnimatedBuilder(
                animation: c,
                builder: (_, _) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black87]),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      VideoProgressIndicator(c, allowScrubbing: true,
                          colors: const VideoProgressColors(
                              playedColor: Colors.pinkAccent,
                              bufferedColor: Colors.white30,
                              backgroundColor: Colors.white24)),
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                            onPressed: () {
                              if (c.value.isPlaying) {
                                c.pause();
                              } else {
                                c.play();
                              }
                            },
                          ),
                          Text('${_fmt(c.value.position)} / ${_fmt(c.value.duration)}',
                              style: const TextStyle(color: Colors.white, fontSize: 12)),
                          const Spacer(),
                          PopupMenuButton<double>(
                            tooltip: '倍速',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Text('${_speed}x', style: const TextStyle(color: Colors.white, fontSize: 13)),
                            ),
                            onSelected: (v) async {
                              setState(() => _speed = v);
                              await _controller?.setPlaybackSpeed(v);
                            },
                            itemBuilder: (_) => [0.5, 1.0, 1.25, 1.5, 2.0]
                                .map((s) => PopupMenuItem<double>(
                                    value: s, child: Text('${s}x${s == _speed ? ' ✓' : ''}')))
                                .toList(),
                          ),
                          if (_variants.length > 1)
                            PopupMenuButton<StreamVariant>(
                              tooltip: '分辨率',
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(_variantLabel ?? '画质',
                                    style: const TextStyle(color: Colors.white, fontSize: 13)),
                              ),
                              onSelected: (v) async {
                                setState(() => _variantLabel = v.label);
                                await _switchVariant(v);
                              },
                              itemBuilder: (_) => _variants
                                  .map((v) => PopupMenuItem<StreamVariant>(
                                      value: v,
                                      child: Text('${v.label}${v.label == _variantLabel ? ' ✓' : ''}')))
                                  .toList(),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12, right: 70, bottom: 76,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_displayItem.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                // 第 42 条：作者名可点（进作者页）；没作者时显示来源名。
                GestureDetector(
                  onTap: _displayItem.author.isEmpty ? null : () => _openAuthor(_displayItem.author),
                  child: Text(
                      '${_displayItem.author.isEmpty ? _displayItem.source : '👤 ${_displayItem.author}'}${_displayItem.durationText.isEmpty ? '' : ' · ${_displayItem.durationText}'}',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          decoration: _displayItem.author.isEmpty ? null : TextDecoration.underline)),
                ),
                Text('第 ${widget.index + 1} / ${widget.total} 段', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          Positioned(
            right: 12, bottom: 76,
            child: Column(
              children: [
                // 第 42 条：作者头像 + 关注，放在点赞上面。
                if (_displayItem.author.isNotEmpty) ...[
                  _authorAvatarButton(),
                  const SizedBox(height: 8),
                ],
                IconButton(
                  icon: Icon(_liked ? Icons.favorite : Icons.favorite_border,
                      color: _liked ? Colors.red : Colors.white, size: 30),
                  onPressed: () async {
                    await widget.store.toggleLike(widget.item);
                    setState(() => _liked = !_liked);
                  },
                ),
                const SizedBox(height: 8),
                // 喇叭：默认静音（打开 App 不许自动出声），点一下才出声，选择持久保存。
                IconButton(
                  icon: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                      color: Colors.white, size: 30),
                  tooltip: _muted ? '点一下出声' : '静音',
                  onPressed: _toggleMute,
                ),
                const SizedBox(height: 8),
                IconButton(
                  icon: const Icon(Icons.fullscreen, color: Colors.white, size: 30),
                  onPressed: _fullscreen,
                ),
                const SizedBox(height: 8),
                // 下载入口（第 27 条）：短视频点一下就开始下。
                // 第 30 条：22px，跟旁边点赞/静音/全屏图标收齐，别挡画面。
                DownloadButton(item: widget.item, size: 22),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 横屏放大播：同一份播放器（切画质会重建，对话框靠 notifier 跟着换），不重新加载。
/// - 点视频区 = 暂停/继续（之前点哪里都直接退出，是点一下就回竖屏的根因）；
/// - 只有右上角 ✕ 和系统返回才退出；
/// - 底部控制条：播放/暂停、进度条（可拖）、时间、倍速、分辨率、喇叭。
/// - 是 StatefulWidget：播的状态变化就重建，之前 StatelessWidget 永远不重建，
///   画面看起来像“全是停止的”。
class _FullscreenShorts extends StatefulWidget {
  final ValueNotifier<VideoPlayerController?> controllerNotifier;
  final VideoItem item;
  final double speed;
  final ValueChanged<double> onSpeedChanged;
  final ValueNotifier<bool> mutedNotifier;
  final List<StreamVariant> variants;
  final String? variantLabel;
  final Future<void> Function(StreamVariant) onVariantSelected;
  const _FullscreenShorts({
    required this.controllerNotifier,
    required this.item,
    required this.speed,
    required this.onSpeedChanged,
    required this.mutedNotifier,
    required this.variants,
    required this.variantLabel,
    required this.onVariantSelected,
  });

  @override
  State<_FullscreenShorts> createState() => _FullscreenShortsState();
}

class _FullscreenShortsState extends State<_FullscreenShorts> {
  VideoPlayerController? _c;
  double _speed = 1.0;
  String? _label;
  // 第 44 条：全屏控制条 3 秒无操作自动隐藏，点画面再出现。
  late final FullscreenControls _fsControls;

  @override
  void initState() {
    super.initState();
    _fsControls = FullscreenControls(onChanged: () {
      if (mounted) setState(() {});
    });
    _speed = widget.speed;
    _label = widget.variantLabel;
    _c = widget.controllerNotifier.value;
    _c?.addListener(_onTick);
    widget.controllerNotifier.addListener(_onControllerChanged);
    widget.mutedNotifier.addListener(_onTick);
    // 第 44 条：进全屏控制条先出现，播的时候开始 3 秒计时。
    _fsControls.poke(isPlaying: _c?.value.isPlaying ?? false);
  }

  void _onControllerChanged() {
    _c?.removeListener(_onTick);
    _c = widget.controllerNotifier.value;
    _c?.addListener(_onTick);
    if (mounted) setState(() {});
    // 第 44 条：短视频切到下一段，全屏控制条重新计时。
    _fsControls.poke(isPlaying: _c?.value.isPlaying ?? false);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _fsControls.dispose();
    _c?.removeListener(_onTick);
    widget.controllerNotifier.removeListener(_onControllerChanged);
    widget.mutedNotifier.removeListener(_onTick);
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final muted = widget.mutedNotifier.value;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 点视频区 = 暂停/继续 + 唤出控制条（播的时候重新计时 3 秒），
          // 退出只走右上角 ✕ 和系统返回；点画面绝不触发放大。
          GestureDetector(
            onTap: () {
              if (c == null) return;
              final wasPlaying = c.value.isPlaying;
              if (wasPlaying) {
                c.pause();
              } else {
                c.play();
              }
              setState(() => _fsControls.poke(isPlaying: !wasPlaying));
            },
            child: Container(
              color: Colors.black,
              child: c != null && c.value.isInitialized
                  ? Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)))
                  : const Center(child: CircularProgressIndicator(color: Colors.pinkAccent)),
            ),
          ),
          if (c != null && !c.value.isPlaying)
            const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 80)),
          Positioned(
            left: 16, right: 16, top: 12,
            child: AnimatedOpacity(
              // 第 44 条：顶栏和底栏一起藏，3 秒无操作自动隐藏，点画面再出现。
              opacity: _fsControls.visible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_fsControls.visible,
                child: Row(
              children: [
                Expanded(
                  child: Text(widget.item.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 14)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: '退出全屏',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
                ),
              ),
            ),
          ),
          if (c != null)
            Positioned(
              left: 16, right: 16, bottom: 12,
              child: AnimatedOpacity(
                opacity: _fsControls.visible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_fsControls.visible,
                  child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87]),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VideoProgressIndicator(c, allowScrubbing: true,
                        colors: const VideoProgressColors(
                            playedColor: Colors.pinkAccent,
                            bufferedColor: Colors.white30,
                            backgroundColor: Colors.white24)),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                          onPressed: () {
                            final wasPlaying = c.value.isPlaying;
                            if (wasPlaying) {
                              c.pause();
                            } else {
                              c.play();
                            }
                            setState(() => _fsControls.poke(isPlaying: !wasPlaying));
                          },
                        ),
                        Text('${_fmt(c.value.position)} / ${_fmt(c.value.duration)}',
                            style: const TextStyle(color: Colors.white, fontSize: 12)),
                        const Spacer(),
                        IconButton(
                          icon: Icon(muted ? Icons.volume_off : Icons.volume_up, color: Colors.white),
                          tooltip: muted ? '点一下出声' : '静音',
                          onPressed: () {
                            widget.mutedNotifier.value = !muted;
                            setState(() => _fsControls.poke(isPlaying: c.value.isPlaying));
                          },
                        ),
                        // 倍速。
                        PopupMenuButton<double>(
                          tooltip: '倍速',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text('${_speed}x', style: const TextStyle(color: Colors.white, fontSize: 13)),
                          ),
                          onSelected: (v) {
                            setState(() {
                              _speed = v;
                              _fsControls.poke(isPlaying: c.value.isPlaying);
                            });
                            // ValueChanged<double> 返回 void，不能 await；
                            // 父级回调里自己会调 setPlaybackSpeed。
                            widget.onSpeedChanged(v);
                          },
                          itemBuilder: (_) => [0.5, 1.0, 1.25, 1.5, 2.0]
                              .map((s) => PopupMenuItem<double>(
                                  value: s, child: Text('${s}x${s == _speed ? ' ✓' : ''}')))
                              .toList(),
                        ),
                        // 分辨率：多档才显示，当前档标 ✓。
                        if (widget.variants.length > 1)
                          PopupMenuButton<StreamVariant>(
                            tooltip: '分辨率',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Text(_label ?? '画质',
                                  style: const TextStyle(color: Colors.white, fontSize: 13)),
                            ),
                            onSelected: (v) async {
                              setState(() {
                                _label = v.label;
                                _fsControls.poke(isPlaying: c.value.isPlaying);
                              });
                              await widget.onVariantSelected(v);
                            },
                            itemBuilder: (_) => widget.variants
                                .map((v) => PopupMenuItem<StreamVariant>(
                                    value: v,
                                    child: Text('${v.label}${v.label == _label ? ' ✓' : ''}')))
                                .toList(),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              ),
              ),
            ),
        ],
      ),
    );
  }
}
