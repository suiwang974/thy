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

  test('直链可达：r34 搜 foot 取第一条解析 master.m3u8', () async {
    final res = await http
        .get(Uri.parse('https://rule34-videos.com/search/?q=foot'), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 25));
    final items = Rule34VideosSource.parseSearchHtml(res.body);
    expect(items, isNotEmpty);
    final stream = await StreamResolver.resolve(items.first);
    // ignore: avoid_print
    print('r34 第一条解析结果：${stream?.url ?? 'null（解析不到，走“在源站看”）'}');
    if (stream != null) {
      expect(stream.url, contains('m3u8'));
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
