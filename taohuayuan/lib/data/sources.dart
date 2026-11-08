import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/catalog.dart';
import '../models/video_item.dart';

/// 全部 9 个源：直接照 JS 插件（~/workspace/super-library/plugins/）逐条搬成 Dart。
/// 规则（用户 2026-11-07 定下的，一直沿用）：
/// - 有标题就收录，没封面也不丢，只显示文字卡；
/// - 热门词不能只返回 20 条，能翻页就翻页。

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 一个源的搜索结果：成功时 items；失败时 error（界面显示“该源暂不可用”，不炸掉整页）。
class SourceResult {
  final String sourceId;
  final String sourceName;
  final List<VideoItem> items;
  final String? error;
  const SourceResult({required this.sourceId, required this.sourceName, this.items = const [], this.error});
}

abstract class Source {
  String get id;
  String get name;
  Future<SourceResult> search(String query);
  Future<SourceResult> home();
}

/// ---------- 工具 ----------

String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

String? _first(RegExp re, String s) => re.firstMatch(s)?.group(1);

/// ---------- 1. Eporner：官方 JSON API，无需解析 HTML ----------

class EpornerSource implements Source {
  @override
  String get id => 'eporner';
  @override
  String get name => 'Eporner';

  /// 供单元测试直接验：把 Eporner API 返回的 videos 数组转成条目。
  static List<VideoItem> parseVideos(List vids) {
    return vids.map((v) {
      final m = v as Map<String, dynamic>;
      final len = (m['length_sec'] ?? 0) as num;
      return VideoItem(
        id: 'eporner-${m['id']}',
        title: (m['title'] ?? '(no title)').toString(),
        durationSec: len.toInt(),
        poster: ((m['default_thumb'] as Map?)?['src'] ?? '').toString(),
        source: 'eporner',
        pageUrl: (m['url'] ?? 'https://www.eporner.com/embed/${m['id']}/').toString(),
      );
    }).toList();
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      const perPage = 100;
      const maxPages = 5;
      final out = <VideoItem>[];
      for (var p = 1; p <= maxPages; p++) {
        final uri = Uri.parse('https://www.eporner.com/api/v2/video/search/'
            '?query=${Uri.encodeComponent(query)}&per_page=$perPage&page=$p&format=json');
        final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final vids = (json['videos'] ?? []) as List;
        out.addAll(parseVideos(vids));
        if (vids.length < perPage) break;
      }
      return SourceResult(sourceId: id, sourceName: name, items: out);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async {
    try {
      final uri = Uri.parse('https://www.eporner.com/api/v2/video/search/'
          '?query=&per_page=20&page=1&order=most-popular&format=json');
      final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
      final json = jsonDecode(res.body) as Map<String, dynamic>;
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
      final img = _first(RegExp(r'''<img[^>]+(?:data-src|src)="([^"]+)"'''), inner);
      var poster = '';
      if (thumbs != null) {
        // 真站的 data-thumbnails 通常不加引号；加了引号的先去掉首尾引号。
        final t = thumbs.split(',').first.replaceAll('"', '').replaceAll("'", '');
        poster = t.startsWith('http') ? t : _base + t;
      } else if (img != null) {
        poster = img.startsWith('http') ? img : _base + img;
      }
      final dur = _first(RegExp(r'(\d+:\d{2})'), inner);
      final text = _stripTags(inner);
      out.add(VideoItem(
        id: 'r34-$href',
        title: alt ?? (text.isEmpty ? href : text.substring(0, text.length > 80 ? 80 : text.length)),
        poster: poster,
        source: 'rule34videos',
        pageUrl: _base + href,
        keywords: [?dur],
      ));
    }
    return out;
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final uri = Uri.parse('$_base/search/?q=${Uri.encodeComponent(query)}');
      final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
      return SourceResult(sourceId: id, sourceName: name, items: parseSearchHtml(res.body));
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async {
    try {
      final res = await http.get(Uri.parse('$_base/'), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
      return SourceResult(sourceId: id, sourceName: name, items: parseSearchHtml(res.body));
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }
}

/// ---------- 3. Niacg：搜索页解析；详情页有 xunge mp4，必须带 Referer ----------

class NiacgSource implements Source {
  @override
  String get id => 'niacg';
  @override
  String get name => 'Niacg';

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
        title: m.group(3) ?? '',
        source: 'niacg',
        pageUrl: 'https://www.niacg.com${m.group(1)}',
      ));
    }
    return out;
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final out = <VideoItem>[];
      for (var p = 1; p <= 3; p++) {
        final uri = Uri.parse('https://www.niacg.com/e/search/?searchget=1&keyboard=${Uri.encodeComponent(query)}&show=title&classid=21&page=$p');
        final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
        final got = parseSearchHtml(res.body);
        out.addAll(got);
        if (got.isEmpty) break;
      }
      return SourceResult(sourceId: id, sourceName: name, items: out);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async => const SourceResult(sourceId: 'niacg', sourceName: 'Niacg');
}

/// ---------- 4. Lianzu11：WordPress 站，?s= 搜索，详情页有直链 mp4 ----------

class Lianzu11Source implements Source {
  @override
  String get id => 'lianzu11';
  @override
  String get name => 'Lianzu11';

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
      final img = _first(RegExp(r'''<img[^>]+(?:data-src|src)="([^"]+)"'''), inner);
      final text = _stripTags(inner);
      if (text.isEmpty) continue;
      seen.add(href);
      out.add(VideoItem(
        id: 'lianzu11-$href',
        title: text.length > 120 ? text.substring(0, 120) : text,
        poster: img ?? '',
        source: 'lianzu11',
        pageUrl: href,
      ));
    }
    return out;
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final out = <VideoItem>[];
      for (var p = 1; p <= 3; p++) {
        final uri = Uri.parse('https://lianzu11.com/${p > 1 ? 'page/$p/' : ''}?s=${Uri.encodeComponent(query)}');
        final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
        final got = parseSearchHtml(res.body);
        out.addAll(got);
        if (got.isEmpty) break;
      }
      return SourceResult(sourceId: id, sourceName: name, items: out);
    } catch (e) {
      return SourceResult(sourceId: id, sourceName: name, error: e.toString());
    }
  }

  @override
  Future<SourceResult> home() async => const SourceResult(sourceId: 'lianzu11', sourceName: 'Lianzu11');
}

/// ---------- 5-8. 通用搜索页解析源：XVideos / XHamster / Pornhub / SpankBang ----------
/// 这些站详情页的直链要从页面 JS 里抠，插件里只返回视频页；
/// 播的时候先试解析直链，解析不到就“在源站看”（App 内嵌网页打开）。

class _HtmlSearchSource implements Source {
  final String _id;
  final String _name;
  final String Function(String q, int page) _url;
  final RegExp _linkRe;

  _HtmlSearchSource(this._id, this._name, this._url, String linkPattern) : _linkRe = RegExp(linkPattern);

  @override
  String get id => _id;
  @override
  String get name => _name;

  /// 供单元测试直接验：搜索页 HTML -> 条目。
  List<VideoItem> parse(String html, String base) {
    final out = <VideoItem>[];
    final seen = <String>{};
    final re = RegExp('<a[^>]+href="(${_linkRe.pattern})"[^>]*>([\\s\\S]*?)<\\/a>');
    for (final m in re.allMatches(html)) {
      if (out.length >= 100) break;
      final href = m.group(1)!;
      if (seen.contains(href)) continue;
      seen.add(href);
      final inner = m.group(2) ?? '';
      final img = _first(RegExp(r'''<img[^>]+(?:data-src|src)="([^"]+)"'''), inner);
      final text = _stripTags(inner);
      final title = text.isEmpty ? href : (text.length > 120 ? text.substring(0, 120) : text);
      out.add(VideoItem(
        id: '$_id-$href',
        title: title,
        poster: img ?? '',
        source: _id,
        pageUrl: href.startsWith('http') ? href : base + href,
      ));
    }
    return out;
  }

  @override
  Future<SourceResult> search(String query) async {
    try {
      final out = <VideoItem>[];
      for (var p = 1; p <= 3; p++) {
        final res = await http.get(Uri.parse(_url(query, p)), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 25));
        final got = parse(res.body, _baseOf(_url(query, p)));
        out.addAll(got);
        if (got.isEmpty) break;
      }
      return SourceResult(sourceId: id, sourceName: name, items: out);
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

/// ---------- 9. 片库：本地目录搜索，瞬间出结果 ----------

class CatalogSource implements Source {
  @override
  String get id => 'catalog';
  @override
  String get name => '片库';

  @override
  Future<SourceResult> search(String query) async {
    final items = await Catalog.load();
    return SourceResult(sourceId: id, sourceName: name, items: Catalog.search(items, query));
  }

  @override
  Future<SourceResult> home() async {
    final items = await Catalog.load();
    return SourceResult(sourceId: id, sourceName: name, items: items);
  }
}

/// 全部源（默认全部启用；用户可以在“我的”里关掉某个源）。
List<Source> allSources() => [
      CatalogSource(),
      EpornerSource(),
      Rule34VideosSource(),
      NiacgSource(),
      Lianzu11Source(),
      _HtmlSearchSource('xvideos', 'XVideos',
          (q, p) => 'https://www.xvideos.com/?k=${Uri.encodeComponent(q)}&p=$p', r'\/video[^"]+'),
      _HtmlSearchSource('xhamster', 'XHamster',
          (q, p) => 'https://xhamster.com/search/${Uri.encodeComponent(q)}?pagenumber=$p', r'https:\/\/xhamster\.com\/videos\/[^"]+'),
      _HtmlSearchSource('pornhub', 'Pornhub',
          (q, p) => 'https://www.pornhub.com/video/search?search=${Uri.encodeComponent(q)}&page=$p', r'\/view_video\.php\?viewkey=[^"]+'),
      _HtmlSearchSource('spankbang', 'SpankBang',
          (q, p) => 'https://spankbang.com/s/${Uri.encodeComponent(q)}/$p/?o=all', r'\/video\/[^"]+'),
    ];
