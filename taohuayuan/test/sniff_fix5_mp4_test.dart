import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/sniffer.dart';
import 'package:taohuayuan/transfer/hls_playlist.dart';

/// 第 5 轮真机反馈修复的测试（2026-11-17）：
/// MP4 元数据（分辨率/时长/大小）+ HLS 富化兜底（嵌套 master、URL 提示、
/// 失败原因、码率显示）。
/// 单元测试里不真联网：播放列表一律用 fetchText 注入；MP4 大小探测的
/// probeRange 走 127.0.0.1:1（本机立即拒绝，不出外网），HEAD 用 probeHead 注入。
/// _mergedSniffed 是浏览器私有 State 方法、单元测试调不到：原生 MP4 抄
/// Dart 元数据这一项改成直接验 SniffedMedia.copyWith 合并逻辑（与 fix4
/// 第 ④ 组同样的做法）。
void main() {
  const pageUrl = 'https://example.com/video/123';
  // probeRange 在本机立即拒绝的地址（不真联网、失败飞快）。
  const mp4a = 'http://127.0.0.1:1/a.mp4';
  const mp4b = 'http://127.0.0.1:1/b.mp4';

  group('MP4 detailLine：全空显示三项未知', () {
    test('mp4/webm 全空：时长未知 · 分辨率未知 · 大小未知', () {
      const m = SniffedMedia(url: mp4a, kind: 'mp4');
      expect(m.detailLine, '时长未知 · 分辨率未知 · 大小未知');
      const w = SniffedMedia(url: mp4b, kind: 'webm');
      expect(w.detailLine, '时长未知 · 分辨率未知 · 大小未知');
    });

    test('m3u8 全空仍是两项未知（不加大小未知）', () {
      const m = SniffedMedia(url: 'https://a/b.m3u8', kind: 'm3u8');
      expect(m.detailLine, '时长未知 · 分辨率未知');
    });
  });

  group('MP4 富化：DOM 实测 + 页面信息 + HEAD 兜底', () {
    test('domMeta 补出分辨率+时长；HEAD 兜底补出大小', () async {
      final items = await Sniffer.groupAndEnrich(
        candidates: [mp4a],
        domMeta: {
          Sniffer.normalizeUrl(mp4a):
              const DomVideoMeta(resolution: '1280x720', durationSec: 90),
        },
        pageUrl: pageUrl,
        probeHead: (_) async => 12345678,
      );
      expect(items.length, 1);
      final m = items.first;
      expect(m.kind, 'mp4');
      expect(m.resolution, '1280x720');
      expect(m.durationSec, 90);
      expect(m.sizeBytes, 12345678);
      expect(m.detailLine, contains('720p'));
      expect(m.detailLine, contains('1:30'));
      expect(m.detailLine, contains('11.8 MB'));
    });

    test('og:video 地址对上才套；对不上时不乱套', () async {
      final items = await Sniffer.groupAndEnrich(
        candidates: [mp4a, mp4b],
        pageMeta: const PageVideoMeta(
          videoUrl: 'https://other.example.com/v.mp4',
          resolution: '1920x1080',
          durationSec: 60,
        ),
        pageUrl: pageUrl,
        probeHead: (_) async => null,
      );
      expect(items.length, 2);
      for (final m in items) {
        expect(m.resolution, isNull);
        expect(m.durationSec, isNull);
        expect(m.detailLine, '时长未知 · 分辨率未知 · 大小未知');
      }
    });

    test('单候选 + og:video 存在：地址对不上也套（页面主视频就是它）', () async {
      final items = await Sniffer.groupAndEnrich(
        candidates: [mp4a],
        pageMeta: const PageVideoMeta(
          videoUrl: 'https://www.youtube.com/embed/aqz-KE-bpKQ',
          resolution: '1920x1080',
          durationSec: 125,
        ),
        pageUrl: pageUrl,
        probeHead: (_) async => null,
      );
      expect(items.length, 1);
      expect(items.first.resolution, '1920x1080');
      expect(items.first.durationSec, 125);
      expect(items.first.detailLine, contains('1080p'));
      expect(items.first.detailLine, contains('2:05'));
    });

    test('probeRange 失败且 HEAD 也拿不到：大小保持 null，不编数字', () async {
      final items = await Sniffer.groupAndEnrich(
        candidates: [mp4a],
        pageUrl: pageUrl,
        probeHead: (_) async => null,
      );
      expect(items.first.sizeBytes, isNull);
    });
  });

  group('页面元数据解析：纯函数', () {
    test('normalizeUrl：小写 + 去 # 后缀', () {
      expect(Sniffer.normalizeUrl('HTTPS://Example.COM/V.MP4#frag'),
          'https://example.com/v.mp4');
      expect(Sniffer.normalizeUrl('https://a/b.mp4'), 'https://a/b.mp4');
    });

    test('parseIso8601Duration：PT1M30S=90，PT2H3M4S=7384，纯数字当秒', () {
      expect(Sniffer.parseIso8601Duration('PT1M30S'), 90);
      expect(Sniffer.parseIso8601Duration('PT2H3M4S'), 7384);
      expect(Sniffer.parseIso8601Duration('PT45S'), 45);
      expect(Sniffer.parseIso8601Duration('45'), 45);
      expect(Sniffer.parseIso8601Duration('bogus'), isNull);
      expect(Sniffer.parseIso8601Duration(''), isNull);
    });

    test('pickPageMeta：og:video 优先；没有 og 时用 VideoObject', () {
      // 真实页面数值（2026-11-17 从 YouTube 观看页实取）：
      // og:video=https://www.youtube.com/embed/aqz-KE-bpKQ，宽 1280、高 720。
      final og = Sniffer.pickPageMeta(
        ogVideo: 'https://www.youtube.com/embed/aqz-KE-bpKQ',
        ogVideoSecure: 'https://www.youtube.com/embed/aqz-KE-bpKQ',
        ogWidth: 1280,
        ogHeight: 720,
      );
      expect(og?.videoUrl, 'https://www.youtube.com/embed/aqz-KE-bpKQ');
      expect(og?.resolution, '1280x720');
      final vo = Sniffer.pickPageMeta(videoObjects: [
        {
          'contentUrl': 'https://cdn.example.com/v.mp4',
          'width': 640,
          'height': 360,
          'duration': 'PT1M30S',
        }
      ]);
      expect(vo?.videoUrl, 'https://cdn.example.com/v.mp4');
      expect(vo?.resolution, '640x360');
      expect(vo?.durationSec, 90);
      expect(Sniffer.pickPageMeta(), isNull);
    });
  });

  group('HLS 共享解析：resolveVariantMeta', () {
    test('master 有 RESOLUTION：直接用最高变体', () async {
      const master =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n1080p.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n720p.m3u8\n';
      const media1080 =
          '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:10.0,\nseg2.ts\n';
      final meta = await HlsPlaylist.resolveVariantMeta(
        masterBody: master,
        masterUrl: 'https://cdn.example.com/master.m3u8',
        fetch: (u) async => media1080,
      );
      expect(meta.resolution, '1920x1080');
      expect(meta.bandwidth, 5000000);
      expect(meta.durationSec, 30);
      expect(meta.segmentCount, 3);
      expect(meta.metaNote, isNull);
    });

    test('master 无 RESOLUTION：从变体 URL 提示抠分辨率', () async {
      const master =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2800000\n720p/prog_index.m3u8\n';
      const media =
          '#EXTM3U\n#EXTINF:8.0,\na.ts\n#EXTINF:8.0,\nb.ts\n';
      final meta = await HlsPlaylist.resolveVariantMeta(
        masterBody: master,
        masterUrl: 'https://cdn.example.com/master.m3u8',
        fetch: (u) async => media,
      );
      expect(meta.resolution, '1280x720');
      expect(meta.bandwidth, 2800000);
      expect(meta.durationSec, 16);
      expect(meta.metaNote, isNull);
    });

    test('嵌套 master：再解析一层拿分辨率', () async {
      const outer =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2800000\ninner.m3u8\n';
      const inner =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=640x360\n360p.m3u8\n';
      const media = '#EXTM3U\n#EXTINF:5.0,\na.ts\n#EXTINF:5.0,\nb.ts\n';
      final meta = await HlsPlaylist.resolveVariantMeta(
        masterBody: outer,
        masterUrl: 'https://cdn.example.com/master.m3u8',
        fetch: (u) async =>
            u.contains('inner') ? inner : media,
      );
      expect(meta.resolution, '640x360');
      expect(meta.durationSec, 10);
      expect(meta.metaNote, isNull);
    });

    test('媒体直链无分辨率：时长有、metaNote 写原因', () async {
      const media =
          '#EXTM3U\n#EXTINF:10.0,\na.ts\n#EXTINF:10.0,\nb.ts\n';
      final meta = await HlsPlaylist.resolveVariantMeta(
        masterBody: media,
        masterUrl: 'https://cdn.example.com/media.m3u8',
        fetch: (_) async => media,
      );
      expect(meta.resolution, isNull);
      expect(meta.durationSec, 20);
      expect(meta.metaNote, '播放列表无分辨率信息');
    });

    test('拉取失败：不抛错，metaNote 写拉取失败', () async {
      const master =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n720p.m3u8\n';
      final meta = await HlsPlaylist.resolveVariantMeta(
        masterBody: master,
        masterUrl: 'https://cdn.example.com/master.m3u8',
        fetch: (_) async => throw StateError('HTTP 403'),
      );
      expect(meta.resolution, '1280x720');
      expect(meta.bandwidth, 2800000);
      expect(meta.durationSec, isNull);
      expect(meta.metaNote, '播放列表拉取失败');
    });
  });

  group('HLS 富化：groupAndEnrich 走共享解析', () {
    test('master 无 RESOLUTION 时从变体 URL 提示拿到分辨率', () async {
      const master =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2800000\n720p/prog_index.m3u8\n';
      const media =
          '#EXTM3U\n#EXTINF:8.0,\na.ts\n#EXTINF:8.0,\nb.ts\n';
      final items = await Sniffer.groupAndEnrich(
        candidates: ['https://cdn.example.com/master.m3u8'],
        pageUrl: pageUrl,
        fetchText: (u) async => u.contains('720p') ? media : master,
      );
      expect(items.length, 1);
      expect(items.first.resolution, '1280x720');
      expect(items.first.durationSec, 16);
      expect(items.first.estimatedSizeBytes, 2800000 ~/ 8 * 16);
    });

    test('失败原因写进 metaNote，但不影响 downloadable', () async {
      const media =
          '#EXTM3U\n#EXTINF:10.0,\na.ts\n#EXTINF:10.0,\nb.ts\n';
      final items = await Sniffer.groupAndEnrich(
        candidates: ['https://cdn.example.com/media.m3u8'],
        pageUrl: pageUrl,
        fetchText: (_) async => media,
      );
      final m = items.first;
      expect(m.resolution, isNull);
      expect(m.durationSec, 20);
      expect(m.metaNote, '播放列表无分辨率信息');
      expect(m.downloadable, isTrue);
      expect(m.detailLine, contains('播放列表无分辨率信息'));
    });

    test('播放列表拉不到：note 照旧 + metaNote 拉取失败', () async {
      final items = await Sniffer.groupAndEnrich(
        candidates: ['https://cdn.example.com/gone.m3u8'],
        pageUrl: pageUrl,
        fetchText: (_) async => throw StateError('HTTP 403'),
      );
      final m = items.first;
      expect(m.note, '播放列表拉不到，下不了，只能在线播');
      expect(m.metaNote, '播放列表拉取失败');
      expect(m.detailLine, contains('播放列表拉取失败'));
    });
  });

  group('码率显示：模型里有的质量信号，detailLine 里全要能看到', () {
    test('无分辨率但码率已知：显示约 X Mbps', () {
      const m = SniffedMedia(
          url: 'https://a/b.m3u8', kind: 'm3u8', bandwidth: 5000000);
      expect(m.detailLine, contains('约 5.0 Mbps'));
      // 码率已知时显示已知的信号，不再用“未知”占位。
      expect(m.detailLine, isNot(contains('未知')));
    });

    test('有分辨率时显示分辨率，不重复显示码率', () {
      const m = SniffedMedia(
          url: 'https://a/b.m3u8',
          kind: 'm3u8',
          resolution: '1280x720',
          bandwidth: 2800000);
      expect(m.detailLine, contains('720p'));
      expect(m.detailLine, isNot(contains('Mbps')));
    });
  });

  group('原生 MP4 抄 Dart 元数据（copyWith 合并逻辑）', () {
    test('原生 MP4 只有地址：Dart 条目的分辨率/时长/大小都抄过去', () {
      // _mergedSniffed 是浏览器私有 State 方法，单元测试调不到；
      // 这里直接验它内部用的 copyWith 合并逻辑（与 fix4 第 ④ 组同款做法）。
      const native =
          SniffedMedia(url: mp4a, kind: 'mp4');
      const dart = SniffedMedia(
        url: mp4a,
        kind: 'mp4',
        resolution: '1920x1080',
        durationSec: 125,
        sizeBytes: 12345678,
      );
      final merged = native.copyWith(
        resolution: dart.resolution ?? native.resolution,
        durationSec: dart.durationSec ?? native.durationSec,
        sizeBytes: dart.sizeBytes ?? native.sizeBytes,
      );
      expect(merged.resolution, '1920x1080');
      expect(merged.durationSec, 125);
      expect(merged.sizeBytes, 12345678);
      expect(merged.detailLine, contains('1080p'));
      expect(merged.detailLine, contains('2:05'));
      expect(merged.detailLine, contains('11.8 MB'));
    });
  });

  group('URL 提示解析：resolutionFromUrlHint', () {
    test('路径里的 1080/720 认得出；视频 id 里的数字不认', () {
      expect(
          HlsPlaylist.resolutionFromUrlHint(
              'https://cdn.example.com/videos/1080p/file.m3u8'),
          '1920x1080');
      expect(
          HlsPlaylist.resolutionFromUrlHint(
              'https://cdn.example.com/v/1234567/x.mp4'),
          isNull);
      expect(
          HlsPlaylist.resolutionFromUrlHint(
              'https://cdn.example.com/4k/movie.m3u8'),
          '3840x2160');
    });

    test('parseMediaDurations：EXTINF 累加', () {
      expect(
          HlsPlaylist.parseMediaDurations(
              '#EXTM3U\n#EXTINF:10.0,\na.ts\n#EXTINF:6.5,\nb.ts\n'),
          (17, 2));
      expect(HlsPlaylist.parseMediaDurations(''), (0, 0));
    });
  });
}
