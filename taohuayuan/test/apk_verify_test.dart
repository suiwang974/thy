import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/apk_verify.dart';

import 'zip_fixture.dart';

/// 第 57 条：APK 完整性校验（大小 + ZIP 结构 + 每条记录 CRC）。
/// v11 的教训：只看大小不够，坏包大小也对，必须验内容。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('apkverify_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Uint8List goodZip() => buildTestZip(
        storedName: 'a.txt',
        storedData: Uint8List.fromList('hello stored'.codeUnits),
        deflatedName: 'b.txt',
        deflatedData:
            Uint8List.fromList(List<int>.generate(5000, (i) => i % 251)),
      );

  Future<String> write(String name, List<int> bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('好包：stored + deflated 各一条，全部通过', () async {
    final path = await write('good.apk', goodZip());
    expect(await verifyApkFile(path), isNull);
  });

  test('好包 + 期望大小对得上：通过；大小不对：报大小不对', () async {
    final bytes = goodZip();
    final path = await write('good.apk', bytes);
    expect(await verifyApkFile(path, expectedSize: bytes.length), isNull);
    expect(await verifyApkFile(path, expectedSize: bytes.length + 1),
        contains('大小不对'));
  });

  test('中间挖 0 洞（v11 真机坏包的样子）：CRC 对不上', () async {
    final bad = Uint8List.fromList(goodZip());
    // stored 那条的数据在文件头附近（本地头 30 字节 + 文件名 5 字节之后）：
    // 大小不变、CRC 对不上——这就是 v11 坏包的样子。
    bad.fillRange(35, 41, 0);
    final path = await write('hole.apk', bad);
    final reason = await verifyApkFile(path);
    expect(reason, isNotNull);
    expect(reason, contains('校验失败'));
  });

  test('截断的包：EOCD / 中央目录找不全', () async {
    final bytes = goodZip();
    final path = await write('trunc.apk', bytes.sublist(0, bytes.length - 30));
    expect(await verifyApkFile(path), isNotNull);
  });

  test('非 ZIP 文件：开头不是 ZIP', () async {
    final path = await write('notzip.apk', List<int>.filled(1000, 0));
    expect(await verifyApkFile(path), contains('不是有效的安装包'));
  });

  test('deflated 数据损坏：解压失败或 CRC 对不上', () async {
    final bad = Uint8List.fromList(goodZip());
    // deflated 数据在本地头之后：找到第二条本地头（PK\x03\x04 第二次出现），
    // 把它的数据区改掉。
    var second = -1;
    for (var i = 4; i < bad.length - 4; i++) {
      if (bad[i] == 0x50 &&
          bad[i + 1] == 0x4B &&
          bad[i + 2] == 0x03 &&
          bad[i + 3] == 0x04) {
        second = i;
        break;
      }
    }
    expect(second, greaterThan(0));
    final nameLen = bad[second + 26] | (bad[second + 27] << 8);
    final dataOff = second + 30 + nameLen;
    bad[dataOff] ^= 0xFF;
    bad[dataOff + 1] ^= 0xFF;
    final path = await write('deflate-bad.apk', bad);
    expect(await verifyApkFile(path), isNotNull);
  });

  test('空文件 / 不存在的文件：报对应原因', () async {
    final empty = await write('empty.apk', <int>[]);
    expect(await verifyApkFile(empty), contains('空文件'));
    expect(await verifyApkFile('${dir.path}/missing.apk'),
        contains('不存在'));
  });
}
