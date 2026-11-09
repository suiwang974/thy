import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/apk_verify.dart';
import 'package:taohuayuan/services/app_update.dart';

/// 第 57 条复现：App 内更新下的 v11 包报「安装包已损坏」——
/// GitHub 附件本身没问题（sha256 与本地包一致、apksigner 通过），
/// App 里显示下好的也是 20.7MB、大小对但内容坏了。
/// 三条假说逐个验：
/// (a) 服务器不认 Range（回 200 不回 206）却按 206 拼；
/// (b) 段顺序/偏移写错；
/// (c) 没下全却当下完了。
/// 真根因见 downloader.dart 的注释：多段同时往同一个文件里写，
/// 每段 `File(targetPath).open(mode: FileMode.write)` 打开就截断，
/// 后开的段把先开的段已写好的数据清掉；又因为预分配把文件截到满大小，
/// 长度校验永远通过，坏包就这么交给了系统安装器。
///
/// 注意：服务器上放的是真 ZIP（一条 20MB 的 stored 记录），
/// 因为修好后的 downloadApk 下完要验 ZIP 才能给安装。
void main() {
  late HttpServer server;
  late Uint8List zipBytes; // 20MB 真 ZIP（一条 stored 记录）
  late Uint8List payload; // ZIP 里那条记录的原文
  late String base;

  setUpAll(() async {
    payload = Uint8List.fromList(
        List<int>.generate(20 * 1024 * 1024, (i) => (i * 7 + 13) % 251));
    zipBytes = _buildZip('payload.bin', payload);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) async {
      final p = req.uri.path;
      final range = req.headers.value('range');
      if (p == '/apk') {
        // 模拟手机网络抖动：每段响应错开 60ms（段号越大越晚）。
        // 真机上 GitHub CDN 各段响应本来就不同时到。
        final m = RegExp(r'bytes=(\d+)-').firstMatch(range ?? '');
        final start = m == null ? 0 : int.parse(m.group(1)!);
        final seg = start ~/ (2 * 1024 * 1024);
        await Future.delayed(Duration(milliseconds: seg * 60));
        _serveRange(req, zipBytes);
      } else if (p == '/apk-probe206') {
        // 探测（bytes=0-0）给 206，分段请求一律回 200（不认 Range）。
        if (range == 'bytes=0-0') {
          _serveRange(req, zipBytes);
        } else {
          req.response.statusCode = 200;
          req.response.headers.set('Content-Length', zipBytes.length.toString());
          req.response.add(zipBytes);
          await req.response.close();
        }
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  AppUpdateInfo infoFor(String url) => AppUpdateInfo(
        remoteCode: 12,
        tag: 'taohuayuan-v12',
        name: '桃花源 v12',
        downloadUrl: url,
        sizeBytes: zipBytes.length,
        notes: '',
      );

  test('第 57 条(b)(c)：多段并行下 20MB，大小对、内容必须也对', () async {
    final dir = await Directory.systemTemp.createTemp('upd57_');
    try {
      final path = await AppUpdateService.instance.downloadApk(
        infoFor('$base/apk'),
        downloadDir: dir,
        isCancelled: () => false,
      );
      final got = await File(path).readAsBytes();
      expect(got.length, zipBytes.length); // 大小对——旧代码这关也能过
      expect(got, zipBytes); // 内容必须逐字节对——旧代码这里是 0 洞
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('第 57 条(a)：分段拿不到 206 就回落单连接，不许直接报错', () async {
    final dir = await Directory.systemTemp.createTemp('upd57_');
    try {
      final path = await AppUpdateService.instance.downloadApk(
        infoFor('$base/apk-probe206'),
        downloadDir: dir,
        isCancelled: () => false,
      );
      expect(await File(path).readAsBytes(), zipBytes);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('第 57 条(c)：缓存里大小对但内容坏的包不许复用，要重下', () async {
    final dir = await Directory.systemTemp.createTemp('upd57_');
    try {
      // 先放一个“大小对、内容坏”的缓存包（ZIP 数据区挖一个 0 洞，模拟真机坏包）。
      final bad = Uint8List.fromList(zipBytes);
      bad.fillRange(5 * 1024 * 1024, 6 * 1024 * 1024, 0);
      final target = File('${dir.path}/taohuayuan-v12.apk');
      await target.writeAsBytes(bad);
      final path = await AppUpdateService.instance.downloadApk(
        infoFor('$base/apk'),
        downloadDir: dir,
        isCancelled: () => false,
      );
      expect(await File(path).readAsBytes(), zipBytes);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}

/// 最小 ZIP：一名字段、一条 stored 记录、无注释。
Uint8List _buildZip(String name, Uint8List data) {
  final nameBytes = name.codeUnits;
  final crc = crc32(data);
  final out = BytesBuilder();
  void u16(int v) =>
      out.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) => out.add(
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  // 本地文件头
  out.add([0x50, 0x4B, 0x03, 0x04]);
  u16(20);
  u16(0);
  u16(0);
  u16(0);
  u16(0);
  u32(crc);
  u32(data.length);
  u32(data.length);
  u16(nameBytes.length);
  u16(0);
  out.add(nameBytes);
  out.add(data);
  // 中央目录
  final cdOffset = out.length;
  out.add([0x50, 0x4B, 0x01, 0x02]);
  u16(20);
  u16(20);
  u16(0);
  u16(0);
  u16(0);
  u16(0);
  u32(crc);
  u32(data.length);
  u32(data.length);
  u16(nameBytes.length);
  u16(0);
  u16(0);
  u16(0);
  u16(0);
  u32(0);
  u32(0);
  out.add(nameBytes);
  final cdSize = out.length - cdOffset;
  // EOCD
  out.add([0x50, 0x4B, 0x05, 0x06]);
  u16(0);
  u16(0);
  u16(1);
  u16(1);
  u32(cdSize);
  u32(cdOffset);
  u16(0);
  return out.toBytes();
}

void _serveRange(HttpRequest req, Uint8List bytes) {
  final range = req.headers.value('range');
  final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range ?? '');
  if (m == null) {
    req.response.statusCode = 200;
    req.response.headers.set('Content-Length', bytes.length.toString());
    req.response.add(bytes);
    req.response.close();
    return;
  }
  final start = int.parse(m.group(1)!);
  final end = m.group(2)!.isEmpty ? bytes.length - 1 : int.parse(m.group(2)!);
  final slice = bytes.sublist(start, end + 1);
  req.response.statusCode = 206;
  req.response.headers.set('Content-Range', 'bytes $start-$end/${bytes.length}');
  req.response.headers.set('Content-Length', slice.length.toString());
  req.response.add(slice);
  req.response.close();
}
