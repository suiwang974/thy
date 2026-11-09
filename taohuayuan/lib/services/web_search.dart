import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../data/sources.dart';

/// WebView 内搜索用的回调接口：SearchService 通过它查 webViewOnly 的源，
/// 单元测试可以传假实现，不用真的起 WebView。
abstract class WebSearchHandler {
  Future<SourceResult> search(Source source, String query, {int page = 1});
}

/// WebView 内搜索（第 41 条）：niacg、lianzu11、hanime 这三个源的纯 HTTP 请求
/// 会被 WAF/Cloudflare 按 TLS 指纹拦，App 里直接搜永远 0 条；但系统 WebView
/// 是真 Chrome 指纹，能过验证。做法：隐藏 WebView 加载搜索页，拿
/// document.documentElement.outerHTML，走各源现成的 parseWebSearchHtml 解析，
/// 结果和普通源一样进搜索列表。搜不到写明原因（验证没通过/加载超时/确实没结果）。
///
/// - 三个源共用一个隐藏 WebView，搜索排队串行跑（一个 WebView 一次只能开一页，
///   并行 loadRequest 会互相顶掉）；HTTP 源不受影响，先回来的先显示。
/// - 验证页会自动刷新重载：加载完轮询 outerHTML，验证通过才解析，最多等 16 秒。
/// - Hanime：首选镜像（hanimeone.me）过不了验证就试另一个镜像（同一站两个域名）。
class WebSearchRunner implements WebSearchHandler {
  final WebViewController controller;

  WebSearchRunner(this.controller) {
    controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
          _loadCompleter!.complete();
        }
      },
      onWebResourceError: (e) {
        if (e.isForMainFrame == true &&
            _loadCompleter != null &&
            !_loadCompleter!.isCompleted) {
          _loadCompleter!.completeError(e.description);
        }
      },
    ));
  }

  Completer<void>? _loadCompleter;

  /// 排队串行：上一个搜完才开始下一个；某次失败不堵后面的。
  Future<void> _tail = Future.value();

  @override
  Future<SourceResult> search(Source source, String query, {int page = 1}) {
    final f = _tail.then((_) => _run(source, query, page));
    _tail = f.then((_) {}, onError: (_) {});
    return f;
  }

  /// Cloudflare/验证页特征（标题或正文里有这些词就是还没通过验证）。
  static bool isChallengeHtml(String html) {
    final l = html.toLowerCase();
    return l.contains('just a moment') ||
        l.contains('attention required') ||
        l.contains('cf-challenge') ||
        l.contains('checking your browser') ||
        l.contains('verify you are human') ||
        l.contains('请完成验证');
  }

  Future<SourceResult> _run(Source source, String query, int page) async {
    final urls = <String>[source.webSearchUrlPage(query, page)];
    // Hanime：首选镜像过不了验证就试另一个镜像（第 20 条：同一站两个域名）。
    if (source is HanimeSource) {
      final mirror = HanimeSource.mirrorUrl(urls.first);
      if (mirror != urls.first) urls.add(mirror);
    }
    var lastError = '加载失败';
    for (final url in urls) {
      if (url.isEmpty) {
        lastError = '这个源没有搜索地址';
        continue;
      }
      try {
        final html = await _fetchHtml(url);
        if (isChallengeHtml(html)) {
          lastError = '验证没通过（Cloudflare 一直在验证），点状态条去内置浏览器里看';
          continue;
        }
        final items = source.parseWebSearchHtml(html);
        return SourceResult(sourceId: source.id, sourceName: source.name, items: items);
      } catch (e) {
        lastError = e.toString();
      }
    }
    return SourceResult(sourceId: source.id, sourceName: source.name, error: lastError);
  }

  Future<String> _fetchHtml(String url) async {
    _loadCompleter = Completer<void>();
    await controller.loadRequest(Uri.parse(url));
    try {
      await _loadCompleter!.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw '页面加载超时（验证太慢或网络太慢）';
    } catch (e) {
      throw '页面加载失败：$e';
    }
    // 验证页会自动刷新重载：轮询 outerHTML，验证通过才解析，最多等 16 秒。
    for (var i = 0; i < 8; i++) {
      final html = await _outerHtml();
      if (!isChallengeHtml(html)) return html;
      await Future.delayed(const Duration(seconds: 2));
    }
    final html = await _outerHtml();
    if (isChallengeHtml(html)) throw '验证没通过（Cloudflare 一直在验证）';
    return html;
  }

  Future<String> _outerHtml() async {
    final raw = await controller.runJavaScriptReturningResult(
      "document.documentElement ? document.documentElement.outerHTML : ''",
    );
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is String) return decoded;
    } catch (_) {}
    return raw.toString();
  }
}
