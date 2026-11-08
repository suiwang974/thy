import 'package:http/http.dart' as http;

import '../models/video_item.dart';

/// 播之前把“视频页”解析成“能直接播的直链”。
/// 规则照 JS 插件搬过来：
/// - 片库条目自带 streamUrl（+ referer），直接用；
/// - r34 详情页里有 master.m3u8，无需 Referer；
/// - niacg 详情页里有 file.xunge.cyou mp4，播时必须带 Referer=详情页；
/// - lianzu11 详情页里有 mp4，无需 Referer；
/// - xvideos/xhamster/pornhub/spankbang 插件里没有直链解析，返回 null，
///   播放页会显示“在源站看”（App 内嵌网页打开源站视频页）。
class ResolvedStream {
  final String url;
  final Map<String, String> headers;
  const ResolvedStream(this.url, [this.headers = const {}]);
}

class StreamResolver {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static Future<ResolvedStream?> resolve(VideoItem item) async {
    // 1. 目录自带直链：直接播（03 批 5 条 streamUrl 为空，播不了，返回 null）。
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
    } catch (_) {
      // 解析失败就返回 null，播放页走“在源站看”。
    }
    return null;
  }
}
