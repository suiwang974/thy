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
/// - pornhub 详情页里有 mediaDefinitions JSON：4 档 HLS master.m3u8
///   （1080/720/480/240）+ 一个 get_media 接口地址，调它拿签名 mp4
///   （2026-11-09 VM 验通：视频页 200、mediaDefinitions 5 条、get_media
///   返回 480p mp4 直链；签名约 2 小时过期还绑 IP，不进缓存）；
/// - xhamster 详情页里有直链：<noscript><video src> 是 720p 签名 mp4，
///   另有 video-nss.xhcdn.com 的 HLS master（_TPL_.h264.mp4.m3u8，
///   拉下来是含 720p 变体的主列表，媒体列表 302 个 .ts 分片；
///   2026-11-09 VM 验通：mp4 Range 拉流 206、ffprobe 1208 秒。
///   注意签名有使用次数限制（limit=3），同一地址反复探会 403——
///   所以解析现算、不缓存，播/下失败就重新解析拿新地址）；
/// - spankbang 在 VM 下被 Cloudflare 403，没见过真页：HTTP 解析不到就
///   返回失败原因，走 WebView 嗅探（不要假装解析到了）；
/// - 通用兜底：上面都没抓到时，对整页做一次通用 mp4/m3u8 扫描
///   （排除缩略图预览 .t.mp4 和 thumb 域名），抓到可用的就用；
/// - 解析不到就返回 null，但要把具体原因写进 lastFailureReason，
///   下载按钮/播放页按原因显示，不要只给一句“下不了”。
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

  /// 最近一次解析失败的具体原因（第 29 条：实在下不了要写明原因，
  /// 不要只给一句“下不了”）。resolve() 开始时清掉，失败时由各分支写；
  /// 下载按钮读它显示给用户。
  static String? lastFailureReason;

  /// 签名直链的源（地址约 2 小时过期、还绑 IP/有使用次数限制）：
  /// 解析现算，不进 _cache（eporner 的老规矩，pornhub/xhamster 同理）。
  static const _signedSources = {'eporner', 'pornhub', 'xhamster'};

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

  /// 第 42 条：视频页 HTML -> 发布者/上传者/频道名（+头像，有才填）。
  /// 每个源的字段不一样，逐源抠（2026-11-09 VM 实测过真页的才写死）：
  /// - pornhub：视频页 JSON 里 `"username":"..."`（全页唯一，和 viewkey 同一块 JSON）。
  /// - xvideos：`uploader-tag` 链接里的名字（去掉后面的粉丝数）。
  /// - xhamster：视频页 JSON 里 `"author":{"name":"...","thumbUrl":"..."}`。
  /// - rule34videos：JSON-LD `"author": "..."`。
  /// - niacg：`<title>` 里的 [作者] 前缀（站内标题都这么写）。
  /// - spankbang / lianzu11 / hanime：通用兜底（JSON-LD author、rel=author、
  ///   uploader/channel 链接）——VM 下没见过真页，抠不到返回 ''，不编一个。
  /// - eporner：API、embed 页、xhr 里都没有作者字段，视频页又有年龄验证墙，
  ///   HTTP 这条路拿不到作者（见 parseVideoAuthor 的注释）；作者只能等用户在
  ///   内置浏览器/官方播放器里打开视频页时由 Sniffer 从 DOM 里补。
  static ({String author, String authorAvatar}) parseVideoAuthor(String html, String source) {
    String clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (source == 'pornhub') {
      final m = RegExp(r'"username"\s*:\s*"([^"]+)"').firstMatch(html);
      if (m != null) {
        return (author: clean(m.group(1)!), authorAvatar: '');
      }
    }
    if (source == 'xvideos') {
      final m = RegExp(
        r'''<a[^>]+class="[^"]*uploader-tag[^"]*"[^>]*>(.*?)</a>''',
        dotAll: true,
      ).firstMatch(html);
      if (m != null) {
        var name = clean(m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), ' '));
        // 名字后面跟的粉丝数（"DarcyDark 58k"）去掉；名字本身带数字的不动
        // （只去尾部纯数字 token）。
        final parts = name.split(' ').where((w) => w.isNotEmpty).toList();
        while (parts.isNotEmpty && RegExp(r'^[\d.,]+[kKmM]?$').hasMatch(parts.last)) {
          parts.removeLast();
        }
        name = parts.join(' ');
        if (name.isNotEmpty) {
          return (author: name, authorAvatar: '');
        }
      }
    }
    if (source == 'xhamster') {
      final obj = RegExp(r'"author":\{[^}]{0,500}\}').firstMatch(html);
      if (obj != null) {
        final body = obj.group(0)!;
        final name = RegExp(r'"name"\s*:\s*"([^"]+)"').firstMatch(body)?.group(1);
        final thumb = RegExp(r'"thumbUrl"\s*:\s*"([^"]+)"').firstMatch(body)?.group(1);
        if (name != null && name.isNotEmpty) {
          return (
            author: clean(name),
            authorAvatar: (thumb ?? '').replaceAll(r'\/', '/'),
          );
        }
      }
    }
    if (source == 'rule34videos') {
      final m = RegExp(r'"author"\s*:\s*"([^"]+)"').firstMatch(html);
      if (m != null) {
        return (author: clean(m.group(1)!), authorAvatar: '');
      }
    }
    if (source == 'niacg') {
      final title = RegExp(r'<title>([^<]+)</title>').firstMatch(html)?.group(1) ?? '';
      final a = _niacgAuthorFromTitle(title);
      if (a.isNotEmpty) {
        return (author: a, authorAvatar: '');
      }
    }
    // 通用兜底：JSON-LD author（对象或字符串）、rel=author、WP 作者链接。
    final ld = RegExp(r'"author"\s*:\s*\{\s*"@type"[^}]{0,200}?"name"\s*:\s*"([^"]+)"')
            .firstMatch(html)
            ?.group(1) ??
        RegExp(r'"author"\s*:\s*"([^"]+)"').firstMatch(html)?.group(1);
    if (ld != null && ld.isNotEmpty) {
      return (author: clean(ld), authorAvatar: '');
    }
    final rel = RegExp(r'''<a[^>]+rel="author"[^>]*>([^<]+)</a>''').firstMatch(html)?.group(1);
    if (rel != null && rel.trim().isNotEmpty) {
      return (author: clean(rel), authorAvatar: '');
    }
    final wp = RegExp(
      r'''<[^>]+class="[^"]*(?:author-name|entry-author)[^"]*"[^>]*>([^<]+)<''',
    ).firstMatch(html)?.group(1);
    if (wp != null && wp.trim().isNotEmpty) {
      return (author: clean(wp), authorAvatar: '');
    }
    return (author: '', authorAvatar: '');
  }

  /// niacg 标题里的 [作者] 前缀（和 sources.dart 里的 _niacgAuthorFromTitle 同一套规则，
  /// 这里单抄一份：stream_resolver 不 import sources，避免循环依赖）。
  static String _niacgAuthorFromTitle(String title) {
    final m = RegExp(r'^\[([^\]]+)\]').firstMatch(title.trim());
    if (m == null) return '';
    final a = m.group(1)!.trim();
    if (RegExp(r'^(中文字幕|字幕|中文|4K|1080p|720p|无码|有码)$').hasMatch(a)) return '';
    return a;
  }

  /// 从详情页 HTML 里补封面/时长（只补缺的：没封面才补封面、没时长才补时长）。
  /// 第 42 条：顺带补作者（视频页找发布者；搜索时没抠到的这里补上）。
  static void _enrichFromDetail(VideoItem item, String html) {
    final poster = item.poster.isEmpty ? parseOgImage(html) : null;
    final duration = item.durationSec <= 0 ? parseOgDuration(html) : null;
    final author = item.author.isEmpty ? parseVideoAuthor(html, item.source) : null;
    if (poster == null &&
        duration == null &&
        (author == null || author.author.isEmpty)) {
      return;
    }
    if (_enriched.length > 100) {
      _enriched.clear();
    }
    _enriched[item.id] = item.copyWith(
      poster: poster ?? item.poster,
      durationSec: duration ?? item.durationSec,
      author: (author != null && author.author.isNotEmpty) ? author.author : item.author,
      authorAvatar: (author != null && author.authorAvatar.isNotEmpty)
          ? author.authorAvatar
          : item.authorAvatar,
    );
  }

  /// 预探直链（详情页打开时对下一段调用）：解析完进缓存，点播放时直接用，失败也不报错。
  static Future<void> prefetch(VideoItem item) async {
    try {
      await resolve(item);
    } catch (_) {}
  }

  static Future<ResolvedStream?> resolve(VideoItem item) async {
    lastFailureReason = null;
    final cached = _cache[item.id];
    if (cached != null) return cached;
    var resolved = await _resolveUncached(item);
    if (resolved != null) {
      // 解析出来的地址先过 sanity 检查：垃圾地址（r34 兜底正则的教训）
      // 直接当没解析到，走官方播放器，不拿去给播放器报错。
      if (!isSaneStreamUrl(resolved.url)) {
        lastFailureReason = '解析到的地址不正常，没法播，去内置浏览器里嗅探下载';
        return null;
      }
      resolved = await _verifyDuration(item, resolved);
      // 签名直链约 2 小时过期还绑 IP，不进缓存：每次播都现算。
      if (!_signedSources.contains(item.source)) {
        if (_cache.length > 50) _cache.clear();
        _cache[item.id] = resolved;
      }
    } else {
      lastFailureReason ??= '这个源站没给直链（页面里找不到视频地址），去内置浏览器里嗅探下载';
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

  /// Pornhub 直链（2026-11-09 VM 验通）：视频页 HTML 里有 mediaDefinitions
  /// JSON（4 档 HLS master + 1 条 get_media 接口地址）；视频页拿不到时
  /// 再抓 embed 页（里面有同一份 JSON）。get_media 接口返回 JSON 数组，
  /// 里面是签名 mp4 直链。签名约 2 小时过期还绑 IP，不进缓存。
  /// html 是调用方已经抓到的视频页正文（别重复抓一次，1.5MB 的页）。
  static Future<ResolvedStream?> _resolvePornhub(VideoItem item, String html) async {
    final page = item.pageUrl;
    if (page == null || page.isEmpty) {
      lastFailureReason = '这条没有视频页地址，下不了';
      return null;
    }
    var entries = parsePornhubMediaDefinitions(html);
    if (entries.isEmpty) {
      // 视频页没拿到 mediaDefinitions：再抓 embed 页（同一份 JSON）。
      final viewkey = RegExp(r'viewkey=([A-Za-z0-9]+)').firstMatch(page)?.group(1);
      if (viewkey != null) {
        try {
          final res = await http
              .get(Uri.parse('https://www.pornhub.com/embed/$viewkey'),
                  headers: {'User-Agent': _ua})
              .timeout(const Duration(seconds: 20));
          if (res.statusCode == 200) {
            entries = parsePornhubMediaDefinitions(utf8.decode(res.bodyBytes));
          }
        } catch (_) {}
      }
    }
    if (entries.isEmpty) {
      lastFailureReason = 'Pornhub 页里没找到 mediaDefinitions，去内置浏览器里嗅探下载';
      return null;
    }
    final variants = <StreamVariant>[];
    String? bestMp4;
    var bestMp4Q = -1;
    String? bestHls;
    var bestHlsQ = -1;
    for (final e in entries) {
      final q = int.tryParse(e.quality) ?? 0;
      if (e.format == 'mp4') {
        if (e.url.contains('/video/get_media')) {
          // get_media 是接口地址：调一次拿真 mp4。
          for (final m in await _fetchPornhubGetMedia(e.url)) {
            final mq = int.tryParse(m.quality) ?? 0;
            variants.add(StreamVariant('${m.quality}p', m.url));
            if (mq > bestMp4Q) {
              bestMp4Q = mq;
              bestMp4 = m.url;
            }
          }
        } else {
          variants.add(StreamVariant(e.quality.isEmpty ? 'mp4' : '${e.quality}p', e.url));
          if (q > bestMp4Q) {
            bestMp4Q = q;
            bestMp4 = e.url;
          }
        }
      } else if (e.format == 'hls') {
        variants.add(StreamVariant(e.quality.isEmpty ? 'HLS 自适应' : '${e.quality}p', e.url));
        if (q > bestHlsQ) {
          bestHlsQ = q;
          bestHls = e.url;
        }
      }
    }
    if (variants.isNotEmpty) {
      variants.sort((a, b) => _qualityRank(b.label).compareTo(_qualityRank(a.label)));
      _variantsCache[item.id] = variants;
    }
    final url = bestMp4 ?? bestHls;
    if (url == null) {
      lastFailureReason = 'Pornhub 只给了接口地址，没拿到真视频，去内置浏览器里嗅探下载';
      return null;
    }
    return ResolvedStream(url);
  }

  static Future<List<({String quality, String url})>> _fetchPornhubGetMedia(String apiUrl) async {
    try {
      final res = await http
          .get(Uri.parse(apiUrl), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      return parsePornhubGetMedia(utf8.decode(res.bodyBytes));
    } catch (_) {
      return [];
    }
  }

  /// XHamster 直链（2026-11-09 VM 验通）：<noscript><video src> 是 720p
  /// 签名 mp4（Range 拉流 206、ffprobe 1208 秒），另有 HLS master。
  /// 签名有使用次数限制（limit=3），同一地址反复探会 403——解析现算、
  /// 不缓存，播/下失败就重新解析拿新地址。mp4 优先（分段下载快），
  /// 没有才用 HLS。html 是调用方已经抓到的视频页正文。
  static Future<ResolvedStream?> _resolveXhamster(VideoItem item, String html) async {
    final page = item.pageUrl;
    if (page == null || page.isEmpty) {
      lastFailureReason = '这条没有视频页地址，下不了';
      return null;
    }
    final links = parseXhamsterDirectLinks(html);
    final variants = <StreamVariant>[];
    if (links.mp4 != null) {
      final q = RegExp(r'(\d+)p\.h264\.mp4').firstMatch(links.mp4!)?.group(1);
      variants.add(StreamVariant(q == null ? 'mp4' : '${q}p', links.mp4!));
    }
    if (links.hls != null) {
      final q = RegExp(r'multi=\d+x(\d+)').firstMatch(links.hls!)?.group(1);
      variants.add(StreamVariant(q == null ? 'HLS 自适应' : '${q}p', links.hls!));
    }
    if (variants.isNotEmpty) _variantsCache[item.id] = variants;
    final url = links.mp4 ?? links.hls;
    if (url == null) {
      lastFailureReason = 'XHamster 这页是动态加载的，HTML 里没有视频地址，去内置浏览器里嗅探下载';
      return null;
    }
    // 签名 mp4 绑 IP：播/下时带 Referer=视频页。
    return ResolvedStream(url, {'Referer': page});
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
  /// 列表时长已知、真实时长已知、真实不到列表一半、且真实本身很短
  /// （<= 5 分钟）-> 是预览。比如列表 10 分钟、直链只有 1 分钟，
  /// 就是 Eporner 那种带水印预览。
  /// 第 37 条：15 分钟的“实际”不可能是预览——那是列表时长写错了
  /// （把图片尺寸 320:180 当成 320:18），不能因为列表错就把正片当预览。
  static bool isPreviewDuration({required int listedSec, required int actualSec}) {
    return listedSec > 0 && actualSec > 0 && actualSec <= 300 && actualSec * 2 < listedSec;
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

  /// 从 HTML 里按 key 抠出一个 JSON 数组（括号计数，跳过字符串里的括号）：
  /// pornhub 的 mediaDefinitions 就是这么嵌在页里的（1.5MB 的页，正则
  /// 非贪婪匹配会在第一个 `", "` 处截断，拿不到完整数组——2026-11-09 实测踩坑）。
  /// 供单元测试直接验。
  static String? extractJsonArray(String html, String key) {
    final ki = html.indexOf(key);
    if (ki < 0) return null;
    var i = html.indexOf('[', ki);
    if (i < 0) return null;
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var k = i; k < html.length; k++) {
      final c = html[k];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == '\\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
      } else {
        if (c == '"') {
          inStr = true;
        } else if (c == '[') {
          depth++;
        } else if (c == ']') {
          depth--;
          if (depth == 0) return html.substring(i, k + 1);
        }
      }
    }
    return null;
  }

  /// pornhub mediaDefinitions JSON 数组 -> 各档位（format/quality/videoUrl）。
  /// 供单元测试直接验（fixture 是真页上抠下来的数组原文，5 条：
  /// 1080/720/480/240 四档 HLS master + 1 条 get_media 接口地址）。
  static List<({String format, String quality, String url})> parsePornhubMediaDefinitions(String html) {
    final raw = extractJsonArray(html, '"mediaDefinitions"');
    if (raw == null) return [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr
          .map((e) {
            final m = e as Map<String, dynamic>;
            return (
              format: (m['format'] ?? '').toString(),
              quality: (m['quality'] ?? '').toString(),
              url: (m['videoUrl'] ?? '').toString(),
            );
          })
          .where((e) => e.url.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// pornhub get_media 接口返回的 JSON 数组 -> mp4 直链（带画质）。
  /// 供单元测试直接验。
  static List<({String quality, String url})> parsePornhubGetMedia(String body) {
    try {
      final arr = jsonDecode(body) as List;
      return arr
          .map((e) {
            final m = e as Map<String, dynamic>;
            return (
              quality: (m['quality'] ?? '').toString(),
              url: (m['videoUrl'] ?? '').toString(),
            );
          })
          .where((e) => e.url.isNotEmpty && e.url.contains('.mp4'))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// xhamster 详情页 HTML -> 直链（mp4 + HLS master）。
  /// mp4 在 <noscript><video src> 里（720p 签名 mp4）；HLS 在
  /// video-nss.xhcdn.com 的 _TPL_.h264.mp4.m3u8。
  /// videoThumbProps 是相关推荐列表，不是本片，别拿它当本片地址。
  /// 缩略图预览（thumb-*.xhcdn.com / .t.mp4）一律排除——那是几秒的预览，
  /// 不是正片。供单元测试直接验。
  static ({String? mp4, String? hls}) parseXhamsterDirectLinks(String html) {
    String? mp4;
    // 先认 <noscript><video src>（最准：就是本片的播放地址）。
    for (final n in RegExp(r'<noscript>(.*?)</noscript>', dotAll: true).allMatches(html)) {
      final m = RegExp(r'''<video[^>]+src=["']([^"']+)["']''').firstMatch(n.group(1) ?? '');
      final u = m?.group(1);
      if (u != null && u.contains('.xhcdn.com') && u.contains('.mp4')) {
        mp4 = u;
        break;
      }
    }
    // 没 noscript 时退回全页找（排除 thumb 预览）。
    mp4 ??= RegExp(r'''https://video[0-9]*\.xhcdn\.com[^"'\s\\]*\.h264\.mp4''')
        .allMatches(html)
        .map((m) => m.group(0)!)
        .where((u) => !u.contains('thumb') && !u.contains('.t.mp4'))
        .firstOrNull;
    final hls = RegExp(r'''https://video-nss\.xhcdn\.com[^"'\s\\]*\.m3u8''')
        .firstMatch(html)
        ?.group(0);
    return (mp4: mp4, hls: hls);
  }

  /// 通用兜底扫描：整页找 mp4/m3u8 直链（排除缩略图预览与广告域名）。
  /// 供单元测试直接验；spankbang 这类没专属分支的源靠它捡漏。
  static String? genericMediaScan(String html) {
    final re = RegExp(r'''https://[^"'\s\\<>]+\.(?:mp4|m3u8)(?:\?[^"'\s\\<>]*)?''');
    for (final m in re.allMatches(html)) {
      var u = m.group(0)!.replaceAll(r'\/', '/');
      final lower = u.toLowerCase();
      if (lower.contains('thumb') ||
          lower.contains('.t.mp4') ||
          lower.contains('preview') ||
          lower.contains('googletag') ||
          lower.contains('doubleclick')) {
        continue;
      }
      if (!isSaneStreamUrl(u)) continue;
      return u;
    }
    return null;
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
  /// - pornhub：mediaDefinitions 各档（mp4 优先，HLS 其次）；
  /// - xhamster：noscript 的 720p mp4 + HLS master；
  /// - niacg/lianzu11：只有一条 mp4，档位就是“原画”；
  /// - 其他源：没直链解析，返回空（菜单里只显示当前这一档）。
  static Future<List<StreamVariant>> variantsFor(VideoItem item) async {
    // 签名源（eporner/pornhub/xhamster）的地址约 2 小时过期还绑 IP，
    // 不读缓存，每次现算。
    if (!_signedSources.contains(item.source)) {
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
      } else if (item.source == 'eporner' ||
          item.source == 'pornhub' ||
          item.source == 'xhamster') {
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
    if (page == null || page.isEmpty) {
      lastFailureReason = '这条没有视频页地址，下不了';
      return null;
    }
    // 2. 已经是直链地址本身。
    if (page.endsWith('.mp4') || page.contains('.m3u8')) {
      return ResolvedStream(page);
    }
    // 3. eporner 先走：它自己抓 embed 页签名，不用下面这份 html。
    //    （视频页 403 时 embed 页可能还通，别让下面的状态检查把它拦了。）
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
    // 4. 按来源解析详情页。
    try {
      final res = await http.get(Uri.parse(page), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        // 站方把纯 HTTP 请求拦了：原因按源写明，别让用户对着空白页猜。
        // 内置浏览器（真浏览器带 JS）能过验证，播放页/搜索页会给入口。
        lastFailureReason = _httpFailureReason(item.source, res.statusCode);
        return null;
      }
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
      if (item.source == 'pornhub') {
        // mediaDefinitions JSON（4 档 HLS + get_media 接口拿签名 mp4），
        // 2026-11-09 VM 验通。拿不到就继续往下走通用兜底扫描。
        final r = await _resolvePornhub(item, html);
        if (r != null) return r;
      }
      if (item.source == 'xhamster') {
        // <noscript><video src> 720p 签名 mp4 + HLS master，2026-11-09 VM 验通。
        // 拿不到就继续往下走通用兜底扫描。
        final r = await _resolveXhamster(item, html);
        if (r != null) return r;
      }
      // 5. 通用兜底：专属分支都没抓到时，对整页扫一次 mp4/m3u8
      //    （spankbang 这类没专属分支的源靠它捡漏；缩略图预览不算）。
      final generic = genericMediaScan(html);
      if (generic != null) return ResolvedStream(generic);
    } catch (_) {
      // 解析失败就返回 null，播放页走“在源站看”。
      lastFailureReason ??= _fetchFailureReason(item.source);
    }
    return null;
  }

  /// 视频页 HTTP 请求被拦/失败的原因（按源写明，别让用户猜）。
  static String _httpFailureReason(String source, int code) {
    switch (source) {
      case 'spankbang':
        return 'SpankBang 被 Cloudflare 拦住了（HTTP $code），去内置浏览器里嗅探下载';
      case 'niacg':
      case 'lianzu11':
      case 'hanime1':
      case 'hanimeone':
        return '站方拦住了 HTTP 请求（HTTP $code），去内置浏览器里看';
      default:
        return '视频页请求失败（HTTP $code），去内置浏览器里嗅探下载';
    }
  }

  /// 请求视频页抛错（断网/超时）的原因。
  static String _fetchFailureReason(String source) {
    switch (source) {
      case 'niacg':
      case 'lianzu11':
      case 'hanime1':
      case 'hanimeone':
        return '站方拦住了 HTTP 请求，去内置浏览器里看';
      default:
        return '请求视频页失败，去内置浏览器里嗅探下载';
    }
  }
}
