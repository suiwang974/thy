import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_item.dart';
import '../services/adblock_service.dart';
import '../services/downloader.dart';
import '../services/fullscreen_controls.dart';
import '../services/sniffer.dart';
import '../services/store.dart';
import '../services/stream_resolver.dart';
import 'author_screen.dart';
import 'download_button.dart';
import 'search_screen.dart' deferred as search_screen;
import 'sniff_sheet.dart';
import 'web_source_browser.dart';

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
  // 本地文件路径（下载管理里点开已下载的视频）：有它就直接播本地文件，
  // 不解析直链、不走官方播放器、不显示画质/下载按钮。
  final String? localFilePath;
  const PlayerScreen({super.key, required this.item, this.playlist, required this.store, this.localFilePath});

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
  // 第 33 条：官方播放器上方那排提示条改成一行瘦条，可关闭；
  // 关掉后留一个小 ⓘ 按钮可 reopen，每段视频重置关闭状态。
  bool _webBarDismissed = false;
  // 第 32 条：官方播放器页主框加载失败时的原因（不拿空白页充数）。
  String? _webError;
  // 第 34 条：官方播放器 WebView 里嗅到的媒体（和内置浏览器同一套嗅探）。
  List<SniffedMedia> _embedSniffed = [];
  String _embedPageTitle = '';
  // 第 54 条：详情页附加信息（标签/点赞率/相关视频），打开后异步拉一次；
  // 拉不到就是空 extras，UI 写“未知”/“暂无”，不编数据。
  DetailExtras? _extras;
  // 第 43+44 条：全屏控制条自动隐藏（播的时候 3 秒无操作自动藏，点画面再出现）。
  late final FullscreenControls _fsControls;

  @override
  void initState() {
    _fsControls = FullscreenControls(onChanged: () {
      if (mounted) setState(() {});
    });
    super.initState();
    _current = widget.item;
    _liked = widget.store.likedIds.contains(_current.id);
    _disliked = widget.store.isDisliked(_current);
    if (widget.localFilePath != null) {
      _playLocal();
    } else {
      _play(_current);
      widget.store.addHistory(_current);
      _prefetchNeighbors();
    }
  }

  /// 播本地已下载的文件（下载管理点开）：直接 VideoPlayerController.file，
  /// 不解析直链、不核时长、不嵌官方播放器。
  Future<void> _playLocal() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = VideoPlayerController.file(File(widget.localFilePath!));
      await c.initialize();
      if (!mounted) return;
      setState(() {
        _controller = c;
        _loading = false;
      });
      final resume = widget.store.watchPosition(_current.id);
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
        _error = '本地文件打不开了，可能已被删掉：${_shortReason(e)}';
      });
    }
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
      _webBarDismissed = false;
      _webError = null;
      _embedSniffed = [];
      _extras = null;
    });
    // 第 54 条：详情页附加信息（标签/相关视频）和直链解析并行拉，不等它播起来。
    unawaited(_loadExtras(item));
    await _controller?.dispose();
    _controller = null;
    _webController = null;
    _prefetchNeighbors();
    final stream = await StreamResolver.resolve(item);
    if (!mounted) return;
    _currentStreamUrl = stream?.url;
    // 第 42 条：解析详情页时可能补上了作者/封面/时长（视频页找发布者），
    // 播之前把补全版换上，作者行才能显示出来。
    final enriched = StreamResolver.enrich(item);
    if (enriched.author.isNotEmpty ||
        enriched.poster != item.poster ||
        enriched.durationSec != item.durationSec) {
      item = enriched;
      setState(() => _current = enriched);
    }
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
      // mp4 在解析时算不出时长，这里用播放器初始化后的真实时长再核一次。
      // 第 37 条：先纠正离谱的列表时长（比如把图片尺寸 320:180 当成 320:18，
      // 列表写 320:18、真实只有 15 分钟），再判预览——15 分钟的正片不能因为
      // 列表写错就被当成“带水印的预览”切走。
      final actualSec = c.value.duration.inSeconds;
      var listedSec = item.durationSec;
      if (actualSec > 0 && listedSec > 0 && (listedSec > actualSec * 4 || actualSec > listedSec * 4)) {
        listedSec = actualSec;
        item = item.copyWith(durationSec: actualSec);
        _current = item;
      }
      if (StreamResolver.isPreviewDuration(listedSec: listedSec, actualSec: actualSec)) {
        await c.dispose();
        if (!mounted) return;
        _embedOfficial(_previewText(item, actualSec));
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
      // 第 44 条：新一段播起来，全屏控制条重新计时（播的时候 3 秒后藏）。
      _fsControls.poke(isPlaying: true);
      // 看门狗 + 画质档位：播起来之后 5 秒再看一眼。
      // 注意：灰框的真根因是视频区 widget 在真机上抛错（release 下只剩灰框，
      // 见 main.dart 的 ErrorWidget 兜底注释），不是没尺寸——尺寸在
      // initialize 时就从轨道元数据里拿到了，有灰框时尺寸也是正常的，
      // 所以光查尺寸查不出灰框。看门狗只抓真正能从播放器状态看出来的卡死：
      // 报错、没尺寸、或者 play() 叫了 5 秒还停在 0 秒、没在播、也没在缓冲。
      // 灰框的自救靠两处：视频区结构改回 v3 验证过的写法 + 标题下面的常驻
      // “没画面？用官方播放器”按钮（视频区控制条没了也能点）。
      _userPaused = false;
      _startWatchdog(c);
      unawaited(_loadVariants());
    } catch (e) {
      if (!mounted) return;
      _embedOfficial('直链播不起来：${_shortReason(e)}');
    }
  }

  /// 看门狗：播起来 5 秒后检查一次，只抓播放器状态能看出来的真卡死——
  /// 报错、视频轨道没尺寸、或者 play() 叫了 5 秒还停在 0 秒、没在播、
  /// 也没在缓冲（不是用户自己点的暂停）。满足任一就自动切官方播放器。
  /// 灰框（widget 抛错）查不出来，靠结构回退 + 常驻逃生按钮自救。
  bool _userPaused = false; // 用户自己点的暂停：看门狗不许把“用户暂停”当卡死。

  void _startWatchdog(VideoPlayerController c) {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 5), () {
      if (!mounted || _controller != c || _webController != null) return;
      final v = c.value;
      if (v.hasError || v.size.width <= 0 || v.size.height <= 0) {
        _embedOfficial('原生播放器出不来画面（只有声音），已切官方播放器');
        return;
      }
      if (!_userPaused &&
          !v.isPlaying &&
          !v.isBuffering &&
          v.position.inSeconds == 0 &&
          v.duration.inSeconds > 0) {
        _embedOfficial('直链播了 5 秒还没动静，已切官方播放器');
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
      // 第 44 条：切档也是操作，控制条重新计时（播的时候 3 秒后才藏）。
      _fsControls.poke(isPlaying: wasPlaying);
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
  /// 第 32 条：embedUrl 只嵌视频播放器本身（embed 播放页），不嵌整个网站——
  /// 见 VideoItem.embedUrl（pornhub/xhamster/xvideos 各走官方 embed 页）。
  void _embedOfficial(String reason) {
    final embed = _current.embedUrl;
    if (embed.isEmpty) {
      setState(() {
        _loading = false;
        _error = '$reason；这段也没有官方播放页可嵌';
      });
      return;
    }
    _webBarDismissed = false;
    _webError = null;
    _embedSniffed = [];
    // 控制器先声明出来，再挂回调：回调里要调 _injectAdblock(wc)，
    // 写成级联 (..setNavigationDelegate) 会在声明完成前引用 wc，编译不过。
    final wc = WebViewController();
    wc.setJavaScriptMode(JavaScriptMode.unrestricted);
    wc.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) async {
        await _injectAdblock(wc);
        await _sniffEmbed(wc);
      },
      onWebResourceError: (error) {
        // 第 32 条：主框加载失败别拿空白页充数——写明原因，给重试/去浏览器看。
        if (error.isForMainFrame == true && mounted) {
          setState(() => _webError = '官方播放器打不开：${_shortReason(error.description)}');
        }
      },
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
    ));
    wc.loadRequest(Uri.parse(embed));
    _webController = wc;
    setState(() {
      _loading = false;
      _error = reason;
    });
  }

  /// 官方播放器 WebView 里嗅视频（第 34 条）：和内置浏览器同一套嗅探，
  /// 嗅到就出瘦条（播/下载），嗅不到不打扰。
  /// 第 42 条：页面里抠到的作者也顺带补上（eporner/lianzu11/hanime 这类
  /// HTTP 拿不到作者的源，在 WebView 里打开视频页时靠它补）。
  Future<void> _sniffEmbed(WebViewController wc) async {
    try {
      final r = await Sniffer.sniff(wc, pageUrl: _current.pageUrl ?? '');
      if (!mounted || _webController == null) return;
      setState(() {
        _embedSniffed = r.items;
        _embedPageTitle = r.pageTitle;
        if (r.author.isNotEmpty && _current.author.isEmpty) {
          _current = _current.copyWith(author: r.author);
        }
      });
      // 视频可能是懒加载的：4 秒后再嗅一次。
      await Future.delayed(const Duration(seconds: 4));
      if (!mounted || _webController == null) return;
      final r2 = await Sniffer.sniff(wc, pageUrl: _current.pageUrl ?? '');
      if (!mounted || _webController == null) return;
      setState(() {
        _embedSniffed = r2.items;
        _embedPageTitle = r2.pageTitle;
        if (r2.author.isNotEmpty && _current.author.isEmpty) {
          _current = _current.copyWith(author: r2.author);
        }
      });
    } catch (_) {}
  }

  /// 第 40 条 + 第 53 条：手动嗅探（官方播放器里没出嗅探条时点一下）。
  /// 嗅不到不再写“列表页没有可播的视频”——这就是视频页，那句话本身是错的；
  /// 改成诊断文案（查了什么、为什么没嗅到）。
  Future<void> _sniffEmbedOnce() async {
    final wc = _webController;
    if (wc == null) return;
    try {
      final r = await Sniffer.sniff(wc, pageUrl: _current.pageUrl ?? '');
      if (!mounted || _webController == null) return;
      setState(() {
        _embedSniffed = r.items;
        _embedPageTitle = r.pageTitle;
        if (r.author.isNotEmpty && _current.author.isEmpty) {
          _current = _current.copyWith(author: r.author);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(r.items.isEmpty ? r.diagnosis.text : '嗅到 ${r.items.length} 个视频')));
    } catch (_) {}
  }

  /// 嗅到的清单里最适合播/下的那条：mp4 优先，其次 m3u8；blob 和下不了的不要。
  SniffedMedia? _bestSniffed(List<SniffedMedia> items) {
    for (final m in items) {
      if (m.kind == 'mp4' && m.downloadable) return m;
    }
    for (final m in items) {
      if (m.kind == 'm3u8' && m.downloadable) return m;
    }
    for (final m in items) {
      if (m.downloadable) return m;
    }
    return null;
  }

  /// 嗅到的直链直接播（不重新解析）：关掉官方播放器，用原生播放器播这条链。
  Future<void> _playSniffed(String url) async {
    await _controller?.dispose();
    _controller = null;
    _webController = null;
    _embedSniffed = [];
    _webError = null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: {'Referer': _current.pageUrl ?? ''},
      );
      await c.initialize();
      if (!mounted) return;
      setState(() {
        _controller = c;
        _currentStreamUrl = url;
        _loading = false;
      });
      _userPaused = false;
      await c.setPlaybackSpeed(_speed);
      await c.play();
      _startWatchdog(c);
    } catch (e) {
      if (!mounted) return;
      _embedOfficial('嗅到的地址播不起来：${_shortReason(e)}');
    }
  }

  /// 广告拦截 JS 注入（第 26 条）：官方播放器页里也有广告，加载完注一次
  /// （fetch/XHR 覆盖 + 藏广告元素；导航层已有白名单在拦站外跳转）。
  Future<void> _injectAdblock(WebViewController wc) async {
    final svc = AdblockService.instance;
    if (!svc.isReady) return;
    try {
      await wc.runJavaScript(svc.injectionJs);
    } catch (_) {}
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

  /// 第 42 条：作者行——头像（有真头像就显示，没有画首字母圆圈）+ 名字 + 关注。
  /// 点头像/名字进作者页，列他发布的所有视频。
  Widget _authorRow() {
    final author = _current.author;
    final followed = widget.store.followedAuthors.contains(author);
    return Row(
      children: [
        GestureDetector(
          onTap: () => _openAuthor(author),
          child: CircleAvatar(
            radius: 18,
            backgroundColor: Colors.pinkAccent,
            backgroundImage: _current.authorAvatar.isNotEmpty
                ? NetworkImage(_current.authorAvatar)
                : null,
            child: _current.authorAvatar.isEmpty
                ? Text(author.isNotEmpty ? author[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: () => _openAuthor(author),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                // 第 54 条：作者视频数（Hanime 卡片写“90 个视频”）。
                // 源站视频页没给这个数时写“视频数未知”，不要编。
                // 2026-11-09 实测：xvideos/pornhub/eporner/r34 视频页都没有，
                // v10 里全是未知，等以后从作者页/站内接口补。
                if (_extras != null)
                  Text(
                    _current.authorVideoCount > 0
                        ? '${_current.authorVideoCount} 个视频'
                        : '视频数未知',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
              ],
            ),
          ),
        ),
        TextButton(
          onPressed: () async {
            await widget.store.toggleFollow(author);
            if (mounted) setState(() {});
          },
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          child: Text(followed ? '已关注 ✓' : '+ 关注',
              style: const TextStyle(color: Colors.pinkAccent, fontSize: 14)),
        ),
      ],
    );
  }

  void _openAuthor(String author) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AuthorScreen(author: author, store: widget.store),
    ));
  }

  /// 第 54 条：详情页附加信息（标签/相关视频）。切段了就丢弃旧结果，
  /// 别把上一段的相关视频贴到这一段下面。
  Future<void> _loadExtras(VideoItem item) async {
    final ex = await StreamResolver.detailExtras(item);
    if (!mounted || _current.id != item.id) return;
    setState(() => _extras = ex);
  }

  /// 第 54 条：点标签进搜索（搜这个标签；用 pushReplacement 换掉播放页，
  /// 返回时回到打开播放页之前的地方，不在返回栈里叠播放页）。
  /// search_screen 和 player_screen 互相引用，用 deferred import 避开循环引用。
  Future<void> _openTag(String tag) async {
    await search_screen.loadLibrary();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => search_screen.SearchScreen(
          store: widget.store, initialQuery: tag),
    ));
  }

  /// 观看数格式化：187200 -> 18.7万；969 -> 969；0 -> ''（未知不显示数字）。
  static String _formatViews(int v) {
    if (v <= 0) return '';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万次';
    return '$v次';
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
    if (!mounted) return;
    setState(() {
      _isFullscreen = !_isFullscreen;
      // 第 43+44 条：进全屏控制条先出现、播的时候开始 3 秒计时；出全屏恢复常显。
      if (_isFullscreen) {
        _fsControls.poke(isPlaying: _controller?.value.isPlaying ?? false);
      } else {
        _fsControls.reset();
      }
    });
  }

  @override
  void dispose() {
    _fsControls.dispose();
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
    // 第 43 条：全屏时系统返回先退全屏，不直接退出播放页。
    return PopScope(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isFullscreen) _toggleFullscreen();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: _isFullscreen
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              iconTheme: const IconThemeData(color: Colors.white),
              title: Text(_current.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
              actions: [
                // 下载入口（第 27 条）：详情页点一下就开始下；播本地文件时没有。
                if (widget.localFilePath == null) DownloadButton(item: _current),
                // 第 52 条：在内置浏览器打开源站页面（点一下直接进这条视频的源站页，
                // 不用先切官方播放器再找入口）；播本地文件时没有源站页。
                if (widget.localFilePath == null &&
                    (_current.pageUrl ?? '').isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.open_in_browser, color: Colors.white),
                    tooltip: '在浏览器打开源站页面',
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => WebSourceBrowser(
                          title: _current.title,
                          url: _current.pageUrl ?? '',
                          sourceId: _current.source,
                          store: widget.store,
                        ),
                      ));
                    },
                  ),
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
      // 第 43 条：全屏时视频区直接占满屏幕——之前套的 16:9 外框在横屏下
      // 比屏幕高，底部控制条被裁到屏外（截图里只有大播放键、没有控制条
      // 就是这么来的），视频本身也被裁成放大裁切的样子。
      body: _isFullscreen
          ? _buildVideoArea(c)
          : Column(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    color: Colors.black,
                    // 注意：这里不要加 Clip.hardEdge——v3 没加时在这台手机上播得好好的，
                    // v4 加上它之后详情页开始出灰框（灰框真根因见 main.dart 注释：
                    // 视频区 widget 抛错、release 下只剩灰框）。报错区已经收紧到能
                    // 塞进 16:9 框里，不用裁剪兜底。
                    child: _buildVideoArea(c),
                  ),
                ),
                Expanded(child: _buildInfo()),
              ],
            ),
    ),
    );
  }

  Widget _buildVideoArea(VideoPlayerController? c) {
    // 内嵌官方播放器优先渲染（修死代码 bug：之前 _error 非空就永远走报错分支，
    // WebView 永远渲染不出来，点“在源站看”什么都没发生）。
    if (_webController != null) {
      final content = Column(
        children: [
          Expanded(child: WebViewWidget(controller: _webController!)),
          // 第 33 条：提示条改成一行瘦条（原因一行省略 + [重试直链] 小按钮 + ✕），
          // 可关闭；关掉后留一个小 ⓘ 按钮可 reopen，不挡视频。
          if (!_webBarDismissed)
            Container(
              width: double.infinity,
              color: const Color(0xFF2A2A35),
              padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error ?? '正在用源站官方播放器播',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: _retryDirect,
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('重试直链', style: TextStyle(fontSize: 12)),
                  ),
                  // 第 43 条：官方播放器也要能进/出全屏（之前这条路根本没有全屏键）。
                  IconButton(
                    icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white70, size: 18),
                    tooltip: _isFullscreen ? '退出全屏' : '全屏',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _toggleFullscreen,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                    tooltip: '收起提示',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => setState(() => _webBarDismissed = true),
                  ),
                ],
              ),
            )
          else
            Container(
              width: double.infinity,
              color: const Color(0xFF2A2A35),
              padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2, right: 4),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => setState(() => _webBarDismissed = false),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    icon: const Icon(Icons.info_outline, size: 14, color: Colors.white54),
                    label: const Text('官方播放器', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  const Spacer(),
                  // 第 40 条：手动嗅探入口常驻（没出嗅探条时点一下，嗅不到就明说）。
                  TextButton(
                    onPressed: _sniffEmbedOnce,
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('嗅探', style: TextStyle(fontSize: 12)),
                  ),
                  // 第 43 条：官方播放器也要能进/出全屏。
                  IconButton(
                    icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white70, size: 18),
                    tooltip: _isFullscreen ? '退出全屏' : '全屏',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _toggleFullscreen,
                  ),
                  TextButton(
                    onPressed: _closeWeb,
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('关掉官方播放器', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          // 第 32 条：官方播放器主框加载失败——写明原因，给重试/去浏览器看，
          // 不拿空白页充数。
          if (_webError != null)
            Container(
              width: double.infinity,
              color: const Color(0xFF3A1F1F),
              padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_webError!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: _retryDirect,
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('重试直链', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => WebSourceBrowser(
                          title: _current.title,
                          url: _current.pageUrl ?? '',
                          sourceId: _current.source,
                          store: widget.store,
                        ),
                      ));
                    },
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('去浏览器看', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          // 第 34 条：官方播放器里嗅到的视频——瘦条（播/下载两个按钮）。
          if (_embedSniffed.isNotEmpty)
            Container(
              width: double.infinity,
              color: const Color(0xFF1F2A1F),
              padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('嗅到 ${_embedSniffed.length} 个视频',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () => SniffSheet.show(
                      context,
                      items: _embedSniffed,
                      pageTitle: _embedPageTitle.isEmpty ? _current.title : _embedPageTitle,
                      sourceId: _current.source,
                      pageUrl: _current.pageUrl ?? '',
                      store: widget.store,
                    ),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('查看', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () {
                      final best = _bestSniffed(_embedSniffed);
                      if (best != null) _playSniffed(best.url);
                    },
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('播', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () async {
                      final best = _bestSniffed(_embedSniffed);
                      if (best == null) return;
                      final messenger = ScaffoldMessenger.of(context);
                      await DownloadManager.instance.startDownloadFromUrl(
                        id: 'sniff-${best.url.hashCode.abs()}',
                        title: _current.title,
                        source: _current.source,
                        url: best.url,
                        headers: {'Referer': _current.pageUrl ?? ''},
                        durationSec: best.durationSec ?? 0,
                      );
                      if (!mounted) return;
                      messenger.showSnackBar(
                        const SnackBar(content: Text('开始下载，去「我的 · 下载管理」看进度')),
                      );
                    },
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('下载', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
        ],
      );
      // 第 43 条：官方播放器全屏——源站播放器自己可能没有控制条，
      // 全屏时叠加我们自己的退出键（右上角常显），底下瘦条（重试/嗅探/去浏览器看）就是控制入口。
      if (!_isFullscreen) return content;
      return Stack(
        children: [
          content,
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: IconButton(
                icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
                tooltip: '退出全屏',
                onPressed: _toggleFullscreen,
              ),
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
    // 尺寸异常时不建 Stack：宽/高为 0 或非法时，VideoPlayer/AspectRatio
    // 在真机布局里可能炸掉整块视频区（灰框的根因就是视频区 widget 抛错），
    // 直接显示“还没准备好”，等下一帧状态正常了再建。
    if (c.value.size.width <= 0 || c.value.size.height <= 0) {
      return const Center(child: Text('播放器还没准备好', style: TextStyle(color: Colors.white54)));
    }
    final ar = c.value.aspectRatio;
    final safeAr = ar.isFinite && ar > 0 ? ar : 16 / 9;
    return Stack(
      alignment: Alignment.center,
      children: [
        // 画面：v3 在这台手机上能播的结构——AspectRatio 直接当第一个子项，
        // 不包 Center、不设 StackFit.expand（v5 那套没修好灰框，反而是
        // v3 这套在真机上验证过）。竖屏视频按比例居中，左右留黑边；
        // 控制条是 Stack 的直接子项，钉在 16:9 框底部。
        AspectRatio(aspectRatio: safeAr, child: VideoPlayer(c)),
        GestureDetector(
          // 第 43+44 条：点视频区只做暂停/继续 + 唤出控制条（播的时候重新计时 3 秒），
          // 绝不触发放大/全屏切换。
          onTap: () {
            final wasPlaying = c.value.isPlaying;
            setState(() {
              if (wasPlaying) {
                _userPaused = true;
                c.pause();
              } else {
                _userPaused = false;
                c.play();
              }
              _fsControls.poke(isPlaying: !wasPlaying);
            });
          },
          child: Container(color: Colors.transparent),
        ),
        if (!c.value.isPlaying)
          const Icon(Icons.play_circle_fill, color: Colors.white70, size: 72),
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: AnimatedOpacity(
            // 第 44 条：全屏播的时候 3 秒无操作自动藏控制条；竖屏常显。
            opacity: (!_isFullscreen || _fsControls.visible) ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: _isFullscreen && !_fsControls.visible,
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
                      onPressed: () {
                        final wasPlaying = c.value.isPlaying;
                        setState(() {
                          if (wasPlaying) {
                            _userPaused = true;
                            c.pause();
                          } else {
                            _userPaused = false;
                            c.play();
                          }
                          _fsControls.poke(isPlaying: !wasPlaying);
                        });
                      },
                    ),
                    Text(
                      '${_fmt(c.value.position)} / ${_fmt(c.value.duration)}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const Spacer(),
                    // 画质：多档才显示，当前档标 ✓。切档不断流重进（记位置、倍速）。
                    if (_variants.length > 1) _qualityButton(),
                    // 画面出不来时一键切官方播放器（灰框自救，不用退出重进）。
                    // 播本地文件时没有官方播放器可切。
                    if (widget.localFilePath == null)
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
                      tooltip: _isFullscreen ? '退出全屏' : '全屏',
                      onPressed: _toggleFullscreen,
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
        setState(() {
          _speed = v;
          // 第 44 条：调倍速也是操作，控制条重新计时。
          _fsControls.poke(isPlaying: _controller?.value.isPlaying ?? false);
        });
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
          // 第 42 条：作者行（TikTok 那样：头像 + 名字 + 关注，点头像/名字进作者页）。
          if (_current.author.isNotEmpty) ...[
            _authorRow(),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            children: [
              _chip(_current.source),
              if (_current.batch.isNotEmpty) _chip(_current.batch),
              if (_current.resolution.isNotEmpty) _chip(_current.resolution),
              if (_current.durationText.isNotEmpty) _chip('时长 ${_current.durationText}'),
              // 第 54 条：主视频点赞率（源站给了才显示，没给不编一个）。
              if (_current.likeRate > 0) _chip('点赞 ${_current.likeRate}%'),
            ],
          ),
          // 第 54 条：标签（可点进搜索）。extras 没回来之前先用搜索时带的
          // keywords（eporner 的 keywords 就是标签）；都拿不到、且 extras
          // 已回来确认没有，才写“标签未知”。
          if (_detailTags().isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _detailTags()
                  .map((t) => ActionChip(
                        label: Text(t, style: const TextStyle(fontSize: 12)),
                        backgroundColor: const Color(0xFF2A2A35),
                        labelStyle: const TextStyle(color: Colors.white70),
                        onPressed: () => _openTag(t),
                      ))
                  .toList(),
            ),
          ] else if (_extras != null) ...[
            const SizedBox(height: 12),
            const Text('标签未知', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
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
          // 常驻逃生口：原生播出灰框/没画面时，视频区里的控制条也可能一起没了，
          // 用户在视频区点不到任何按钮——这里（标题下面）永远有一排“官方播放器 /
          // 重试直链”，一点就切，不用退出重进。点开是在 App 里嵌官方播放器，
          // 不踢出到外部浏览器。已经在官方播放器里时不重复显示（视频区里已有按钮）。
          if (_current.embedUrl.isNotEmpty && _webController == null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _embedOfficial('已切换到源站官方播放器'),
                    child: const Text('没画面？用官方播放器'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _retryDirect,
                    child: const Text('重试直链'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '第 ${idx >= 0 ? idx + 1 : 1} / ${list?.length ?? 1} 段',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          // 第 54 条：相关视频（源站页面有的，详情页也要有；点进详情）。
          // extras 没回来之前不显示（避免先闪“暂无”再出列表）。
          if (_extras != null) ...[
            const SizedBox(height: 20),
            const Text('相关视频',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            if (_extras!.related.isEmpty)
              const Text('暂无相关视频（源站页面没给）',
                  style: TextStyle(color: Colors.white54, fontSize: 12))
            else
              ..._extras!.related.map(_relatedRow),
          ],
        ],
      ),
    );
  }

  /// 第 54 条：详情页要显示的标签——视频页抠的优先，没有就用搜索时带的
  /// keywords（eporner 的 keywords 就是标签）；keywords 里混进的时长
  /// 字符串（r34 搜索把时长写进 keywords）不要。
  List<String> _detailTags() {
    final ex = _extras;
    if (ex != null && ex.tags.isNotEmpty) return ex.tags;
    return _current.keywords.where((k) {
      final t = k.trim();
      return t.isNotEmpty && !RegExp(r'^\d+:\d+$').hasMatch(t);
    }).toList();
  }

  /// 第 54 条：相关视频一行（封面 + 标题 + 时长/观看数/点赞率 + 作者，
  /// 点进详情）。拿不到的字段不显示数字、不编。
  Widget _relatedRow(VideoItem v) {
    final meta = <String>[];
    if (v.durationText.isNotEmpty) meta.add(v.durationText);
    final views = _formatViews(v.views);
    if (views.isNotEmpty) meta.add(views);
    if (v.likeRate > 0) meta.add('点赞 ${v.likeRate}%');
    return InkWell(
      onTap: () => _play(v),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              height: 63,
              child: v.poster.isEmpty
                  ? Container(
                      color: const Color(0xFF2A2A35),
                      child: const Icon(Icons.play_arrow, color: Colors.white54),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(v.poster,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                              color: const Color(0xFF2A2A35),
                              child: const Icon(Icons.play_arrow, color: Colors.white54))),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(meta.isEmpty ? '时长/观看数未知' : meta.join(' · '),
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  if (v.author.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(v.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ],
        ),
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
