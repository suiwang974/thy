// 一个视频条目：来自 10 个在线源之一的搜索/热门结果。
// 没有本地目录：所有数据都是实时从网上查来的。
import 'dart:convert';

class VideoItem {
  final String id;
  final String title;
  final String author;
  final String batch; // 保留字段（在线源为空）；播放页不再按批次分组。
  final int durationSec;
  final String resolution; // 如 '1080p'；在线源多数不提供，空 = 未知。
  final String poster; // 网络 URL，或 ''（无封面也收，显示文字卡）。
  final String? streamUrl; // 能直接播的 mp4/m3u8 直链（可能为 null：要先解析详情页）。
  final String? referer; // 播直链时要带的 Referer（niacg 的 xunge 链需要）。
  final String source; // 来源标识：eporner / rule34videos / niacg / lianzu11 / xvideos / xhamster / pornhub / spankbang
  final String? pageUrl; // 在源站的视频页（点“在源站看”用；没有直链时也用它兜底播）。
  final List<String> keywords; // 标签：用于分类过滤、推荐打分。
  final bool needsRelink; // true = 直链待补，暂时播不了（在线源解析失败时用）。
  final int views; // 播放量（源站提供才有；没有就是 0，用于“最多看”排序）。
  final int publishedAtMs; // 发布时间（毫秒时间戳；没有就是 0，用于“最新”排序/新鲜度）。

  const VideoItem({
    required this.id,
    required this.title,
    this.author = '',
    this.batch = '',
    this.durationSec = 0,
    this.resolution = '',
    this.poster = '',
    this.streamUrl,
    this.referer,
    required this.source,
    this.pageUrl,
    this.keywords = const [],
    this.needsRelink = false,
    this.views = 0,
    this.publishedAtMs = 0,
  });

  /// 能不能直接播（有直链）。
  bool get playable => streamUrl != null && streamUrl!.isNotEmpty;

  /// App 内嵌官方播放器用的地址：只嵌视频播放器本身（embed 播放页），
  /// 不要嵌整个源站网站（第 32 条：嵌整站根本看不了视频）。
  /// - eporner：https://www.eporner.com/embed/{id}/（官方 embed 页）；
  /// - pornhub：https://www.pornhub.com/embed/{viewkey}（VM 验通：200，
  ///   页里有 mediaDefinitions，干净的播放器页）；
  /// - xhamster：https://xhamster.com/embed/{id}（VM 验通数字 id：200，
  ///   新式字母 id 按同一规则拼，未验真页）；
  /// - xvideos：https://www.xvideos.com/embedframe/{id}（VM 验通真 id：
  ///   200，页里有 setVideoUrlHigh + mp4 直链）；
  /// - spankbang：embed 格式 VM 下 403 没法验，暂留视频页（整页能播，
  ///   手机待验后补 embed）；
  /// - r34/niacg/lianzu11/hanime：没有单独的 embed 页，视频页本身就是
  ///   播放器页，直接用视频页。
  String get embedUrl {
    if (source == 'eporner' && id.startsWith('eporner-')) {
      return 'https://www.eporner.com/embed/${id.substring('eporner-'.length)}/';
    }
    final page = pageUrl ?? '';
    if (page.isEmpty) return '';
    if (source == 'pornhub') {
      final key = RegExp(r'viewkey=([A-Za-z0-9]+)').firstMatch(page)?.group(1);
      if (key != null) return 'https://www.pornhub.com/embed/$key';
      return page;
    }
    if (source == 'xhamster') {
      final m = RegExp(r'/videos/([^/?#]+)').firstMatch(page);
      if (m != null) {
        final slug = m.group(1)!;
        // 新式 id（xhu72iL）直接用；老式 slug（footjob-14468644）取尾部数字。
        final num = RegExp(r'(\d+)$').firstMatch(slug)?.group(1);
        final embId = slug.startsWith('xh') ? slug : (num ?? slug);
        return 'https://xhamster.com/embed/$embId';
      }
      return page;
    }
    if (source == 'xvideos') {
      final m = RegExp(r'/video\.([^/?#]+)').firstMatch(page);
      if (m != null) return 'https://www.xvideos.com/embedframe/${m.group(1)}';
      return page;
    }
    return page;
  }

  VideoItem copyWith({
    String? title,
    String? author,
    int? durationSec,
    String? resolution,
    String? poster,
    String? streamUrl,
    String? referer,
    String? pageUrl,
    List<String>? keywords,
    int? views,
    int? publishedAtMs,
  }) =>
      VideoItem(
        id: id,
        title: title ?? this.title,
        author: author ?? this.author,
        batch: batch,
        durationSec: durationSec ?? this.durationSec,
        resolution: resolution ?? this.resolution,
        poster: poster ?? this.poster,
        streamUrl: streamUrl ?? this.streamUrl,
        referer: referer ?? this.referer,
        source: source,
        pageUrl: pageUrl ?? this.pageUrl,
        keywords: keywords ?? this.keywords,
        needsRelink: needsRelink,
        views: views ?? this.views,
        publishedAtMs: publishedAtMs ?? this.publishedAtMs,
      );

  /// 是不是 1080p 或以上（画质过滤用；分辨率未知时返回 false，
  /// 过滤逻辑里“未知”当作通过——因为源站没给数据，不能直接丢掉）。
  bool get isHd {
    final r = resolution.toLowerCase();
    return r.contains('1080') || r.contains('2160') || r.contains('4k') || r.contains('1440');
  }

  /// 乱码修复：UTF-8 字节被当成 latin1 解出来的标题（比如 "Iâ€™m" 其实是 "I'm"、
  /// "â€¦" 其实是 "…"），按字节重新拼回来再按 UTF-8 解。
  /// 乱码特征：含 â 或 Ã（UTF-8 多字节的首字节被当成 latin1 字符）。
  /// Eporner 的 API 甚至直接在 JSON 里写 \u00e2\u0080\u0099 这种转义，
  /// 乱码长在数据里，光改解码还不够，标题进屏前必须过这一道。
  /// 修完还有替换符、或特征还在、或有无法映射的字符的，原样返回，不硬修。
  static String repairMojibake(String s) {
    if (!s.contains('â') && !s.contains('Ã')) return s;
    const cp1252 = <int, int>{
      0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85,
      0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A,
      0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92,
      0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
      0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C,
      0x017E: 0x9E, 0x0178: 0x9F,
    };
    try {
      final bytes = <int>[];
      for (final unit in s.codeUnits) {
        if (unit <= 0xFF) {
          bytes.add(unit);
        } else if (cp1252.containsKey(unit)) {
          bytes.add(cp1252[unit]!);
        } else {
          return s; // 有正常多字节字符，说明不是纯乱码，不动它
        }
      }
      final fixed = utf8.decode(bytes);
      if (fixed.contains('�')) return s;
      if (fixed.contains('â') || fixed.contains('Ã')) return s;
      return fixed;
    } catch (_) {
      return s;
    }
  }

  String get durationText {
    if (durationSec <= 0) return '';
    final m = durationSec ~/ 60;
    final s = durationSec % 60;
    return m > 0 ? '$m:${s.toString().padLeft(2, '0')}' : '0:${s.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'batch': batch,
        'durationSec': durationSec,
        'resolution': resolution,
        'poster': poster,
        'streamUrl': streamUrl,
        'referer': referer,
        'source': source,
        'pageUrl': pageUrl,
        'keywords': keywords,
        'needsRelink': needsRelink,
        'views': views,
        'publishedAtMs': publishedAtMs,
      };

  factory VideoItem.fromJson(Map<String, dynamic> j) => VideoItem(
        id: (j['id'] ?? '') as String,
        // 缓存/记录里可能存着旧的乱码标题（latin1 误解 UTF-8 的产物），
        // 读出来时顺手修掉，乱码标题不许再上屏。
        title: repairMojibake((j['title'] ?? '') as String),
        author: repairMojibake((j['author'] ?? '') as String),
        batch: (j['batch'] ?? '') as String,
        durationSec: ((j['durationSec'] ?? 0) as num).toInt(),
        resolution: (j['resolution'] ?? '') as String,
        poster: (j['poster'] ?? '') as String,
        streamUrl: j['streamUrl'] as String?,
        referer: j['referer'] as String?,
        source: (j['source'] ?? '') as String,
        pageUrl: j['pageUrl'] as String?,
        keywords: ((j['keywords'] ?? []) as List).map((e) => e.toString()).toList(),
        needsRelink: (j['needsRelink'] ?? false) as bool,
        views: ((j['views'] ?? 0) as num).toInt(),
        publishedAtMs: ((j['publishedAtMs'] ?? 0) as num).toInt(),
      );
}
