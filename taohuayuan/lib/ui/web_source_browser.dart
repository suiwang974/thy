import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/sources.dart';
import '../models/video_item.dart';
import '../services/adblock_service.dart';
import '../services/downloader.dart';
import '../services/store.dart';
import '../services/stream_resolver.dart';
import 'player_screen.dart';

/// 内置浏览器（要过验证的源站都在这里打开：Hanime1 / HanimeOne、Niacg、Lianzu11，
/// 以及搜索页里某个源失败时点状态条进来的其他源）：
/// App 的纯 HTTP 请求会被 Cloudflare / WAF 拦，真浏览器带 JS，验证能过；
/// 在视频页里嗅到 <video> 直链就弹出“用播放器播”，切原生播放器。
/// 没验过的地方（2026-11-09，VM 下两站都 403，没见过真页）：
/// 嗅到的直链格式、视频页结构都没跑通过；嗅不到直链时这里就只当浏览器用，
/// 用户照样能在站里看（页面有广告的站会写清楚，没广告的 niacg/lianzu11 也写清楚）。
/// 返回规矩（2026-11-09 用户定死，第 18 条）：跟真浏览器一样——
/// 上面那个退出按钮（AppBar 左边那个）随时直接退出；系统返回键走 WebView
/// 历史回退（有上一页就回上一页，到第一页再按才退出）；不另加花样。
/// 镜像自动切（2026-11-09 用户反馈，第 20 条）：Hanime1 / HanimeOne 是同一站
/// 的两个镜像域名，内容一样；hanime1.me 常被验证拦住、hanimeone.me 能进。
/// 打开 hanime1.me 就先切到 hanimeone.me；加载失败或撞上 Cloudflare 验证页
/// 时自动切另一个镜像，两个都试过了才停手（不死循环）。
class WebSourceBrowser extends StatefulWidget {
  final String title;
  final String url;
  final String sourceId;
  final Store store;
  const WebSourceBrowser({
    super.key,
    required this.title,
    required this.url,
    required this.sourceId,
    required this.store,
  });

  @override
  State<WebSourceBrowser> createState() => _WebSourceBrowserState();
}

class _WebSourceBrowserState extends State<WebSourceBrowser> {
  late final WebViewController _controller;
  String _currentUrl = '';
  String _pageTitle = '';
  String _videoUrl = '';
  bool _loading = true;
  String _mirrorNote = '';
  // 退出按钮按下的标记：PopScope 平时拦住所有返回（让系统返回键走 WebView 历史），
  // 只有退出按钮按下时才放行、直接退出。
  bool _forceExit = false;
  // 镜像已试过的域名：每个镜像只试一次，两个都试过了就不再切（不死循环）。
  final _triedHosts = <String>{};
  // 广告拦截计数（第 26 条）：导航层拦掉的广告跳转数，底部显示。
  int _blockedCount = 0;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
          // 尽早注入拦截 JS（fetch/XHR 覆盖越早越好；页面还没准备好时会抛错，
          // 忽略，等 onPageFinished 再注一次）。
          unawaited(_injectAdblock().catchError((_) {}));
        },
        onPageFinished: (_) async {
          if (!mounted) return;
          setState(() => _loading = false);
          await _injectAdblock();
          await _sniffVideo();
          // 视频可能是懒加载的：4 秒后再嗅一次。
          await Future.delayed(const Duration(seconds: 4));
          if (mounted) await _sniffVideo();
        },
        // 广告拦截第一层（第 26 条）：顶层跳转到广告域名直接不让跳
        // （弹窗/跳转广告就是这么来的）。第一方（当前站自己的域名）
        // 永远放行——种子里有 ||xvideos.com^$third-party 这类规则，
        // 不加第一方豁免会把站本身拦掉。
        onNavigationRequest: (req) {
          final url = req.url;
          if (url.startsWith('about:blank') || url.startsWith('data:')) {
            return NavigationDecision.navigate;
          }
          final firstParty = Uri.tryParse(_currentUrl)?.host ?? '';
          if (AdblockService.instance
              .isBlockedUrl(url, firstPartyHost: firstParty)) {
            if (mounted) setState(() => _blockedCount++);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onWebResourceError: (error) {
          // 主页面加载失败（断网、被拦、证书错）：是 hanime 镜像就自动切另一个。
          if (error.isForMainFrame == true) _tryMirror(_currentUrl);
        },
        onUrlChange: (change) {
          final u = change.url;
          if (u != null && u.isNotEmpty) {
            _currentUrl = u;
            _videoUrl = '';
          }
        },
      ));
    // Hanime1 镜像常被验证拦住：要开 hanime1.me 就直接先切到能进的 hanimeone.me，
    // 不让用户对着验证页发懵；hanimeone.me 打不开时 _tryMirror 再切回来。
    final initialHost = Uri.tryParse(widget.url)?.host ?? '';
    _triedHosts.add(initialHost);
    if (initialHost == 'hanime1.me') {
      final mirror = HanimeSource.mirrorUrl(widget.url);
      _triedHosts.add(Uri.parse(mirror).host);
      _mirrorNote = 'hanime1.me 常被验证拦住，已自动切到能打开的 hanimeone.me';
      _controller.loadRequest(Uri.parse(mirror));
    } else {
      _controller.loadRequest(Uri.parse(widget.url));
    }
  }

  /// 撞上验证页/加载失败时切另一个镜像（只切没试过的，两个都试过了就停）。
  void _tryMirror(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (!HanimeSource.isHanimeHost(host)) return;
    final mirror = HanimeSource.mirrorUrl(url);
    final mirrorHost = Uri.parse(mirror).host;
    if (_triedHosts.contains(mirrorHost)) return;
    _triedHosts.add(mirrorHost);
    if (!mounted) return;
    setState(() => _mirrorNote = '$host 打不开，已自动切到能打开的 $mirrorHost');
    _controller.loadRequest(Uri.parse(mirror));
  }

  /// 广告拦截第二层（第 26 条）：JS 注入——fetch/XHR 发往广告域名直接 abort、
  /// window.open 弹窗拦截、按 ## 选择器藏广告元素。规则没准备好时不注。
  /// 上限见 AdblockService 类注释：webview_flutter 没有 shouldInterceptRequest，
  /// 首屏 HTML 里内嵌的广告子资源在注入前可能已经发出去了，拦不干净。
  Future<void> _injectAdblock() async {
    final svc = AdblockService.instance;
    if (!svc.isReady) return;
    try {
      await _controller.runJavaScript(svc.injectionJs);
    } catch (_) {}
  }

  /// 嗅视频直链：页里 <video> / <source> 的 src。
  /// 顺带看页面标题是不是 Cloudflare 验证页（Just a moment / Attention
  /// Required）：是的话，hanime 镜像自动切另一个。
  Future<void> _sniffVideo() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        "(function(){var v=document.querySelector('video');var src='';"
        "if(v){var s=v.querySelector('source');src=(s&&s.src)||v.src||v.currentSrc||'';}"
        "return JSON.stringify({src:src,title:document.title});})()",
      );
      final text = raw.toString();
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final src = (decoded['src'] ?? '').toString();
      final title = (decoded['title'] ?? '').toString();
      if (!mounted) return;
      setState(() {
        _pageTitle = title;
        // 只认 mp4 直链，其他格式（blob:、m3u8）原生播放器不一定吃，先不认。
        _videoUrl = src.contains('.mp4') ? src : '';
      });
      final t = title.toLowerCase();
      if (t.contains('just a moment') || t.contains('attention required')) {
        _tryMirror(_currentUrl);
      }
    } catch (_) {
      // 嗅不到就不弹条，不打扰浏览。
    }
  }

  String get _cleanPageTitle {
    var t = VideoItem.repairMojibake(_pageTitle);
    t = t.replaceAll(RegExp(r'\s*[-|]\s*(Hanime1|HanimeOne).*$', caseSensitive: false), '');
    return t.trim().isEmpty ? widget.title : t.trim();
  }

  Future<void> _openInPlayer() async {
    // referer 从当前页面的 host 取（之前写死 hanime1/hanimeone.me，
    // 其他源的视频页用这个 referer 会错）。
    final host = Uri.tryParse(_currentUrl)?.host ?? '';
    final item = VideoItem(
      id: '${widget.sourceId}-$_currentUrl',
      title: _cleanPageTitle,
      source: widget.sourceId,
      pageUrl: _currentUrl,
      streamUrl: _videoUrl,
      referer: host.isEmpty ? '' : 'https://$host/',
    );
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, store: widget.store),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final hasAds = StreamResolver.sourcePageHasAds(widget.sourceId);
    return PopScope(
      // 平时拦住所有返回：系统返回键走 WebView 历史；退出按钮按下时才放行。
      canPop: _forceExit,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // NavigatorState 在 await 之前取出来：await 之后再用 context 会触发 lint，
        // 拿已经取到的 navigator.pop() 就没这个问题。
        final navigator = Navigator.of(context);
        // 系统返回键：有上一页就回上一页；到第一页了再按才退出（真浏览器就是这样）。
        if (await _controller.canGoBack()) {
          await _controller.goBack();
          return;
        }
        if (!mounted) return;
        setState(() => _forceExit = true);
        navigator.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          // 上面这个退出按钮：随时直接退出，不走 WebView 历史。
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '退出浏览器',
            onPressed: () {
              setState(() => _forceExit = true);
              Navigator.of(context).pop();
            },
          ),
          title: Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 15)),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              tooltip: '刷新并重新嗅直链',
              onPressed: () async {
                await _controller.reload();
                await Future.delayed(const Duration(seconds: 2));
                await _sniffVideo();
              },
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading) const LinearProgressIndicator(color: Colors.pinkAccent),
            if (_mirrorNote.isNotEmpty)
              Container(
                width: double.infinity,
                color: const Color(0xFF2A2A35),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(_mirrorNote, style: const TextStyle(color: Colors.amber, fontSize: 12)),
              ),
            Expanded(child: WebViewWidget(controller: _controller)),
            if (_videoUrl.isNotEmpty)
              Container(
                width: double.infinity,
                color: const Color(0xFF2A2A35),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('检测到视频直链', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ),
                    // 嗅到的直链直接下（第 27 条）：不用再进播放页解析一次。
                    IconButton(
                      icon: const Icon(Icons.download, color: Colors.white),
                      tooltip: '下载这段视频',
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await DownloadManager.instance.startDownloadFromUrl(
                          id: '${widget.sourceId}-$_currentUrl',
                          title: _cleanPageTitle,
                          source: widget.sourceId,
                          url: _videoUrl,
                          headers: {
                            'Referer': _currentUrl,
                          },
                        );
                        if (!mounted) return;
                        messenger.showSnackBar(
                          const SnackBar(content: Text('开始下载，去「我的 · 下载管理」看进度')),
                        );
                      },
                    ),
                    ElevatedButton(
                      onPressed: _openInPlayer,
                      child: const Text('用播放器播'),
                    ),
                  ],
                ),
              ),
            Container(
              width: double.infinity,
              color: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                '${hasAds ? '站内页面有广告；嗅到的直链播就没有广告。' : '这个站本身没广告；嗅到的直链播也没有广告。'}'
                '${_blockedCount > 0 ? '已拦截 $_blockedCount 个广告跳转。' : ''}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
