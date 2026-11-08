/// 一个视频条目：可以来自在线片库目录，也可以来自某个源的搜索结果。
class VideoItem {
  final String id;
  final String title;
  final String author;
  final String batch;
  final int durationSec;
  final String resolution;
  final String poster; // 本地 asset 路径（assets/thumbs/xxx.jpg）或网络 URL，或 ''
  final String? streamUrl; // 能直接播的 mp4/m3u8 直链（可能为 null：03 批待补链）
  final String? referer; // 播直链时要带的 Referer（niacg 的 xunge 链需要）
  final String source; // 来源标识：eporner / rule34videos / niacg / lianzu11 / xvideos / xhamster / pornhub / spankbang / 片库
  final String? pageUrl; // 在源站的视频页（点“在源站看”用；没有直链时也用它兜底播）
  final List<String> keywords;
  final bool needsRelink; // true = 直链待补，暂时播不了

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
  });

  /// 能不能直接播（有直链）。
  bool get playable => streamUrl != null && streamUrl!.isNotEmpty;

  String get durationText {
    if (durationSec <= 0) return '';
    final m = durationSec ~/ 60;
    final s = durationSec % 60;
    return m > 0 ? '$m:${s.toString().padLeft(2, '0')}' : '0:${s.toString().padLeft(2, '0')}';
  }

  factory VideoItem.fromCatalog(Map<String, dynamic> j) {
    return VideoItem(
      id: (j['id'] ?? '') as String,
      title: (j['title'] ?? '') as String,
      author: (j['author'] ?? '') as String,
      batch: (j['batch'] ?? '') as String,
      durationSec: ((j['durationSec'] ?? 0) as num).toInt(),
      resolution: (j['resolution'] ?? '') as String,
      poster: (j['poster'] ?? '') as String,
      streamUrl: j['streamUrl'] as String?,
      referer: j['referer'] as String?,
      source: '片库',
      pageUrl: j['sourcePage'] as String?,
      keywords: ((j['keywords'] ?? []) as List).map((e) => e.toString()).toList(),
      needsRelink: (j['needsRelink'] ?? false) as bool,
    );
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
        source: (j['source'] ?? '片库') as String,
        pageUrl: j['pageUrl'] as String?,
        keywords: ((j['keywords'] ?? []) as List).map((e) => e.toString()).toList(),
        needsRelink: (j['needsRelink'] ?? false) as bool,
      );
}
