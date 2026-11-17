import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import '../transfer/hls_playlist.dart';
import 'downloader.dart';
import 'stream_resolver.dart';

/// 网页嗅探（第 34 条，2026-11-09 用户纠正：不是“太弱”，是根本就没有；
/// 第 53 条重写：视频正在播也嗅不到，用户发火）。
///
/// 53 条的根因（2026-11-09 逐个验过，见反馈文件）：
/// ① 旧嗅探只在页面加载时跑一次（onPageFinished + 4 秒后），播放器是懒加载/
////   点了播放才开始拉流时，嗅的那一刻 performance 里还没有媒体请求；
/// ② 只认主文档的 video——播放器在跨域 iframe 里时，主文档里根本没有
///    video 元素、performance 里也没有它的请求（iframe 有自己的时间线，
///    跨域还读不到），旧代码对此一声不吭，直接报“没嗅到”；
/// ③ JS 求值抛错被 catch 静默吃掉——嗅探本身没跑起来和“页面没视频”
///    看起来一模一样，用户只能看到一个摆设图标；
/// ④ 文案本身是错的：视频页正在播，提示却写“列表页没有可播的视频”。
///
/// 现在的嗅探（抄 SniffDL browser_sniff 的思路，见
/// ~/workspace/sniffdl/src/video_downloader.py L459-600）：
/// ① 触发：先把没初始化过的 video 静音播放（只碰 paused 且 currentSrc
///    为空的——已经在播的绝不动，不抢用户声音；SniffDL 是 v.muted=true
///    全触发，它在无头浏览器里没人听，我们在真浏览器里不能这么干），
///    再等 2.5 秒让分片请求发出来（已经在播的只等 1 秒）；
/// ② 收集：主文档 + 同源 iframe 的 video/audio/source（含 data-src 等
///    属性）、<a href> 里的媒体链接、每份文档的 performance 资源列表、
///    HTML 正则；跨域 iframe 只记 src（读不到里面，但能告诉用户、
///    还能一键打开它再嗅）；
/// ③ 诊断：嗅不到时写明到底查了什么、为什么没嗅到（video 几个、在播几个、
///    是不是 blob:、网络请求里有没有、iframe 几个），再也不写
///    “列表页没有可播的视频”这种睁眼瞎的文案；JS 抛错也如实报出来。
///
/// 搬过来的（SniffDL 有、WebView 里能做）：
/// - video/source 标签、performance 资源列表、HTML 正则；
/// - MutationObserver 式“等一等再查”（这里用触发后等 2.5 秒 + 浏览器
///   每 3 秒轮询 performance 的方式代替——webview_flutter 没有
///   MutationObserver 的 Dart 回调，JS 里可以挂，但结果一样要轮询着拿）；
/// - 触发 video 静音播放逼出媒体请求；
/// - 逐 frame 查（同源 iframe 直接读，跨域只记 src）。
/// 搬不了的（WebView 硬限制，如实说，见反馈文件）：
/// - Playwright 的 request/response 体拦截（按 content-type 认“媒体类型”、
///   从 API/JS 响应体里抽直链）：webview_flutter 4.14.1 的
///   NavigationDelegate 只有 onPageStarted/onPageFinished/onProgress/
///   onWebResourceError/onUrlChange/onHttpAuthRequest/onHttpError/
///   onSslAuthError，没有 shouldInterceptRequest，也没有 onLoadResource
///   （2026-11-09 亲手翻过 pub 缓存的源码确认）——响应体/响应头拿不到，
///   只能看到 performance 里已经发出去的请求地址；
/// - yt-dlp、aria2c、ffmpeg：App 里本来就没有，不包；
/// - 跨域 iframe 的 DOM：浏览器安全策略，读不到，只能记 src、
///   或直接打开它再嗅。
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
  final String? resolution; // 如 "1920x1080"，无则 null
  final int? bandwidth; // bps，无则 null
  final int? estimatedSizeBytes; // 预估大小字节数，无则 null
  final String? metaNote; // 失败原因显示文案（只用于显示，不影响 downloadable）

  const SniffedMedia({
    required this.url,
    required this.kind,
    this.sizeBytes,
    this.durationSec,
    this.segmentCount = 0,
    this.playableOnly = false,
    this.note,
    this.resolution,
    this.bandwidth,
    this.estimatedSizeBytes,
    this.metaNote,
  });

  SniffedMedia copyWith({
    String? url,
    String? kind,
    int? sizeBytes,
    int? durationSec,
    int? segmentCount,
    bool? playableOnly,
    String? note,
    String? resolution,
    int? bandwidth,
    int? estimatedSizeBytes,
    String? metaNote,
  }) {
    return SniffedMedia(
      url: url ?? this.url,
      kind: kind ?? this.kind,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      durationSec: durationSec ?? this.durationSec,
      segmentCount: segmentCount ?? this.segmentCount,
      playableOnly: playableOnly ?? this.playableOnly,
      note: note ?? this.note,
      resolution: resolution ?? this.resolution,
      bandwidth: bandwidth ?? this.bandwidth,
      estimatedSizeBytes: estimatedSizeBytes ?? this.estimatedSizeBytes,
      metaNote: metaNote ?? this.metaNote,
    );
  }

  /// 能不能下：blob 下不了；m3u8 播放列表拉不到也下不了（不知道分片地址）。
  bool get downloadable => !playableOnly && note == null;

  /// 分辨率像素数（宽×高），没有分辨率时为 0，供质量比较用。
  int get qualityPixels {
    final r = resolution;
    if (r == null || r.isEmpty) return 0;
    final parts = r.toLowerCase().split('x');
    if (parts.length != 2) return 0;
    final w = int.tryParse(parts[0].trim());
    final h = int.tryParse(parts[1].trim());
    if (w == null || h == null || w <= 0 || h <= 0) return 0;
    return w * h;
  }

  /// 如 "1920x1080" -> "1080p"；无分辨率返回 ''。
  String get resolutionText {
    final r = resolution;
    if (r == null || r.isEmpty) return '';
    final parts = r.toLowerCase().split('x');
    if (parts.length != 2) return '';
    final h = int.tryParse(parts[1].trim());
    if (h == null || h <= 0) return '';
    return '${h}p';
  }

  String get sizeText {
    final n = sizeBytes;
    if (n == null || n <= 0) return '';
    if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(n / 1024).toStringAsFixed(0)} KB';
  }

  String get estimatedSizeText {
    final n = estimatedSizeBytes;
    if (n == null || n <= 0) return '';
    if (n >= 1024 * 1024) {
      return '约 ${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '约 ${(n / 1024).toStringAsFixed(0)} KB';
  }

  String get durationText {
    final s = durationSec;
    if (s == null || s <= 0) return '';
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  /// 清单里的一行说明：分辨率/码率 · 大小/预估大小 · 时长 · 分片数（有的才写）。
  /// m3u8/mp4/webm/mov 全空时显示“未知”：m3u8 是“时长未知 · 分辨率未知”，
  /// mp4/webm/mov 再加“大小未知”；失败原因（metaNote）有就带上。
  String get detailLine {
    final res = resolutionText;
    final sz = sizeText;
    final est = estimatedSizeText;
    final dur = durationText;
    final d = durationSec;
    final r = resolution;
    final noDuration = d == null || d <= 0;
    final noResolution = r == null || r.isEmpty;
    final noBandwidth = bandwidth == null || bandwidth! <= 0;
    if ((kind == 'm3u8' ||
            kind == 'mp4' ||
            kind == 'webm' ||
            kind == 'mov') &&
        noDuration &&
        noResolution &&
        sz.isEmpty &&
        est.isEmpty &&
        noBandwidth) {
      final parts = <String>['时长未知', '分辨率未知'];
      if (kind == 'mp4' || kind == 'webm' || kind == 'mov') {
        parts.add('大小未知');
      }
      if (segmentCount > 0) parts.add('$segmentCount 个分片');
      if (metaNote != null) parts.add(metaNote!);
      if (note != null) parts.add(note!);
      return parts.join(' · ');
    }
    final parts = <String>[];
    if (res.isNotEmpty) {
      parts.add(res);
    } else if (!noBandwidth) {
      // 没分辨率但码率已知：码率就是质量信号，显示出来别藏着。
      parts.add('约 ${(bandwidth! / 1000000).toStringAsFixed(1)} Mbps');
    }
    if (sz.isNotEmpty) {
      parts.add(sz);
    } else if (est.isNotEmpty) {
      parts.add(est);
    }
    if (dur.isNotEmpty) parts.add(dur);
    if (segmentCount > 0) parts.add('$segmentCount 个分片');
    if (kind == 'ts') parts.add('分段视频');
    if (metaNote != null) parts.add(metaNote!);
    if (note != null) parts.add(note!);
    return parts.join(' · ');
  }

  static int _kindRank(String kind) {
    switch (kind) {
      case 'mp4':
      case 'webm':
        return 0;
      case 'm3u8':
        return 1;
      case 'ts':
        return 2;
      case 'blob':
        return 3;
      default:
        return 4;
    }
  }

  /// 质量比较（最好在前）：分辨率像素降序 → 码率降序 → 大小降序 → 类型优先级。
  /// 返回负数表示 a 排在 b 前面。
  static int compareQuality(SniffedMedia a, SniffedMedia b) {
    final byPixels = b.qualityPixels.compareTo(a.qualityPixels);
    if (byPixels != 0) return byPixels;
    final byBandwidth = (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
    if (byBandwidth != 0) return byBandwidth;
    final bySize = (b.sizeBytes ?? 0).compareTo(a.sizeBytes ?? 0);
    if (bySize != 0) return bySize;
    return _kindRank(a.kind).compareTo(_kindRank(b.kind));
  }

  /// 可下条目里质量最好的一条；没有可下的返回 null。
  static SniffedMedia? bestOf(Iterable<SniffedMedia> items) {
    SniffedMedia? best;
    for (final item in items) {
      if (!item.downloadable) continue;
      if (best == null || compareQuality(item, best) < 0) {
        best = item;
      }
    }
    return best;
  }
}

/// 嗅探诊断（第 53 条）：嗅不到时写明到底查了什么、为什么没嗅到，
/// 不要只给个图标摆设。纯数据 + 纯文本生成，单元测试直接验。
/// 文案铁律：只写查到的事实，不编原因、不把视频页说成列表页。
class SniffDiagnosis {
  final int videoCount; // 主文档 + 同源 iframe 里找到的 video/audio 元素数
  final int playingCount; // 正在播的（没暂停且进度 > 0）
  final int blobVideoCount; // currentSrc 是 blob: 的（MSE 播放器）
  final int performanceMediaCount; // performance 里媒体后缀的请求数
  final int iframeCount; // 页面里 iframe 总数
  final int crossOriginIframeCount; // 跨域 iframe 数（读不到里面）
  final List<String> iframeSrcs; // 跨域 iframe 的 src（最多记 3 个）
  final int htmlMediaCount; // HTML 正则扫到的媒体地址数
  final String? jsError; // JS 求值本身抛错（之前是静默吞掉）
  final int previewFilteredCount; // 被当成预览/广告短片过滤掉的候选地址数

  const SniffDiagnosis({
    this.videoCount = 0,
    this.playingCount = 0,
    this.blobVideoCount = 0,
    this.performanceMediaCount = 0,
    this.iframeCount = 0,
    this.crossOriginIframeCount = 0,
    this.iframeSrcs = const [],
    this.htmlMediaCount = 0,
    this.jsError,
    this.previewFilteredCount = 0,
  });

  /// 像播放器的跨域 iframe 地址（能一键打开它再嗅）：
  /// 优先含 embed/player/watch/video 的；没有就只剩唯一一个跨域 iframe
  /// 时才认（单个 iframe 极大概率就是播放器）；广告 iframe 不要。
  String? get playerIframeUrl {
    String? pick(bool Function(String u) test) {
      for (final u in iframeSrcs) {
        if (_isAdUrl(u)) continue;
        if (test(u)) return u;
      }
      return null;
    }

    final keyword = pick((u) {
      final l = u.toLowerCase();
      return l.contains('embed') ||
          l.contains('player') ||
          l.contains('watch') ||
          l.contains('video');
    });
    if (keyword != null) return keyword;
    final nonAd = iframeSrcs.where((u) => !_isAdUrl(u)).toList();
    if (nonAd.length == 1) return nonAd.first;
    return null;
  }

  static bool _isAdUrl(String url) {
    final l = url.toLowerCase();
    return l.contains('googletag') ||
        l.contains('doubleclick') ||
        l.contains('googleads') ||
        l.contains('adsystem') ||
        l.contains('adservice');
  }

  /// 人话诊断：只写查到的事实。嗅到东西时不调用它。
  String get text {
    if (jsError != null && jsError!.isNotEmpty) {
      return '嗅探脚本在页面里执行失败（$jsError）：没查到任何东西，不是页面没有视频，是嗅探本身没跑起来。退出重进一次再试。';
    }
    // 只嗅到预览：诊断只在没嗅到正片时展示，所以这里直接说清，不装作没嗅到。
    if (previewFilteredCount > 0) {
      return '本页只嗅到预览短片，没找到正片：$previewFilteredCount 个预览/广告地址已过滤掉。正片可能要等播放器加载出来，点开播一次再嗅。';
    }
    final parts = <String>['查了本页：'];
    if (videoCount == 0) {
      parts.add('没找到 video 元素（可能是播放器在跨域 iframe 里，或还没加载出来）');
    } else {
      parts.add('找到 $videoCount 个 video 元素'
          '${playingCount > 0 ? '，其中 $playingCount 个正在播' : '，都没在播'}');
    }
    if (blobVideoCount > 0) {
      parts.add('在播的地址是 blob:（MSE 播放器），底层分片地址没出现在网络请求里');
    }
    if (performanceMediaCount == 0) {
      parts.add('网络请求里没有 .m3u8/.mp4/.ts 地址');
    } else {
      parts.add('网络请求里有 $performanceMediaCount 个媒体地址，但都是缩略图/广告，已排除');
    }
    if (crossOriginIframeCount > 0) {
      parts.add('页面有 $crossOriginIframeCount 个跨域 iframe，播放器可能在里面，里面的地址拿不到');
    }
    if (htmlMediaCount == 0) {
      parts.add('页面源码里也没扫到媒体地址');
    }
    if (playerIframeUrl != null) {
      parts.add('可以点“打开播放页”直接进 iframe 里的播放页再嗅一次');
    }
    return '${parts.join('；')}。';
  }
}

class SniffResult {
  final List<SniffedMedia> items;
  final String pageTitle;
  /// 第 42 条：页面里的发布者（JSON-LD author、uploader 链接等，JS 里抠的；
  /// 拿不到就是 ''——eponner/lianzu11/hanime 这类 HTTP 拿不到作者的源，
  /// 在内置浏览器/官方播放器里打开视频页时靠它补上）。
  final String author;
  /// 第 53 条：嗅不到时的诊断（查了什么、为什么没嗅到）。
  final SniffDiagnosis diagnosis;
  /// 页面封面地址（video poster / og:image / twitter:image，拿不到就是 ''）。
  final String pagePoster;
  const SniffResult(this.items, this.pageTitle,
      [this.author = '',
      this.diagnosis = const SniffDiagnosis(),
      this.pagePoster = '']);
}

/// 单个 video 元素实测的元数据（videoWidth/videoHeight、duration）。
class DomVideoMeta {
  final String? resolution; // 如 '1920x1080'，无则 null
  final int? durationSec;
  const DomVideoMeta({this.resolution, this.durationSec});
}

/// 页面级视频信息（og:video 或 JSON-LD VideoObject）。
class PageVideoMeta {
  final String? videoUrl; // og:video 或 VideoObject 的 contentUrl/embedUrl
  final String? resolution;
  final int? durationSec;
  const PageVideoMeta({this.videoUrl, this.resolution, this.durationSec});
}

class Sniffer {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 排除：缩略图预览、广告域名（和 StreamResolver.genericMediaScan 同一套词）。
  /// 预览标记按 URL 路径段判（不是任意子串），规则见 isPreviewUrl：
  /// 路径段恰好叫 preview 的正片页（如 /videos/preview/12345.mp4）不排除。
  static bool isExcludedUrl(String url) {
    final l = url.toLowerCase();
    return l.contains('thumb') ||
        l.contains('.t.mp4') ||
        isPreviewUrl(url) ||
        l.contains('googletag') ||
        l.contains('doubleclick') ||
        l.contains('googleads') ||
        l.contains('adsystem') ||
        l.contains('adservice');
  }

  /// 预览/广告短片判定（只看 URL 路径段，不看标题）：
  /// - 任一段 == 'pre_videos'（Pornhub 预览 CDN 路径段，如
  ///   .../pre_videos/003/003/832/3003832/mp4_720p...）；
  /// - 任一段 == 'trailer'，或以 'trailer_' / 'trailer-' / 'trailer.' 开头；
  /// - 任一段以 'preview_' / 'preview-' / 'preview.' 开头，或含 '_preview'
  ///   （preview_720p.mp4、x_preview.mp4、video_preview.mp4 这类文件名）；
  /// - 裸一段 == 'preview'（只是路由/目录段）不算，避免错杀正片。
  static bool isPreviewUrl(String url) {
    final l = url.toLowerCase();
    final path = Uri.tryParse(l)?.path ?? l.split('?').first;
    for (final seg in path.split('/')) {
      if (seg == 'pre_videos') return true;
      if (seg == 'trailer' ||
          seg.startsWith('trailer_') ||
          seg.startsWith('trailer-') ||
          seg.startsWith('trailer.')) {
        return true;
      }
      if (seg.startsWith('preview_') ||
          seg.startsWith('preview-') ||
          seg.startsWith('preview.') ||
          seg.contains('_preview')) {
        return true;
      }
    }
    return false;
  }

  /// 在 WebView 里跑 JS 嗅两遍，返回分组后的媒体清单 + 页面标题 + 诊断。
  /// pageUrl：相对地址拼绝对地址、下载时当 Referer 用。
  /// extraCandidates：浏览器每 3 秒轮询 performance 攒下来的候选地址
  /// （webview_flutter 没有 onLoadResource 回调，轮询是唯一能“持续监听”
  ///   的办法——见 web_source_browser.dart 的 _pollSniff）。
  ///
  /// 两段式（第 53 条，抄 SniffDL browser_sniff）：
  /// ① 触发：只把没初始化过的 video 静音播放（paused 且 currentSrc 为空——
  ///    已经在播的绝不动，不抢用户声音），把资源时间线缓冲调大；
  ///    已经在播就只等 1 秒，没在播就等 2.5 秒让分片请求发出来；
  /// ② 收集：主文档 + 同源 iframe 的 video/source（含 data-* 属性）、
  ///    <a href> 媒体链接、每份文档的 performance、HTML 正则。
  /// JS 抛错不再静默吞掉：记进诊断里如实报出来。
  static Future<SniffResult> sniff(
    WebViewController controller, {
    required String pageUrl,
    List<String> extraCandidates = const [],
    Map<String, DomVideoMeta> extraDomMeta = const {},
  }) async {
    var title = '';
    var pageAuthor = '';
    var pagePoster = '';
    var candidates = <String>[];
    var domDurations = <String, double>{};
    var domMeta = <String, DomVideoMeta>{};
    PageVideoMeta? pageMeta;
    var diagnosis = const SniffDiagnosis();

    // ---- 第一段：触发（SniffDL：muted-play + 等 2.5 秒）----
    Map<String, dynamic> trigger = {};
    try {
      final rawTrigger = await controller.runJavaScriptReturningResult(_triggerJs);
      trigger = _parseJsonMap(rawTrigger);
    } catch (e) {
      // JS 求值本身失败：不装作“页面没视频”，如实报。
      return SniffResult(
        const [],
        '',
        '',
        SniffDiagnosis(jsError: _shortError(e)),
      );
    }
    final triggerError = (trigger['error'] ?? '').toString();
    if (triggerError.isNotEmpty) {
      return SniffResult(
        const [],
        '',
        '',
        SniffDiagnosis(jsError: triggerError),
      );
    }
    // 已经在播：分片请求正在发，只等 1 秒；没在播：等触发起效，等 2.5 秒。
    final alreadyPlaying = (trigger['playing'] as num?)?.toInt() ?? 0;
    await Future.delayed(
        Duration(milliseconds: alreadyPlaying > 0 ? 1000 : 2500));

    // ---- 第二段：收集 ----
    try {
      final raw = await controller.runJavaScriptReturningResult(_collectJs);
      final decoded = _parseJsonMap(raw);
      final collectError = (decoded['error'] ?? '').toString();
      if (collectError.isNotEmpty) {
        return SniffResult(
          const [],
          '',
          '',
          SniffDiagnosis(jsError: collectError),
        );
      }
      title = (decoded['title'] ?? '').toString();
      pageAuthor = (decoded['author'] ?? '').toString().trim();
      pagePoster = (decoded['poster'] ?? '').toString().trim();
      if (pagePoster.startsWith('//')) {
        pagePoster = 'https:$pagePoster';
      }
      if (pagePoster.isNotEmpty && !pagePoster.startsWith('http')) {
        try {
          pagePoster = Uri.parse(pageUrl).resolve(pagePoster).toString();
        } catch (_) {
          pagePoster = '';
        }
      }
      final videos = (decoded['videos'] as List?) ?? [];
      var videoCount = 0;
      var playingCount = 0;
      var blobCount = 0;
      for (final v in videos) {
        final m = v as Map<String, dynamic>;
        final src = (m['src'] ?? '').toString();
        if (src.isEmpty) continue;
        videoCount++;
        if (src.startsWith('blob:')) blobCount++;
        final paused = m['paused'] == true;
        final t = (m['currentTime'] as num?)?.toDouble() ?? 0;
        if (!paused && t > 0) playingCount++;
        candidates.add(src);
        final d = (m['duration'] as num?)?.toDouble() ?? 0;
        if (d > 0 && d.isFinite) domDurations[src] = d;
        final vw = (m['videoWidth'] as num?)?.toInt() ?? 0;
        final vh = (m['videoHeight'] as num?)?.toInt() ?? 0;
        if (vw > 0 && vh > 0) {
          domMeta[normalizeUrl(src)] = DomVideoMeta(
            resolution: '${vw}x$vh',
            durationSec: d > 0 && d.isFinite ? d.round() : null,
          );
        }
      }
      final resources = (decoded['resources'] as List?) ?? [];
      for (final r in resources) {
        candidates.add(r.toString());
      }
      final links = (decoded['links'] as List?) ?? [];
      for (final l in links) {
        candidates.add(l.toString());
      }
      final html = (decoded['html'] ?? '').toString();
      final htmlFound = _scanHtmlForMedia(html);
      candidates.addAll(pornhubMainCandidates(html)); // 正片 HLS 优先
      candidates.addAll(htmlFound);
      final iframeSrcs = ((decoded['iframeSrcs'] as List?) ?? [])
          .map((e) => e.toString())
          .where((u) => u.isNotEmpty)
          .toSet()
          .take(3)
          .toList();
      diagnosis = SniffDiagnosis(
        videoCount: videoCount,
        playingCount: playingCount,
        blobVideoCount: blobCount,
        performanceMediaCount: resources.length,
        iframeCount: (decoded['iframes'] as num?)?.toInt() ?? 0,
        crossOriginIframeCount:
            (decoded['crossOrigin'] as num?)?.toInt() ?? 0,
        iframeSrcs: iframeSrcs,
        htmlMediaCount: htmlFound.length,
        previewFilteredCount: candidates.where(isPreviewUrl).length,
      );
      // 页面级视频信息：og:video 优先，其次 JSON-LD VideoObject。
      final voList = <Map<String, dynamic>>[];
      for (final vo in (decoded['videoObjects'] as List?) ?? []) {
        if (vo is Map<String, dynamic>) {
          voList.add(vo);
        } else if (vo is Map) {
          voList.add(Map<String, dynamic>.from(vo));
        }
      }
      String? nonEmpty(dynamic v) {
        final s = (v ?? '').toString().trim();
        return s.isEmpty ? null : s;
      }

      pageMeta = pickPageMeta(
        ogVideo: nonEmpty(decoded['ogVideo']),
        ogVideoSecure: nonEmpty(decoded['ogVideoSecure']),
        ogWidth: (decoded['ogVideoWidth'] as num?)?.toInt(),
        ogHeight: (decoded['ogVideoHeight'] as num?)?.toInt(),
        ogDuration: (decoded['ogVideoDuration'] as num?)?.toDouble(),
        videoObjects: voList,
      );
    } catch (e) {
      return SniffResult(
        const [],
        title,
        pageAuthor,
        SniffDiagnosis(jsError: _shortError(e)),
      );
    }
    candidates.addAll(extraCandidates);
    final items = await groupAndEnrich(
      candidates: candidates,
      domDurations: domDurations,
      domMeta: {...extraDomMeta, ...domMeta},
      pageMeta: pageMeta,
      pageUrl: pageUrl,
    );
    return SniffResult(items, title, pageAuthor, diagnosis, pagePoster);
  }

  static String _shortError(Object e) {
    final s = e.toString().replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  /// runJavaScriptReturningResult 的返回值解成 Map（Android 上是 JSON 字符串，
  /// 有时已是 Map；解不开返回空 Map，别抛错）。
  static Map<String, dynamic> _parseJsonMap(Object? raw) {
    try {
      if (raw == null) return {};
      if (raw is Map<String, dynamic>) return raw;
      final decoded = jsonDecode(raw.toString());
      if (decoded is Map<String, dynamic>) return decoded;
      return {};
    } catch (_) {
      return {};
    }
  }

  /// 地址归一化（去重/查表用）：小写、去 # 后缀。
  static String normalizeUrl(String url) {
    final l = url.toLowerCase();
    final h = l.indexOf('#');
    return h == -1 ? l : l.substring(0, h);
  }

  /// ISO 8601 时长转秒数（如 'PT1M30S' → 90；'PT2H3M4S' → 7384）。
  /// 纯数字字符串当秒数；非法返回 null。
  static int? parseIso8601Duration(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    final asNum = double.tryParse(t);
    if (asNum != null) return asNum.round();
    final m = RegExp(
            r'^PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$')
        .firstMatch(t);
    if (m == null) return null;
    var total = 0.0;
    var any = false;
    final h = double.tryParse(m.group(1) ?? '');
    if (h != null) {
      total += h * 3600;
      any = true;
    }
    final min = double.tryParse(m.group(2) ?? '');
    if (min != null) {
      total += min * 60;
      any = true;
    }
    final sec = double.tryParse(m.group(3) ?? '');
    if (sec != null) {
      total += sec;
      any = true;
    }
    if (!any || total <= 0) return null;
    return total.round();
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// 页面级视频信息：og:video 优先，其次 JSON-LD VideoObject；
  /// 都没有返回 null。
  static PageVideoMeta? pickPageMeta({
    String? ogVideo,
    String? ogVideoSecure,
    int? ogWidth,
    int? ogHeight,
    num? ogDuration,
    List<Map<String, dynamic>> videoObjects = const [],
  }) {
    final ogUrl = (ogVideoSecure != null && ogVideoSecure.isNotEmpty)
        ? ogVideoSecure
        : (ogVideo != null && ogVideo.isNotEmpty ? ogVideo : null);
    if (ogUrl != null) {
      final w = ogWidth ?? 0;
      final h = ogHeight ?? 0;
      final d = ogDuration ?? 0;
      return PageVideoMeta(
        videoUrl: ogUrl,
        resolution: w > 0 && h > 0 ? '${w}x$h' : null,
        durationSec: d > 0 ? d.round() : null,
      );
    }
    for (final vo in videoObjects) {
      final url =
          (vo['contentUrl'] ?? vo['embedUrl'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      final w = _asInt(vo['width']) ?? 0;
      final h = _asInt(vo['height']) ?? 0;
      int? dur;
      final rawDur = vo['duration'];
      if (rawDur is num) {
        dur = rawDur.toInt();
      } else if (rawDur is String) {
        dur = parseIso8601Duration(rawDur);
      }
      return PageVideoMeta(
        videoUrl: url,
        resolution: w > 0 && h > 0 ? '${w}x$h' : null,
        durationSec: dur != null && dur > 0 ? dur : null,
      );
    }
    return null;
  }

  /// 第一段 JS：触发（只动没初始化过的 video）+ 扩资源时间线缓冲。
  /// 返回 {videos, playing, triggered, iframes, crossOrigin, iframeSrcs, error}。
  static const _triggerJs = "(function(){"
      "var out={videos:0,playing:0,triggered:0,iframes:0,crossOrigin:0,iframeSrcs:[],error:''};"
      "try{"
      "try{performance.setResourceTimingBufferSize(2000);}catch(e){}"
      "function docs(){var d=[document];"
      "document.querySelectorAll('iframe').forEach(function(f){out.iframes++;"
      "try{if(f.contentDocument){d.push(f.contentDocument);}"
      "else{out.crossOrigin++;if(f.src)out.iframeSrcs.push(f.src);}}"
      "catch(e){out.crossOrigin++;if(f.src)out.iframeSrcs.push(f.src);}});return d;}"
      "docs().forEach(function(doc){"
      "doc.querySelectorAll('video,audio').forEach(function(v){out.videos++;"
      "var src=v.currentSrc||v.src||'';"
      "if(!v.paused&&(v.currentTime||0)>0)out.playing++;"
      // 只触发没初始化过的（paused 且连地址都没有）：已经在播的绝不动，
      // 不抢用户声音；还没初始化的静音播一下，逼播放器去拉播放列表/分片。
      "if(v.paused&&!src){try{v.muted=true;var p=v.play();"
      "if(p&&p.catch)p.catch(function(){});out.triggered++;}catch(e){}}"
      "});});"
      "}catch(e){out.error=String((e&&e.message)||e);}"
      "return JSON.stringify(out);})()";

  /// 第二段 JS：收集（主文档 + 同源 iframe；跨域 iframe 只记 src）。
  /// 返回 {videos:[{src,duration,paused,currentTime}],resources,links,html,
  /// title,author,poster,iframes,crossOrigin,iframeSrcs,error}。
  static const _collectJs = "(function(){"
      "var out={videos:[],resources:[],links:[],html:'',title:document.title,author:'',poster:'',"
      "ogVideo:'',ogVideoSecure:'',ogVideoWidth:0,ogVideoHeight:0,ogVideoDuration:0,videoObjects:[],"
      "iframes:0,crossOrigin:0,iframeSrcs:[],error:''};"
      "try{"
      "function collectDoc(doc){"
      "doc.querySelectorAll('video,audio').forEach(function(v){"
      "var src=v.currentSrc||v.src||'';"
      "var vw=(v.tagName==='VIDEO')?(v.videoWidth||0):0;"
      "var vh=(v.tagName==='VIDEO')?(v.videoHeight||0):0;"
      "var o={src:src,duration:v.duration||0,paused:!!v.paused,currentTime:v.currentTime||0,videoWidth:vw,videoHeight:vh};"
      "if(src)out.videos.push(o);"
      "v.querySelectorAll('source').forEach(function(s){"
      "if(s.src)out.videos.push({src:s.src,duration:v.duration||0,paused:!!v.paused,currentTime:v.currentTime||0,videoWidth:vw,videoHeight:vh});});"
      "['data-src','data-video','data-url','data-source'].forEach(function(a){"
      "var val=v.getAttribute&&v.getAttribute(a);"
      "if(val)out.videos.push({src:val,duration:v.duration||0,paused:!!v.paused,currentTime:v.currentTime||0,videoWidth:vw,videoHeight:vh});});});"
      "doc.querySelectorAll('a[href]').forEach(function(a){"
      "var h=a.getAttribute('href')||'';"
      "if(/\\.(mp3|mp4|m4a|flac|wav|aac|ogg|opus|wma|m4b|mkv|avi|mov|flv|ts|webm|m3u8)(\\?|#|\$)/i.test(h))out.links.push(h);});"
      "try{var perf=(doc.defaultView&&doc.defaultView.performance)||performance;"
      "perf.getEntriesByType('resource').forEach(function(r){var u=r.name||'';"
      "if(/\\.(mp4|m3u8|ts|webm|mov)(\\?|#|\$)/i.test(u)||u.indexOf('blob:')===0)out.resources.push(u);});}catch(e){}"
      "}"
      "collectDoc(document);"
      "document.querySelectorAll('iframe').forEach(function(f){out.iframes++;"
      "try{if(f.contentDocument){collectDoc(f.contentDocument);}"
      "else{out.crossOrigin++;if(f.src)out.iframeSrcs.push(f.src);}}"
      "catch(e){out.crossOrigin++;if(f.src)out.iframeSrcs.push(f.src);}});"
      "var h=document.documentElement?document.documentElement.outerHTML:'';"
      "out.html=h.slice(0,400000);"
      "try{var _pvs=document.querySelectorAll('video[poster]');"
      "for(var _pi=0;_pi<_pvs.length&&!out.poster;_pi++){var _pp=_pvs[_pi].getAttribute('poster')||'';if(_pp.indexOf('http')===0)out.poster=_pp.trim();}"
      "if(!out.poster){var _og=document.querySelector('meta[property=\"og:image\"]');"
      "if(_og&&_og.getAttribute('content')){out.poster=_og.getAttribute('content');}}"
      "if(!out.poster){var _tw=document.querySelector('meta[name=\"twitter:image\"]');"
      "if(_tw&&_tw.getAttribute('content')){out.poster=_tw.getAttribute('content');}}"
      "if(out.poster){out.poster=out.poster.trim();}}catch(e){}"
      "try{var author='';"
      "var lds=document.querySelectorAll('script[type=\"application/ld+json\"]');"
      "for(var i=0;i<lds.length&&!author;i++){try{var j=JSON.parse(lds[i].textContent);"
      "var a=j.author||(j['@graph']&&j['@graph'][0]&&j['@graph'][0].author);"
      "if(a)author=(typeof a==='string'?a:(a.name||''));}catch(e){}}"
      "if(!author){var u=document.querySelector('[data-label=\"thumb_username\"]');if(u)author=u.textContent.trim();}"
      "if(!author){var t=document.querySelector('.uploader-tag .name');if(t)author=t.textContent.replace(/[0-9.,kKmM\\s]+\$/,'').trim();}"
      "if(!author){var r=document.querySelector('a[rel=\"author\"]');if(r)author=r.textContent.trim();}"
      "if(!author){var e=document.querySelector('.entry-author a,.posted-by a,.author-name');if(e)author=e.textContent.trim();}"
      "if(author)out.author=author;}catch(e){}"
      "try{function _mg(p){var _m=document.querySelector('meta[property=\"' + p + '\"]');return _m?(_m.getAttribute('content')||''):'';}"
      "out.ogVideo=_mg('og:video');out.ogVideoSecure=_mg('og:video:secure_url');"
      "out.ogVideoWidth=parseInt(_mg('og:video:width'),10)||0;"
      "out.ogVideoHeight=parseInt(_mg('og:video:height'),10)||0;"
      "out.ogVideoDuration=parseFloat(_mg('og:video:duration'))||0;"
      "var _vos=[];"
      "document.querySelectorAll('script[type=\"application/ld+json\"]').forEach(function(s){try{var _j=JSON.parse(s.textContent);"
      "var _arr=Array.isArray(_j)?_j:(_j['@graph']||[_j]);"
      "_arr.forEach(function(_o){if(!_o)return;var _t=_o['@type'];var _isVo=_t==='VideoObject'||(Array.isArray(_t)&&_t.indexOf('VideoObject')>=0);"
      "if(_isVo)_vos.push({url:_o.contentUrl||_o.embedUrl||'',width:_o.width||0,height:_o.height||0,duration:_o.duration||''});});}catch(e){}});"
      "out.videoObjects=_vos;}catch(e){}"
      "}catch(e){out.error=String((e&&e.message)||e);}"
      "return JSON.stringify(out);})()";

  /// 浏览器每 3 秒轮询用的轻量 JS（第 53 条）：只拿 video 地址 + performance
  /// 媒体请求，不扫 HTML、不碰播放状态。webview_flutter 没有 onLoadResource
  /// 回调，轮询是唯一能“持续监听”新请求的办法。
  /// 返回 {videos:[{src,duration}],resources:[url]}。
  static const pollJs = "(function(){"
      "var out={videos:[],resources:[]};"
      "try{"
      "document.querySelectorAll('video,audio').forEach(function(v){"
      "var src=v.currentSrc||v.src||'';"
      "if(src)out.videos.push({src:src,duration:v.duration||0,videoWidth:(v.tagName==='VIDEO')?(v.videoWidth||0):0,videoHeight:(v.tagName==='VIDEO')?(v.videoHeight||0):0});});"
      "try{performance.getEntriesByType('resource').forEach(function(r){var u=r.name||'';"
      "if(/\\.(mp4|m3u8|ts|webm|mov)(\\?|#|\$)/i.test(u)||u.indexOf('blob:')===0)out.resources.push(u);});}catch(e){}"
      "}catch(e){}"
      "return JSON.stringify(out);})()";

  /// 页面 HTML 内正则扫媒体地址（绝对 + 相对地址都认）。
  /// HTML 里的转义地址还原（供单测直接验）：JSON 里 `\/` 与 `\u002F`
  /// 都是 `/`，不还原正则就匹配不到（反斜杠把 // 隔开了）。
  static String unescapeHtmlUrls(String html) {
    return html.replaceAll(r'\/', '/').replaceAll(r'\u002F', '/');
  }

  static List<String> _scanHtmlForMedia(String html) {
    // JSON 里转义过的地址（https:\/\/...、\u002F）先还原，否则正则
    // 匹配不到（反斜杠把 // 隔开了）。
    html = unescapeHtmlUrls(html);
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

  /// Pornhub 正片候选：复用 StreamResolver 的 mediaDefinitions 提取，
  /// 只取 format == 'hls' 的 master.m3u8（正片多档）；format == 'mp4'
  /// 那条是 get_media 接口地址（返回 JSON，不是直链），不要。
  static List<String> pornhubMainCandidates(String html) {
    final seen = <String>{};
    final out = <String>[];
    for (final d in StreamResolver.parsePornhubMediaDefinitions(html)) {
      if (d.format != 'hls' || d.url.isEmpty) continue;
      if (seen.add(d.url)) out.add(d.url);
    }
    return out;
  }

  /// 候选地址 -> 分组后的媒体清单（纯逻辑 + 联网补信息）。
  /// fetchText 可注入（单元测试用假播放列表，不真联网）。
  /// probeHead 可注入（单元测试用假 HEAD 响应，不真联网）。
  static Future<List<SniffedMedia>> groupAndEnrich({
    required List<String> candidates,
    Map<String, double> domDurations = const {},
    Map<String, DomVideoMeta> domMeta = const {},
    PageVideoMeta? pageMeta,
    required String pageUrl,
    Future<String> Function(String url)? fetchText,
    Future<int?> Function(String url)? probeHead,
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
          lower.endsWith('.mov') ||
          lower.contains('/mp4_')) {
        // '/mp4_'：Pornhub 预览地址形如 .../pre_videos/.../mp4_720p...，
        // 后缀可能被截断得看不清，路径里有 mp4_ 标记的也算 mp4。
        files.add(u);
      } else if (lower.endsWith('.ts')) {
        final prefix = u.substring(0, u.lastIndexOf('/'));
        (tsGroups[prefix] ??= []).add(u);
      }
    }
    final out = <SniffedMedia>[];
    // 页面元数据的匹配规则（分辨率/时长都走同一套）：
    // 精确匹配：地址相同（归一化后比较）才套；
    // 单候选兜底：页面只有一个媒体候选时，页面级信息就是它的（主视频）。
    // 多个候选且对不上地址的，绝不乱套。
    final singleCandidate = m3u8s.length + files.length == 1;
    String? resolutionFromDom(String url) {
      final exact = domMeta[normalizeUrl(url)]?.resolution;
      if (exact != null) return exact;
      if (singleCandidate && domMeta.length == 1) {
        return domMeta.values.first.resolution;
      }
      return null;
    }

    int? durationFromDom(String url) {
      final exact = domMeta[normalizeUrl(url)]?.durationSec;
      if (exact != null) return exact;
      if (singleCandidate && domMeta.length == 1) {
        return domMeta.values.first.durationSec;
      }
      return null;
    }

    String? resolutionFromPage(String url) {
      final pm = pageMeta;
      if (pm == null || pm.resolution == null) return null;
      if (pm.videoUrl != null &&
          normalizeUrl(pm.videoUrl!) == normalizeUrl(url)) {
        return pm.resolution;
      }
      if (singleCandidate) return pm.resolution;
      return null;
    }

    int? durationFromPage(String url) {
      final pm = pageMeta;
      if (pm == null || pm.durationSec == null) return null;
      if (pm.videoUrl != null &&
          normalizeUrl(pm.videoUrl!) == normalizeUrl(url)) {
        return pm.durationSec;
      }
      if (singleCandidate) return pm.durationSec;
      return null;
    }

    // 3) m3u8：共享解析（HlsPlaylist.resolveVariantMeta）算分辨率/码率/
    // 时长/分片数；DOM/页面信息只当兜底（解析没给分辨率/时长时）。
    for (final u in m3u8s) {
      try {
        final body = await fetch(u);
        final meta = await HlsPlaylist.resolveVariantMeta(
          masterBody: body,
          masterUrl: u,
          fetch: fetch,
        );
        final durationSec = meta.durationSec ??
            _domDuration(domDurations, u) ??
            durationFromDom(u) ??
            durationFromPage(u);
        final resolution =
            meta.resolution ?? resolutionFromDom(u) ?? resolutionFromPage(u);
        final estimatedSizeBytes =
            (meta.bandwidth != null && durationSec != null && durationSec > 0)
                ? meta.bandwidth! ~/ 8 * durationSec
                : null;
        out.add(SniffedMedia(
          url: u,
          kind: 'm3u8',
          durationSec: durationSec,
          segmentCount: meta.segmentCount,
          resolution: resolution,
          bandwidth: meta.bandwidth,
          estimatedSizeBytes: estimatedSizeBytes,
          metaNote: meta.metaNote,
        ));
      } catch (_) {
        out.add(SniffedMedia(
          url: u,
          kind: 'm3u8',
          durationSec: _domDuration(domDurations, u),
          note: '播放列表拉不到，下不了，只能在线播',
          metaNote: '播放列表拉取失败',
        ));
      }
    }
    // 4) mp4/webm：分辨率/时长（DOM 实测 → 页面信息）+ 大小
    // （Range 探 → HEAD 兜底，并行；三样都拿不到的字段保持 null）。
    final headProbe = probeHead ??
        (String u) => probeHeadSize(u, {'Referer': pageUrl});
    final sizes = await Future.wait(files.map((u) async {
      try {
        final p = await DownloadManager.probeRange(u, {'Referer': pageUrl});
        if (p.totalBytes > 0) return p.totalBytes;
      } catch (_) {}
      try {
        return await headProbe(u);
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
        durationSec: _domDuration(domDurations, u) ??
            durationFromDom(u) ??
            durationFromPage(u),
        resolution: resolutionFromDom(u) ?? resolutionFromPage(u),
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

  /// HEAD 探大小：只拿响应头、不下正文。返回 Content-Length（>0 才算），
  /// 拿不到返回 null，不抛错。
  static Future<int?> probeHeadSize(
      String url, Map<String, String> headers) async {
    try {
      final res = await http
          .head(Uri.parse(url), headers: {'User-Agent': _ua, ...headers})
          .timeout(const Duration(seconds: 8));
      final cl = res.headers['content-length'] ?? '';
      final n = int.tryParse(cl.trim()) ?? 0;
      return n > 0 ? n : null;
    } catch (_) {
      return null;
    }
  }

  /// 媒体播放列表正文 -> (总时长秒, 分片数)。供单元测试直接验。
  static (int, int) parseM3u8Durations(String body) {
    return HlsPlaylist.parseMediaDurations(body);
  }
}
