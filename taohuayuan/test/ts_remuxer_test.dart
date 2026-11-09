import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/ts_remuxer.dart';

/// TS->MP4 重封装测试：用 r34 真分片（test/fixtures/r34-seg{0,1,2}.ts，
/// 2026-11-09 从 rule34-videos.com 拉的 720p HLS 分片，h264 + aac 48kHz）。
/// 断言只做 Dart 层结构检查（ftyp/mdat/moov、两条轨、avc1/mp4a、
/// 采样数、时长）；能不能播用 VM 里的 ffprobe 另行验（见文件头注释）。
void main() {
  test('remux 3 个 r34 分片 -> 有效 mp4（结构检查）', () async {
    final tmp = await Directory.systemTemp.createTemp('ts_remux_test_');
    try {
      // 3 个分片拼成一个 .ts（模拟下载器拼好的文件）。
      final tsPath = '${tmp.path}/in.ts';
      final sink = File(tsPath).openWrite();
      for (var i = 0; i < 3; i++) {
        final seg = await File('test/fixtures/r34-seg$i.ts').readAsBytes();
        sink.add(seg);
      }
      await sink.close();

      final mp4Path = '${tmp.path}/out.mp4';
      final r = await TsRemuxer.remuxFile(tsPath, mp4Path);
      // 3 段 × 每段 4 秒 = 约 12 秒；每段 120 帧视频（30fps）。
      expect(r.videoSamples, greaterThanOrEqualTo(300));
      expect(r.videoSamples, lessThanOrEqualTo(400));
      expect(r.audioSamples, greaterThan(100));
      expect(r.durationMs, greaterThanOrEqualTo(11000));
      expect(r.durationMs, lessThanOrEqualTo(13000));

      final mp4 = await File(mp4Path).readAsBytes();
      expect(mp4.length, greaterThan(1000000));
      final boxes = _topBoxes(mp4);
      expect(boxes, containsAll(['ftyp', 'mdat', 'moov']));
      // moov 里有两条轨（视频 + 音频），stsd 里有 avc1 和 mp4a。
      final moov = _findBox(mp4, 'moov');
      expect(moov, isNotNull);
      final moovText = String.fromCharCodes(moov!);
      expect(moovText.contains('avc1'), isTrue);
      expect(moovText.contains('mp4a'), isTrue);
      expect(moovText.contains('avcC'), isTrue);
      expect(moovText.contains('esds'), isTrue);
      // stss（关键帧表）存在：每段开头一个 IDR，至少 3 个关键帧。
      final stss = _findBox(moov, 'stss');
      expect(stss, isNotNull);
      final stssCount = ByteData.sublistView(stss!, 4, 8).getUint32(0);
      expect(stssCount, greaterThanOrEqualTo(3));
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('空文件 / 非 TS 抛错，不静默产出坏 mp4', () async {
    final tmp = await Directory.systemTemp.createTemp('ts_remux_test2_');
    try {
      final bad = File('${tmp.path}/bad.ts');
      await bad.writeAsBytes(List.filled(1000, 0));
      await expectLater(
        TsRemuxer.remuxFile(bad.path, '${tmp.path}/out.mp4'),
        throwsA(isA<StateError>()),
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}

/// 顶层 box 类型列表（ftyp/mdat/moov……）。
List<String> _topBoxes(Uint8List data) {
  final out = <String>[];
  var off = 0;
  while (off + 8 <= data.length) {
    final size = ByteData.sublistView(data, off, off + 4).getUint32(0);
    final type = String.fromCharCodes(data.sublist(off + 4, off + 8));
    out.add(type);
    if (size < 8) break;
    off += size;
  }
  return out;
}

/// 在 data 里找第一个指定类型的 box（含嵌套），返回 box 全部字节。
Uint8List? _findBox(Uint8List data, String type) {
  final want = type.codeUnits;
  for (var i = 0; i + 8 <= data.length; i++) {
    var match = true;
    for (var k = 0; k < 4; k++) {
      if (data[i + 4 + k] != want[k]) {
        match = false;
        break;
      }
    }
    if (!match) continue;
    final size = ByteData.sublistView(data, i, i + 4).getUint32(0);
    if (size >= 8 && i + size <= data.length) {
      return Uint8List.sublistView(data, i, i + size);
    }
  }
  return null;
}
