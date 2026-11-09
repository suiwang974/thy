import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:taohuayuan/data/sources.dart';
import 'package:taohuayuan/services/downloader.dart';
import 'package:taohuayuan/services/stream_resolver.dart';

/// 提速实测（第 28 条）：不是本地回环，是真实源站直链。
///   flutter test tool/bench_download.dart
/// 不进常规 flutter test（文件不在 test/ 下）。
/// 测两样：
/// ① mp4 整文件：单连接（downloadSingle）vs 8 段 Range 并行（downloadSegmented），
///    同一条 eporner 签名 mp4；
/// ② HLS：分片逐个串行取 vs downloadHlsFile（8 并行取），同一条 r34 master.m3u8。
/// 数字是 VM 实测（VM 网络 ≠ 手机网络），手机待复验；不要拿 1DM 的「500%」充数。
const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

void main() {
  test('bench mp4：单连接 vs 8 段并行（eporner 签名直链）', () async {
    final res = await http
        .get(
            Uri.parse(
                'https://www.eporner.com/api/v2/video/search/?query=foot&per_page=20&page=1&format=json'),
            headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 25));
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final items = EpornerSource.parseVideos((json['videos'] ?? []) as List);
    expect(items, isNotEmpty);
    // 别拿第一条就测：第一条可能是 1.8GB 的长直播录像（Webcam Feet 112），
    // 单连接下一遍就要十几分钟，/tmp 还是 512MB 的 tmpfs，根本装不下。
    // 20 条里挑一条 1–10 分钟的短片做对照，文件几十 MB；没有就挑最短的那条。
    final shorts = items.where((i) => i.durationSec >= 60 && i.durationSec <= 600).toList();
    final item = shorts.isNotEmpty
        ? shorts.first
        : (items.toList()..sort((a, b) => a.durationSec.compareTo(b.durationSec))).first;
    final stream = await StreamResolver.resolve(item);
    if (stream == null) {
      // ignore: avoid_print
      print('BENCH mp4：eporner 签名解析失败，跳过（走 App 内嵌官方播放器那条路）');
      return;
    }
    final url = stream.url;
    final probe = await DownloadManager.probeRange(url, stream.headers);
    // ignore: avoid_print
    print('BENCH mp4：${item.title}，总量 '
        '${(probe.totalBytes / 1048576).toStringAsFixed(1)}MB，'
        'Range 支持=${probe.supported}');
    expect(probe.supported, isTrue);
    expect(probe.totalBytes, greaterThan(0));
    if (probe.totalBytes > 300 * 1024 * 1024) {
      // /tmp 是 512MB 的 tmpfs，300MB 以上的片子下两遍装不下，跳过不硬测。
      // ignore: avoid_print
      print('BENCH mp4：挑到的片子 ${(probe.totalBytes / 1048576).toStringAsFixed(0)}MB，'
          '太大，跳过（/tmp 只有 512MB）');
      return;
    }

    final tmp = await Directory.systemTemp.createTemp('bench-mp4');
    try {
      final singlePath = '${tmp.path}/single.mp4';
      var sw = Stopwatch()..start();
      await DownloadManager.downloadSingle(
        url: url,
        headers: stream.headers,
        targetPath: singlePath,
        onBytes: (_) {},
        isCancelled: () => false,
      );
      sw.stop();
      final singleBytes = await File(singlePath).length();
      final singleMbps = singleBytes / sw.elapsedMilliseconds * 1000 / 1048576;
      // ignore: avoid_print
      print('BENCH mp4 单连接：${sw.elapsed.inSeconds} 秒，'
          '${singleMbps.toStringAsFixed(2)} MB/s');

      final segPath = '${tmp.path}/seg.mp4';
      sw = Stopwatch()..start();
      final used = await DownloadManager.downloadSegmented(
        url: url,
        headers: stream.headers,
        targetPath: segPath,
        parts: 8,
        onProgress: (_, _) {},
      );
      sw.stop();
      final segBytes = await File(segPath).length();
      final segMbps = segBytes / sw.elapsedMilliseconds * 1000 / 1048576;
      // ignore: avoid_print
      print('BENCH mp4 $used 段并行：${sw.elapsed.inSeconds} 秒，'
          '${segMbps.toStringAsFixed(2)} MB/s，'
          '加速比 ${(segMbps / singleMbps).toStringAsFixed(2)}x');
      expect(segBytes, singleBytes);
      expect(used, greaterThan(1));
    } finally {
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('bench HLS：分片串行 vs 8 并行（r34 master.m3u8）', () async {
    final res = await http
        .get(Uri.parse('https://rule34-videos.com/search/?q=foot'),
            headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 25));
    final items = Rule34VideosSource.parseSearchHtml(res.body);
    expect(items, isNotEmpty);
    final stream = await StreamResolver.resolve(items.first);
    if (stream == null || !stream.url.contains('.m3u8')) {
      // ignore: avoid_print
      print('BENCH HLS：r34 第一条没解析出 m3u8（${stream?.url ?? 'null'}），跳过');
      return;
    }
    // 先把主列表解成媒体播放列表（跟 downloadHlsFile 同一步：选 BANDWIDTH
    // 最大的变体），再从媒体列表里取分片。直接拿主列表当媒体列表解析会把
    // 变体 .m3u8 当成分片，串行基线只会下到几百字节的文本文件，数字全错。
    final masterBody = utf8.decode((await http
            .get(Uri.parse(stream.url),
                headers: {'User-Agent': _ua, ...stream.headers})
            .timeout(const Duration(seconds: 25)))
        .bodyBytes);
    final mediaUrl = masterBody.contains('#EXT-X-STREAM-INF')
        ? DownloadManager.pickHlsVariant(masterBody, stream.url)!
        : stream.url;
    final mediaRes = await http
        .get(Uri.parse(mediaUrl), headers: {'User-Agent': _ua, ...stream.headers})
        .timeout(const Duration(seconds: 25));
    final segs = DownloadManager.parseHlsSegments(
        utf8.decode(mediaRes.bodyBytes), mediaUrl);
    // ignore: avoid_print
    print('BENCH HLS：${items.first.title}，${segs.length} 个分片');

    var sw = Stopwatch()..start();
    var serialBytes = 0;
    for (final s in segs) {
      final r = await http
          .get(Uri.parse(s), headers: {'User-Agent': _ua, ...stream.headers})
          .timeout(const Duration(seconds: 30));
      serialBytes += r.bodyBytes.length;
    }
    sw.stop();
    final serialMbps = serialBytes / sw.elapsedMilliseconds * 1000 / 1048576;
    // ignore: avoid_print
    print('BENCH HLS 串行：${sw.elapsed.inSeconds} 秒，'
        '${serialMbps.toStringAsFixed(2)} MB/s（${(serialBytes / 1048576).toStringAsFixed(1)}MB）');

    final tmp = await Directory.systemTemp.createTemp('bench-hls');
    try {
      sw = Stopwatch()..start();
      final out = await DownloadManager.downloadHlsFile(
        masterUrl: stream.url,
        headers: stream.headers,
        targetPath: '${tmp.path}/out.ts.tmp',
      );
      sw.stop();
      final parBytes = await File(out).length();
      final parMbps = parBytes / sw.elapsedMilliseconds * 1000 / 1048576;
      // ignore: avoid_print
      print('BENCH HLS 8 并行：${sw.elapsed.inSeconds} 秒，'
          '${parMbps.toStringAsFixed(2)} MB/s（${(parBytes / 1048576).toStringAsFixed(1)}MB），'
          '加速比 ${(parMbps / serialMbps).toStringAsFixed(2)}x');
      expect(parBytes, greaterThan(0));
    } finally {
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
