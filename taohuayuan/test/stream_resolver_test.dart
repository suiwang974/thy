import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/stream_resolver.dart';

void main() {
  test('xvideos 直链解析：优先高清 mp4', () {
    const html = '''
<script>
html5player.setVideoTitle('test video');
html5player.setVideoUrlLow('https://g-video.com/low.mp4');
html5player.setVideoUrlHigh('https://g-video.com/high.mp4');
html5player.setVideoHLS('https://g-video.com/hls.m3u8');
</script>
''';
    expect(StreamResolver.parseXvideosDirectLink(html), 'https://g-video.com/high.mp4');
  });

  test('xvideos 直链解析：没有高清就拿 HLS，再没有拿低清', () {
    const hlsOnly = '''
html5player.setVideoUrlLow('https://g-video.com/low.mp4');
html5player.setVideoHLS('https://g-video.com/hls.m3u8');
''';
    expect(StreamResolver.parseXvideosDirectLink(hlsOnly), 'https://g-video.com/hls.m3u8');

    const lowOnly = '''
html5player.setVideoUrlLow('https://g-video.com/low.mp4');
''';
    expect(StreamResolver.parseXvideosDirectLink(lowOnly), 'https://g-video.com/low.mp4');
  });

  test('xvideos 直链解析：三个都没有返回 null（走“在源站看”备选）', () {
    const html = '<html><body>no player here</body></html>';
    expect(StreamResolver.parseXvideosDirectLink(html), isNull);
  });

  test('预览判定：真实不到列表一半就是预览', () {
    // Eporner 案例：列表 10 分钟，直链只有 1 分钟带水印预览。
    expect(StreamResolver.isPreviewDuration(listedSec: 600, actualSec: 60), isTrue);
    // 列表 2 分钟、真实 59 秒也是预览。
    expect(StreamResolver.isPreviewDuration(listedSec: 120, actualSec: 59), isTrue);
    // 真实 400 秒对列表 600 秒不是预览（误差/剪辑不算预览）。
    expect(StreamResolver.isPreviewDuration(listedSec: 600, actualSec: 400), isFalse);
    // 正好一半不算预览。
    expect(StreamResolver.isPreviewDuration(listedSec: 120, actualSec: 60), isFalse);
    // 列表时长未知不核对，真实时长未知也不误判。
    expect(StreamResolver.isPreviewDuration(listedSec: 0, actualSec: 60), isFalse);
    expect(StreamResolver.isPreviewDuration(listedSec: 600, actualSec: 0), isFalse);
  });

  test('m3u8 总时长：媒体播放列表把 #EXTINF 加起来', () {
    const media = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:9.5,
seg0.ts
#EXTINF:10.0,
seg1.ts
#EXTINF:8.25,
seg2.ts
#EXT-X-ENDLIST
''';
    expect(StreamResolver.parseM3u8Duration(media), 28); // 9.5+10+8.25=27.75 -> 28
  });

  test('m3u8 总时长：主播放列表返回 null，要先取变体', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
high.m3u8
''';
    expect(StreamResolver.parseM3u8Duration(master), isNull);
    expect(StreamResolver.parseM3u8Variant(master), 'low.m3u8');
    expect(StreamResolver.parseM3u8Variant('#EXTM3U\n#EXTINF:10.0,\nseg.ts\n'), isNull);
    expect(StreamResolver.parseM3u8Duration('#EXTM3U\n'), isNull);
  });

  test('官方页广告分类：niacg、lianzu11 没广告，其他 6 个源有广告要如实说', () {
    expect(StreamResolver.sourcePageHasAds('niacg'), isFalse);
    expect(StreamResolver.sourcePageHasAds('lianzu11'), isFalse);
    expect(StreamResolver.sourcePageHasAds('xvideos'), isTrue);
    expect(StreamResolver.sourcePageHasAds('xhamster'), isTrue);
    expect(StreamResolver.sourcePageHasAds('pornhub'), isTrue);
    expect(StreamResolver.sourcePageHasAds('spankbang'), isTrue);
    expect(StreamResolver.sourcePageHasAds('eporner'), isTrue);
    expect(StreamResolver.sourcePageHasAds('rule34videos'), isTrue);
  });

  test('详情页预探补封面/时长：og:image 和 og:video:duration', () {
    const html = '''
<html><head>
<meta property="og:image" content="https://example.com/poster.jpg">
<meta property="og:video:duration" content="754">
</head></html>
''';
    expect(StreamResolver.parseOgImage(html), 'https://example.com/poster.jpg');
    expect(StreamResolver.parseOgDuration(html), 754);
    // content 在前的写法也能抓
    const html2 = '<meta content="https://example.com/p2.jpg" property="og:image">';
    expect(StreamResolver.parseOgImage(html2), 'https://example.com/p2.jpg');
    expect(StreamResolver.parseOgImage('<html></html>'), isNull);
    expect(StreamResolver.parseOgDuration('<html></html>'), isNull);
    // JSON 里的 "duration" 也能当后备
    expect(StreamResolver.parseOgDuration('{"duration": 623}'), 623);
  });
}
