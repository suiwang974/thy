import 'package:http/http.dart' as http;

import '../models/video_item.dart';

/// 播之前把“视频页”解析成“能直接播的直链”。
/// 规则（用户 2026-11-08 定：播放一律走直链、原生播）：
/// - 广告是源站页面和播放器周围加的，视频文件本身没广告；
///   直链播就没广告，开源站页面才有广告。所以能解析直链的一律直链播，
///   拿不到直链的才给“在源站看”当备选，备选页里有广告要如实说；
/// - r34 详情页里有 master.m3u8，无需 Referer；
/// - niacg 详情页里有 file.xunge.cyou mp4，播时必须带 Referer=详情页；
/// - lianzu11 详情页里有 mp4，无需 Referer；
/// - xvideos 详情页里有 setVideoUrlHigh/Low/HLS，优先直链；
/// - xhamster/pornhub/spankbang 暂无直链解析，返回 null，
///   播放页会显示官方播放器/官方页备选（有广告的站要如实说，见 sourcePageHasAds）。
/// - 通用规则（用户 2026-11-08 定）：所有 8 个源都这样——直链优先，
///   拿不到直链就走官方播放器/官方页；官方页有广告的要如实说，
///   没广告的（niacg、lianzu11）直接嵌官方播。
/// - 详情页预探直链时顺带把时长和封面一起探回来（og:image / og:video:duration），
///   别让用户点开再等：预探过的条目进 enrich()，播放页/短视频页直接用补全后的条目。
/// - 不是每个视频都能抓到直链，不要假装都能抓到：解析不到就返回 null，
///   播放页标官方播放器备选，不要硬播。
/// - 抓到的直链必须按真实时长核对（之前出过 Eporner 1 分钟带水印预览被当成正片）：
///   m3u8 在解析时就算播放列表总时长；mp4 没法在解析时算，靠播放器初始化后的
///   真实时长核对（播放页里做）。直链时长不到列表时长一半的，一律算预览，
///   不标成“能直接播”，自动切备选并写明是预览。
/// 解析过的直链进内存缓存；详情页打开时预探下一段的直链，点播放不用等。
class ResolvedStream {
  final String url;
  final Map<String, String> headers;
  /// 解析时核出来的真实时长（秒；只有 m3u8 能算出来，mp4 为 null）。
  final int? durationSec;
  /// true = 这条直链只是带水印的短预览（时长不到列表时长一半），不是正片。
  final bool isPreview;
  const ResolvedStream(this.url, [this.headers = const {}, this.durationSec, this.isPreview = false]);
}

class StreamResolver {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static final Map<String, ResolvedStream> _cache = {};

  /// 预探时补全的条目（封面/时长）：key 是条目 id。
  static final Map<String, VideoItem> _enriched = {};

  /// 官方页有没有广告（用户 2026-11-08 定，通用规则）：
  /// niacg、lianzu11 官方站本身没广告，拿不到直链时直接嵌官方播放器；
  /// xvideos、xhamster、pornhub、spankbang 的官方页有广告，备选时要如实说。
  /// eporner、rule34videos 是用户没点名的两家，按“有广告”算（都是带广告的站），
  /// 用户纠正就改。
  static const _adFreeSources = {'niacg', 'lianzu11'};
  static bool sourcePageHasAds(String sourceId) => !_adFreeSources.contains(sourceId);

  /// 拿预探时补全过的条目（封面/时长补上了就用补全版，没有就原样返回）。
  static VideoItem enrich(VideoItem item) => _enriched[item.id] ?? item;

  /// 供单元测试直接验：详情页 HTML 里的 og:image -> 封面地址（没有返回 null）。
  static String? parseOgImage(String html) {
    var m = RegExp(r'''<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']''').firstMatch(html);
    m ??= RegExp(r'''<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']''').firstMatch(html);
    final url = m?.group(1);
    if (url == null || url.isEmpty || url.startsWith('data:')) return null;
    return url;
  }

  /// 供单元测试直接验：详情页 HTML 里的 og:video:duration（或 JSON 里的 "duration"）-> 秒数。
  static int? parseOgDuration(String html) {
    var m = RegExp(r'''<meta[^>]+property=["']og:video:duration["'][^>]+content=["'](\d+)["']''').firstMatch(html);
    m ??= RegExp(r'''<meta[^>]+content=["'](\d+)["'][^>]+property=["']og:video:duration["']''').firstMatch(html);
    if (m != null) return int.tryParse(m.group(1)!);
    final j = RegExp(r'"duration"\s*:\s*"?(\d+)"?').firstMatch(html);
    return j == null ? null : int.tryParse(j.group(1)!);
  }

  /// 从详情页 HTML 里补封面/时长（只补缺的：没封面才补封面、没时长才补时长）。
  static void _enrichFromDetail(VideoItem item, String html) {
    final poster = item.poster.isEmpty ? parseOgImage(html) : null;
    final duration = item.durationSec <= 0 ? parseOgDuration(html) : null;
    if (poster == null && duration == null) return;
    if (_enriched.length > 100) _enriched.clear();
    _enriched[item.id] = item.copyWith(
      poster: poster ?? item.poster,
      durationSec: duration ?? item.durationSec,
    );
  }

  /// 预探直链（详情页打开时对下一段调用）：解析完进缓存，点播放时直接用，失败也不报错。
  static Future<void> prefetch(VideoItem item) async {
    try {
      await resolve(item);
    } catch (_) {}
  }

  static Future<ResolvedStream?> resolve(VideoItem item) async {
    final cached = _cache[item.id];
    if (cached != null) return cached;
    var resolved = await _resolveUncached(item);
    if (resolved != null) {
      resolved = await _verifyDuration(item, resolved);
      if (_cache.length > 50) _cache.clear();
      _cache[item.id] = resolved;
    }
    return resolved;
  }

  /// 直链时长核对：m3u8 在解析时就算播放列表总时长，和列表时长对不上就标预览。
  /// 列表时长未知（durationSec=0）时不核对；核不出来（拉不到播放列表）时也不误判，
  /// 交给播放页用播放器初始化后的真实时长再核一次。
  static Future<ResolvedStream> _verifyDuration(VideoItem item, ResolvedStream resolved) async {
    if (!resolved.url.contains('.m3u8')) return resolved;
    if (item.durationSec <= 0) return resolved;
    final actual = await _m3u8Duration(resolved.url);
    if (actual == null) return resolved;
    final preview = isPreviewDuration(listedSec: item.durationSec, actualSec: actual);
    return ResolvedStream(resolved.url, resolved.headers, actual, preview);
  }

  /// 预览判定（供单元测试直接验，也供播放页用播放器真实时长核对时复用）：
  /// 列表时长已知、真实时长已知、真实不到列表一半 -> 是预览。
  /// 比如列表 10 分钟、直链只有 1 分钟，就是 Eporner 那种带水印预览。
  static bool isPreviewDuration({required int listedSec, required int actualSec}) {
    return listedSec > 0 && actualSec > 0 && actualSec * 2 < listedSec;
  }

  /// 供单元测试直接验：媒体播放列表正文 -> 总时长（秒，相加 #EXTINF）。
  /// 主播放列表（含 #EXT-X-STREAM-INF）返回 null，要先取变体再算。
  static int? parseM3u8Duration(String body) {
    if (body.contains('#EXT-X-STREAM-INF')) return null;
    var total = 0.0;
    var found = false;
    for (final m in RegExp(r'#EXTINF:([\d.]+)').allMatches(body)) {
      total += double.tryParse(m.group(1) ?? '') ?? 0;
      found = true;
    }
    return found ? total.round() : null;
  }

  /// 供单元测试直接验：主播放列表正文 -> 第一个变体播放列表的地址（相对地址原样返回）。
  static String? parseM3u8Variant(String masterBody) {
    final lines = masterBody.split('\n').map((e) => e.trim()).toList();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        for (var j = i + 1; j < lines.length; j++) {
          final u = lines[j];
          if (u.isNotEmpty && !u.startsWith('#')) return u;
        }
      }
    }
    return null;
  }

  /// 拉 m3u8 播放列表算总时长：主播放列表先跟变体再算。8 秒超时，失败返回 null（不误判）。
  static Future<int?> _m3u8Duration(String url) async {
    try {
      final res = await http.get(Uri.parse(url), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 8));
      final body = res.body;
      final direct = parseM3u8Duration(body);
      if (direct != null) return direct;
      final variant = parseM3u8Variant(body);
      if (variant == null) return null;
      final variantUrl = variant.startsWith('http') ? variant : Uri.parse(url).resolve(variant).toString();
      final res2 = await http.get(Uri.parse(variantUrl), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 8));
      return parseM3u8Duration(res2.body);
    } catch (_) {
      return null;
    }
  }

  /// 供单元测试直接验：xvideos 详情页 HTML -> 直链。
  /// 优先高清 mp4（setVideoUrlHigh），其次 HLS，再次低清 mp4；都没有返回 null。
  static String? parseXvideosDirectLink(String html) {
    final high = RegExp(r"""setVideoUrlHigh\(['"]([^'"]+)['"]\)""").firstMatch(html)?.group(1);
    if (high != null && high.isNotEmpty) return high;
    final hls = RegExp(r"""setVideoHLS\(['"]([^'"]+)['"]\)""").firstMatch(html)?.group(1);
    if (hls != null && hls.isNotEmpty) return hls;
    final low = RegExp(r"""setVideoUrlLow\(['"]([^'"]+)['"]\)""").firstMatch(html)?.group(1);
    if (low != null && low.isNotEmpty) return low;
    return null;
  }

  static Future<ResolvedStream?> _resolveUncached(VideoItem item) async {
    // 1. 条目自带直链：直接播。
    if (item.playable) {
      final headers = <String, String>{};
      if (item.referer != null && item.referer!.isNotEmpty) {
        headers['Referer'] = item.referer!;
      }
      return ResolvedStream(item.streamUrl!, headers);
    }
    final page = item.pageUrl;
    if (page == null || page.isEmpty) return null;
    // 2. 已经是直链地址本身。
    if (page.endsWith('.mp4') || page.contains('.m3u8')) {
      return ResolvedStream(page);
    }
    // 3. 按来源解析详情页。
    try {
      final res = await http.get(Uri.parse(page), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
      final html = res.body;
      // 预探直链的同时顺带补封面/时长（og:image / og:video:duration），别让用户点开再等。
      _enrichFromDetail(item, html);
      if (item.source == 'rule34videos') {
        final m = RegExp(r'https:\/\/r34content\.b-cdn\.net\/videos\/\d+\/master\.m3u8').firstMatch(html) ??
            RegExp(r'''https:\/\/[^"']+\/master\.m3u8''').firstMatch(html);
        if (m != null) return ResolvedStream(m.group(0)!);
      }
      if (item.source == 'niacg') {
        final m = RegExp(r'''https:\/\/file\.xunge\.cyou\/1080\/[^"' ]+\.mp4''').firstMatch(html);
        if (m != null) return ResolvedStream(m.group(0)!, {'Referer': page});
      }
      if (item.source == 'lianzu11') {
        final m = RegExp(r'''https:\/\/(?:media\.lianzu11\.com|66843\.gyujmnb\.net)\/[^"' ]+\.mp4''').firstMatch(html) ??
            RegExp(r'''https:\/\/[^"' ]+\.mp4''').firstMatch(html);
        if (m != null) return ResolvedStream(m.group(0)!);
      }
      if (item.source == 'eporner') {
        // Eporner 详情页：embed 页里找 mp4。
        final m = RegExp(r'''https:\/\/[^"' ]+\.mp4''').firstMatch(html);
        if (m != null) return ResolvedStream(m.group(0)!);
      }
      if (item.source == 'xvideos') {
        // xvideos 优先直链：高清 mp4 -> HLS -> 低清 mp4。
        final url = parseXvideosDirectLink(html);
        if (url != null) return ResolvedStream(url);
      }
    } catch (_) {
      // 解析失败就返回 null，播放页走“在源站看”。
    }
    return null;
  }
}
