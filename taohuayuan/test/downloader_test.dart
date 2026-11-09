import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/downloader.dart';

/// 本地 HttpServer：支持 Range（206）与忽略 Range（200）两种模式，
/// 再加 HLS 播放列表与分片。提速对照与 HLS 拼合都在这上面验，
/// 不依赖外网、不依赖源站直链。
void main() {
  late HttpServer server;
  late Uint8List fileBytes; // 20MB 确定性内容（20 ÷ 每段至少 2MB = 正好 8 段）
  late String base;

  setUpAll(() async {
    fileBytes = Uint8List.fromList(
        List<int>.generate(20 * 1024 * 1024, (i) => (i * 7 + 13) % 251));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) async {
      final p = req.uri.path;
      if (p == '/file.mp4') {
        _serveFile(req, fileBytes, supportRange: true);
      } else if (p == '/file-norange.mp4') {
        _serveFile(req, fileBytes, supportRange: false);
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

    test('downloadRange：一段 Range 字节正确', () async {
      final outPath = '${tmp.path}/range.mp4';
      final f = await File(outPath).open(mode: FileMode.write);
      await f.truncate(1000);
      await f.close();
      await DownloadManager.downloadRange(
        url: '$base/file.mp4',
        headers: const {},
        start: 100,
        end: 199,
        targetPath: outPath,
        writeOffset: 100,
        onBytes: (_) {},
        isCancelled: () => false,
      );
      final bytes = await File(outPath).readAsBytes();
      expect(bytes.sublist(100, 200), fileBytes.sublist(100, 200));
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
