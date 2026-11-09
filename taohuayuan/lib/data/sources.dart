import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/video_item.dart';

/// 全部 10 个在线源：直接照 JS 插件（~/workspace/super-library/plugins/）逐条搬成 Dart，
/// 规则（用户 2026-11-07 定下的，一直沿用）：
/// - 有标题就收录，没封面也不丢，只显示文字卡；
/// - 热门词不能只返回 20 条，能翻页就翻页。

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 一个源的搜索结果：成功时 items；失败时 error（界面显示“该源暂不可用”，不炸掉整页）。
/// elapsedMs 是这次调用花了多少毫秒（记下来，慢的源后台再试）。
class SourceResult {
  final String sourceId;
  final String sourceName;
  final List<VideoItem> items;
  final String? error;
  final int elapsedMs;
  const SourceResult({required this.sourceId, required this.sourceName, this.items = const [], this.error, this.elapsedMs = 0});
}

abstract class Source {
  String get id;
  String get name;

  /// true = 这个源要过 Cloudflare 验证，App 的纯 HTTP 请求会被拦，
  /// 只能在 WebView 内置浏览器里打开（真浏览器带 JS，验证能过）。
  /// 目前只有 Hanime1 / HanimeOne。
  bool get webViewOnly => false;

  /// 内置浏览器用的搜索地址 / 首页地址（webViewOnly 的源必须有；
  /// 其他源也提供：搜不到/握手失败时点状态条就能去内置浏览器里看，不卡死）。
  String webSearchUrl(String query) => '';
  String get webHomeUrl => '';

  Future<SourceResult> search(String query);
  Future<SourceResult> home();

  /// 分页搜第 page 页（搜索分页加载用）。默认实现：只有第 1 页走 search，
  /// 第 2 页起返回空；各源按需重写成真正的单页抓取。
  Future<SourceResult> searchPage(String query, int page) async {
    if (page <= 1) return search(query);
    return SourceResult(sourceId: id, sourceName: name);
  }
}

/// ---------- 工具 ----------

String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

String? _first(RegExp re, String s) => re.firstMatch(s)?.group(1);

/// '10:23' / '1:02:03' / '30 sec' / '5 min' / '30'（纯秒数）-> 秒数；解析不到返回 0（时长未知）。
int _parseDuration(String s) {
  final t = s.trim();
  if (t.isEmpty) return 0;
  final minMatch = RegExp(r'^(\d+)\s*min$').firstMatch(t);
  if (minMatch != null) return int.parse(minMatch.group(1)!) * 60;
  if (RegExp(r'^\d+$').hasMatch(t)) return int.parse(t);
  final parts = t.split(':').map(int.tryParse).toList();
  if (parts.any((p) => p == null)) return 0;
  final nums = parts.cast<int>();
  if (nums.length == 2) return nums[0] * 60 + nums[1];
  if (nums.length == 3) return nums[0] * 3600 + nums[1] * 60 + nums[2];
  return 0;
}

/// 解 HTML 实体（&quot; &#039; &amp; &lt; &gt; &nbsp;）。
String _decodeEntities(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ');

/// 从一小段 HTML 里挑封面：优先懒加载的真图（data-src），再是 src。
/// 跳过占位图：data: 内联 gif、lightbox-blank.gif、.svg logo、1px 占位图。
/// （实测教训：xvideos 的 <img src> 是 blank.gif，真图在 data-src；旧解析按 src 抓，
///  25 张“封面”全是空白图。）
String _pickPoster(String html, String base) {
  const attrs = ['data-src', 'data-thumb', 'data-mediumthumb', 'data-original'];
  for (final attr in attrs) {
    final v = _first(RegExp('$attr="([^"]+)"'), html);
    if (v != null && _isRealPoster(v)) return _absUrl(v, base);
  }
  final srcset = _first(RegExp(r'srcset="([^"]+)"'), html);
  if (srcset != null) {
    final first = srcset.split(',').first.trim().split(' ').first;
    if (_isRealPoster(first)) return _absUrl(first, base);
  }
  final src = _first(RegExp(r'''<img[^>]+src="([^"]+)"'''), html);
  if (src != null && _isRealPoster(src)) return _absUrl(src, base);
  return '';
}

bool _isRealPoster(String url) {
  final u = url.trim().toLowerCase();
  if (u.isEmpty) return false;
  if (u.startsWith('data:')) return false;
  if (u.contains('blank.gif') || u.contains('lightbox-blank')) return false;
  if (u.endsWith('.svg')) return false;
  if (u.contains('1px.gif') || u.contains('pixel.gif') || u.contains('spacer.gif')) return false;
  return true;
}

String _absUrl(String url, String base) {
  if (url.startsWith('http')) return url;
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('/')) return base + url;
  return url;
}

/// HTTP 正文一律按 UTF-8 解（不要用 res.body：Dart 的 http 包在服务端
/// 不给 charset 时默认按 latin1 解，中文/全角标点标题会变成乱码，
/// 比如 eporner 标题里的 ’ 会变成 â€™）。
String _decodeBody(http.Response res) {
  try {
    return utf8.decode(res.bodyBytes);
  } catch (_) {
    return res.body;
  }
}

/// 标题清洗（所有解析入口最后都过这一道）：
/// - 先修乱码（UTF-8 被当 latin1 解的产物，见 VideoItem.repairMojibake）；
/// - 去掉页面垃圾后缀：img alt 里的 " thumbnail"（r34 详情页相关视频的 alt
///   都是 "<标题> thumbnail"）；
/// - 压空白。注意：不要动标题里的画质词（比如 "4k ultra hd" 是标题本身，
///   用户真机截图里就这么显示，剥了反而改了他认得的标题）。
/// 洗完是空的返回 ''，由调用方按“没真标题”处理。
String _cleanTitle(String raw) {
  var t = VideoItem.repairMojibake(raw);
  // 末尾的 " thumbnail"（可能连着好几个）去掉；不区分大小写。
  t = t.replaceAll(RegExp(r'(\s+thumbnail)+$', caseSensitive: false), '');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 标题是不是“假标题”：只有星号（xhamster 占位符）、只有时长数字、只有标点——
/// 这种不要，宁可丢掉这条也不拿空卡充数。
bool _isJunkTitle(String title) {
  final t = title.trim();
  if (t.isEmpty) return true;
  if (RegExp(r'^\*+$').hasMatch(t)) return true;
  if (RegExp(r'^[\d:.,\-/ ]+$').hasMatch(t)) return true;
  return false;
}

/// ---------- 1. Eporner：官方 JSON API，无需解析 HTML ----------

class EpornerSource implements Source {
  @override
  String get id => 'eporner';
  @override
  String get name => 'Eporner';

  @override
  bool get webViewOnly => false;

  @override
  String webSearchUrl(String query) =>
      'https://www.eporner.com/search/${Uri.encodeComponent(query)}/';

  @override
  String get webHomeUrl => 'https://www.eporner.com/';

  /// 供单元测试直接验：把 Eporner API 返回的 videos 数组转成条目。
  static List<VideoItem> parseVideos(List vids) {
    return vids.map((v) {
      final m = v as Map<String, dynamic>;
      final len = (m['length_sec'] ?? 0) as num;
      final keywords = <String>[];
      final kw = (m['keywords'] ?? '').toString();
      if (kw.isNotEmpty) {
        keywords.addAll(kw.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty));
      }
      var publishedAtMs = 0;
      final added = (m['added'] ?? '').toString();
      if (added.isNotEmpty) {
        try {
          publishedAtMs = DateTime.parse(added).millisecondsSinceEpoch;
        } catch (_) {}
      }
      return VideoItem(
        id: 'eporner-${m['id']}',
        title: _cleanTitle((m['title'] ?? '(no title)').toString()),
        durationSec: len.toInt(),
        poster: ((m['default_thumb'] as Map?)?['src'] ?? '').toString(),
        source: 'eporner',
        pageUrl: (m['url'] ?? 'https://www.eporner.com/embed/${m['id']}/').toString(),
        keywords: keywords,
        views: ((m['views'] ?? 0) as num).toInt(),
        publishedAtMs: publishedAtMs,
      );
    }).toList();
  }

  Future<SourceResult> _fetchPage(String query, int page, {int perPage = 100}) async {
    final uri = Uri.parse('https://www.eporner.com/api/v2/video/search/'
        '?query=${Uri.encodeComponent(query)}&per_page=$perPage&page=$page&format=json');
    final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    final json = jsonDecode(_decodeBody(res)) as Map<String, dynamic>;
    final vids = (json['videos'] ?? []) as List;
    return SourceResult(sourceId: id, sourceName: name, items: parseVideos(vids));
  }

  @override
  Future<SourceResult> search(String query) async {
    // 之前是 5 页串行取：每页 1–3 秒，5 页经常超过搜索服务的 8 秒总超时，
    // 第一轮永远报“超时（8秒）”，只能靠后台重试——用户截图 2 就是这么来的。
    // 现在 5 页并行取，总耗时约等于最慢的一页；个别页失败不拖累其他页。
    try {
      const perPage = 100;
      const maxPages = 5;
      final pages = await Future.wait(
        List.generate(maxPages, (i) => _fetchPage(query, i + 1, perPage: perPage).then((r) => r.items).catchError((_) => <VideoItem>[])),
      );
      final out = pages.expand((e) => e).toList();
      return SourceResult(sourceId: id, sourceName: name, items: out);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    try {
      return await _fetchPage(query, page);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async {
    try {
      final uri = Uri.parse('https://www.eporner.com/api/v2/video/search/'
          '?query=&per_page=100&page=1&order=most-popular&format=json');
      final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
      final json = jsonDecode(_decodeBody(res)) as Map<String, dynamic>;
      final vids = (json['videos'] ?? []) as List;
      return SourceResult(sourceId: id, sourceName: name, items: parseVideos(vids));
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }
}

/// ---------- 2. Rule34Video：搜索页 HTML 解析，详情页有 master.m3u8 ----------

class Rule34VideosSource implements Source {
  static const _base = 'https://rule34-videos.com';
  @override
  String get id => 'rule34videos';
  @override
  String get name => 'Rule34Video';

  @override
  bool get webViewOnly => false;

  @override
  String webSearchUrl(String query) =>
      'https://rule34-videos.com/search/?q=${Uri.encodeComponent(query)}';

  @override
  String get webHomeUrl => 'https://rule34-videos.com/';

  /// 供单元测试直接验：搜索页 HTML -> 条目。
  static List<VideoItem> parseSearchHtml(String html) {
    final out = <VideoItem>[];
    final re = RegExp(r'''<a[^>]+href=(?:"(\/video\/[^"]+)"|(\/video\/[^>\s]+))[^>]*>([\s\S]*?)<\/a>''');
    for (final m in re.allMatches(html)) {
      if (out.length >= 100) break;
      final href = m.group(1) ?? m.group(2) ?? '';
      final inner = m.group(3) ?? '';
      final alt = _first(RegExp(r'alt="([^"]+)"'), inner);
      final thumbs = _first(RegExp(r'data-thumbnails=([^ >]+)'), inner);
      var poster = '';
      if (thumbs != null) {
        // 真站的 data-thumbnails 通常不加引号；加了引号的先去掉首尾引号。
        final t = thumbs.split(',').first.replaceAll('"', '').replaceAll("'", '');
        final candidate = t.startsWith('http') ? t : _base + t;
        if (_isRealPoster(candidate)) poster = candidate;
      }
      if (poster.isEmpty) poster = _pickPoster(inner, _base);
      final durText = _first(RegExp(r'(\d+:\d{2}(?::\d{2})?)'), inner) ?? '';
      final text = _stripTags(inner);
      out.add(VideoItem(
        id: 'r34-$href',
        title: _cleanTitle(alt ?? (text.isEmpty ? href : text.substring(0, text.length > 80 ? 80 : text.length))),
        durationSec: _parseDuration(durText),
        poster: poster,
        source: 'rule34videos',
        pageUrl: _base + href,
        keywords: [if (durText.isNotEmpty) durText],
      ));
    }
    return out;
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final uri = Uri.parse('$_base/search/?q=${Uri.encodeComponent(query)}');
      final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) {
        throw HttpException('被拦了（HTTP ${res.statusCode}），去内置浏览器看');
      }
      return SourceResult(sourceId: id, sourceName: name, items: parseSearchHtml(_decodeBody(res)));
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    try {
      final uri = Uri.parse('$_base/search/?q=${Uri.encodeComponent(query)}&page=$page');
      final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) {
        throw HttpException('被拦了（HTTP ${res.statusCode}），去内置浏览器看');
      }
      return SourceResult(sourceId: id, sourceName: name, items: parseSearchHtml(_decodeBody(res)));
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async {
    try {
      final res = await http.get(Uri.parse('$_base/'), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) {
        throw HttpException('被拦了（HTTP ${res.statusCode}），去内置浏览器看');
      }
      return SourceResult(sourceId: id, sourceName: name, items: parseSearchHtml(_decodeBody(res)));
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }
}

/// ---------- 3. Niacg：搜索页解析；详情页有 xunge mp4，必须带 Referer ----------
/// 注意（2026-11-09 Dart 实测，根因已钉死）：niacg 的 WAF 按 TLS 指纹拦请求——
/// 同一台 VM 上 curl（OpenSSL）能拿到 302→200、结果页 12 条，Dart 的
/// package:http（BoringSSL）直接 403、甚至连接被掐断；手机上同样是 Dart，
/// 所以手机搜也是 0 条——不是 VM 网络问题，也不是解析问题。
/// 更坑的是旧代码不判状态码：403 的拦截页解析出 0 条、error 还是 null，
/// 界面就显示成“0 条”，看起来像“确实没这个片”。
/// 修法：标 webViewOnly（系统 WebView 是 Chrome 指纹，能过验证），搜索走内置浏览器；
/// HTTP 入口保留但先判状态码，非 200 直接报“被拦了”，不静默 0 条。
/// 详情页 xunge mp4 是 2026-11-07 ffprobe 实测过的（20 条里 16 条真 1080p，
/// 带 Referer 返回 200/206），直链本身能抓到。
/// niacg 官方站本身没广告，拿不到直链时嵌官方播放器当备选。

class NiacgSource implements Source {
  @override
  String get id => 'niacg';
  @override
  String get name => 'Niacg';

  @override
  bool get webViewOnly => true;

  @override
  String webSearchUrl(String query) =>
      'https://www.niacg.com/e/search/?searchget=1&keyboard=${Uri.encodeComponent(query)}&show=title&classid=21';

  @override
  String get webHomeUrl => 'https://www.niacg.com/';

  /// 供单元测试直接验：搜索页 HTML -> 条目。
  static List<VideoItem> parseSearchHtml(String html) {
    final out = <VideoItem>[];
    final seen = <String>{};
    final re = RegExp(r'href="(\/showinfo-21-(\d+)-0\.html)"[^>]*title="([^"]*)"');
    for (final m in re.allMatches(html)) {
      if (out.length >= 100 || seen.contains(m.group(2))) continue;
      seen.add(m.group(2)!);
      out.add(VideoItem(
        id: 'niacg-${m.group(2)}',
        title: _cleanTitle(m.group(3) ?? ''),
        source: 'niacg',
        pageUrl: 'https://www.niacg.com${m.group(1)}',
      ));
    }
    return out;
  }

  Future<SourceResult> _fetchSearchPage(String query, int page) async {
    final uri = Uri.parse('https://www.niacg.com/e/search/?searchget=1&keyboard=${Uri.encodeComponent(query)}&show=title&classid=21&page=$page');
    final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      // WAF 拦截页别当成“没结果”：非 200 直接报错，界面会给内置浏览器入口。
      throw HttpException('被拦了（HTTP ${res.statusCode}），去内置浏览器看');
    }
    return SourceResult(sourceId: id, sourceName: name, items: parseSearchHtml(_decodeBody(res)));
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final out = <VideoItem>[];
      for (var p = 1; p <= 3; p++) {
        final got = await _fetchSearchPage(query, p);
        out.addAll(got.items);
        if (got.items.isEmpty) break;
      }
      return SourceResult(sourceId: id, sourceName: name, items: out);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    try {
      return await _fetchSearchPage(query, page);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async => const SourceResult(sourceId: 'niacg', sourceName: 'Niacg');
}

/// ---------- 4. Lianzu11：WordPress 站，?s= 搜索，详情页有直链 mp4 ----------
/// 注意（2026-11-09 Dart/curl 实测，根因已钉死）：lianzu11.com 现在挂了
/// Cloudflare“Just a moment”验证，纯 HTTP 请求一律 403——手机上同样 0 条，
/// 不是 VM 网络问题，也不是解析问题（2026-11-07 探针还通，是站方后来加的验证）。
/// 修法：标 webViewOnly，搜索走内置浏览器（Chrome 指纹能过验证）；
/// HTTP 入口保留但先判状态码，非 200 直接报错，不静默 0 条。

class Lianzu11Source implements Source {
  @override
  String get id => 'lianzu11';
  @override
  String get name => 'Lianzu11';

  @override
  bool get webViewOnly => true;

  @override
  String webSearchUrl(String query) =>
      'https://lianzu11.com/?s=${Uri.encodeComponent(query)}';

  @override
  String get webHomeUrl => 'https://lianzu11.com/';

  /// 供单元测试直接验：搜索页 HTML -> 条目。
  static List<VideoItem> parseSearchHtml(String html) {
    final out = <VideoItem>[];
    final seen = <String>{};
    final re = RegExp(r'''<a[^>]+href="(https:\/\/lianzu11\.com\/[^"]+)"[^>]*>([\s\S]*?)<\/a>''');
    for (final m in re.allMatches(html)) {
      if (out.length >= 100) break;
      final href = m.group(1)!;
      if (seen.contains(href) || RegExp(r'page\/|category|tag\/').hasMatch(href)) continue;
      final inner = m.group(2) ?? '';
      final text = _stripTags(inner);
      if (text.isEmpty) continue;
      seen.add(href);
      final durText = _first(RegExp(r'(\d+:\d{2}(?::\d{2})?)'), inner) ?? '';
      out.add(VideoItem(
        id: 'lianzu11-$href',
        title: _cleanTitle(text.length > 120 ? text.substring(0, 120) : text),
        durationSec: _parseDuration(durText),
        poster: _pickPoster(inner, 'https://lianzu11.com'),
        source: 'lianzu11',
        pageUrl: href,
      ));
    }
    return out;
  }

  Future<SourceResult> _fetchSearchPage(String query, int page) async {
    final uri = Uri.parse('https://lianzu11.com/${page > 1 ? 'page/$page/' : ''}?s=${Uri.encodeComponent(query)}');
    final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      throw HttpException('被拦了（HTTP ${res.statusCode}），去内置浏览器看');
    }
    return SourceResult(sourceId: id, sourceName: name, items: parseSearchHtml(_decodeBody(res)));
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final out = <VideoItem>[];
      for (var p = 1; p <= 3; p++) {
        final got = await _fetchSearchPage(query, p);
        out.addAll(got.items);
        if (got.items.isEmpty) break;
      }
      return SourceResult(sourceId: id, sourceName: name, items: out);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    try {
      return await _fetchSearchPage(query, page);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async {
    // WordPress 首页就是最新文章列表，同一套解析能用。
    try {
      final res = await http.get(Uri.parse('https://lianzu11.com/'), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
      return SourceResult(sourceId: id, sourceName: name, items: parseSearchHtml(_decodeBody(res)));
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }
}

/// ---------- 5/7/8. 通用搜索页解析源：XVideos / Pornhub / SpankBang ----------
/// （XHamster 单独一节走 JSON；niacg、lianzu11 也各有专节。）
/// 播的时候先试解析直链（xvideos 有 setVideoUrlHigh/Low/HLS，优先直链），
/// 解析不到就走官方播放器/官方页备选（有广告的站要如实说，见 StreamResolver）。

class HtmlSearchSource implements Source {
  final String _id;
  final String _name;
  final String Function(String q, int page) _url;
  final RegExp _linkRe;

  HtmlSearchSource(this._id, this._name, this._url, String linkPattern) : _linkRe = RegExp(linkPattern);

  @override
  String get id => _id;
  @override
  String get name => _name;

  @override
  bool get webViewOnly => false;

  @override
  String webSearchUrl(String query) => _url(query, 1);

  @override
  String get webHomeUrl => _baseOf(_url('', 1));

  /// 供单元测试直接验：搜索页 HTML -> 条目。
  /// 标题优先级：<a> 的 title 属性（pornhub）> img alt > aria-label（xhamster）
  /// > 锚点内文字（去掉开头的时长）> URL slug（xvideos 的标题在 slug 里）。
  /// 没真标题的不要（xhamster 占位符 ***、只有时长），宁可少几条也不拿空卡充数。
  /// 时长：锚点内先找；没有就往 </a> 后面 400 字符里找（xvideos 的时长在锚点外面的兄弟节点）。
  /// 画质：锚点里有 1080p/720p/4K 标记（xvideos 的 video-hd-mark）就记下来，供“只看 1080p+”过滤。
  List<VideoItem> parse(String html, String base) =>
      parseHtml(html, base, _id, _linkRe.pattern);

  static List<VideoItem> parseHtml(String html, String base, String sourceId, String linkPattern) {
    final out = <VideoItem>[];
    final seen = <String>{};
    final linkRe = RegExp(linkPattern);
    final re = RegExp('<a([^>]*href="(${linkRe.pattern})"[^>]*)>([\\s\\S]*?)<\\/a>');
    for (final m in re.allMatches(html)) {
      if (out.length >= 100) break;
      final openTag = m.group(1) ?? '';
      final href = m.group(2)!;
      if (seen.contains(href)) continue;
      seen.add(href);
      final inner = m.group(3) ?? '';
      var title = _decodeEntities(_first(RegExp(r'''title="([^"]+)"'''), openTag) ?? '');
      if (title.isEmpty) {
        title = _decodeEntities(_first(RegExp(r'''<img[^>]+alt="([^"]+)"'''), inner) ?? '');
      }
      if (title.isEmpty) {
        title = _decodeEntities(_first(RegExp(r'''aria-label="([^"]+)"'''), openTag) ?? '');
      }
      if (title.isEmpty) {
        var text = _stripTags(inner);
        // 去掉开头的时长（xhamster/pornhub 的锚点文字经常以“20:08”开头）
        // 和画质标记（xvideos 锚点里的 video-hd-mark "1080p" 不是标题）。
        text = text.replaceFirst(RegExp(r'^\d+:\d{2}(?::\d{2})?\s*'), '');
        text = text.replaceAll(RegExp(r'\b(2160p|1440p|1080p|720p|4K)\b'), '').trim();
        title = text.length > 120 ? text.substring(0, 120) : text;
      }
      if (title.isEmpty) {
        // URL slug 当标题：/video.xxx/chill_cherry_pov_footjob -> chill cherry pov footjob。
        // 只有 slug 里含 _ 或 -（分词符）时才用；纯 ID（xhamster 的 ccc333）不算标题。
        final slug = href.split('/').last.split('?').first;
        if (slug.contains('_') || slug.contains('-')) {
          title = Uri.decodeComponent(slug).replaceAll(RegExp(r'[_\-]+'), ' ').trim();
        }
      }
      title = _cleanTitle(title);
      if (_isJunkTitle(title)) continue;
      var durText = _first(RegExp(r'(\d+:\d{2}(?::\d{2})?)'), inner) ?? '';
      if (durText.isEmpty) {
        final tail = html.substring(m.end, (m.end + 400).clamp(0, html.length));
        durText = _first(RegExp(r'(\d+:\d{2}(?::\d{2})?)'), tail) ?? '';
        if (durText.isEmpty) {
          // "30 sec" -> 纯秒数；"5 min" -> 带 min 后缀（_parseDuration 会 x60）。
          final secs = _first(RegExp(r'(\d+)\s*sec'), tail);
          final mins = secs == null ? _first(RegExp(r'(\d+)\s*min'), tail) : null;
          if (secs != null) {
            durText = secs;
          } else if (mins != null) {
            durText = '$mins min';
          }
        }
      }
      final res = _first(RegExp(r'\b(2160p|1440p|1080p|720p|4K)\b'), inner) ?? '';
      out.add(VideoItem(
        id: '$sourceId-$href',
        title: title,
        durationSec: _parseDuration(durText),
        resolution: res,
        poster: _pickPoster(inner, base),
        source: sourceId,
        pageUrl: href.startsWith('http') ? href : base + href,
      ));
    }
    return out;
  }

  Future<SourceResult> _fetchPage(String query, int page) async {
    final url = _url(query, page);
    final res = await http.get(Uri.parse(url), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      throw HttpException('被拦了（HTTP ${res.statusCode}），去内置浏览器看');
    }
    return SourceResult(sourceId: id, sourceName: name, items: parse(_decodeBody(res), _baseOf(url)));
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final out = <VideoItem>[];
      for (var p = 1; p <= 3; p++) {
        final got = await _fetchPage(query, p);
        out.addAll(got.items);
        if (got.items.isEmpty) break;
      }
      return SourceResult(sourceId: id, sourceName: name, items: out);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    try {
      return await _fetchPage(query, page);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  String _baseOf(String url) {
    final u = Uri.parse(url);
    return '${u.scheme}://${u.host}';
  }

  @override
  Future<SourceResult> home() async => SourceResult(sourceId: id, sourceName: name);
}

/// ---------- 6. XHamster：搜索页嵌着 JSON（videoThumbProps），直接解析它 ----------
/// 静态 HTML 里大部分卡片是占位符（标题被打成 ***、没有 img），只有前十来张是真的；
/// 但同一页嵌的 videoThumbProps JSON 里有全部 46 条的真实标题、时长（秒）、封面、
/// 播放量、作者（landing.name）、是否超清。JSON 拿不到时退回通用锚点解析。
class XhamsterSource implements Source {
  @override
  String get id => 'xhamster';
  @override
  String get name => 'XHamster';

  @override
  bool get webViewOnly => false;

  @override
  String webSearchUrl(String query) =>
      'https://xhamster.com/search/${Uri.encodeComponent(query)}';

  @override
  String get webHomeUrl => 'https://xhamster.com/';

  /// 供单元测试直接验：搜索页 HTML 里的 videoThumbProps JSON -> 条目。
  static List<VideoItem> parseJson(String html) {
    final m = RegExp(r'"videoThumbProps":\[(.*?)\]\s*,\s*"', dotAll: true).firstMatch(html);
    if (m == null) return [];
    try {
      final list = jsonDecode('[${m.group(1)}]') as List;
      return list.map((e) {
        final v = e as Map<String, dynamic>;
        final landing = v['landing'] as Map<String, dynamic>?;
        return VideoItem(
          id: 'xhamster-${v['id']}',
          title: _cleanTitle((v['title'] ?? '').toString()),
          author: (landing?['name'] ?? '').toString(),
          durationSec: ((v['duration'] ?? 0) as num).toInt(),
          resolution: (v['isUHD'] == true) ? '2160p' : '',
          poster: (v['thumbURL'] ?? v['imageURL'] ?? '').toString(),
          source: 'xhamster',
          pageUrl: (v['pageURL'] ?? '').toString(),
          views: ((v['views'] ?? 0) as num).toInt(),
          publishedAtMs: ((v['created'] ?? 0) as num).toInt() * 1000,
        );
      }).where((v) => v.title.isNotEmpty && (v.pageUrl?.isNotEmpty ?? false)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<SourceResult> _fetchPage(String query, int page) async {
    final uri = Uri.parse('https://xhamster.com/search/${Uri.encodeComponent(query)}?pagenumber=$page');
    final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      throw HttpException('被拦了（HTTP ${res.statusCode}），去内置浏览器看');
    }
    var items = parseJson(_decodeBody(res));
    if (items.isEmpty) {
      // JSON 拿不到时退回通用锚点解析（只有前十来张是真的，标题可能是 *** 占位符）。
      items = HtmlSearchSource.parseHtml(_decodeBody(res), 'https://xhamster.com', 'xhamster', r'https:\/\/xhamster\.com\/videos\/[^"]+');
    }
    return SourceResult(sourceId: id, sourceName: name, items: items);
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final out = <VideoItem>[];
      for (var p = 1; p <= 3; p++) {
        final got = await _fetchPage(query, p);
        out.addAll(got.items);
        if (got.items.isEmpty) break;
      }
      return SourceResult(sourceId: id, sourceName: name, items: out);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    try {
      return await _fetchPage(query, page);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async => SourceResult(sourceId: id, sourceName: name);
}

/// 成人动漫源 Hanime1 / HanimeOne（hanime1.me / hanimeone.me，互为镜像）。
/// 接法按 Kazumi 规则 Hanime1.json v0.3（AzlmZ-del/Kazumi-Plus-Rules）：
/// 搜 `https://hanime1.me/search?query={词}&page={页}&genre=裏番`，
/// 结果是 href 里带 "watch" 的链接，标题在 div.title 或
/// div.home-rows-videos-title 里。
/// ！！！未验（2026-11-09，VM 实测）：hanime1.me 和 hanimeone.me 在 VM 下都被
/// Cloudflare 拦（403 "Just a moment..." / "Attention Required!"），
/// 没见过真实搜索页 HTML，上面这套解析是按 Kazumi 规则写的，没跑通过真页。
/// 所以这两个源标 webViewOnly：App 里 HTTP 搜不到就走内置浏览器（WebView），
/// 在视频页里嗅到 <video> 直链再切原生播放器；不要把没验过的写成已验。
/// 镜像说明（2026-11-09 用户反馈，第 20 条）：hanime1.me 和 hanimeone.me
/// 是同一个站的两个镜像域名，内容一样，不是两个站；hanime1.me 常被
/// Cloudflare 验证拦住，hanimeone.me 能进。App 里只当成一个站显示，
/// 一个打不开就自动切另一个（见 mirrorUrl / preferredHost）。
class HanimeSource implements Source {
  final String _host; // 'hanime1.me' 或 'hanimeone.me'
  HanimeSource(this._host);

  /// 两个镜像域名（同一站，内容一样）。
  static const hosts = ['hanime1.me', 'hanimeone.me'];

  /// 能进的那个镜像优先（2026-11-09 用户实测：hanimeone.me 可以，hanime1.me 不行）。
  static const preferredHost = 'hanimeone.me';

  static bool isHanimeHost(String host) => hosts.contains(host);

  /// 给定一个 hanime 地址，换成另一个镜像的同地址（路径/query 不变）；
  /// 不是 hanime 地址就原样返回。
  static String mirrorUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null || !isHanimeHost(u.host)) return url;
    final other = u.host == 'hanime1.me' ? 'hanimeone.me' : 'hanime1.me';
    return url.replaceFirst(u.host, other);
  }

  @override
  String get id => _host == 'hanime1.me' ? 'hanime1' : 'hanimeone';

  @override
  String get name => _host == 'hanime1.me' ? 'Hanime1 (hanime1.me)' : 'HanimeOne (hanimeone.me)';

  @override
  bool get webViewOnly => true;

  @override
  String get webHomeUrl => 'https://$_host/';

  /// 内置浏览器用的搜索地址（genre=裏番，只搜成人动漫）。
  @override
  String webSearchUrl(String query, [int page = 1]) =>
      'https://$_host/search?query=${Uri.encodeComponent(query)}&page=$page&genre=%E8%A3%8F%E7%95%AA';

  @override
  Future<SourceResult> search(String query) async => _fetch(webSearchUrl(query));

  @override
  Future<SourceResult> searchPage(String query, int page) async =>
      _fetch(webSearchUrl(query, page));

  @override
  Future<SourceResult> home() async => _fetch(webHomeUrl);

  Future<SourceResult> _fetch(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua, 'Referer': 'https://$_host/'})
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        // Cloudflare 验证页：App 的纯 HTTP 请求过不了，内置浏览器里才能开。
        return SourceResult(
            sourceId: id, sourceName: name, error: 'Cloudflare 验证拦住了（去内置浏览器里开）');
      }
      return SourceResult(
          sourceId: id, sourceName: name, items: parseSearchHtml(_decodeBody(res), _host, id));
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  /// 供单元测试直接验：搜索页 HTML -> 条目（按 Kazumi 规则结构写的假 HTML；
  /// 真页没见过，手机上若 HTTP 通了按此解析，否则走 WebView）。
  static List<VideoItem> parseSearchHtml(String html, String host, String sourceId) {
    final base = 'https://$host';
    final items = <VideoItem>[];
    final seen = <String>{};
    final anchorRe = RegExp(r'<a\b[^>]*href="([^"]*watch[^"]*)"[^>]*>(.*?)</a>',
        dotAll: true, caseSensitive: false);
    for (final m in anchorRe.allMatches(html)) {
      final pageUrl = _absUrl(m.group(1)!, base);
      if (!seen.add(pageUrl)) continue;
      final inner = m.group(2)!;
      // 标题：div.title / div.home-rows-videos-title 优先，其次锚点文字。
      var title = '';
      final titleDiv = RegExp(
              r'<div[^>]*class="[^"]*(?:title|home-rows-videos-title)[^"]*"[^>]*>(.*?)</div>',
              dotAll: true)
          .firstMatch(inner)
          ?.group(1);
      if (titleDiv != null && titleDiv.trim().isNotEmpty) {
        title = _decodeEntities(_stripTags(titleDiv));
      } else {
        title = _decodeEntities(_stripTags(inner));
      }
      title = _cleanTitle(title);
      if (_isJunkTitle(title)) continue;
      String poster = '';
      final img = RegExp(r'''<img[^>]+(?:data-src|src)=["']([^"']+)["']''')
          .firstMatch(inner)
          ?.group(1);
      if (img != null && img.isNotEmpty && _isRealPoster(img)) {
        poster = _absUrl(img, base);
      }
      final dur = _first(RegExp(r'(\d+:\d{2}(?::\d{2})?)'), inner);
      items.add(VideoItem(
        id: '$sourceId-$pageUrl',
        title: title,
        durationSec: dur == null ? 0 : _parseDuration(dur),
        poster: poster,
        source: sourceId,
        pageUrl: pageUrl,
      ));
    }
    return items;
  }
}

/// 全部 10 个在线源（默认全部启用；用户可以在“我的”里关掉某个源）。
/// 网站版（3D Video Library）的源列表是 10 个（见 server/src/sources.ts），
/// App 之前只有 8 个，缺 Hanime1 / HanimeOne 两个——2026-11-09 补上。
/// 注意：用户问“少了哪三个”是数错了——网站版 10 个减 App 8 个是 2 个，
/// lianzu11 那个 chips App 里本来就有，不是缺的。
List<Source> allSources() => [
      EpornerSource(),
      Rule34VideosSource(),
      NiacgSource(),
      Lianzu11Source(),
      // 成人动漫源（网站版有、App 之前缺的两个，2026-11-09 补上）：
      // Hanime1 / HanimeOne 要过 Cloudflare 验证，纯 HTTP 搜不到，
      // 走内置浏览器（WebView）+ 视频页嗅直链；见 HanimeSource 上的“未验”说明。
      HanimeSource('hanime1.me'),
      HanimeSource('hanimeone.me'),
      // xvideos 链接收紧成 /video.xxx/…：/videos-i-like 这种导航链接不再混进来。
      HtmlSearchSource('xvideos', 'XVideos',
          (q, p) => 'https://www.xvideos.com/?k=${Uri.encodeComponent(q)}&p=$p', r'\/video\.[^"]+'),
      XhamsterSource(),
      HtmlSearchSource('pornhub', 'Pornhub',
          (q, p) => 'https://www.pornhub.com/video/search?search=${Uri.encodeComponent(q)}&page=$p', r'\/view_video\.php\?viewkey=[^"]+'),
      HtmlSearchSource('spankbang', 'SpankBang',
          (q, p) => 'https://spankbang.com/s/${Uri.encodeComponent(q)}/$p/?o=all', r'\/video\/[^"]+'),
    ];
