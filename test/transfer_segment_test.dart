import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/transfer/segment_downloader.dart';

/// 本地 HttpServer：分片服务（支持 Range / 忽略 Range / 403 恢复两档），
/// 不依赖外网。
void main() {
  late HttpServer server;
  late String base;
  late Map<String, Uint8List> bodies;
  final hits = <String, int>{};

  setUpAll(() async {
    bodies = {
      '/seg0': Uint8List.fromList(List.generate(1000, (i) => i % 251)),
      '/seg1': Uint8List.fromList(List.generate(2000, (i) => (i * 3) % 251)),
      '/seg2': Uint8List.fromList(List.generate(500, (i) => (i * 7 + 1) % 251)),
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) async {
      final p = req.uri.path;
      hits[p] = (hits[p] ?? 0) + 1;
      if (p == '/seg-403') {
        if (req.headers.value('referer') != null) {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        serveBytes(req, bodies['/seg0']!);
        return;
      }
      if (p == '/seg-403-always') {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final body = bodies[p];
      if (body == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      if (p == '/seg-norange') {
        serveBytes(req, body);
        return;
      }
      serveRange(req, body);
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    hits.clear();
  });

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('segdl_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('三段并发下载，字节正确，进度到 (3,3)', () async {
    final dl = SegmentDownloader(concurrency: 2);
    final progress = <String>[];
    final tasks = [
      for (var i = 0; i < 3; i++)
        SegmentTask(
          url: '$base/seg$i',
          savePath: '${tmp.path}/seg$i.bin',
          index: i,
          expectedSize: bodies['/seg$i']!.length,
        ),
    ];
    await dl.downloadAll(tasks,
        onProgress: (done, total) => progress.add('$done/$total'));
    for (var i = 0; i < 3; i++) {
      expect(await File('${tmp.path}/seg$i.bin').readAsBytes(),
          bodies['/seg$i']);
    }
    expect(progress.last, '3/3');
    expect(progress.length, 3);
  });

  test('expectedSize 已完成：不发请求、文件原样不动', () async {
    final file = File('${tmp.path}/seg0.bin');
    await file.writeAsBytes(bodies['/seg0']!);
    final dl = SegmentDownloader();
    await dl.downloadAll([
      SegmentTask(
        url: '$base/seg0',
        savePath: file.path,
        index: 0,
        expectedSize: bodies['/seg0']!.length,
      ),
    ]);
    expect(hits['/seg0'] ?? 0, 0);
    expect(await file.readAsBytes(), bodies['/seg0']);
  });

  test('断点续传：一半文件接着下完，字节正确', () async {
    final body = bodies['/seg1']!;
    final file = File('${tmp.path}/seg1.bin');
    await file.writeAsBytes(body.sublist(0, 1000));
    final dl = SegmentDownloader();
    await dl.downloadAll([
      SegmentTask(
        url: '$base/seg1',
        savePath: file.path,
        index: 1,
        expectedSize: body.length,
      ),
    ]);
    expect(await file.readAsBytes(), body);
  });

  test('续传文件比 expectedSize 长：截断重下，字节正确', () async {
    final body = bodies['/seg0']!;
    final file = File('${tmp.path}/seg0.bin');
    await file.writeAsBytes(Uint8List.fromList([...body, 9, 9, 9]));
    final dl = SegmentDownloader();
    await dl.downloadAll([
      SegmentTask(
        url: '$base/seg0',
        savePath: file.path,
        index: 0,
        expectedSize: body.length,
      ),
    ]);
    expect(await file.readAsBytes(), body);
  });

  test('服务器忽略 Range 回 200：一半文件截断重下，字节正确', () async {
    final body = bodies['/seg0']!;
    final file = File('${tmp.path}/seg-norange.bin');
    await file.writeAsBytes(body.sublist(0, 400));
    bodies['/seg-norange'] = body;
    final dl = SegmentDownloader();
    await dl.downloadAll([
      SegmentTask(
        url: '$base/seg-norange',
        savePath: file.path,
        index: 0,
        expectedSize: body.length,
      ),
    ]);
    expect(await file.readAsBytes(), body);
  });

  test('403 换请求头恢复：带 Referer 被拒，去掉后成功', () async {
    final body = bodies['/seg0']!;
    final dl = SegmentDownloader();
    await dl.downloadAll([
      SegmentTask(
        url: '$base/seg-403',
        savePath: '${tmp.path}/seg403.bin',
        index: 0,
        expectedSize: body.length,
        referer: 'https://www.example.com/watch/1',
      ),
    ]);
    expect(await File('${tmp.path}/seg403.bin').readAsBytes(), body);
    expect(hits['/seg-403'], 2);
  });

  test('持续 403：3 次用完抛错，信息含 failed after 3 attempts', () async {
    final dl = SegmentDownloader(maxAttempts: 3);
    await expectLater(
      dl.downloadAll([
        SegmentTask(
          url: '$base/seg-403-always',
          savePath: '${tmp.path}/segx.bin',
          index: 0,
        ),
      ]),
      throwsA(isA<Exception>().having(
          (e) => e.toString(), 'message', contains('failed after 3 attempts'))),
    );
    expect(hits['/seg-403-always'], 3);
  });

  test('BYTERANGE：取文件中间一段，字节正确', () async {
    final body = bodies['/seg1']!;
    final dl = SegmentDownloader();
    await dl.downloadAll([
      SegmentTask(
        url: '$base/seg1',
        savePath: '${tmp.path}/range.bin',
        index: 0,
        expectedSize: 1000,
        rangeStart: 1000,
        rangeEnd: 1999,
      ),
    ]);
    expect(await File('${tmp.path}/range.bin').readAsBytes(),
        body.sublist(1000, 2000));
  });

  test('BYTERANGE 续传：已有前 400 字节，从 1400 起接着取', () async {
    final body = bodies['/seg1']!;
    final file = File('${tmp.path}/range2.bin');
    await file.writeAsBytes(body.sublist(1000, 1400));
    final dl = SegmentDownloader();
    await dl.downloadAll([
      SegmentTask(
        url: '$base/seg1',
        savePath: file.path,
        index: 0,
        expectedSize: 1000,
        rangeStart: 1000,
        rangeEnd: 1999,
      ),
    ]);
    expect(await file.readAsBytes(), body.sublist(1000, 2000));
  });

  test('BYTERANGE 但服务器忽略 Range 回 200：整包切出要的区间', () async {
    final body = bodies['/seg0']!;
    bodies['/seg-norange'] = body;
    final dl = SegmentDownloader();
    await dl.downloadAll([
      SegmentTask(
        url: '$base/seg-norange',
        savePath: '${tmp.path}/range3.bin',
        index: 0,
        expectedSize: 400,
        rangeStart: 200,
        rangeEnd: 599,
      ),
    ]);
    expect(await File('${tmp.path}/range3.bin').readAsBytes(),
        body.sublist(200, 600));
  });

  test('headerVariants：原样/去 Referer+备用 UA/origin Referer+备用 UA', () {
    final dl = SegmentDownloader();
    final task = SegmentTask(
      url: 'https://cdn.example.com/seg0.ts',
      savePath: '/tmp/x',
      index: 0,
      headers: {'User-Agent': 'OrigUA/1.0'},
      referer: 'https://www.example.com/watch/1?x=2',
    );
    final variants = dl.headerVariants(task);
    expect(variants.length, 3);
    expect(variants[0]['Referer'], 'https://www.example.com/watch/1?x=2');
    expect(variants[0]['User-Agent'], 'OrigUA/1.0');
    expect(variants[1].containsKey('Referer'), isFalse);
    expect(variants[1]['User-Agent'], SegmentDownloader.altUserAgent);
    expect(variants[2]['Referer'], 'https://www.example.com');
    expect(variants[2]['User-Agent'], SegmentDownloader.altUserAgent);
  });
}

void serveBytes(HttpRequest req, Uint8List body) {
  req.response.statusCode = HttpStatus.ok;
  req.response.headers.contentLength = body.length;
  req.response.add(body);
  req.response.close();
}

void serveRange(HttpRequest req, Uint8List body) {
  final range = req.headers.value('range');
  if (range == null) {
    serveBytes(req, body);
    return;
  }
  final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
  if (m == null) {
    serveBytes(req, body);
    return;
  }
  final start = int.parse(m.group(1)!);
  final end = m.group(2)!.isEmpty ? body.length - 1 : int.parse(m.group(2)!);
  if (start >= body.length) {
    req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    req.response.close();
    return;
  }
  final slice = body.sublist(start, end + 1);
  req.response.statusCode = HttpStatus.partialContent;
  req.response.headers.set('Content-Range', 'bytes $start-$end/${body.length}');
  req.response.headers.contentLength = slice.length;
  req.response.add(slice);
  req.response.close();
}
