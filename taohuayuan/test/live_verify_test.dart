import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:taohuayuan/data/sources.dart';
import 'package:taohuayuan/services/stream_resolver.dart';

/// 联网验证（只在明确跑这个文件时跑，不进常规 flutter test 的快通道）：
///   flutter test test/live_verify_test.dart
/// 跑真实 HTTP，验 Dart 版搜索逻辑 + VM 网络通。
/// 注意：VM 的网络和手机网络不一样，这里只证明逻辑 + VM 网络通；
/// 手机上的真实情况仍要真机验。
const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

void main() {
  test('Eporner API 实时搜 foot 有结果', () async {
    final res = await http
        .get(Uri.parse('https://www.eporner.com/api/v2/video/search/?query=foot&per_page=5&page=1&format=json'),
            headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 25));
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final vids = (json['videos'] ?? []) as List;
    expect(vids, isNotEmpty);
    expect(EpornerSource.parseVideos(vids).length, vids.length);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('第 48 条：Eporner latest 实测——order=latest 返回的就是最近的新片', () async {
    final r = await EpornerSource().latest(page: 1);
    expect(r.error, isNull);
    expect(r.items, isNotEmpty);
    final dated = r.items.where((v) => v.publishedAtMs > 0).toList();
    expect(dated, isNotEmpty);
    // 返回的都是最近几天的新片（added 字段即发布时间），不是几年前的老片。
    final now = DateTime.now().millisecondsSinceEpoch;
    final newest = dated.map((v) => v.publishedAtMs).reduce((a, b) => a > b ? a : b);
    expect(now - newest, lessThan(14 * 24 * 3600 * 1000));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('Rule34Video 搜索页实时抓 foot 有结果', () async {
    final res = await http
        .get(Uri.parse('https://rule34-videos.com/search/?q=foot'), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 25));
    final items = Rule34VideosSource.parseSearchHtml(res.body);
    expect(items, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('Niacg 搜索页状态（只记录，不判死刑：VM 下可能 302/断连）', () async {
    try {
      final res = await http
          .get(Uri.parse('https://www.niacg.com/e/search/?searchget=1&keyboard=foot&show=title&classid=21&page=1'),
              headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 25));
      final items = NiacgSource.parseSearchHtml(res.body);
      // ignore: avoid_print
      print('Niacg 搜 foot：HTTP ${res.statusCode}，解析出 ${items.length} 条');
    } catch (e) {
      // VM 网络下 niacg 经常直接断连（已知情况，手机网络要另验），只记录不判失败。
      // ignore: avoid_print
      print('Niacg 搜 foot 异常（VM 网络问题，待手机真机复验）：$e');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('Hanime1/HanimeOne 状态（只记录，不判死刑：VM 下 Cloudflare 403 是已知的墙）', () async {
    // 2026-11-09 VM 实测：hanime1.me、hanimeone.me 的搜索页都返回 403
    // Cloudflare "Just a moment..."，纯 HTTP 过不了验证。
    // 所以这两个源在 App 里标 webViewOnly，走内置浏览器 + 视频页嗅直链；
    // 这个测试只记录状态，不判失败——手机真机上 WebView 那条路要另验。
    for (final host in ['hanime1.me', 'hanimeone.me']) {
      try {
        final res = await http
            .get(Uri.parse('https://$host/search?query=foot&page=1&genre=%E8%A3%8F%E7%95%AA'),
                headers: {'User-Agent': _ua})
            .timeout(const Duration(seconds: 25));
        // ignore: avoid_print
        print('$host 搜 foot：HTTP ${res.statusCode}（200 说明 HTTP 通了，解析按 Kazumi 规则走；'
            '403 说明仍被 Cloudflare 拦，走 WebView）');
      } catch (e) {
        // ignore: avoid_print
        print('$host 搜 foot 异常（VM 网络问题，待手机真机复验）：$e');
      }
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('直链可达：eporner 搜 foot 取第一条走签名流程（裸 gvideo 链 403 是死路）', () async {
    final res = await http
        .get(Uri.parse('https://www.eporner.com/api/v2/video/search/?query=foot&per_page=3&page=1&format=json'),
            headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 25));
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final items = EpornerSource.parseVideos((json['videos'] ?? []) as List);
    expect(items, isNotEmpty);
    final stream = await StreamResolver.resolve(items.first);
    // ignore: avoid_print
    print('eporner 第一条解析结果：${stream?.url ?? 'null（签名流程失败，走 App 内嵌官方播放器）'}');
    if (stream != null) {
      // 签名地址在 vid-*-cdn.eporner.com 上，绝不是裸 gvideo 链。
      expect(stream.url, contains('cdn.eporner.com'));
      expect(stream.url.contains('gvideo.eporner.com'), isFalse);
      expect(StreamResolver.isSaneStreamUrl(stream.url), isTrue);
      // 签名地址现拉现验：Range 拉前 1KB 要 206。
      final head = await http.get(Uri.parse(stream.url),
          headers: {'User-Agent': _ua, 'Range': 'bytes=0-1023'}).timeout(const Duration(seconds: 25));
      // ignore: avoid_print
      print('eporner 签名直链 Range 拉流：HTTP ${head.statusCode}');
      expect(head.statusCode, 206);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('直链可达：r34 搜 foot 取第一条解析直链（优先 contentUrl mp4，其次 master.m3u8）', () async {
    final res = await http
        .get(Uri.parse('https://rule34-videos.com/search/?q=foot'), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 25));
    final items = Rule34VideosSource.parseSearchHtml(res.body);
    expect(items, isNotEmpty);
    final stream = await StreamResolver.resolve(items.first);
    // ignore: avoid_print
    print('r34 第一条解析结果：${stream?.url ?? 'null（解析不到，走 App 内嵌官方播放器）'}');
    if (stream != null) {
      // 直链必须是 mp4 或 m3u8，且过 sanity 检查（之前兜底正则抓出几 KB
      // 垃圾地址导致 Source error 的教训）。
      expect(stream.url.contains('.mp4') || stream.url.contains('.m3u8'), isTrue);
      expect(StreamResolver.isSaneStreamUrl(stream.url), isTrue);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('直链可达：niacg 搜 3d 取第一条解析 xunge mp4（带 Referer）', () async {
    try {
      final res = await http
          .get(Uri.parse('https://www.niacg.com/e/search/?searchget=1&keyboard=3d&show=title&classid=21&page=1'),
              headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 25));
      final items = NiacgSource.parseSearchHtml(res.body);
      // ignore: avoid_print
      print('niacg 搜 3d：HTTP ${res.statusCode}，解析出 ${items.length} 条');
      if (items.isEmpty) return; // VM 网络下 niacg 常断连，只记录不判失败
      final stream = await StreamResolver.resolve(items.first);
      // ignore: avoid_print
      print('niacg 第一条解析结果：${stream?.url ?? 'null（解析不到，走“在源站看”）'}');
      if (stream != null) {
        expect(stream.url, contains('xunge.cyou'));
        expect(stream.headers['Referer'], isNotNull);
      }
    } catch (e) {
      // VM 网络下 niacg 经常直接断连（已知情况，手机网络要另验），只记录不判失败。
      // ignore: avoid_print
      print('niacg 解析异常（VM 网络问题，待手机真机复验）：$e');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
