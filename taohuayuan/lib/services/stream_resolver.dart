import 'dart:convert';

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
/// - 通用规则（用户 2026-11-08 定）：所有源都这样——直链优先，
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

/// 一个画质档位（全屏播放器的分辨率菜单用）：标签是真实分辨率
/// （能从地址里抠出来的就抠，比如 xvideos 的 video_360p.mp4 就是 360p，
/// 不要把 360p 写成“高清”骗人；抠不出来的才用站方叫法）。
class StreamVariant {
  final String label;
  final String url;
  final Map<String, String> headers;
  const StreamVariant(this.label, this.url, [this.headers = const {}]);
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
      // 解析出来的地址先过 sanity 检查：垃圾地址（r34 兜底正则的教训）
      // 直接当没解析到，走官方播放器，不拿去给播放器报错。
      if (!isSaneStreamUrl(resolved.url)) return null;
      resolved = await _verifyDuration(item, resolved);
      // eporner 签名地址约 2 小时过期还绑 IP，不进缓存：每次播都现算。
      if (item.source != 'eporner') {
        if (_cache.length > 50) _cache.clear();
        _cache[item.id] = resolved;
      }
    }
    return resolved;
  }

  /// Eporner 签名直链（供单元测试直接验 hash 转换 + xhr 解析）：
  /// ① embed 页取 EP.video.player.hash；② 四组 8 位 hex 转 36 进制拼起来；
  /// ③ 调 xhr/video 拿 sources.mp4 里 default=true 的那档（一般是 720p HD）。
  /// 任何一步失败返回 null（播放页自动嵌官方播放器，不硬播裸 gvideo 链）。
  static String convertEpornerHash(String hash32) {
    final buf = StringBuffer();
    for (var i = 0; i < 32; i += 8) {
      buf.write(_toBase36(int.parse(hash32.substring(i, i + 8), radix: 16)));
    }
    return buf.toString();
  }

  static String _toBase36(int n) {
    const digits = '0123456789abcdefghijklmnopqrstuvwxyz';
    if (n == 0) return '0';
    var out = '';
    var v = n;
    while (v > 0) {
      out = digits[v % 36] + out;
      v ~/= 36;
    }
    return out;
  }

  /// xhr/video 接口的 JSON -> 签名 mp4 直链（优先 default=true，其次 720p，
  /// 再次第一档）。duration 也从这里拿（xhr 自带真实时长）。
  static ({String url, int durationSec})? parseEpornerXhr(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final mp4 = (json['sources'] as Map?)?['mp4'] as Map?;
      if (mp4 == null || mp4.isEmpty) return null;
      // 注意：不要用 entries.firstWhere(..., orElse: ...)——jsonDecode 出来的
      // 是 _Map<String, dynamic>，firstWhere 的 orElse 在运行时会因为
      // MapEntry<dynamic, dynamic> 不是 MapEntry<String, dynamic> 的子类型
      // 而抛错（2026-11-09 实测踩坑）。手动循环最稳。
      String? best720;
      String? first;
      for (final e in mp4.entries) {
        final v = e.value as Map?;
        final src = v?['src']?.toString() ?? '';
        if (src.isEmpty) continue;
        first ??= src;
        if (v?['default'] == true) {
          final duration = (json['duration'] as num?)?.toInt() ?? 0;
          return (url: src, durationSec: duration);
        }
        if ((e.key as String).contains('720')) best720 ??= src;
      }
      final url = best720 ?? first ?? '';
      if (url.isEmpty) return null;
      final duration = (json['duration'] as num?)?.toInt() ?? 0;
      return (url: url, durationSec: duration);
    } catch (_) {
      return null;
    }
  }

  static Future<ResolvedStream?> _resolveEporner(VideoItem item) async {
    final vid = RegExp(r'eporner-([A-Za-z0-9]+)').firstMatch(item.id)?.group(1) ??
        RegExp(r'video-([A-Za-z0-9]+)').firstMatch(item.pageUrl ?? '')?.group(1) ??
        RegExp(r'embed/([A-Za-z0-9]+)').firstMatch(item.pageUrl ?? '')?.group(1);
    if (vid == null || vid.isEmpty) return null;
    try {
      final embedUrl = 'https://www.eporner.com/embed/$vid/';
      final embedRes = await http
          .get(Uri.parse(embedUrl), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 15));
      if (embedRes.statusCode != 200) return null;
      final hash = RegExp(r"""EP\.video\.player\.hash\s*=\s*['"]([0-9a-fA-F]{32})['"]""")
          .firstMatch(utf8.decode(embedRes.bodyBytes))
          ?.group(1);
      if (hash == null) return null;
      final xhrUrl = 'https://www.eporner.com/xhr/video/$vid'
          '?hash=${convertEpornerHash(hash)}&domain=www.eporner.com&embed=true&supportedFormats=hls,mp4';
      final xhrRes = await http
          .get(Uri.parse(xhrUrl), headers: {'User-Agent': _ua, 'Referer': embedUrl})
          .timeout(const Duration(seconds: 15));
      if (xhrRes.statusCode != 200) return null;
      final parsed = parseEpornerXhr(utf8.decode(xhrRes.bodyBytes));
      if (parsed == null) return null;
      // 各画质档位也缓存起来（全屏分辨率菜单用），key 是 720p/480p 这类标签。
      final all = parseEpornerXhrAll(utf8.decode(xhrRes.bodyBytes));
      if (all.isNotEmpty) {
        final variants = all.entries
            .map((e) => StreamVariant(e.key, e.value))
            .toList()
          ..sort((a, b) => _qualityRank(b.label).compareTo(_qualityRank(a.label)));
        _variantsCache[item.id] = variants;
      }
      // xhr 自带真实时长：不到列表一半就是预览，不标成“能直接播”。
      final preview = isPreviewDuration(listedSec: item.durationSec, actualSec: parsed.durationSec);
      return ResolvedStream(parsed.url, {}, parsed.durationSec, preview);
    } catch (_) {
      return null;
    }
  }

  /// 画质标签排档位高低用（720p > 480p > 360p > 240p；HLS 自适应放最前）。
  static int _qualityRank(String label) {
    final m = RegExp(r'(\d+)p').firstMatch(label);
    if (m != null) return int.parse(m.group(1)!);
    if (label.contains('HLS') || label.contains('自适应')) return 10000;
    if (label.contains('原画')) return 5000;
    return 0;
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
      final body = utf8.decode(res.bodyBytes);
      final direct = parseM3u8Duration(body);
      if (direct != null) return direct;
      final variant = parseM3u8Variant(body);
      if (variant == null) return null;
      final variantUrl = variant.startsWith('http') ? variant : Uri.parse(url).resolve(variant).toString();
      final res2 = await http.get(Uri.parse(variantUrl), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 8));
      return parseM3u8Duration(utf8.decode(res2.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  /// 供单元测试直接验：r34 详情页 HTML -> 直链。
  /// 实测（2026-11-09，curl 探针）：详情页里根本没有绝对地址的 master.m3u8，
  /// 只有两样真的东西——
  /// ① JSON-LD 里的 contentUrl：https://r34content.b-cdn.net/videos/{id}/360p.mp4，
  ///    HEAD 200、无需任何请求头，ffprobe 能读出真实时长（Chun-Li 那条 236.7 秒，
  ///    和列表写的 3:56 完全一致），优先拿它；
  /// ② 相对地址的 master.m3u8：/media/videos/{id}/master.m3u8，
  ///    拼成 https://rule34-videos.com/media/videos/{id}/master.m3u8 能拉到
  ///    含 720p/480p/360p/240p 变体的主播放列表，备选。
  /// 教训：之前那条 `https://[^"']+/master.m3u8` 的兜底正则会横跨整个
  /// 不加引号的 HTML、抓出几 KB 长的垃圾地址（从 canonical 链接一路吃到
  /// master.m3u8），播放器拿它去播就报 Source error——用户截图 1 就是这么来的。
  /// 所以：只认上面两种精确格式，再也不用“包含 master.m3u8 就行”的宽松匹配。
  /// r34 直链：优先相对地址的 master.m3u8（HLS，最高 720p，ExoPlayer 原生播），
  /// 其次 JSON-LD 的 contentUrl mp4（只有 360p——720p/480p mp4 直拼是 404，
  /// 2026-11-09 实测）。注意真站的属性大量不加引号（href=/media/...），
  /// JS 里用反引号（const b=`/media/...`），所以分隔符认引号/反引号/= 三种，
  /// 只认 /media/videos/{id}/master.m3u8 这种精确路径，不会横跨整页抓垃圾地址。
  static String? parseR34DirectLink(String html) {
    final rel = RegExp(r'''["'`=]\s*\/media\/videos\/(\d+)\/master\.m3u8''')
        .firstMatch(html)
        ?.group(1);
    if (rel != null) return 'https://rule34-videos.com/media/videos/$rel/master.m3u8';
    final mp4 = RegExp(r'https:\/\/r34content\.b-cdn\.net\/videos\/\d+\/\d+p\.mp4')
        .firstMatch(html)
        ?.group(0);
    if (mp4 != null && mp4.isNotEmpty) return mp4;
    return null;
  }

  /// 直链地址 sanity 检查：长度、空白、尖括号——几 KB 长的垃圾地址、
  /// 带空格或 < > 的地址一律不算直链（r34 兜底正则抓垃圾地址的教训）。
  static bool isSaneStreamUrl(String url) {
    if (url.isEmpty || url.length > 500) return false;
    if (url.contains(RegExp(r'\s'))) return false;
    if (url.contains('<') || url.contains('>')) return false;
    return url.startsWith('https://');
  }

  /// 重试用：清掉某条的解析缓存，下次重新解析详情页。
  static void clearCacheFor(String itemId) => _cache.remove(itemId);

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

  /// xvideos 详情页 HTML -> 全部画质档位（全屏分辨率菜单用）。
  /// 标签从地址里抠真实分辨率（video_360p.mp4 -> 360p）；抠不出来才用站方叫法。
  static List<StreamVariant> parseXvideosVariants(String html) {
    final out = <StreamVariant>[];
    String label(String url, String fallback) {
      final m = RegExp(r'video_(\d+)p').firstMatch(url);
      return m != null ? '${m.group(1)}p' : fallback;
    }

    final high = RegExp(r"""setVideoUrlHigh\(['"]([^'"]+)['"]\)""").firstMatch(html)?.group(1);
    if (high != null && high.isNotEmpty) out.add(StreamVariant(label(high, '高清'), high));
    final hls = RegExp(r"""setVideoHLS\(['"]([^'"]+)['"]\)""").firstMatch(html)?.group(1);
    if (hls != null && hls.isNotEmpty) out.add(StreamVariant('HLS 自适应', hls));
    final low = RegExp(r"""setVideoUrlLow\(['"]([^'"]+)['"]\)""").firstMatch(html)?.group(1);
    if (low != null && low.isNotEmpty) out.add(StreamVariant(label(low, '标清'), low));
    return out;
  }

  /// r34 详情页 HTML -> JSON-LD 的 360p mp4（只有 360p 是真文件，
  /// 720p/480p mp4 直拼是 404，见 parseR34DirectLink 的注释）。
  static String? parseR34Mp4(String html) {
    return RegExp(r'https:\/\/r34content\.b-cdn\.net\/videos\/\d+\/\d+p\.mp4')
        .firstMatch(html)
        ?.group(0);
  }

  /// eporner xhr/video 的 JSON -> 全部画质档位（key 是 720/480/360 这类数字或带 p）。
  /// 供单元测试直接验；_resolveEporner 里解析完会把档位缓存起来，全屏菜单直接用。
  static Map<String, String> parseEpornerXhrAll(String body) {
    final out = <String, String>{};
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final mp4 = (json['sources'] as Map?)?['mp4'] as Map?;
      if (mp4 == null) return out;
      for (final e in mp4.entries) {
        final v = e.value as Map?;
        final src = v?['src']?.toString() ?? '';
        if (src.isEmpty) continue;
        final key = (e.key as String).trim();
        out.addAll({key.contains('p') ? key : '${key}p': src});
      }
    } catch (_) {}
    return out;
  }

  /// HLS 主播放列表正文 -> 各变体播放列表（带分辨率标签；相对地址按 baseUrl 拼）。
  /// 供单元测试直接验；master 里没有变体（已是媒体播放列表）返回空。
  static List<StreamVariant> parseM3u8VariantList(String body, String baseUrl) {
    final out = <StreamVariant>[];
    final lines = body.split('\n').map((e) => e.trim()).toList();
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(lines[i]);
      final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i])?.group(1);
      for (var j = i + 1; j < lines.length; j++) {
        final u = lines[j];
        if (u.isEmpty || u.startsWith('#')) continue;
        final url = u.startsWith('http') ? u : Uri.parse(baseUrl).resolve(u).toString();
        final label = res != null
            ? '${res.group(2)}p'
            : (bw != null ? '${int.parse(bw) ~/ 1000}kbps' : '自适应');
        out.add(StreamVariant(label, url));
        break;
      }
    }
    return out;
  }

  static final Map<String, List<StreamVariant>> _variantsCache = {};

  /// 当前条目的全部画质档位（全屏分辨率菜单用）。
  /// - xvideos：详情页 High/Low/HLS 三档；
  /// - rule34videos：HLS 主列表里的变体 + 360p mp4 兜底；
  /// - eporner：xhr 返回的各档（解析直链时已缓存，没缓存就现算一次）；
  /// - niacg/lianzu11：只有一条 mp4，档位就是“原画”；
  /// - 其他源：没直链解析，返回空（菜单里只显示当前这一档）。
  static Future<List<StreamVariant>> variantsFor(VideoItem item) async {
    // eporner 的签名地址约 2 小时过期还绑 IP，不读缓存，每次现算。
    if (item.source != 'eporner') {
      final cached = _variantsCache[item.id];
      if (cached != null) return cached;
    }
    final out = <StreamVariant>[];
    try {
      if (item.source == 'xvideos') {
        final page = item.pageUrl;
        if (page != null && page.isNotEmpty) {
          final res = await http
              .get(Uri.parse(page), headers: {'User-Agent': _ua})
              .timeout(const Duration(seconds: 15));
          out.addAll(parseXvideosVariants(utf8.decode(res.bodyBytes)));
        }
      } else if (item.source == 'rule34videos') {
        final resolved = await resolve(item);
        if (resolved != null && resolved.url.contains('.m3u8')) {
          try {
            final res = await http
                .get(Uri.parse(resolved.url), headers: {'User-Agent': _ua})
                .timeout(const Duration(seconds: 8));
            out.addAll(parseM3u8VariantList(utf8.decode(res.bodyBytes), resolved.url));
          } catch (_) {}
          out.add(StreamVariant('HLS 自适应', resolved.url));
        }
        if (resolved != null) {
          // 360p mp4 兜底：详情页里 JSON-LD 的 contentUrl。
          final page = item.pageUrl;
          if (page != null && page.isNotEmpty) {
            try {
              final res = await http
                  .get(Uri.parse(page), headers: {'User-Agent': _ua})
                  .timeout(const Duration(seconds: 15));
              final mp4 = parseR34Mp4(utf8.decode(res.bodyBytes));
              if (mp4 != null && mp4 != resolved.url) {
                out.add(StreamVariant('360p', mp4));
              }
            } catch (_) {}
          }
        }
      } else if (item.source == 'eporner') {
        // 解析直链时已把各档缓存进 _variantsCache；没缓存说明还没解析过，
        // 先 resolve 一次（里面会缓存档位），再读缓存。
        await resolve(item);
        return _variantsCache[item.id] ?? const [];
      } else if (item.source == 'niacg' || item.source == 'lianzu11') {
        final resolved = await resolve(item);
        if (resolved != null) {
          out.add(StreamVariant('原画', resolved.url, resolved.headers));
        }
      }
    } catch (_) {}
    if (out.isNotEmpty) _variantsCache[item.id] = out;
    return out;
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
      final html = utf8.decode(res.bodyBytes);
      // 预探直链的同时顺带补封面/时长（og:image / og:video:duration），别让用户点开再等。
      _enrichFromDetail(item, html);
      if (item.source == 'rule34videos') {
        // 只认两种精确格式（见 parseR34DirectLink 的注释）：相对地址的
        // master.m3u8（HLS，最高 720p）优先，其次 JSON-LD 的 360p.mp4。
        // 宽松的“包含 master.m3u8 就行”已删，它会抓出几 KB 垃圾地址导致 Source error。
        final url = parseR34DirectLink(html);
        if (url != null) return ResolvedStream(url);
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
        // Eporner 直链必须走签名流程（裸 gvideo mp4 一律 403，不是直链）：
        // embed 页里的 EP.video.player.hash（32 位 hex）→ 四组 8 位 hex 各自
        // 16 进制转整数再转 36 进制拼起来 → 调 xhr/video 接口拿签名 mp4。
        // 这套是网站版 2026-11-07 逆向并用 curl 验过的，2026-11-09 VM 再验通：
        // 签名 720p Range 拉流 206、ffprobe 475.96 秒，和 API 的 475 秒一致。
        // 签名地址约 2 小时过期、还绑解析时的出口 IP——必须在点开播那一刻现算，
        // 不能跨会话缓存（resolve 里 eporner 不进缓存）；播不起来就自动切
        // App 内嵌官方播放器，不只给外跳按钮。
        return await _resolveEporner(item);
      }
      if (item.source == 'hanime1' || item.source == 'hanimeone') {
        // 未验（2026-11-09，VM 实测）：hanime1.me/hanimeone.me 都被 Cloudflare 403，
        // 没见过真实 watch 页。按常见结构找 mp4：<video>/<source src> 或直链。
        // HTTP 通不过时返回 null，播放页自动嵌官方播放器（WebView 能过验证）。
        final m = RegExp(r'''<source[^>]+src=["']([^"']+\.mp4[^"']*)["']''').firstMatch(html) ??
            RegExp(r'''<video[^>]+src=["']([^"']+\.mp4[^"']*)["']''').firstMatch(html) ??
            RegExp(r'''https:\/\/[^"' ]+\.mp4''').firstMatch(html);
        if (m != null) return ResolvedStream(m.group(1)!, {'Referer': page});
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
