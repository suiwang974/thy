import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
// get_video_thumbnail 0.9.1 只导出了 XFile，没有导出 ImageFormat，只能直接引
// 它的 src 文件；这是该包的缺陷（连它自己 README 的示例都因此编不过）。
// ignore: implementation_imports
import 'package:get_video_thumbnail/src/image_format.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:taohuayuan/services/downloader.dart';
import 'package:taohuayuan/transfer/concurrency_ramp.dart';
import 'package:taohuayuan/transfer/throughput_tracker.dart';
import 'package:taohuayuan/transfer/transfer_config.dart';

/// 本地 HttpServer：支持 Range（206）与忽略 Range（200）两种模式，
/// 再加 HLS 播放列表与分片。提速对照与 HLS 拼合都在这上面验，
/// 不依赖外网、不依赖源站直链。
void main() {
  late HttpServer server;
  late Uint8List fileBytes; // 20MB 确定性内容（20 ÷ 每段至少 2MB = 正好 8 段）
  late String base;
  // fix5：记下每个路径收到的请求头（Referer/UA 的真凭据）与请求次数。
  final seenHeaders = <String, Map<String, String>>{};
  final requestCounts = <String, int>{};

  setUpAll(() async {
    fileBytes = Uint8List.fromList(
        List<int>.generate(20 * 1024 * 1024, (i) => (i * 7 + 13) % 251));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) async {
      final p = req.uri.path;
      seenHeaders[p] = {
        for (final k in ['referer', 'user-agent'])
          if (req.headers.value(k) != null) k: req.headers.value(k)!,
      };
      requestCounts[p] = (requestCounts[p] ?? 0) + 1;
      if (p == '/file.mp4') {
        _serveFile(req, fileBytes, supportRange: true);
      } else if (p == '/file-norange.mp4') {
        _serveFile(req, fileBytes, supportRange: false);
      } else if (p == '/file-probe206.mp4') {
        // 第 57 条(a)：探测（bytes=0-0）给 206，分段请求一律回 200。
        if (req.headers.value('range') == 'bytes=0-0') {
          _serveFile(req, fileBytes, supportRange: true);
        } else {
          _serveFile(req, fileBytes, supportRange: false);
        }
      } else if (p == '/master.m3u8') {
        _serveText(req, '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=500000\n'
            '/low.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000\n'
            '/high.m3u8\n');
      } else if (p == '/low.m3u8' || p == '/high.m3u8') {
        _serveText(req, '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:10.0,\n'
            '/seg0.ts\n'
            '#EXTINF:10.0,\n'
            '/seg1.ts\n'
            '#EXTINF:10.0,\n'
            '/seg2.ts\n'
            '#EXT-X-ENDLIST\n');
      } else if (p == '/enc.m3u8') {
        _serveText(req, '#EXTM3U\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="/key.bin"\n'
            '#EXTINF:10.0,\n'
            '/seg0.ts\n'
            '#EXT-X-ENDLIST\n');
      } else if (p.startsWith('/seg')) {
        final idx = int.parse(p.substring(4, 5));
        _serveBytes(req, Uint8List.fromList(
            List<int>.generate(1000, (i) => (idx * 37 + i) % 251)));
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  group('probeRange', () {
    test('支持 Range 的服务器：206 + 总量', () async {
      final probe = await DownloadManager.probeRange('$base/file.mp4', {});
      expect(probe.supported, isTrue);
      expect(probe.totalBytes, fileBytes.length);
    });

    test('忽略 Range 的服务器：200 + 不支持', () async {
      final probe =
          await DownloadManager.probeRange('$base/file-norange.mp4', {});
      expect(probe.supported, isFalse);
      expect(probe.totalBytes, fileBytes.length);
    });
  });

  group('分段并行 vs 单连接', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dltest');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('8 段与 1 段下同一文件字节一致，进度到 1.0', () async {
      final segPath = '${tmp.path}/seg.mp4';
      final used = await DownloadManager.downloadSegmented(
        url: '$base/file.mp4',
        headers: const {},
        targetPath: segPath,
        parts: 8,
        onProgress: (_, _) {},
      );
      expect(used, 8);
      final segBytes = await File(segPath).readAsBytes();
      expect(segBytes.length, fileBytes.length);
      expect(segBytes, fileBytes);

      final singlePath = '${tmp.path}/single.mp4';
      await DownloadManager.downloadSingle(
        url: '$base/file.mp4',
        headers: const {},
        targetPath: singlePath,
        onBytes: (_) {},
        isCancelled: () => false,
      );
      final singleBytes = await File(singlePath).readAsBytes();
      expect(singleBytes, fileBytes);
    });

    test('服务器不支持 Range 时回落单连接（usedParts == 1）', () async {
      final outPath = '${tmp.path}/fallback.mp4';
      final used = await DownloadManager.downloadSegmented(
        url: '$base/file-norange.mp4',
        headers: const {},
        targetPath: outPath,
        parts: 8,
        onProgress: (_, _) {},
      );
      expect(used, 1);
      expect(await File(outPath).readAsBytes(), fileBytes);
    });

    test('downloadRange：一段 Range 写进 part 文件，字节正确', () async {
      // 第 57 条新语义：targetPath 是这段专属的 part 文件（不是多段共用的
      // 目标文件），writeOffset = part 文件里已有的字节数（全新下为 0）。
      final partPath = '${tmp.path}/range.part0';
      await DownloadManager.downloadRange(
        url: '$base/file.mp4',
        headers: const {},
        start: 100,
        end: 199,
        targetPath: partPath,
        writeOffset: 0,
        onBytes: (_) {},
        isCancelled: () => false,
      );
      expect(await File(partPath).readAsBytes(),
          fileBytes.sublist(100, 200));
    });

    test('downloadRange：断点续传——part 文件已有前 50 字节，接着下完', () async {
      final partPath = '${tmp.path}/resume.part0';
      await File(partPath).writeAsBytes(fileBytes.sublist(100, 150));
      await DownloadManager.downloadRange(
        url: '$base/file.mp4',
        headers: const {},
        start: 100,
        end: 199,
        targetPath: partPath,
        writeOffset: 50,
        onBytes: (_) {},
        isCancelled: () => false,
      );
      expect(await File(partPath).readAsBytes(),
          fileBytes.sublist(100, 200));
    });

    test('downloadRange：续传文件长度对不上记账时报错，不许静默拼坏', () async {
      final partPath = '${tmp.path}/resume-bad.part0';
      await File(partPath).writeAsBytes(fileBytes.sublist(100, 140));
      expect(
        () => DownloadManager.downloadRange(
          url: '$base/file.mp4',
          headers: const {},
          start: 100,
          end: 199,
          targetPath: partPath,
          writeOffset: 50, // 记账说已有 50 字节，文件实际只有 40 字节
          onBytes: (_) {},
          isCancelled: () => false,
        ),
        throwsStateError,
      );
    });

    test('第 57 条(a)：分段中途拿不到 206 就回落单连接，内容仍对', () async {
      final outPath = '${tmp.path}/midway200.mp4';
      final used = await DownloadManager.downloadSegmented(
        url: '$base/file-probe206.mp4',
        headers: const {},
        targetPath: outPath,
        parts: 8,
        onProgress: (_, _) {},
      );
      expect(used, 1);
      expect(await File(outPath).readAsBytes(), fileBytes);
      // 回落时 part 残留必须清掉，别留在磁盘上。
      expect(await File('$outPath.part0').exists(), isFalse);
    });
  });

  group('HLS', () {
    test('parseHlsSegments：相对地址按 baseUrl 拼', () {
      const body = '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXTINF:10.0,\n'
          'https://cdn.example.com/seg1.ts\n#EXT-X-ENDLIST\n';
      final segs = DownloadManager.parseHlsSegments(body, '$base/high.m3u8');
      expect(segs, ['$base/seg0.ts', 'https://cdn.example.com/seg1.ts']);
    });

    test('pickHlsVariant：选 BANDWIDTH 最大的变体', () {
      const body = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=500000\n'
          '/low.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2000000\n'
          '/high.m3u8\n';
      expect(
          DownloadManager.pickHlsVariant(body, '$base/master.m3u8'),
          '$base/high.m3u8');
    });

    test('downloadHlsFile：主列表选高清变体，分片按序拼成一个文件', () async {
      final tmp = await Directory.systemTemp.createTemp('hlstest');
      try {
        final out = await DownloadManager.downloadHlsFile(
          masterUrl: '$base/master.m3u8',
          headers: const {},
          targetPath: '${tmp.path}/out.ts.tmp',
        );
        expect(out, '${tmp.path}/out.ts.tmp');
        final bytes = await File(out).readAsBytes();
        expect(bytes.length, 3000);
        // 三片按序拼：每片内容由 idx 决定
        for (var seg = 0; seg < 3; seg++) {
          final slice = bytes.sublist(seg * 1000, (seg + 1) * 1000);
          expect(slice[0], (seg * 37) % 251);
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('downloadHlsFile：加密 HLS 直接报错，不假装能下', () async {
      final tmp = await Directory.systemTemp.createTemp('hlstest');
      try {
        await expectLater(
          DownloadManager.downloadHlsFile(
            masterUrl: '$base/enc.m3u8',
            headers: const {},
            targetPath: '${tmp.path}/enc.ts.tmp',
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('HLS 下载修复（fix5）', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hlsfix5');
      seenHeaders.clear();
      requestCounts.clear();
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('分段请求真实带出 Referer 与 UA（本地服务器记请求头）', () async {
      const referer = 'https://www.xvideos.com/video/1';
      final out = await DownloadManager.downloadHlsFile(
        masterUrl: '$base/master.m3u8',
        headers: const {'Referer': referer},
        targetPath: '${tmp.path}/out.ts.tmp',
      );
      final bytes = await File(out).readAsBytes();
      expect(bytes.length, 3000);
      for (final p in [
        '/master.m3u8',
        '/high.m3u8',
        '/seg0.ts',
        '/seg1.ts',
        '/seg2.ts'
      ]) {
        expect(seenHeaders[p]?['referer'], referer, reason: '$p 没带 Referer');
        expect(seenHeaders[p]?['user-agent'], contains('Chrome'),
            reason: '$p 没带 UA');
      }
    });

    test('签名在路径里：相对分片解析后签名还在', () {
      const body =
          '#EXTM3U\n#EXTINF:10.0,\nhls-1080p-f2e270.ts\n#EXTINF:10.0,\nhls-1080p-f2e271.ts\n';
      final segs = DownloadManager.parseHlsSegments(
        body,
        'https://hls-cdn77.xvideos-cdn.com/0TARefjlDnV4owLMxLmFkA==,1794904419/e3bb0ab2-4a8e-4c4f-befa-11be8f560dc0/6/hls.m3u8',
      );
      expect(segs.length, 2);
      for (final s in segs) {
        expect(s, contains('0TARefjlDnV4owLMxLmFkA==,1794904419'));
      }
    });

    test('每段完成即记账（onSegmentDone 逐段回调）', () async {
      final doneIdx = <int>{};
      final out = await DownloadManager.downloadHlsFile(
        masterUrl: '$base/master.m3u8',
        headers: const {},
        targetPath: '${tmp.path}/out.ts.tmp',
        onSegmentDone: (i) => doneIdx.add(i),
      );
      expect(doneIdx, {0, 1, 2});
      expect((await File(out).readAsBytes()).length, 3000);
    });

    test('403 后重拉分片列表再续传（只重拉 1 次）', () async {
      var seg1Tries = 0;
      var refreshCalls = 0;
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p == '/master.m3u8') {
          return http.Response(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\n/v.m3u8\n', 200);
        }
        if (p == '/v.m3u8') {
          return http.Response(
              '#EXTM3U\n#EXTINF:10.0,\n/s0.ts\n#EXTINF:10.0,\n/s1.ts\n#EXTINF:10.0,\n/s2.ts\n#EXT-X-ENDLIST\n',
              200);
        }
        if (p == '/s0.ts') return http.Response.bytes([65, 65, 65], 200);
        if (p == '/s1.ts') {
          seg1Tries++;
          return http.Response('forbidden', 403);
        }
        if (p == '/s1-fixed.ts') {
          return http.Response.bytes([66, 66, 66], 200);
        }
        if (p == '/s2.ts') return http.Response.bytes([67, 67, 67], 200);
        return http.Response('not found', 404);
      });
      final out = await DownloadManager.downloadHlsFile(
        masterUrl: 'http://mock/master.m3u8',
        headers: const {},
        targetPath: '${tmp.path}/out.ts.tmp',
        client: client,
        refreshSegments: () async {
          refreshCalls++;
          return [
            'http://mock/s0.ts',
            'http://mock/s1-fixed.ts',
            'http://mock/s2.ts',
          ];
        },
      );
      expect(refreshCalls, 1);
      // 每轮尝试发 2 次请求：原样头 403 后，换头（去 Referer + 备用 UA）再试一次
      // 也 403，才算这轮失败；3 轮共 6 次。
      expect(seg1Tries, 6);
      expect(await File(out).readAsBytes(),
          [65, 65, 65, 66, 66, 66, 67, 67, 67]);
    });

    test('Retry-After：429 等指定秒数后重试成功', () async {
      var s0Tries = 0;
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p == '/master.m3u8') {
          return http.Response(
              '#EXTM3U\n#EXTINF:10.0,\n/s0.ts\n#EXT-X-ENDLIST\n', 200);
        }
        if (p == '/s0.ts') {
          s0Tries++;
          if (s0Tries == 1) {
            return http.Response('slow down', 429,
                headers: {'retry-after': '1'});
          }
          return http.Response.bytes([68, 68], 200);
        }
        return http.Response('not found', 404);
      });
      final out = await DownloadManager.downloadHlsFile(
        masterUrl: 'http://mock/master.m3u8',
        headers: const {},
        targetPath: '${tmp.path}/out.ts.tmp',
        client: client,
      );
      expect(s0Tries, 2);
      expect(await File(out).readAsBytes(), [68, 68]);
    });

    test('alreadyDone：磁盘上已有的分段不重下', () async {
      final segDir = Directory('${tmp.path}/out.ts.tmp.segs');
      await segDir.create(recursive: true);
      await File('${segDir.path}/0.ts').writeAsBytes([65, 65, 65]);
      var s0Tries = 0;
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p == '/master.m3u8') {
          return http.Response(
              '#EXTM3U\n#EXTINF:10.0,\n/s0.ts\n#EXTINF:10.0,\n/s1.ts\n#EXT-X-ENDLIST\n',
              200);
        }
        if (p == '/s0.ts') {
          s0Tries++;
          return http.Response.bytes([65, 65, 65], 200);
        }
        if (p == '/s1.ts') return http.Response.bytes([66, 66], 200);
        return http.Response('not found', 404);
      });
      final out = await DownloadManager.downloadHlsFile(
        masterUrl: 'http://mock/master.m3u8',
        headers: const {},
        targetPath: '${tmp.path}/out.ts.tmp',
        alreadyDone: {0},
        client: client,
      );
      expect(s0Tries, 0);
      expect(await File(out).readAsBytes(), [65, 65, 65, 66, 66]);
    });
  });

  group('下载加速（fix5）', () {
    test('并发常量是 8 且可配；分段门槛是 2MB', () {
      expect(DownloadManager.hlsDefaultConcurrency, 8);
      expect(DownloadManager.defaultParts, 8);
      expect(DownloadManager.minSegmentedSize, 2 * 1024 * 1024);
    });

    test('HLS：单并发下 6 个请求只走 1 条 TCP 连接（共享连接复用）', () async {
      final seg = List<int>.generate(1000, (i) => i % 251);
      final srv = await _CountingServer.bind({
        '/m.m3u8': utf8.encode(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\n/v.m3u8\n'),
        '/v.m3u8': utf8.encode(
            '#EXTM3U\n#EXTINF:10.0,\n/s0.ts\n#EXTINF:10.0,\n/s1.ts\n#EXTINF:10.0,\n/s2.ts\n#EXTINF:10.0,\n/s3.ts\n#EXT-X-ENDLIST\n'),
        for (var i = 0; i < 4; i++) '/s$i.ts': seg,
      });
      final tmp = await Directory.systemTemp.createTemp('accel');
      try {
        final out = await DownloadManager.downloadHlsFile(
          masterUrl: '${srv.base}/m.m3u8',
          headers: const {'Referer': 'https://example.com/v/1'},
          targetPath: '${tmp.path}/out.ts.tmp',
          concurrency: 1,
        );
        expect((await File(out).readAsBytes()).length, 4000);
        expect(srv.requests, 6); // master + media + 4 分片
        expect(srv.accepted, 1); // 6 个请求只建 1 条连接（原来每次 http.get 都新建）
      } finally {
        await tmp.delete(recursive: true);
        await srv.close();
      }
    });

    test('HLS：默认 8 并发下连接数仍少于请求数', () async {
      final seg = List<int>.generate(1000, (i) => i % 251);
      final srv = await _CountingServer.bind({
        '/m.m3u8': utf8.encode(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\n/v.m3u8\n'),
        '/v.m3u8': utf8.encode(
            '#EXTM3U\n#EXTINF:10.0,\n/s0.ts\n#EXTINF:10.0,\n/s1.ts\n#EXTINF:10.0,\n/s2.ts\n#EXTINF:10.0,\n/s3.ts\n#EXT-X-ENDLIST\n'),
        for (var i = 0; i < 4; i++) '/s$i.ts': seg,
      });
      final tmp = await Directory.systemTemp.createTemp('accel8');
      try {
        final out = await DownloadManager.downloadHlsFile(
          masterUrl: '${srv.base}/m.m3u8',
          headers: const {},
          targetPath: '${tmp.path}/out.ts.tmp',
        );
        expect((await File(out).readAsBytes()).length, 4000);
        expect(srv.requests, 6);
        expect(srv.accepted, lessThanOrEqualTo(4)); // 4 个分片最多 4 路并行
        expect(srv.accepted, lessThan(srv.requests));
      } finally {
        await tmp.delete(recursive: true);
        await srv.close();
      }
    });

    test('HLS 流式写盘：大分片内容正确（256KB × 4）', () async {
      final seg = List<int>.generate(256 * 1024, (i) => (i * 7) % 251);
      final srv = await _CountingServer.bind({
        '/m.m3u8': utf8.encode(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\n/v.m3u8\n'),
        '/v.m3u8': utf8.encode(
            '#EXTM3U\n#EXTINF:10.0,\n/s0.ts\n#EXTINF:10.0,\n/s1.ts\n#EXTINF:10.0,\n/s2.ts\n#EXTINF:10.0,\n/s3.ts\n#EXT-X-ENDLIST\n'),
        for (var i = 0; i < 4; i++) '/s$i.ts': seg,
      });
      final tmp = await Directory.systemTemp.createTemp('accel-stream');
      try {
        final out = await DownloadManager.downloadHlsFile(
          masterUrl: '${srv.base}/m.m3u8',
          headers: const {},
          targetPath: '${tmp.path}/out.ts.tmp',
          concurrency: 2,
        );
        final bytes = await File(out).readAsBytes();
        expect(bytes.length, 1024 * 1024);
        for (var s = 0; s < 4; s++) {
          expect(bytes.sublist(s * 256 * 1024, (s + 1) * 256 * 1024), seg);
        }
      } finally {
        await tmp.delete(recursive: true);
        await srv.close();
      }
    });

    test('MP4 downloadRange：同一 HttpClient 三次调用只建 1 条连接', () async {
      final file = List<int>.generate(3000, (i) => i % 251);
      final srv = await _CountingServer.bind({'/f.mp4': file});
      final tmp = await Directory.systemTemp.createTemp('accel-mp4');
      try {
        final client = HttpClient();
        try {
          for (var i = 0; i < 3; i++) {
            await DownloadManager.downloadRange(
              url: '${srv.base}/f.mp4',
              headers: const {},
              start: i * 1000,
              end: i * 1000 + 999,
              targetPath: '${tmp.path}/p$i',
              writeOffset: 0,
              onBytes: (_) {},
              isCancelled: () => false,
              client: client,
            );
          }
        } finally {
          client.close(force: true);
        }
        expect(srv.requests, 3);
        expect(srv.accepted, 1);
        for (var i = 0; i < 3; i++) {
          expect(await File('${tmp.path}/p$i').readAsBytes(),
              file.sublist(i * 1000, (i + 1) * 1000));
        }
      } finally {
        await tmp.delete(recursive: true);
        await srv.close();
      }
    });

    test('MP4 分段门槛 2MB：4.8MB 文件也分段（原来 8MB 以下单连接）', () async {
      final file = List<int>.generate(4800 * 1024, (i) => i % 251);
      final srv = await _CountingServer.bind({'/f.mp4': file});
      final tmp = await Directory.systemTemp.createTemp('accel-thr');
      try {
        final used = await DownloadManager.downloadSegmented(
          url: '${srv.base}/f.mp4',
          headers: const {},
          targetPath: '${tmp.path}/out.mp4',
          parts: 8,
          onProgress: (_, _) {},
        );
        expect(used, 2); // 4.8MB ~/ 2MB = 2 段；旧门槛 8MB 时 used == 1
        expect(await File('${tmp.path}/out.mp4').readAsBytes(), file);
      } finally {
        await tmp.delete(recursive: true);
        await srv.close();
      }
    });

    test('403 换请求头恢复：带 Referer 被 403，去 Referer 后通', () async {
      var forbidden = 0;
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p == '/m.m3u8') {
          return http.Response(
              '#EXTM3U\n#EXTINF:10.0,\n/s0.ts\n#EXT-X-ENDLIST\n', 200);
        }
        if (p == '/s0.ts') {
          final hasReferer = req.headers.entries
              .any((e) => e.key.toLowerCase() == 'referer');
          if (hasReferer) {
            forbidden++;
            return http.Response('forbidden', 403);
          }
          return http.Response.bytes([9, 9, 9], 200);
        }
        return http.Response('not found', 404);
      });
      final tmp = await Directory.systemTemp.createTemp('accel403');
      try {
        final out = await DownloadManager.downloadHlsFile(
          masterUrl: 'http://mock/m.m3u8',
          headers: const {'Referer': 'https://www.xvideos.com/video/1'},
          targetPath: '${tmp.path}/out.ts.tmp',
          client: client,
        );
        expect(forbidden, 1); // 第一次带 Referer 被 403，换头重试通了
        expect(await File(out).readAsBytes(), [9, 9, 9]);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('自适应并发：起步 8，被压制减半，好转再爬坡', () {
      final tracker = ThroughputTracker();
      final ramp = ConcurrencyRamp(
        config: const TransferConfig(
            startConcurrency: 8, minConcurrency: 4, maxConcurrency: 16),
        tracker: tracker,
      );
      expect(ramp.current, 8);
      tracker.record(const RunMeasurement(
          bytes: 1000,
          elapsed: Duration(seconds: 1),
          concurrency: 8,
          status429: 1));
      expect(ramp.next(), 4); // 被 429 压制：8 -> 4，并冷却一轮
      tracker.record(const RunMeasurement(
          bytes: 1000, elapsed: Duration(seconds: 1), concurrency: 4));
      expect(ramp.next(), 4); // 冷却期内不动
      tracker.record(const RunMeasurement(
          bytes: 2000, elapsed: Duration(seconds: 1), concurrency: 4));
      expect(ramp.next(), 5); // 速率翻倍：4 -> 5
    });
  });

  test('第 38 条：下载失败写人话，不甩原始堆栈', () {
    expect(
      DownloadManager.humanDownloadError(
        'HandshakeException: Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: Hostname mismatch(handshake.cc:320))',
      ),
      contains('证书验证失败'),
    );
    expect(
      DownloadManager.humanDownloadError('SocketException: Failed host lookup'),
      contains('网络连不上'),
    );
    expect(
      DownloadManager.humanDownloadError('HTTP 403 Forbidden'),
      contains('403'),
    );
    // 原始堆栈里的文件名行号不许出现在给用户看的文案里。
    expect(
      DownloadManager.humanDownloadError(
        'HandshakeException: Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: Hostname mismatch(handshake.cc:320))',
      ),
      isNot(contains('handshake.cc')),
    );
  });

  group('封面抽帧（extractPosterFrame）', () {
    const channelName = 'plugins.kasunthilina.dev/get_video_thumbnail';
    final channel = const MethodChannel(channelName);

    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    Map<String, dynamic>? lastArgs;
    String mockMode = 'success';

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      lastArgs = null;
      mockMode = 'success';
      messenger().setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'file') return null;
        final args = Map<String, dynamic>.from(call.arguments as Map);
        lastArgs = args;
        final callId = args['callId'] as int;
        final fakePath = '${args['path']}/thumb.jpg';
        final mode = mockMode;
        // 原生侧先回 true，再异步发结果，模拟真实插件行为。
        Future.microtask(() async {
          final MethodCall reply;
          switch (mode) {
            case 'error':
              reply = MethodCall('result#error', {
                'result': 'boom',
                'callId': callId,
              });
              break;
            case 'empty':
              reply = MethodCall('result#file', {
                'result': '',
                'callId': callId,
              });
              break;
            default:
              reply = MethodCall('result#file', {
                'result': fakePath,
                'callId': callId,
              });
          }
          await messenger().handlePlatformMessage(
            channelName,
            const StandardMethodCodec().encodeMethodCall(reply),
            (_) {},
          );
        });
        return true;
      });
    });

    tearDown(() {
      messenger().setMockMethodCallHandler(channel, null);
    });

    test('第 39 条：抽帧成功返回原生给的封面路径，请求参数原样透传', () async {
      final thumbDir = await Directory.systemTemp.createTemp('poster-');
      addTearDown(() async {
        if (await thumbDir.exists()) {
          await thumbDir.delete(recursive: true);
        }
      });

      const videoPath = '/tmp/fake.mp4';
      final result = await DownloadManager.extractPosterFrame(
        videoPath: videoPath,
        thumbDirPath: thumbDir.path,
      );

      expect(result, '${thumbDir.path}/thumb.jpg');

      final args = lastArgs;
      expect(args, isNotNull);
      expect(args!['video'], videoPath);
      expect(args['format'], ImageFormat.JPEG.index);
      expect(args['maxw'], 640);
      expect(args['quality'], 75);
      expect(args['timeMs'], 1000);
      expect(args['path'], thumbDir.path);
      // callId 是 int，且由插件生成后原样回传。
      expect(args['callId'], isA<int>());
    });

    test('第 40 条：原生回 result#error 时抽帧返回 null', () async {
      mockMode = 'error';
      final thumbDir = await Directory.systemTemp.createTemp('poster-');
      addTearDown(() async {
        if (await thumbDir.exists()) {
          await thumbDir.delete(recursive: true);
        }
      });

      final result = await DownloadManager.extractPosterFrame(
        videoPath: '/tmp/fake.mp4',
        thumbDirPath: thumbDir.path,
      );

      expect(result, isNull);
    });

    test('第 41 条：视频路径为空时直接返回 null，且通道未被调用', () async {
      final thumbDir = await Directory.systemTemp.createTemp('poster-');
      addTearDown(() async {
        if (await thumbDir.exists()) {
          await thumbDir.delete(recursive: true);
        }
      });

      final result = await DownloadManager.extractPosterFrame(
        videoPath: '',
        thumbDirPath: thumbDir.path,
      );

      expect(result, isNull);
      // 通道一次都没被调到。
      expect(lastArgs, isNull);
    });

    test('第 42 条：原生回空路径时抽帧返回 null', () async {
      mockMode = 'empty';
      final thumbDir = await Directory.systemTemp.createTemp('poster-');
      addTearDown(() async {
        if (await thumbDir.exists()) {
          await thumbDir.delete(recursive: true);
        }
      });

      final result = await DownloadManager.extractPosterFrame(
        videoPath: '/tmp/fake.mp4',
        thumbDirPath: thumbDir.path,
      );

      expect(result, isNull);
    });
  });
}

void _serveFile(HttpRequest req, Uint8List bytes, {required bool supportRange}) {
  final range = req.headers.value('range');
  if (supportRange && range != null) {
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    if (m != null) {
      final start = int.parse(m.group(1)!);
      final end = m.group(2)!.isEmpty
          ? bytes.length - 1
          : int.parse(m.group(2)!);
      final slice = bytes.sublist(start, end + 1);
      req.response.statusCode = 206;
      req.response.headers.set('Content-Range',
          'bytes $start-$end/${bytes.length}');
      req.response.headers.set('Content-Length', slice.length.toString());
      req.response.add(slice);
      req.response.close();
      return;
    }
  }
  req.response.statusCode = 200;
  req.response.headers.set('Content-Length', bytes.length.toString());
  if (supportRange) {
    req.response.headers.set('Accept-Ranges', 'bytes');
  }
  req.response.add(bytes);
  req.response.close();
}

void _serveText(HttpRequest req, String body) {
  req.response.statusCode = 200;
  req.response.headers.contentType = ContentType.text;
  req.response.write(body);
  req.response.close();
}

void _serveBytes(HttpRequest req, Uint8List bytes) {
  req.response.statusCode = 200;
  req.response.headers.set('Content-Length', bytes.length.toString());
  req.response.add(bytes);
  req.response.close();
}

/// 最小 HTTP/1.1 服务器（跑在原始 ServerSocket 上）：数 TCP 连接数与请求数，
/// 证明共享连接真的复用了（keep-alive）。只支持 GET + Range（206）。
class _CountingServer {
  final ServerSocket _socket;
  final Map<String, List<int>> _routes;
  int accepted = 0;
  int requests = 0;

  _CountingServer._(this._socket, this._routes) {
    _socket.listen(_handle);
  }

  static Future<_CountingServer> bind(Map<String, List<int>> routes) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _CountingServer._(s, routes);
  }

  String get base => 'http://127.0.0.1:${_socket.port}';

  Future<void> close() async {
    await _socket.close();
  }

  Future<void> _handle(Socket sock) async {
    accepted++;
    var buf = <int>[];
    try {
      await for (final chunk in sock) {
        buf.addAll(chunk);
        while (true) {
          final end = _indexOf(buf, [13, 10, 13, 10]);
          if (end < 0) break;
          final head = ascii.decode(buf.sublist(0, end));
          final lines = head.split('\r\n');
          final parts = lines.first.split(' ');
          final path = parts.length > 1 ? parts[1] : '/';
          var rangeHeader = '';
          for (final l in lines.skip(1)) {
            if (l.toLowerCase().startsWith('range:')) {
              rangeHeader = l.substring('range:'.length).trim();
            }
          }
          requests++;
          final full = _routes[path];
          if (full == null) {
            _reply(sock, 404, utf8.encode('not found'), null);
          } else if (rangeHeader.isNotEmpty) {
            final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
            if (m == null) {
              _reply(sock, 200, full, null);
            } else {
              final a = int.parse(m.group(1)!);
              final b =
                  m.group(2)!.isEmpty ? full.length - 1 : int.parse(m.group(2)!);
              _reply(sock, 206, full.sublist(a, b + 1),
                  'bytes $a-$b/${full.length}');
            }
          } else {
            _reply(sock, 200, full, null);
          }
          buf = buf.sublist(end + 4);
        }
      }
    } catch (_) {
      // 客户端断开，正常。
    } finally {
      try {
        await sock.close();
      } catch (_) {}
    }
  }

  void _reply(Socket sock, int status, List<int> body, String? contentRange) {
    final head = StringBuffer()
      ..write('HTTP/1.1 $status ')
      ..write(status == 200
          ? 'OK'
          : status == 206
              ? 'Partial Content'
              : 'Not Found')
      ..write('\r\n')
      ..write('Content-Type: application/octet-stream\r\n')
      ..write('Content-Length: ${body.length}\r\n');
    if (contentRange != null) {
      head.write('Content-Range: $contentRange\r\n');
    }
    head
      ..write('Accept-Ranges: bytes\r\n')
      ..write('Connection: keep-alive\r\n\r\n');
    sock.add(utf8.encode(head.toString()));
    sock.add(body);
  }
}

int _indexOf(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
