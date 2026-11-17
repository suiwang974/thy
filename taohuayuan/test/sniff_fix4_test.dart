import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/downloader.dart';
import 'package:taohuayuan/services/sniffer.dart';
import 'package:taohuayuan/services/store.dart';
import 'package:taohuayuan/ui/sniff_sheet.dart';
import 'package:taohuayuan/ui/widgets.dart';

/// 4 条真机反馈修复的测试（2026-11-17）：
/// ① master 播放列表解析出分辨率/码率/时长/预估大小；
/// ② 质量排序顺序；③ 默认选中只选最优一条；
/// ④ 原生富化：同地址 Dart 条目有元数据时直接抄（不联网）；
/// ⑤ 封面收集与透传。
/// 单元测试里不真联网、不真起 WebView：播放列表一律用 fetchText 注入。
void main() {
  const pageUrl = 'https://example.com/video/123';

  group('① HLS 元数据：master 播放列表解析', () {
    test('最高变体的分辨率/码率/时长/预估大小都记到条目上', () async {
      const master =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n1080p.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n720p.m3u8\n';
      const media1080 =
          '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:10.0,\nseg2.ts\n';
      final items = await Sniffer.groupAndEnrich(
        candidates: ['https://cdn.example.com/master.m3u8'],
        pageUrl: pageUrl,
        fetchText: (u) async => u.contains('1080p') ? media1080 : master,
      );
      expect(items.length, 1);
      final m = items.first;
      expect(m.kind, 'm3u8');
      expect(m.resolution, '1920x1080');
      expect(m.bandwidth, 5000000);
      expect(m.durationSec, 30);
      expect(m.segmentCount, 3);
      // 预估大小 = 码率 / 8 × 时长 = 5000000 / 8 × 30 = 18750000 字节。
      expect(m.estimatedSizeBytes, 18750000);
      expect(m.resolutionText, '1080p');
      expect(m.qualityPixels, 1920 * 1080);
      expect(m.detailLine, contains('1080p'));
      expect(m.detailLine, contains('约 17.9 MB'));
      expect(m.detailLine, contains('0:30'));
    });

    test('media 列表直链（无 STREAM-INF）：分辨率/码率留空，时长照常算', () async {
      const media =
          '#EXTM3U\n#EXTINF:6.0,\na.ts\n#EXTINF:6.0,\nb.ts\n';
      final items = await Sniffer.groupAndEnrich(
        candidates: ['https://cdn.example.com/media.m3u8'],
        pageUrl: pageUrl,
        fetchText: (_) async => media,
      );
      expect(items.length, 1);
      expect(items.first.resolution, isNull);
      expect(items.first.bandwidth, isNull);
      expect(items.first.estimatedSizeBytes, isNull);
      expect(items.first.durationSec, 12);
    });

    test('m3u8 啥都没有：detailLine 显示“时长未知 · 分辨率未知”', () async {
      final items = await Sniffer.groupAndEnrich(
        candidates: ['https://cdn.example.com/empty.m3u8'],
        pageUrl: pageUrl,
        fetchText: (_) async => '#EXTM3U\n',
      );
      expect(items.length, 1);
      expect(items.first.detailLine, '时长未知 · 分辨率未知');
    });

    test('分辨率/像素换算：空值与非法值返回 0/空串', () {
      const noRes = SniffedMedia(url: 'https://a/b.m3u8', kind: 'm3u8');
      expect(noRes.qualityPixels, 0);
      expect(noRes.resolutionText, '');
      const bad = SniffedMedia(
          url: 'https://a/b.m3u8', kind: 'm3u8', resolution: 'abc');
      expect(bad.qualityPixels, 0);
      expect(bad.resolutionText, '');
      const hd = SniffedMedia(
          url: 'https://a/b.m3u8', kind: 'm3u8', resolution: '1280x720');
      expect(hd.qualityPixels, 1280 * 720);
      expect(hd.resolutionText, '720p');
    });
  });

  group('② 质量排序：分辨率优先，缺分辨率时按大小', () {
    test('1080p 在 720p 前；无分辨率时大文件在前', () {
      final items = [
        const SniffedMedia(
            url: 'https://cdn.example.com/720p.m3u8',
            kind: 'm3u8',
            resolution: '1280x720',
            bandwidth: 2800000),
        const SniffedMedia(
            url: 'https://cdn.example.com/big.mp4',
            kind: 'mp4',
            sizeBytes: 500 * 1024 * 1024),
        const SniffedMedia(
            url: 'https://cdn.example.com/1080p.m3u8',
            kind: 'm3u8',
            resolution: '1920x1080',
            bandwidth: 5000000),
        const SniffedMedia(
            url: 'https://cdn.example.com/small.mp4',
            kind: 'mp4',
            sizeBytes: 100 * 1024 * 1024),
      ];
      final sorted = [...items]..sort(SniffedMedia.compareQuality);
      expect(sorted[0].url, contains('1080p'));
      expect(sorted[1].url, contains('720p'));
      expect(sorted[2].url, contains('big.mp4'));
      expect(sorted[3].url, contains('small.mp4'));
    });

    test('同分辨率比码率；都一样时 mp4 在 m3u8 前', () {
      final items = [
        const SniffedMedia(
            url: 'https://cdn.example.com/a.m3u8',
            kind: 'm3u8',
            resolution: '1280x720',
            bandwidth: 1000000),
        const SniffedMedia(
            url: 'https://cdn.example.com/b.mp4',
            kind: 'mp4',
            resolution: '1280x720',
            bandwidth: 1000000),
        const SniffedMedia(
            url: 'https://cdn.example.com/c.m3u8',
            kind: 'm3u8',
            resolution: '1280x720',
            bandwidth: 2000000),
      ];
      final sorted = [...items]..sort(SniffedMedia.compareQuality);
      expect(sorted[0].url, contains('/c.m3u8')); // 码率最高
      expect(sorted[1].url, contains('/b.mp4')); // 同码率 mp4 优先
      expect(sorted[2].url, contains('/a.m3u8'));
    });

    test('bestOf：跳过下不了的条目；没有可下的返回 null', () {
      final items = [
        const SniffedMedia(
            url: 'https://cdn.example.com/1080p.m3u8',
            kind: 'm3u8',
            resolution: '1920x1080',
            note: '播放列表拉不到，下不了，只能在线播'),
        const SniffedMedia(
            url: 'https://cdn.example.com/720p.m3u8',
            kind: 'm3u8',
            resolution: '1280x720'),
        const SniffedMedia(
            url: 'blob:', kind: 'blob', playableOnly: true),
      ];
      expect(SniffedMedia.bestOf(items)?.url, contains('720p'));
      expect(
          SniffedMedia.bestOf([
            const SniffedMedia(
                url: 'blob:', kind: 'blob', playableOnly: true),
          ]),
          isNull);
    });
  });

  group('④ 原生富化：同地址 Dart 条目的元数据直接抄（不联网）', () {
    test('copyWith 把 Dart 条目的分辨率/码率/时长抄到原生条目上', () {
      // 原生候选转成的条目：只有地址和类型，没有任何元数据。
      const native = SniffedMedia(
          url: 'https://cdn.example.com/master.m3u8', kind: 'm3u8');
      // 同地址的 Dart 条目（groupAndEnrich 已富化过）：有完整元数据。
      const dart = SniffedMedia(
        url: 'https://cdn.example.com/master.m3u8',
        kind: 'm3u8',
        resolution: '1920x1080',
        bandwidth: 5000000,
        estimatedSizeBytes: 18750000,
        durationSec: 30,
        segmentCount: 3,
      );
      final merged = native.copyWith(
        resolution: dart.resolution ?? native.resolution,
        bandwidth: dart.bandwidth ?? native.bandwidth,
        estimatedSizeBytes:
            dart.estimatedSizeBytes ?? native.estimatedSizeBytes,
        durationSec: dart.durationSec ?? native.durationSec,
        segmentCount:
            dart.segmentCount > 0 ? dart.segmentCount : native.segmentCount,
      );
      expect(merged.resolution, '1920x1080');
      expect(merged.bandwidth, 5000000);
      expect(merged.estimatedSizeBytes, 18750000);
      expect(merged.durationSec, 30);
      expect(merged.segmentCount, 3);
      expect(merged.url, native.url);
    });

    test('groupAndEnrich 注入假播放列表：不联网也能富化（供原生富化兜底用）',
        () async {
      const master =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n720p.m3u8\n';
      const media = '#EXTM3U\n#EXTINF:8.0,\na.ts\n#EXTINF:8.0,\nb.ts\n';
      var fetched = 0;
      final items = await Sniffer.groupAndEnrich(
        candidates: ['https://cdn.example.com/master.m3u8'],
        pageUrl: pageUrl,
        fetchText: (u) async {
          fetched++;
          return u.contains('720p') ? media : master;
        },
      );
      expect(fetched, 2); // 只拉了 master + 选中变体，没多拉
      expect(items.first.resolution, '1280x720');
      expect(items.first.durationSec, 16);
      expect(items.first.estimatedSizeBytes, 2800000 ~/ 8 * 16);
    });
  });

  group('⑤ 封面收集与透传', () {
    test('SniffResult.pagePoster：有封面就带上，没有默认空串', () {
      const r = SniffResult(
        [],
        '标题',
        '',
        SniffDiagnosis(),
        'https://cdn.example.com/poster.jpg',
      );
      expect(r.pagePoster, 'https://cdn.example.com/poster.jpg');
      const empty = SniffResult([], '标题');
      expect(empty.pagePoster, '');
    });

    test('DownloadTask poster 持久化：toJson/fromJson 一圈回来还在', () {
      final t = DownloadTask(
        id: 't1',
        title: '视频',
        source: 'web',
        poster: 'https://cdn.example.com/poster.jpg',
        durationSec: 30,
        kind: DownloadKind.hls,
      );
      final back = DownloadTask.fromJson(t.toJson());
      expect(back.poster, 'https://cdn.example.com/poster.jpg');
    });

    test('startDownloadFromUrl 的 poster 参数会存进任务', () async {
      SharedPreferences.setMockInitialValues({});
      final t = await DownloadManager.instance.startDownloadFromUrl(
        id: 'sniff-fix4-poster-test',
        title: '视频',
        source: 'web',
        url: 'https://cdn.example.com/no-such-video.m3u8',
        poster: 'https://cdn.example.com/poster.jpg',
      );
      expect(t, isNotNull);
      expect(t!.poster, 'https://cdn.example.com/poster.jpg');
      // 假地址下不成是预期的（任务会失败），但封面必须已存进任务里。
      await Future.delayed(const Duration(seconds: 1));
      final stored =
          DownloadManager.instance.taskFor('sniff-fix4-poster-test');
      expect(stored?.poster, 'https://cdn.example.com/poster.jpg');
    });

    testWidgets('PosterThumb 没封面时显示图标占位，不写“无封面”',
        (tester) async {
      const item = VideoItem(
        id: 'v1',
        title: '视频标题',
        source: 'web',
        poster: '',
        durationSec: 30,
      );
      // 下载管理用的 54px 小尺寸：只显示居中图标。
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PosterThumb(item: item, height: 54)),
        ),
      );
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
      expect(find.text('无封面'), findsNothing);
      // 大尺寸：图标 + 标题 + 来源/时长都显示。
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 200,
              child: PosterThumb(item: item),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
      expect(find.text('无封面'), findsNothing);
      expect(find.text('视频标题'), findsOneWidget);
    });
  });

  group('③ 默认选中只选最优一条（SniffSheet 真弹）', () {
    testWidgets('21 条里只勾质量最好的一条；没有可下的全不勾',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = await Store.load();
      final items = [
        const SniffedMedia(
            url: 'https://cdn.example.com/720p.m3u8',
            kind: 'm3u8',
            resolution: '1280x720',
            bandwidth: 2800000,
            durationSec: 60),
        const SniffedMedia(
            url: 'https://cdn.example.com/1080p.m3u8',
            kind: 'm3u8',
            resolution: '1920x1080',
            bandwidth: 5000000,
            durationSec: 60),
        const SniffedMedia(
            url: 'https://cdn.example.com/small.mp4',
            kind: 'mp4',
            sizeBytes: 50 * 1024 * 1024),
        const SniffedMedia(
            url: 'blob:', kind: 'blob', playableOnly: true),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => SniffSheet.show(
                context,
                items: items,
                pageTitle: '测试页',
                sourceId: 'web',
                pageUrl: pageUrl,
                store: store,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      // 只看媒体条目的勾选（ts 转 mp4 那行勾选不算）：标题是地址的那些。
      final tiles = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .where((t) {
        final title = t.title;
        return title is Text &&
            ((title.data ?? '').startsWith('https://'));
      }).toList();
      expect(tiles.length, 3); // 3 条可下；blob 不可勾，不在其中
      final checked = tiles.where((t) => t.value == true).toList();
      expect(checked.length, 1);
      final checkedTitle = (checked.first.title as Text).data!;
      expect(checkedTitle, contains('1080p'));
      expect(find.text('下载所选（1）'), findsOneWidget);
    });
  });
}
