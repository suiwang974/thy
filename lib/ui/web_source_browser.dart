import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/sources.dart';
import '../models/video_item.dart';
import '../search/global_search.dart';
import '../search/search_history.dart';
import '../services/adblock_service.dart';
import '../services/downloader.dart';
import '../services/sniffer.dart';
import '../services/store.dart';
import '../services/stream_resolver.dart';
import '../services/translator.dart';
import '../sniffer/native_sniffer_bridge.dart';
import '../source/source_registry.dart';
import '../source/source_session_policy.dart';
import 'player_screen.dart';
import 'sniff_sheet.dart';

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
  // 第 34 条：嗅到的媒体清单（DOM + performance + HTML 三路），
  // 不再是只认 mp4 的单个地址。
  List<SniffedMedia> _sniffed = [];
  bool _loading = true;
  String _mirrorNote = '';
  // 第 35 条：翻译开关（默认开，跟着 Store 走；AppBar 按钮可随时切回原文）。
  bool _translateOn = true;
  // 翻译前原文地址（切回原文用）；已翻过的地址（防 onPageFinished 重复翻）。
  String _originalUrl = '';
  String _lastTranslatedFor = '';
  // 退出按钮按下的标记：PopScope 平时拦住所有返回（让系统返回键走 WebView 历史），
  // 只有退出按钮按下时才放行、直接退出。
  bool _forceExit = false;
  // 镜像已试过的域名：每个镜像只试一次，两个都试过了就不再切（不死循环）。
  final _triedHosts = <String>{};
  // 广告拦截计数（第 26 条）：导航层拦掉的广告跳转数，底部显示。
  int _blockedCount = 0;
  // 第 53 条：嗅探诊断（上次嗅的结果：查了什么、为什么没嗅到）。
  SniffDiagnosis _lastDiagnosis = const SniffDiagnosis();
  // 第 53 条：每 3 秒轮询 performance 攒下来的候选地址——webview_flutter
  // 没有 onLoadResource 回调，拿不到请求发出的实时通知，轮询是唯一能
  // “持续监听”新请求的办法。用户点了播放、分片开始拉流后，
  // 下一次轮询就能把 .m3u8/.ts 攒下来，手动嗅探时直接用，不用等加载时机。
  Timer? _pollTimer;
  final _accumulated = <String>{};
  // 实现 5 全局搜索：地址栏 + 引擎切换 + 历史 + 引擎打不开时的回退。
  final _addressController = TextEditingController();
  final _addressFocus = FocusNode();
  SearchHistory? _history;
  late SearchEngine _engine;
  // 当前正在尝试的搜索（引擎回退状态）；不在搜索页时为 null。
  SearchEngineFallback? _searchFallback;
  // 正在加载的搜索页地址（回退时判断本次报错是不是该页的依据）。
  String? _searchUrl;
  // 最近一次搜索词（全部引擎打不开时“重试”用）。
  String? _lastSearchQuery;
  // 全部引擎都打不开时显示“搜索不可用”横幅。
  bool _searchUnavailable = false;
  // 当前页的源身份：已知源用绑定 id，未知站记 'web'（下载任务的来源标签）。
  late String _sourceId;
  // 实现 6 回滚开关：当前源整源下线时为 true，嗅探停掉、只当浏览器用。
  bool _sniffDisabled = false;
  // 集成：原生无头会话的桥（可见浏览器不动，旧 Dart 嗅探当保底）。
  final _bridge = NativeSnifferBridge();
  // 原生候选转成的展示条目（与旧嗅探的 _sniffed 合并展示，原生在前）。
  List<SniffedMedia> _nativeSniffed = [];
  // 上次发给原生会话的地址（去 # 后比较，防同一页反复 navigate）。
  String _nativeUrl = '';

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _translateOn = widget.store.translateEnabled;
    _sourceId = widget.sourceId;
    _engine = widget.store.preferredSearchEngine;
    _addressController.text = widget.url;
    // 搜索历史异步加载（读本地存储；没加载完之前提交照常导航，记历史时跳过）。
    SearchHistory.load().then((h) {
      if (mounted) setState(() => _history = h);
    });
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
          // 第 35 条：默认翻译成中文（翻译页加载失败自动回落原文 + toast）。
          if (mounted) await _maybeTranslate();
          // 第 39 条：翻译页加载完看内容判断（Google 的错误页是 HTTP 200，
          // 不触发 onWebResourceError，不看内容就回落不了）。
          if (mounted) await _checkTranslation();
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
          // 翻译页加载失败：按回落链走（Google -> Bing -> 原文，第 39 条），不假装翻译可用。
          if (error.isForMainFrame == true &&
              (Translator.isTranslatedUrl(error.url ?? '') ||
                  Translator.isBingTranslatedUrl(error.url ?? ''))) {
            _fallbackFromTranslated(error.url!);
            return;
          }
          // 实现 5：搜索页打不开，按首选引擎顺序换下一个；全部打不开就降级——
          // 打开首条历史地址 + 显示“搜索不可用”横幅（带重试）。
          if (error.isForMainFrame == true &&
              _searchFallback != null &&
              error.url != null &&
              error.url == _searchUrl) {
            final next = _searchFallback!.advance();
            if (next != null) {
              _searchUrl = next;
              _controller.loadRequest(Uri.parse(next));
              return;
            }
            _searchFallback = null;
            _searchUrl = null;
            if (mounted) setState(() => _searchUnavailable = true);
            final first = _history?.firstUrl;
            if (first != null && first != _currentUrl) {
              _controller.loadRequest(Uri.parse(first));
            }
            return;
          }
          // 主页面加载失败（断网、被拦、证书错）：是 hanime 镜像就自动切另一个。
          if (error.isForMainFrame == true) _tryMirror(_currentUrl);
        },
        onUrlChange: (change) {
          final u = change.url;
          if (u != null && u.isNotEmpty) {
            _currentUrl = u;
            _sniffed = [];
            _accumulated.clear();
            _lastDiagnosis = const SniffDiagnosis();
            // 地址栏跟随当前地址（正在输入时不抢）。
            if (!_addressFocus.hasFocus && _addressController.text != u) {
              _addressController.text = u;
            }
            // 离开搜索引擎结果页：搜索回退状态清掉，横幅收起。
            if (!_isSearchEngineUrl(u)) {
              _searchFallback = null;
              _searchUrl = null;
              _lastSearchQuery = null;
              if (_searchUnavailable) _searchUnavailable = false;
            }
            // 当前页的源身份：已知源用绑定 id；翻译代理页不改身份；未知站记 'web'。
            final host = Uri.tryParse(u)?.host ?? '';
            final binding = SourceRegistry.bindingForHost(host);
            if (binding != null) {
              _sourceId = binding.id;
            } else if (!Translator.isTranslatedUrl(u) &&
                !Translator.isBingTranslatedUrl(u)) {
              _sourceId = 'web';
            }
            // 实现 6 回滚开关：整源下线就不嗅探（会话启动/每次导航时热读取）。
            final disabled = !sniffEnabledFor(binding);
            if (disabled != _sniffDisabled && mounted) {
              setState(() {
                _sniffDisabled = disabled;
                if (disabled) {
                  _sniffed = [];
                  _nativeSniffed = [];
                  _accumulated.clear();
                }
              });
            } else {
              _sniffDisabled = disabled;
            }
            // 集成：跟导航走原生会话（翻译代理页不跟，原生会话留在原文页继续收候选；
            // 回滚停用时 navigateTo 内部会停会话；同一地址去 # 后相同就不反复发）。
            if (!Translator.isTranslatedUrl(u) &&
                !Translator.isBingTranslatedUrl(u)) {
              final stripped = _stripFragment(u);
              if (stripped != _nativeUrl) {
                _nativeUrl = stripped;
                _nativeSniffed = [];
                unawaited(_bridge.navigateTo(u, binding));
              }
            }
          }
        },
      ));
    // Hanime1 镜像常被验证拦住：要开 hanime1.me 就直接先切到能进的 hanimeone.me，
    // 不让用户对着验证页发懵；hanimeone.me 打不开时 _tryMirror 再切回来。
    final initialHost = Uri.tryParse(widget.url)?.host ?? '';
    _triedHosts.add(initialHost);
    final initialLoadUrl =
        initialHost == 'hanime1.me' ? HanimeSource.mirrorUrl(widget.url) : widget.url;
    if (initialHost == 'hanime1.me') {
      final mirror = initialLoadUrl;
      _triedHosts.add(Uri.parse(mirror).host);
      _mirrorNote = 'hanime1.me 常被验证拦住，已自动切到能打开的 hanimeone.me';
      _controller.loadRequest(Uri.parse(mirror));
    } else {
      _controller.loadRequest(Uri.parse(widget.url));
    }
    // 集成：原生无头会话并行跑同一地址（可见浏览器不动，旧嗅探当保底）。
    // 会话起不来也不炸浏览器（桥内部吞错）；翻译代理页不跟（onUrlChange 里拦）。
    _nativeUrl = _stripFragment(initialLoadUrl);
    unawaited(_bridge.startSession(
      initialLoadUrl,
      SourceRegistry.bindingForHost(
          Uri.tryParse(initialLoadUrl)?.host ?? ''),
    ));
    // 第 53 条：轮询 performance 攒候选地址（3 秒一次，轻量 JS，不扫 HTML）。
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollSniff());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    // 集成：浏览器关掉就销毁原生会话（MainActivity 侧只停实例、不取消 scope，
    // 下次再开浏览器还能起新会话）。
    unawaited(_bridge.dispose());
    _addressController.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  /// 第 53 条：轮询一次 performance + video 地址，攒进候选集。
  /// 失败（页面正在跳转/JS 还没准备好）就跳过，不打扰浏览。
  /// 实现 6：回滚停用时不轮询。
  /// 集成：顺手拉一次原生候选进仓库，合并展示（原生在前、按地址去重）。
  Future<void> _pollSniff() async {
    if (!mounted || _sniffDisabled) return;
    try {
      final raw = await _controller.runJavaScriptReturningResult(Sniffer.pollJs);
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      var changed = false;
      for (final v in (decoded['videos'] as List?) ?? []) {
        final src = ((v as Map)['src'] ?? '').toString();
        if (src.isNotEmpty && _accumulated.add(src)) changed = true;
      }
      for (final r in (decoded['resources'] as List?) ?? []) {
        final u = r.toString();
        if (u.isNotEmpty && _accumulated.add(u)) changed = true;
      }
      if (changed && mounted) {
        // 只攒下来，不在这里跑完整嗅探：完整嗅探要拉播放列表、探大小，
        // 视频播着的时候每几秒来一次太费流量。攒下来的地址在用户点
        // 嗅探按钮 / 页面加载嗅探时一起用，不用等加载时机。
      }
    } catch (_) {}
    if (_bridge.isRunning && mounted) {
      await _bridge.pollCandidates();
      if (mounted) setState(() => _nativeSniffed = _bridge.sniffedMedia);
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

  // ---------- 实现 5：全局搜索（地址栏 + 引擎 + 历史 + 回退） ----------

  /// 首选引擎在前，其余按默认顺序补齐（引擎打不开时的回退顺序）。
  List<SearchEngine> _engineOrder() {
    final order = <SearchEngine>[_engine];
    for (final e in GlobalSearch.defaultEngineOrder) {
      if (e != _engine) order.add(e);
    }
    return order;
  }

  /// 地址栏提交：解析输入并导航；搜索词记入历史。
  /// sniffOnly 的源（niacg/lianzu11/hanime1/hanimeone）不走 HTTP 搜索——
  /// 这里本来就不做 HTTP 搜索，只导航；输域名直接打开后由浏览器内嗅探发现视频。
  Future<void> _goToAddress(String input) async {
    final resolved = GlobalSearch.resolve(
      input,
      engine: _engine,
      isKnownHost: (host) => SourceRegistry.bindingForHost(host) != null,
    );
    if (resolved == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('输入为空')),
      );
      return;
    }
    final history = _history;
    if (history != null) {
      await history.add(input.trim(), resolved.url);
      if (mounted) setState(() {});
    }
    _navigateTo(resolved);
  }

  /// 统一导航入口（地址栏提交、历史点选都走这里）。
  /// 只决定“加载哪个页面”，不产出候选、不解析 playlist；嗅探由浏览器已有的
  /// 嗅探管线在页面加载时自动跑（搜索结果页也一样）。
  void _navigateTo(ResolvedNavigation resolved) {
    if (resolved.isSearch) {
      _searchFallback = SearchEngineFallback(
        resolved.query!,
        order: _engineOrder(),
      );
      _searchUrl = resolved.url;
      _lastSearchQuery = resolved.query;
    } else {
      _searchFallback = null;
      _searchUrl = null;
      _lastSearchQuery = null;
    }
    setState(() => _searchUnavailable = false);
    _controller.loadRequest(Uri.parse(resolved.url));
  }

  /// 切换默认引擎（持久保存）。正在看搜索页就用新引擎重搜一次。
  Future<void> _switchEngine(SearchEngine engine) async {
    if (engine == _engine) return;
    setState(() => _engine = engine);
    await widget.store.setPreferredSearchEngine(engine);
    final query = _lastSearchQuery;
    if (query != null && mounted) {
      final fallback = SearchEngineFallback(query, order: _engineOrder());
      _searchFallback = fallback;
      _searchUrl = fallback.firstUrl();
      setState(() => _searchUnavailable = false);
      await _controller.loadRequest(Uri.parse(fallback.firstUrl()));
    }
  }

  /// “搜索不可用”横幅里的重试：用首选引擎重搜一次。
  Future<void> _retrySearch() async {
    final query = _lastSearchQuery;
    if (query == null) {
      setState(() => _searchUnavailable = false);
      return;
    }
    final fallback = SearchEngineFallback(query, order: _engineOrder());
    _searchFallback = fallback;
    _searchUrl = fallback.firstUrl();
    setState(() => _searchUnavailable = false);
    await _controller.loadRequest(Uri.parse(fallback.firstUrl()));
  }

  /// 是否搜索引擎的结果页地址（Bing/Google 搜 /search，DuckDuckGo 用 /?q=）。
  bool _isSearchEngineUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    switch (uri.host) {
      case 'www.bing.com':
      case 'www.google.com':
        return uri.path == '/search';
      case 'duckduckgo.com':
      case 'www.duckduckgo.com':
        return uri.path == '/' || uri.path.isEmpty;
      default:
        return false;
    }
  }

  /// 搜索历史 bottom sheet：点一条打开，左滑删一条，右上角一键清空。
  void _showHistorySheet() {
    final history = _history;
    if (history == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A22),
      builder: (sheetContext) {
        final entries = history.entries;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('搜索历史',
                    style: TextStyle(color: Colors.white)),
                trailing: TextButton(
                  onPressed: () async {
                    await history.clear();
                    if (!mounted) return;
                    setState(() {});
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                  child: const Text('清空'),
                ),
              ),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('还没有搜索历史',
                      style: TextStyle(color: Colors.white54)),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      return Dismissible(
                        key: ValueKey(e.url),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child:
                              const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) async {
                          await history.remove(e.url);
                          if (mounted) setState(() {});
                        },
                        child: ListTile(
                          title: Text(e.label,
                              style: const TextStyle(color: Colors.white),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(e.url,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          onTap: () async {
                            await history.add(e.label, e.url);
                            if (sheetContext.mounted) {
                              Navigator.of(sheetContext).pop();
                            }
                            await _controller.loadRequest(Uri.parse(e.url));
                          },
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
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

  /// 嗅视频（第 34 条 + 第 53 条两段式）：DOM + performance 网络请求 +
  /// HTML 正则三路，m3u8/blob/ts 都认，不再是只认 mp4。
  /// 轮询攒下来的候选地址一起传进去（视频播了一会儿才拉流的也能嗅到）。
  /// 顺带看页面标题是不是 Cloudflare 验证页（Just a moment / Attention
  /// Required）：是的话，hanime 镜像自动切另一个。
  /// 实现 6：回滚停用时不嗅探。
  /// 集成：顺手刷新一次原生候选（原生会话在后台并行收，手动点雷达时也要看到）。
  Future<void> _sniffVideo() async {
    if (_sniffDisabled) return;
    try {
      final r = await Sniffer.sniff(
        _controller,
        pageUrl: _currentUrl,
        extraCandidates: _accumulated.toList(),
      );
      if (!mounted) return;
      setState(() {
        _pageTitle = r.pageTitle;
        _sniffed = r.items;
        _lastDiagnosis = r.diagnosis;
      });
      final t = r.pageTitle.toLowerCase();
      if (t.contains('just a moment') || t.contains('attention required')) {
        _tryMirror(_currentUrl);
      }
    } catch (_) {
      // 嗅不到就不弹条，不打扰浏览。
    }
    if (_bridge.isRunning && mounted) {
      await _bridge.pollCandidates();
      if (mounted) setState(() => _nativeSniffed = _bridge.sniffedMedia);
    }
  }

  /// 合并展示：原生候选在前（有真实请求头、六路全开），旧嗅探去重后在后。
  /// 按地址去重（小写、去 # 后缀），同一地址只留原生那条。
  List<SniffedMedia> _mergedSniffed() {
    final out = <SniffedMedia>[..._nativeSniffed];
    final nativeUrls = _nativeSniffed.map((m) => _stripFragment(m.url)).toSet();
    for (final m in _sniffed) {
      if (!nativeUrls.contains(_stripFragment(m.url))) out.add(m);
    }
    return out;
  }

  /// 去 # 后缀并小写（地址去重比较用）。
  static String _stripFragment(String url) {
    final l = url.toLowerCase();
    final h = l.indexOf('#');
    return h == -1 ? l : l.substring(0, h);
  }

  /// 第 35 条：翻译开关开着、当前页还没翻过，就加载 translate.goog 代理页。
  /// 翻译页加载失败（主框报错）时自动回落原文 + toast，不假装可用。
  Future<void> _maybeTranslate() async {
    if (!_translateOn) return;
    if (!Translator.isTranslatableUrl(_currentUrl)) return;
    if (_currentUrl == _lastTranslatedFor) return;
    _lastTranslatedFor = _currentUrl;
    _originalUrl = _currentUrl;
    await _controller.loadRequest(Uri.parse(Translator.toTranslatedUrl(_currentUrl)));
  }

  /// 第 39 条：翻译页打不开/翻不了时的回落链：Google -> Bing -> 原文。
  /// onWebResourceError（主框报错）和 _checkTranslation（内容是错误页）都走这里。
  void _fallbackFromTranslated(String failedUrl) {
    var back = _originalUrl.isNotEmpty
        ? _originalUrl
        : Translator.originalUrlFromTranslated(failedUrl);
    // Google 翻不了就试 Bing（国内一般能直接打开）；Bing 也不行就回原文。
    if (Translator.isTranslatedUrl(failedUrl)) {
      final bing = Translator.toBingTranslatedUrl(back);
      if (bing != back) {
        _lastTranslatedFor = back;
        _controller.loadRequest(Uri.parse(bing));
        return;
      }
    }
    // 原文地址拿不到（理论上不会发生：_maybeTranslate 一定先记了原文），
    // 就不乱跳，只提示。
    if (back.isEmpty ||
        Translator.isTranslatedUrl(back) ||
        Translator.isBingTranslatedUrl(back)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('翻译服务不通，已切回原文')),
        );
      }
      return;
    }
    _lastTranslatedFor = '';
    _originalUrl = '';
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('翻译服务不通（Google/Bing 都打不开），已切回原文')),
      );
    }
    _controller.loadRequest(Uri.parse(back));
  }

  /// 第 39 条：翻译页加载完看内容判断——Google 的 "Can't translate this page"
  /// 是 HTTP 200 正常页，不触发 onWebResourceError，不看内容就永远回落不了，
  /// 用户直接看到英文错误页。读不到内容就不判断，别把好页当坏页切走。
  Future<void> _checkTranslation() async {
    if (!Translator.isTranslatedUrl(_currentUrl) &&
        !Translator.isBingTranslatedUrl(_currentUrl)) {
      return;
    }
    String title = '';
    String body = '';
    try {
      final t = await _controller.runJavaScriptReturningResult('document.title');
      try {
        final d = jsonDecode(t.toString());
        if (d is String) title = d;
      } catch (_) {
        title = t.toString();
      }
      final b = await _controller.runJavaScriptReturningResult(
        "document.body ? document.body.innerText.slice(0, 500) : ''",
      );
      try {
        final d = jsonDecode(b.toString());
        if (d is String) body = d;
      } catch (_) {
        body = b.toString();
      }
    } catch (_) {
      return;
    }
    if (!Translator.isTranslationFailurePage(title, body)) return;
    _fallbackFromTranslated(_currentUrl);
  }

  /// AppBar 翻译按钮：开/关翻译（选择持久保存到 Store）。
  /// 关：回到翻译前的原文地址（翻不回去就反向映射当前地址）。
  Future<void> _toggleTranslate() async {
    final on = !_translateOn;
    setState(() => _translateOn = on);
    await widget.store.setTranslateEnabled(on);
    if (!mounted) return;
    if (on) {
      _lastTranslatedFor = '';
      await _maybeTranslate();
    } else {
      final back = _originalUrl.isNotEmpty
          ? _originalUrl
          : Translator.originalUrlFromTranslated(_currentUrl);
      _lastTranslatedFor = '';
      _originalUrl = '';
      if (back != _currentUrl) {
        await _controller.loadRequest(Uri.parse(back));
      }
    }
  }

  String get _cleanPageTitle {
    var t = VideoItem.repairMojibake(_pageTitle);
    t = t.replaceAll(RegExp(r'\s*[-|]\s*(Hanime1|HanimeOne).*$', caseSensitive: false), '');
    return t.trim().isEmpty ? widget.title : t.trim();
  }

  Future<void> _openInPlayer(String url) async {
    // referer 从当前页面的 host 取（之前写死 hanime1/hanimeone.me，
    // 其他源的视频页用这个 referer 会错）。
    final host = Uri.tryParse(_currentUrl)?.host ?? '';
    final item = VideoItem(
      id: '$_sourceId-$_currentUrl',
      title: _cleanPageTitle,
      source: _sourceId,
      pageUrl: _currentUrl,
      streamUrl: url,
      referer: host.isEmpty ? '' : 'https://$host/',
    );
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, store: widget.store),
    ));
  }

  /// 嗅到的清单里最适合播/下的那条：mp4 优先，其次 m3u8；blob 和下不了的不要。
  /// 走合并清单（原生候选在前）。
  SniffedMedia? _bestSniffed() {
    final items = _mergedSniffed();
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

  /// 某条目的下载请求头：原生候选走原生侧记到的真实请求头
  /// （含 Referer/UA/Cookie 上下文，403 恢复靠它）；旧嗅探的条目
  /// 沿用原来的 pageUrl 当 Referer。
  Map<String, String> _headersFor(String url) =>
      _bridge.headersFor(url) ?? {'Referer': _currentUrl};

  @override
  Widget build(BuildContext context) {
    final hasAds = StreamResolver.sourcePageHasAds(_sourceId);
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
            // 第 35 条：翻译按钮（默认开，翻成中文；点一下切回原文）。
            IconButton(
              icon: Icon(Icons.translate,
                  color: _translateOn ? Colors.pinkAccent : Colors.white70),
              tooltip: _translateOn ? '翻译成中文（已开，点一下切回原文）' : '翻译成中文（已关，点一下打开）',
              onPressed: _toggleTranslate,
            ),
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              tooltip: '刷新并重新嗅探',
              onPressed: () async {
                await _controller.reload();
                await Future.delayed(const Duration(seconds: 2));
                await _sniffVideo();
              },
            ),
            // 第 40 条 + 第 53 条：手动嗅探入口常驻（页里有视频却没出嗅探条时点一下）。
            // 嗅不到不再写“列表页没有可播的视频”——这就是视频页，那句话本身是错的；
            // 改成诊断文案（查了什么、为什么没嗅到）。播放器在跨域 iframe 里时，
            // 给“打开播放页”动作：直接进 iframe 里的播放页再嗅一次。
            IconButton(
              icon: const Icon(Icons.radar, color: Colors.white),
              tooltip: '嗅探本页视频',
              onPressed: () async {
                await _sniffVideo();
                if (!context.mounted) return;
                final items = _mergedSniffed();
                if (items.isEmpty) {
                  final playerUrl = _lastDiagnosis.playerIframeUrl;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(_lastDiagnosis.text),
                      duration: const Duration(seconds: 6),
                      action: playerUrl == null
                          ? null
                          : SnackBarAction(
                              label: '打开播放页',
                              onPressed: () async {
                                _accumulated.clear();
                                await _controller.loadRequest(Uri.parse(playerUrl));
                              },
                            ),
                    ),
                  );
                } else {
                  SniffSheet.show(
                    context,
                    items: items,
                    pageTitle: _cleanPageTitle,
                    sourceId: _sourceId,
                    pageUrl: _currentUrl,
                    store: widget.store,
                    headersFor: _headersFor,
                  );
                }
              },
            ),
            // 实现 6：回滚开关——一键停用/恢复当前源的嗅探（整源下线）。
            // 未知站（不在 10 源里）没有绑定，嗅探常开，不可停用。
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              tooltip: '更多',
              onSelected: (value) async {
                if (value != 'toggle-sniff') return;
                final b = SourceRegistry.bindingForHost(
                  Uri.tryParse(_currentUrl)?.host ?? '',
                );
                if (b == null) return;
                if (b.enabled) {
                  SourceRegistry.disable(b.id);
                } else {
                  SourceRegistry.enable(b.id);
                }
                if (!mounted) return;
                final nowDisabled =
                    !sniffEnabledFor(SourceRegistry.bindingFor(b.id));
                setState(() {
                  _sniffDisabled = nowDisabled;
                  if (nowDisabled) {
                    _sniffed = [];
                    _nativeSniffed = [];
                    _accumulated.clear();
                  }
                });
                // 集成：停用就停原生会话，恢复就按当前地址重起（走同一套回滚开关）。
                // messenger 在 await 之前取出来：await 之后再用 context 会触发 lint。
                final messenger = ScaffoldMessenger.of(context);
                if (nowDisabled) {
                  await _bridge.stopSession();
                } else {
                  await _bridge.startSession(
                    _currentUrl,
                    SourceRegistry.bindingForHost(
                        Uri.tryParse(_currentUrl)?.host ?? ''),
                  );
                }
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(nowDisabled
                        ? '已停用${b.displayName}的嗅探（回滚）'
                        : '已恢复${b.displayName}的嗅探'),
                  ),
                );
                if (!nowDisabled) await _sniffVideo();
              },
              itemBuilder: (_) {
                final b = SourceRegistry.bindingForHost(
                  Uri.tryParse(_currentUrl)?.host ?? '',
                );
                if (b == null) {
                  return const [
                    PopupMenuItem(
                      value: 'none',
                      enabled: false,
                      child: Text('未知站：嗅探常开'),
                    ),
                  ];
                }
                return [
                  PopupMenuItem(
                    value: 'toggle-sniff',
                    child: Text(
                        b.enabled ? '停用该源嗅探（回滚）' : '恢复该源嗅探'),
                  ),
                ];
              },
            ),
          ],
        ),
        body: Column(
          children: [
            // 实现 5：地址栏——输网址直接打开，输词走搜索引擎出结果（像 1DM+ 那样）。
            Container(
              color: const Color(0xFF1A1A22),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.history, color: Colors.white70),
                    tooltip: '搜索历史',
                    onPressed: _showHistorySheet,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _addressController,
                      focusNode: _addressFocus,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜索或输入网址',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF2A2A35),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      textInputAction: TextInputAction.go,
                      onSubmitted: (value) {
                        _addressFocus.unfocus();
                        _goToAddress(value);
                      },
                    ),
                  ),
                  PopupMenuButton<SearchEngine>(
                    tooltip: '搜索引擎（当前：${_engine.displayName}）',
                    onSelected: _switchEngine,
                    itemBuilder: (_) => SearchEngine.values
                        .map((e) => PopupMenuItem(
                              value: e,
                              child: Row(
                                children: [
                                  if (e == _engine)
                                    const Icon(Icons.check, size: 16),
                                  if (e == _engine)
                                    const SizedBox(width: 6),
                                  Text(e.displayName),
                                ],
                              ),
                            ))
                        .toList(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      child: Text(
                        _engine.displayName,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 实现 5：全部引擎都打不开时的横幅（已降级打开首条历史地址）。
            if (_searchUnavailable)
              Container(
                width: double.infinity,
                color: const Color(0xFF3A2A1A),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '搜索不可用：搜索引擎都打不开',
                        style: TextStyle(color: Colors.amber, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: _retrySearch,
                      child: const Text('重试'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.amber, size: 18),
                      tooltip: '关闭',
                      onPressed: () =>
                          setState(() => _searchUnavailable = false),
                    ),
                  ],
                ),
              ),
            // 实现 6：回滚停用横幅——该源嗅探已停，只当浏览器用。
            if (_sniffDisabled)
              Container(
                width: double.infinity,
                color: const Color(0xFF3A2A2A),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: const Text(
                  '该源嗅探已停用（回滚开关），只当浏览器用',
                  style: TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ),
            if (_loading) const LinearProgressIndicator(color: Colors.pinkAccent),
            if (_mirrorNote.isNotEmpty)
              Container(
                width: double.infinity,
                color: const Color(0xFF2A2A35),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(_mirrorNote, style: const TextStyle(color: Colors.amber, fontSize: 12)),
              ),
            Expanded(child: WebViewWidget(controller: _controller)),
            // 第 34 条：嗅到视频就弹出瘦条（播/下载两个按钮）。
            // 只有 blob、没找到底层地址时只显示条目说明（清单里写明下不了）。
            // 集成：条数与清单走合并清单（原生候选在前）；下载用原生真实请求头。
            if (_mergedSniffed().isNotEmpty)
              Container(
                width: double.infinity,
                color: const Color(0xFF1F2A1F),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '嗅到 ${_mergedSniffed().length} 个视频${_bestSniffed() == null ? '（浏览器内播放，拿不到地址）' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: () => SniffSheet.show(
                        context,
                        items: _mergedSniffed(),
                        pageTitle: _cleanPageTitle,
                        sourceId: _sourceId,
                        pageUrl: _currentUrl,
                        store: widget.store,
                        headersFor: _headersFor,
                      ),
                      child: const Text('查看'),
                    ),
                    if (_bestSniffed() != null) ...[
                      TextButton(
                        onPressed: () => _openInPlayer(_bestSniffed()!.url),
                        child: const Text('播'),
                      ),
                      IconButton(
                        icon: const Icon(Icons.download, color: Colors.white),
                        tooltip: '下载嗅到的视频',
                        onPressed: () async {
                          final best = _bestSniffed();
                          if (best == null) return;
                          final messenger = ScaffoldMessenger.of(context);
                          await DownloadManager.instance.startDownloadFromUrl(
                            id: 'sniff-${best.url.hashCode.abs()}',
                            title: _cleanPageTitle,
                            source: _sourceId,
                            url: best.url,
                            headers: _headersFor(best.url),
                            durationSec: best.durationSec ?? 0,
                          );
                          if (!mounted) return;
                          messenger.showSnackBar(
                            const SnackBar(content: Text('开始下载，去「我的 · 下载管理」看进度')),
                          );
                        },
                      ),
                    ],
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
