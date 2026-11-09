import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import 'downloader.dart';

/// 网页嗅探（第 34 条，2026-11-09 用户纠正：不是“太弱”，是根本就没有）。
///
/// 之前 `_sniffVideo` 只认 <video>/<source> 里的 .mp4，r34 播的是 HLS
/// （blob:/m3u8），所以视频正在播也嗅不到。现在三路一起嗅：
/// ① DOM：<video>/<audio>/<source> 的 src/currentSrc（含 blob:）；
/// ② performance：页面网络请求里已经发出去的媒体地址
///    （mp4/m3u8/ts/webm——这是 SniffDL 嗅探的核心思路，
///    见 ~/workspace/sniffdl/src/video_downloader.py 的 browser_sniff：
///    Playwright 监听全部网络请求按扩展名过滤）；
/// ③ 页面 HTML 内正则扫 mp4/m3u8/ts 地址。
/// 搬不了的（WebView 硬限制，如实说）：
/// - Playwright 的 request/response 体拦截：webview_flutter 没有
///   shouldInterceptRequest 回调，拿不到响应体/响应头，只能看到
///   performance 里已经发出去的请求地址；
/// - blob: 地址本身下不了：要靠 performance 里同一视频的 m3u8/分片地址，
///   只有 blob、没找到底层地址时条目写明“浏览器内播放，拿不到地址”，
///   不假装能下；
/// - 加密 HLS（AES-128）下不了（没解密库），条目写明。
///
/// 分组（按 1DM“查找到文件”的样子）：
/// - m3u8：一个播放列表归一条，拉播放列表算总时长/分片数；
/// - .ts：没播放列表时按同一目录前缀归成一条（N 个分片），不几十条刷屏；
/// - mp4/webm：单条，Range 探大小；
/// - 缩略图预览（thumb/.t.mp4/preview）与广告域名一律排除。
class SniffedMedia {
  final String url;
  final String kind; // mp4 | m3u8 | ts | webm | blob
  final int? sizeBytes; // mp4 经 Range 探到；m3u8/ts 没有
  final int? durationSec; // m3u8 播放列表算出；DOM video.duration 有时也有
  final int segmentCount; // m3u8 分片数；ts 分组时是该组分片数
  final bool playableOnly; // 只有 blob：浏览器内播放，拿不到地址
  final String? note; // 下不了的原因（写明，不只说“下不了”）

  const SniffedMedia({
    required this.url,
    required this.kind,
    this.sizeBytes,
    this.durationSec,
    this.segmentCount = 0,
    this.playableOnly = false,
    this.note,
  });

  /// 能不能下：blob 下不了；m3u8 播放列表拉不到也下不了（不知道分片地址）。
  bool get downloadable => !playableOnly && note == null;

  String get sizeText {
    final n = sizeBytes;
    if (n == null || n <= 0) return '';
    if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(n / 1024).toStringAsFixed(0)} KB';
  }

  String get durationText {
    final s = durationSec;
    if (s == null || s <= 0) return '';
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  /// 清单里的一行说明：大小 · 时长 · 分片数（有的才写）。
  String get detailLine {
    final parts = <String>[];
    if (sizeText.isNotEmpty) parts.add(sizeText);
    if (durationText.isNotEmpty) parts.add(durationText);
    if (segmentCount > 0) parts.add('$segmentCount 个分片');
    if (kind == 'ts') parts.add('分段视频');
    if (note != null) parts.add(note!);
    return parts.join(' · ');
  }
}

class SniffResult {
  final List<SniffedMedia> items;
  final String pageTitle;
  const SniffResult(this.items, this.pageTitle);
}

class Sniffer {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 排除：缩略图预览、广告域名（和 StreamResolver.genericMediaScan 同一套词）。
  static bool isExcludedUrl(String url) {
    final l = url.toLowerCase();
    return l.contains('thumb') ||
        l.contains('.t.mp4') ||
        l.contains('preview') ||
        l.contains('googletag') ||
        l.contains('doubleclick') ||
        l.contains('googleads') ||
        l.contains('adsystem') ||
        l.contains('adservice');
  }

  /// 在 WebView 里跑 JS 嗅一遍，返回分组后的媒体清单 + 页面标题。
  /// pageUrl：相对地址拼绝对地址、下载时当 Referer 用。
  static Future<SniffResult> sniff(
    WebViewController controller, {
    required String pageUrl,
  }) async {
    var title = '';
    var candidates = <String>[];
    var domDurations = <String, double>{};
    try {
      final raw = await controller.runJavaScriptReturningResult(
        "(function(){var out={videos:[],resources:[],html:'',title:document.title};"
        "document.querySelectorAll('video,audio').forEach(function(v){"
        "var src=v.currentSrc||v.src||'';"
        "if(src)out.videos.push({src:src,duration:v.duration||0});"
        "v.querySelectorAll('source').forEach(function(s){"
        "if(s.src)out.videos.push({src:s.src,duration:v.duration||0});});});"
        "try{performance.getEntriesByType('resource').forEach(function(r){"
        "var u=r.name||'';"
        "if(/\\.(mp4|m3u8|ts|webm|mov)(\\?|#|\$)/i.test(u)||u.indexOf('blob:')===0)"
        "out.resources.push(u);});}catch(e){}"
        "var h=document.documentElement?document.documentElement.outerHTML:'';"
        "out.html=h.slice(0,400000);"
        "return JSON.stringify(out);})()",
      );
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      title = (decoded['title'] ?? '').toString();
      final videos = (decoded['videos'] as List?) ?? [];
      for (final v in videos) {
        final m = v as Map<String, dynamic>;
        final src = (m['src'] ?? '').toString();
        if (src.isEmpty) continue;
        candidates.add(src);
        final d = (m['duration'] as num?)?.toDouble() ?? 0;
        if (d > 0 && d.isFinite) domDurations[src] = d;
      }
      final resources = (decoded['resources'] as List?) ?? [];
      for (final r in resources) {
        candidates.add(r.toString());
      }
      final html = (decoded['html'] ?? '').toString();
      candidates.addAll(_scanHtmlForMedia(html));
    } catch (_) {
      // 嗅不到就返回空清单，不打扰浏览。
    }
    final items = await groupAndEnrich(
      candidates: candidates,
      domDurations: domDurations,
      pageUrl: pageUrl,
    );
    return SniffResult(items, title);
  }

  /// 页面 HTML 内正则扫媒体地址（绝对 + 相对地址都认）。
  static List<String> _scanHtmlForMedia(String html) {
    final out = <String>[];
    final re = RegExp(
        r'''(?:https?:)?//[^"'<>\s\\]+?\.(?:mp4|m3u8|ts|webm)(?:\?[^"'<>\s\\]*)?''',
        caseSensitive: false);
    for (final m in re.allMatches(html)) {
      out.add(m.group(0)!);
    }
    final rel = RegExp(
        r'''["'][^"'<>\s]*?/[^"'<>\s]*?\.(?:mp4|m3u8|ts)(?:\?[^"'<>\s]*)?["']''',
        caseSensitive: false);
    for (final m in rel.allMatches(html)) {
      var u = m.group(0)!;
      u = u.substring(1, u.length - 1); // 去掉两边引号
      out.add(u);
    }
    return out;
  }

  /// 候选地址 -> 分组后的媒体清单（纯逻辑 + 联网补信息）。
  /// fetchText 可注入（单元测试用假播放列表，不真联网）。
  static Future<List<SniffedMedia>> groupAndEnrich({
    required List<String> candidates,
    Map<String, double> domDurations = const {},
    required String pageUrl,
    Future<String> Function(String url)? fetchText,
  }) async {
    final fetch = fetchText ??
        (String u) async {
          final res = await http
              .get(Uri.parse(u), headers: {
                'User-Agent': _ua,
                'Referer': pageUrl,
              })
              .timeout(const Duration(seconds: 8));
          if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
          return utf8.decode(res.bodyBytes);
        };
    // 1) 归一化 + 去重 + 排除。
    final seen = <String>{};
    final urls = <String>[];
    for (final raw in candidates) {
      var u = raw.trim();
      if (u.isEmpty) continue;
      if (u.startsWith('//')) u = 'https:$u';
      if (!u.startsWith('http') && !u.startsWith('blob:')) {
        try {
          u = Uri.parse(pageUrl).resolve(u).toString();
        } catch (_) {
          continue;
        }
      }
      if (isExcludedUrl(u)) continue;
      if (!seen.add(u)) continue;
      urls.add(u);
    }
    // 2) 分组。
    final m3u8s = <String>[];
    final files = <String>[]; // mp4/webm/mov
    final tsGroups = <String, List<String>>{}; // 目录前缀 -> 分片地址
    var hasBlob = false;
    for (final u in urls) {
      final lower = u.toLowerCase().split('?').first;
      if (u.startsWith('blob:')) {
        hasBlob = true;
      } else if (lower.endsWith('.m3u8')) {
        m3u8s.add(u);
      } else if (lower.endsWith('.mp4') ||
          lower.endsWith('.webm') ||
          lower.endsWith('.mov')) {
        files.add(u);
      } else if (lower.endsWith('.ts')) {
        final prefix = u.substring(0, u.lastIndexOf('/'));
        (tsGroups[prefix] ??= []).add(u);
      }
    }
    final out = <SniffedMedia>[];
    // 3) m3u8：拉播放列表算总时长/分片数（主播放列表先挑最高变体）。
    for (final u in m3u8s) {
      try {
        var body = await fetch(u);
        if (body.contains('#EXT-X-STREAM-INF')) {
          final variant = DownloadManager.pickHlsVariant(body, u);
          if (variant != null) body = await fetch(variant);
        }
        final (dur, count) = parseM3u8Durations(body);
        out.add(SniffedMedia(
          url: u,
          kind: 'm3u8',
          durationSec: dur > 0 ? dur : _domDuration(domDurations, u),
          segmentCount: count,
        ));
      } catch (_) {
        out.add(SniffedMedia(
          url: u,
          kind: 'm3u8',
          durationSec: _domDuration(domDurations, u),
          note: '播放列表拉不到，下不了，只能在线播',
        ));
      }
    }
    // 4) mp4/webm：Range 探大小（并行）。
    final sizes = await Future.wait(files.map((u) async {
      try {
        final p = await DownloadManager.probeRange(u, {'Referer': pageUrl});
        return p.totalBytes > 0 ? p.totalBytes : null;
      } catch (_) {
        return null;
      }
    }));
    for (var i = 0; i < files.length; i++) {
      final u = files[i];
      final lower = u.toLowerCase().split('?').first;
      out.add(SniffedMedia(
        url: u,
        kind: lower.endsWith('.webm')
            ? 'webm'
            : lower.endsWith('.mov')
                ? 'mp4'
                : 'mp4',
        sizeBytes: sizes[i],
        durationSec: _domDuration(domDurations, u),
      ));
    }
    // 5) ts 分组：同一目录前缀归一条。
    for (final e in tsGroups.entries) {
      out.add(SniffedMedia(
        url: e.value.first,
        kind: 'ts',
        segmentCount: e.value.length,
      ));
    }
    // 6) blob：页里 <video> 的 currentSrc 是 blob:，说明有视频在浏览器里播，
    // 但 blob 地址本身下不了——只要出现了就单列一条，写明拿不到地址，
    // 不管有没有找到其他可下地址（用户要知道在播的这条能不能下）。
    if (hasBlob) {
      out.add(const SniffedMedia(
        url: 'blob:',
        kind: 'blob',
        playableOnly: true,
        note: '浏览器内播放，拿不到地址，下不了',
      ));
    }
    // 排序：m3u8/mp4 在前（最可能是正片），ts 分组在后，blob 最后。
    int rank(SniffedMedia m) {
      switch (m.kind) {
        case 'mp4':
        case 'webm':
          return 0;
        case 'm3u8':
          return 1;
        case 'ts':
          return 2;
        default:
          return 3;
      }
    }

    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  static int? _domDuration(Map<String, double> domDurations, String url) {
    final d = domDurations[url];
    if (d == null || d <= 0 || !d.isFinite) return null;
    return d.round();
  }

  /// 媒体播放列表正文 -> (总时长秒, 分片数)。供单元测试直接验。
  static (int, int) parseM3u8Durations(String body) {
    var total = 0.0;
    var count = 0;
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (!t.startsWith('#EXTINF:')) continue;
      final sec = double.tryParse(
              t.substring(8).split(',').first.trim()) ??
          0;
      total += sec;
      count++;
    }
    return (total.round(), count);
  }
}
