import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/sniffer.dart';

/// 嗅探分组测试（第 34 条，1DM“查找到文件”的样子）：
/// - m3u8 一个播放列表归一条，拉播放列表算总时长/分片数；
/// - .ts 没播放列表时按同一目录前缀归成一条，不几十条刷屏；
/// - mp4 单条；blob 只有它自己时标“拿不到地址”；
/// - 缩略图预览/广告域名排除。
/// 联网部分（拉播放列表、Range 探大小）用注入的假 fetch，不真联网。
void main() {
  const pageUrl = 'https://rule34-videos.com/video/12345/sadako-curse';

  test('m3u8 分组归一：一个播放列表一条，时长/分片数从播放列表算', () async {
    const media = '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:4.5,\nseg2.ts\n';
    final items = await Sniffer.groupAndEnrich(
      candidates: [
        'https://rule34-videos.com/media/videos/90011/master.m3u8',
        // 同一播放列表在 DOM 和 performance 里各出现一次：只留一条。
        'https://rule34-videos.com/media/videos/90011/master.m3u8',
      ],
      pageUrl: pageUrl,
      fetchText: (_) async => media,
    );
    expect(items.length, 1);
    expect(items.first.kind, 'm3u8');
    expect(items.first.durationSec, 25); // 10+10+4.5 四舍五入
    expect(items.first.segmentCount, 3);
    expect(items.first.downloadable, isTrue);
  });

  test('m3u8 主播放列表：先挑最高变体再算时长', () async {
    const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=854x480\n480p.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n720p.m3u8\n';
    const media720 = '#EXTM3U\n#EXTINF:6.0,\na.ts\n#EXTINF:6.0,\nb.ts\n';
    final items = await Sniffer.groupAndEnrich(
      candidates: ['https://cdn.example.com/master.m3u8'],
      pageUrl: pageUrl,
      fetchText: (u) async => u.contains('720p') ? media720 : master,
    );
    expect(items.length, 1);
    expect(items.first.durationSec, 12);
    expect(items.first.segmentCount, 2);
  });

  test('m3u8 播放列表拉不到：条目留着、写明下不了', () async {
    final items = await Sniffer.groupAndEnrich(
      candidates: ['https://cdn.example.com/broken.m3u8'],
      pageUrl: pageUrl,
      fetchText: (_) async => throw StateError('HTTP 403'),
    );
    expect(items.length, 1);
    expect(items.first.downloadable, isFalse);
    expect(items.first.note, contains('下不了'));
  });

  test('ts 分组：同一目录前缀归一条，分片数写清楚', () async {
    final items = await Sniffer.groupAndEnrich(
      candidates: [
        'https://op.udhhzr.cn/hls/abc/seg-1.ts',
        'https://op.udhhzr.cn/hls/abc/seg-2.ts',
        'https://op.udhhzr.cn/hls/abc/seg-3.ts',
        // 另一个目录是另一个视频：分开归。
        'https://op.udhhzr.cn/hls/def/seg-1.ts',
      ],
      pageUrl: pageUrl,
    );
    expect(items.length, 2);
    expect(items.where((m) => m.kind == 'ts').length, 2);
    final abc = items.firstWhere((m) => m.url.contains('/abc/'));
    expect(abc.segmentCount, 3);
  });

  test('mp4 单条 + 缩略图预览/广告排除 + blob 标记', () async {
    final items = await Sniffer.groupAndEnrich(
      candidates: [
        'https://cdn.example.com/real.mp4',
        'https://cdn.example.com/thumb-preview.mp4',
        'https://thumb-v1.xhcdn.com/abc/526x298/t.mp4',
        'https://doubleclick.net/ads/video.mp4',
        'blob:https://rule34-videos.com/1234-abcd',
      ],
      pageUrl: pageUrl,
    );
    // mp4 一条；blob 没找到底层地址时也留一条（写明拿不到地址）。
    expect(items.length, 2);
    expect(items.first.kind, 'mp4');
    expect(items.first.url, 'https://cdn.example.com/real.mp4');
    final blob = items.last;
    expect(blob.kind, 'blob');
    expect(blob.playableOnly, isTrue);
    expect(blob.downloadable, isFalse);
    expect(blob.note, contains('拿不到地址'));
  });

  test('m3u8 时长解析：#EXTINF 加起来（纯函数）', () {
    const body = '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:4.5,\nseg2.ts\n';
    final (dur, count) = Sniffer.parseM3u8Durations(body);
    expect(dur, 25);
    expect(count, 3);
    expect(Sniffer.parseM3u8Durations('#EXTM3U\n'), (0, 0));
  });

  test('第 53 条：诊断——JS 抛错要如实报，不要装作页面没视频', () {
    const d = SniffDiagnosis(jsError: 'TypeError: Cannot read properties of null');
    expect(d.text, contains('嗅探脚本在页面里执行失败'));
    expect(d.text, contains('TypeError'));
    expect(d.text, contains('不是页面没有视频'));
  });

  test('第 53 条：诊断——一个 video 都没找到时写明查了什么，不写“列表页”', () {
    const d = SniffDiagnosis(
      videoCount: 0,
      performanceMediaCount: 0,
      htmlMediaCount: 0,
    );
    expect(d.text, contains('没找到 video 元素'));
    expect(d.text, contains('网络请求里没有'));
    expect(d.text, contains('页面源码里也没扫到'));
    expect(d.text, isNot(contains('列表页')));
  });

  test('第 53 条：诊断——视频在播但只有 blob:，要写明底层地址没出现', () {
    const d = SniffDiagnosis(
      videoCount: 1,
      playingCount: 1,
      blobVideoCount: 1,
      performanceMediaCount: 0,
      htmlMediaCount: 0,
    );
    expect(d.text, contains('1 个正在播'));
    expect(d.text, contains('blob:'));
    expect(d.text, contains('MSE 播放器'));
  });

  test('第 53 条：诊断——跨域 iframe 里的播放器：认出来 + 给打开播放页的地址', () {
    const d = SniffDiagnosis(
      videoCount: 0,
      performanceMediaCount: 0,
      iframeCount: 2,
      crossOriginIframeCount: 1,
      iframeSrcs: ['https://player.example.com/embed/xyz123'],
      htmlMediaCount: 0,
    );
    expect(d.text, contains('1 个跨域 iframe'));
    expect(d.playerIframeUrl, 'https://player.example.com/embed/xyz123');
    expect(d.text, contains('打开播放页'));
  });

  test('第 53 条：诊断——广告 iframe 不当播放器；多个跨域 iframe 时不乱指', () {
    const ads = SniffDiagnosis(
      crossOriginIframeCount: 1,
      iframeSrcs: ['https://googleads.g.doubleclick.net/pagead/html'],
    );
    expect(ads.playerIframeUrl, isNull);
    const multi = SniffDiagnosis(
      crossOriginIframeCount: 2,
      iframeSrcs: [
        'https://widget.example.com/chat',
        'https://other.example.com/panel',
      ],
    );
    expect(multi.playerIframeUrl, isNull);
  });
}
