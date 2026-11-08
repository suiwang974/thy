/// 一个视频条目：来自 8 个在线源之一的搜索/热门结果。
/// 没有本地目录：所有数据都是实时从网上查来的。
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
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
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
