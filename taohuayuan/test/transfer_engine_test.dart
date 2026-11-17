import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:taohuayuan/transfer/download_candidate.dart';
import 'package:taohuayuan/transfer/transfer_engine.dart';

Uint8List hexDecode(String hex) {
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(out);
}

void serveFile(HttpRequest req, Uint8List body, String contentType) {
  req.response.headers.contentType = ContentType.parse(contentType);
  if (req.method == 'HEAD') {
    req.response.headers.contentLength = body.length;
    req.response.close();
    return;
  }
  final range = req.headers.value('range');
  if (range == null) {
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentLength = body.length;
    req.response.add(body);
    req.response.close();
    return;
  }
  final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
  if (m == null) {
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentLength = body.length;
    req.response.add(body);
    req.response.close();
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
  req.response.headers
      .set('Content-Range', 'bytes $start-$end/${body.length}');
  req.response.headers.contentLength = slice.length;
  req.response.add(slice);
  req.response.close();
}

void serveText(HttpRequest req, String text, {int status = 200}) {
  req.response.statusCode = status;
  req.response.headers.contentType =
      ContentType.parse('application/vnd.apple.mpegurl');
  if (req.method == 'HEAD') {
    req.response.close();
    return;
  }
  req.response.write(text);
  req.response.close();
}

/// 本地 HttpServer 模拟传输层 fixture：直链 mp4、HLS 多变体、AES-128、
/// BYTERANGE fMP4、直播、403 恢复、METHOD=NONE / SAMPLE-AES。
void main() {
  late HttpServer server;
  late String base;
  late Uint8List fileBytes;
  late Uint8List seg0, seg1, seg2;
  late Uint8List keyBytes;
  late Uint8List enc0, enc1, encSeq0, encSeq1;
  late Uint8List initBytes, fileTsBytes;

  setUpAll(() async {
    fileBytes = Uint8List.fromList(
        List<int>.generate(20 * 1024, (i) => (i * 7 + 13) % 251));
    seg0 = Uint8List.fromList(List<int>.generate(1000, (i) => i % 251));
    seg1 = Uint8List.fromList(List<int>.generate(1500, (i) => (i * 3) % 251));
    seg2 = Uint8List.fromList(List<int>.generate(800, (i) => (i * 5 + 2) % 251));
    keyBytes = Uint8List.fromList(List<int>.generate(16, (i) => i * 11 % 251));
    const ivHex = '000102030405060708090a0b0c0d0e0f';
    final iv = hexDecode(ivHex);
    enc0 = TransferEngine.encryptAes128Cbc(seg0, keyBytes, iv);
    enc1 = TransferEngine.encryptAes128Cbc(seg1, keyBytes, iv);
    encSeq0 = TransferEngine.encryptAes128Cbc(
        seg0, keyBytes, Uint8List.fromList(TransferEngine.deriveIv(0)));
    encSeq1 = TransferEngine.encryptAes128Cbc(
        seg1, keyBytes, Uint8List.fromList(TransferEngine.deriveIv(1)));
    initBytes = Uint8List.fromList(List<int>.generate(200, (i) => 200 - i));
    fileTsBytes =
        Uint8List.fromList(List<int>.generate(3000, (i) => (i * 13) % 251));

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) async {
      final p = req.uri.path;
      if (p == '/file.mp4') {
        serveFile(req, fileBytes, 'video/mp4');
      } else if (p == '/file-norange.mp4') {
        req.response.headers.contentType = ContentType.parse('video/mp4');
        if (req.method == 'HEAD') {
          req.response.headers.contentLength = fileBytes.length;
          await req.response.close();
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentLength = fileBytes.length;
          req.response.add(fileBytes);
          await req.response.close();
        }
      } else if (p == '/master.m3u8') {
        serveText(req, '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360\n'
            '/low.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
            '/high.m3u8\n');
      } else if (p == '/low.m3u8') {
        serveText(req, '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:10.0,\n/seg0.ts\n#EXT-X-ENDLIST\n');
      } else if (p == '/high.m3u8') {
        serveText(req, '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:10.0,\n/seg0.ts\n'
            '#EXTINF:10.0,\n/seg1.ts\n'
            '#EXTINF:10.0,\n/seg2.ts\n#EXT-X-ENDLIST\n');
      } else if (p == '/seg0.ts') {
        serveFile(req, seg0, 'video/mp2t');
      } else if (p == '/seg1.ts') {
        serveFile(req, seg1, 'video/mp2t');
      } else if (p == '/seg2.ts') {
        serveFile(req, seg2, 'video/mp2t');
      } else if (p == '/key.bin') {
        serveFile(req, keyBytes, 'application/octet-stream');
      } else if (p == '/enc.m3u8') {
        serveText(req, '#EXTM3U\n#EXT-X-VERSION:3\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="/key.bin",IV=0x000102030405060708090a0b0c0d0e0f\n'
            '#EXTINF:10.0,\n/enc0.ts\n'
            '#EXTINF:10.0,\n/enc1.ts\n#EXT-X-ENDLIST\n');
      } else if (p == '/enc0.ts') {
        serveFile(req, enc0, 'video/mp2t');
      } else if (p == '/enc1.ts') {
        serveFile(req, enc1, 'video/mp2t');
      } else if (p == '/enc-seq.m3u8') {
        serveText(req, '#EXTM3U\n#EXT-X-VERSION:3\n'
            '#EXT-X-MEDIA-SEQUENCE:0\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="/key.bin"\n'
            '#EXTINF:10.0,\n/enc-seq0.ts\n'
            '#EXTINF:10.0,\n/enc-seq1.ts\n#EXT-X-ENDLIST\n');
      } else if (p == '/enc-seq0.ts') {
        serveFile(req, encSeq0, 'video/mp2t');
      } else if (p == '/enc-seq1.ts') {
        serveFile(req, encSeq1, 'video/mp2t');
      } else if (p == '/byterange.m3u8') {
        serveText(req, '#EXTM3U\n#EXT-X-VERSION:6\n'
            '#EXT-X-MAP:URI="init.mp4"\n'
            '#EXT-X-BYTERANGE:1000@0\n#EXTINF:10.0,\n/file.ts\n'
            '#EXT-X-BYTERANGE:1000\n#EXTINF:10.0,\n/file.ts\n'
            '#EXT-X-BYTERANGE:1000@2000\n#EXTINF:10.0,\n/file.ts\n'
            '#EXT-X-ENDLIST\n');
      } else if (p == '/init.mp4') {
        serveFile(req, initBytes, 'video/mp4');
      } else if (p == '/file.ts') {
        serveFile(req, fileTsBytes, 'video/mp2t');
      } else if (p == '/live.m3u8') {
        serveText(req, '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:10.0,\n/seg0.ts\n'
            '#EXTINF:10.0,\n/seg1.ts\n');
      } else if (p == '/protected.m3u8') {
        if (req.headers.value('referer') != null) {
          serveText(req, 'forbidden', status: HttpStatus.forbidden);
        } else {
          serveText(req, '#EXTM3U\n#EXT-X-VERSION:3\n'
              '#EXTINF:10.0,\n/seg0.ts\n#EXT-X-ENDLIST\n');
        }
      } else if (p == '/none.m3u8') {
        serveText(req, '#EXTM3U\n#EXT-X-VERSION:3\n'
            '#EXT-X-KEY:METHOD=NONE\n'
            '#EXTINF:10.0,\n/seg0.ts\n#EXT-X-ENDLIST\n');
      } else if (p == '/sampleaes.m3u8') {
        serveText(req, '#EXTM3U\n#EXT-X-VERSION:3\n'
            '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="/key.bin"\n'
            '#EXTINF:10.0,\n/seg0.ts\n#EXT-X-ENDLIST\n');
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('teng_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> runEngine(String url, {Map<String, String> headers = const {},
      String? referer}) async {
    final engine = TransferEngine();
    final target = '${tmp.path}/out.bin';
    final events = <TransferProgress>[];
    await for (final e in engine.download(
        DownloadCandidate(url: url, headers: headers, referer: referer),
        target)) {
      events.add(e);
    }
    expect(events.last.done, isTrue);
    expect(events.last.outputPath, target);
    return target;
  }

  test('NIST AES-128-CBC 向量：原始 CBC 核心解密已知密文得已知明文', () {
    // 注：NIST 向量是无填充的原始 CBC；HLS 用 PKCS7 填充，解密走
    // decryptAes128Cbc（见下方的 round-trip 断言）。这里直接验 AES 核心。
    final key = hexDecode('2b7e151628aed2a6abf7158809cf4f3c');
    final iv = hexDecode('000102030405060708090a0b0c0d0e0f');
    final cipherText = hexDecode('7649abac8119b246cee98e9b12e9197d');
    final cipher = CBCBlockCipher(AESEngine());
    cipher.init(false, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(16);
    cipher.processBlock(cipherText, 0, out, 0);
    expect(out, hexDecode('6bc1bee22e409f96e93d7e117393172a'));

    // PKCS7 round-trip：加密再解密回原文（填充块由库处理）。
    final plain = hexDecode('6bc1bee22e409f96e93d7e117393172a');
    final enc = TransferEngine.encryptAes128Cbc(plain, key, iv);
    expect(enc.length, 32);
    expect(TransferEngine.decryptAes128Cbc(enc, key, iv), plain);
  });

  test('deriveIv：序号 1 末字节为 1，其余为 0', () {
    expect(TransferEngine.deriveIv(0), List<int>.filled(16, 0));
    final iv1 = TransferEngine.deriveIv(1);
    expect(iv1.sublist(0, 15), List<int>.filled(15, 0));
    expect(iv1[15], 1);
  });

  test('直链 mp4 多段并行：字节正确，进度递增到完成', () async {
    final target = await runEngine('$base/file.mp4');
    expect(await File(target).readAsBytes(), fileBytes);
  });

  test('直链 mp4 服务器不支持 Range：单连接下完，字节正确', () async {
    final target = await runEngine('$base/file-norange.mp4');
    expect(await File(target).readAsBytes(), fileBytes);
  });

  test('HLS master：选最高码率变体，三分片按序拼合', () async {
    final target = await runEngine('$base/master.m3u8');
    final expected = Uint8List.fromList([...seg0, ...seg1, ...seg2]);
    expect(await File(target).readAsBytes(), expected);
  });

  test('AES-128 HLS（显式 IV）：解密后字节正确', () async {
    final target = await runEngine('$base/enc.m3u8');
    final expected = Uint8List.fromList([...seg0, ...seg1]);
    expect(await File(target).readAsBytes(), expected);
  });

  test('AES-128 HLS（无 IV，序号推导）：解密后字节正确', () async {
    final target = await runEngine('$base/enc-seq.m3u8');
    final expected = Uint8List.fromList([...seg0, ...seg1]);
    expect(await File(target).readAsBytes(), expected);
  });

  test('BYTERANGE fMP4：init + 三段区间拼合，字节正确', () async {
    final target = await runEngine('$base/byterange.m3u8');
    final expected =
        Uint8List.fromList([...initBytes, ...fileTsBytes]);
    expect(await File(target).readAsBytes(), expected);
  });

  test('直播列表（无 ENDLIST）：按现有分片下完', () async {
    final target = await runEngine('$base/live.m3u8');
    final expected = Uint8List.fromList([...seg0, ...seg1]);
    expect(await File(target).readAsBytes(), expected);
  });

  test('列表 403 换请求头恢复：带 Referer 被拒，去掉后成功', () async {
    final target = await runEngine('$base/protected.m3u8',
        referer: 'https://www.example.com/watch/1');
    expect(await File(target).readAsBytes(), seg0);
  });

  test('METHOD=NONE：按明文下，不解密', () async {
    final target = await runEngine('$base/none.m3u8');
    expect(await File(target).readAsBytes(), seg0);
  });

  test('SAMPLE-AES：抛 StateError，信息含不支持', () async {
    final engine = TransferEngine();
    await expectLater(
      engine
          .download(
              DownloadCandidate(url: '$base/sampleaes.m3u8'),
              '${tmp.path}/out.bin')
          .toList(),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('不支持'))),
    );
  });
}
