import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/sniffer.dart';
import 'package:taohuayuan/sniffer/native_sniffer_bridge.dart';
import 'package:taohuayuan/transfer/download_candidate.dart';
import 'package:taohuayuan/transfer/hls_playlist.dart';
import 'package:taohuayuan/transfer/mp4_probe.dart';

/// 元数据修复（2026-11-17，用户真机三张截图）：
/// 轮询洗富化、预览当正片、全未知还排第一——三项的回归锁。
/// 夹具是真网拉的：Mux 测试流 master + 1080p 媒体列表、
/// Big Buck Bunny 720p 10 秒真文件前 64KB。
void main() {
  group('isExcludedUrl 新增规则', () {
    test('HanimeOne 预览 300x250.low.mp4 排除', () {
      expect(
          Sniffer.isExcludedUrl(
              'https://cdn.example.com/9561-0-300x250.low.mp4'),
          isTrue);
    });

    test('low 单独出现不排除：xxx-low.mp4 可能是低画质正片全片', () {
      expect(Sniffer.isExcludedUrl('https://cdn.example.com/x/xxx-low.mp4'),
          isFalse);
      expect(
          Sniffer.isExcludedUrl(
              'https://cdn.example.com/x/xxx_low_720p.mp4'),
          isFalse);
      expect(Sniffer.isExcludedUrl('https://cdn.example.com/x/follow.mp4'),
          isFalse);
    });

    test('小尺寸 token 与 previews 目录段', () {
      expect(
          Sniffer.isExcludedUrl(
              'https://cdn.example.com/x/clip-320x240.mp4'),
          isTrue);
      expect(
          Sniffer.isExcludedUrl(
              'https://cdn.example.com/previews/123/720p.mp4'),
          isTrue);
    });

    test('正片不错杀：720p 与裸段 preview', () {
      expect(
          Sniffer.isExcludedUrl('https://cdn.example.com/409236-720p.mp4'),
          isFalse);
      expect(
          Sniffer.isExcludedUrl(
              'https://cdn.example.com/videos/preview/12345.mp4'),
          isFalse);
    });
  });

  group('looksLikePreview / compareQuality / bestOf', () {
    test('小体积无时长是预览；有真实时长就不是', () {
      const preview = SniffedMedia(
          url: 'https://cdn.example.com/p.mp4',
          kind: 'mp4',
          sizeBytes: 300 * 1024);
      expect(preview.looksLikePreview, isTrue);
      const shortReal = SniffedMedia(
          url: 'https://cdn.example.com/s.mp4',
          kind: 'mp4',
          sizeBytes: 300 * 1024,
          durationSec: 8);
      expect(shortReal.looksLikePreview, isFalse);
    });

    test('有元数据的排在全未知前面；预览排在全未知后面', () {
      const withMeta = SniffedMedia(
          url: 'https://cdn.example.com/720p.m3u8',
          kind: 'm3u8',
          resolution: '1280x720');
      const unknown = SniffedMedia(
          url: 'https://cdn.example.com/u.mp4', kind: 'mp4');
      const preview = SniffedMedia(
          url: 'https://cdn.example.com/p.mp4',
          kind: 'mp4',
          sizeBytes: 300 * 1024);
      final sorted = [unknown, preview, withMeta]
        ..sort(SniffedMedia.compareQuality);
      expect(sorted[0].url, contains('720p.m3u8'));
      expect(sorted[1].url, contains('/u.mp4'));
      expect(sorted[2].url, contains('/p.mp4'));
    });

    test('bestOf：全无元数据返回 null；预览不当中选', () {
      const unknown = SniffedMedia(
          url: 'https://cdn.example.com/u.mp4', kind: 'mp4');
      const preview = SniffedMedia(
          url: 'https://cdn.example.com/p.mp4',
          kind: 'mp4',
          sizeBytes: 300 * 1024);
      expect(SniffedMedia.bestOf([unknown, preview]), isNull);
      const withMeta = SniffedMedia(
          url: 'https://cdn.example.com/720p.m3u8',
          kind: 'm3u8',
          resolution: '1280x720');
      expect(SniffedMedia.bestOf([preview, withMeta])?.url,
          contains('720p.m3u8'));
      expect(SniffedMedia.bestOf([preview]), isNull);
    });
  });

  group('candidateToSniffed 过滤', () {
    test('预览 URL 返回 null', () {
      expect(
          NativeSnifferBridge.candidateToSniffed(const DownloadCandidate(
              url: 'https://cdn.example.com/9561-0-300x250.low.mp4',
              mime: 'video/mp4')),
          isNull);
    });

    test('正片 mp4 正常转条目', () {
      final item = NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(
              url: 'https://cdn.example.com/409236-720p.mp4',
              mime: 'video/mp4'));
      expect(item, isNotNull);
      expect(item!.kind, 'mp4');
    });
  });

  group('Mp4Probe.parseBytes 真实字节', () {
    test('Big Buck Bunny 720p 10 秒：10 秒、1280x720', () {
      final bytes =
          File('test/fixtures/bbb_head_64k.bin').readAsBytesSync();
      final r = Mp4Probe.parseBytes(bytes);
      expect(r?.durationSec, 10);
      expect(r?.resolution, '1280x720');
    });

    test('空字节与 moov 截断返回 null', () {
      expect(Mp4Probe.parseBytes([]), isNull);
      final bytes =
          File('test/fixtures/bbb_head_64k.bin').readAsBytesSync();
      expect(Mp4Probe.parseBytes(bytes.sublist(0, 40)), isNull);
    });
  });

  group('HlsPlaylist.resolveVariantMeta Mux 夹具', () {
    test('master 选 1080p 变体：1920x1080、6221600、635 秒、64 分片',
        () async {
      final master =
          File('test/fixtures/mux_master.m3u8').readAsStringSync();
      final media =
          File('test/fixtures/mux_media_1080p.m3u8').readAsStringSync();
      final meta = await HlsPlaylist.resolveVariantMeta(
        masterBody: master,
        masterUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        fetch: (u) async {
          if (u.contains('url_8')) return media;
          throw StateError('unexpected fetch: $u');
        },
      );
      expect(meta.resolution, '1920x1080');
      expect(meta.bandwidth, 6221600);
      expect(meta.durationSec, 635);
      expect(meta.segmentCount, 64);
    });
  });
}
