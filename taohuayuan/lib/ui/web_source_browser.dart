import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_item.dart';
import '../services/store.dart';
import 'player_screen.dart';

/// 内置浏览器（成人动漫源 Hanime1 / HanimeOne 专用）：
/// 这两个站会被 Cloudflare 拦，App 的纯 HTTP 请求过不了验证，
/// 只能在 WebView 里打开（真浏览器带 JS，验证能过）；
/// 在视频页里嗅到 <video> 直链就弹出“用播放器播”，切原生播放器。
/// 没验过的地方（2026-11-09，VM 下两站都 403，没见过真页）：
/// 嗅到的直链格式、视频页结构都没跑通过；嗅不到直链时这里就只当浏览器用，
/// 用户照样能在站里看（页面有广告，会写清楚）。
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

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (_) async {
          if (!mounted) return;
          setState(() => _loading = false);
          await _sniffVideo();
          // 视频可能是懒加载的：4 秒后再嗅一次。
          await Future.delayed(const Duration(seconds: 4));
          if (mounted) await _sniffVideo();
        },
        onUrlChange: (change) {
          final u = change.url;
          if (u != null && u.isNotEmpty) {
            _currentUrl = u;
            _videoUrl = '';
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  /// 嗅视频直链：页里 <video> / <source> 的 src。
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
    final host = widget.sourceId == 'hanime1' ? 'hanime1.me' : 'hanimeone.me';
    final item = VideoItem(
      id: '${widget.sourceId}-$_currentUrl',
      title: _cleanPageTitle,
      source: widget.sourceId,
      pageUrl: _currentUrl,
      streamUrl: _videoUrl,
      referer: 'https://$host/',
    );
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, store: widget.store),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
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
            child: const Text(
              '站内页面有广告；嗅到的直链播就没有广告。',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
