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

  test('r34 直链解析：优先 master.m3u8（HLS 最高 720p），其次 contentUrl mp4（只有 360p）', () {
    const html = '''
<script type="application/ld+json">
{"@type":"VideoObject","contentUrl":"https://r34content.b-cdn.net/videos/91018/360p.mp4"}
</script>
<link rel="preload" href="/media/videos/91018/master.m3u8">
''';
    expect(StreamResolver.parseR34DirectLink(html),
        'https://rule34-videos.com/media/videos/91018/master.m3u8');
  });

  test('r34 直链解析：没有 master 就退到 contentUrl mp4', () {
    const html = '''
<script type="application/ld+json">
{"@type":"VideoObject","contentUrl":"https://r34content.b-cdn.net/videos/91018/360p.mp4"}
</script>
''';
    expect(StreamResolver.parseR34DirectLink(html),
        'https://r34content.b-cdn.net/videos/91018/360p.mp4');
  });

  test('r34 直链解析：真站的 master 链接不加引号或用反引号，也要认出来', () {
    // 2026-11-09 实测真站详情页：<link ... href=/media/videos/91016/master.m3u8>
    // 和 JS 里的 const b=`/media/videos/91016/master.m3u8`，两种都没有普通引号。
    const html = '''
<link rel=preload href=/media/videos/91016/master.m3u8>
<script>const b=`/media/videos/91016/master.m3u8`;</script>
<script type="application/ld+json">
{"@type":"VideoObject","contentUrl":"https://r34content.b-cdn.net/videos/91016/360p.mp4"}
</script>
''';
    expect(StreamResolver.parseR34DirectLink(html),
        'https://rule34-videos.com/media/videos/91016/master.m3u8');
  });

  test('r34 直链解析：没有 mp4 就拼相对 master.m3u8 成绝对地址', () {
    const html = '''
<link rel="canonical" href="https://rule34-videos.com/video/chun-li-gym-doggy-da/">
<script>const b='/media/videos/91016/master.m3u8';</script>
''';
    expect(StreamResolver.parseR34DirectLink(html),
        'https://rule34-videos.com/media/videos/91016/master.m3u8');
  });

  test('r34 直链解析：页里没有两种真格式就返回 null，绝不拼垃圾地址', () {
    // 旧兜底正则的教训：这段 HTML 里只有 canonical 链接和一句提到 master.m3u8
    // 的文字，宽松正则会从 canonical 一路横跨整个 <head> 拼出几 KB 垃圾地址。
    const html = '''
<link rel="canonical" href="https://rule34-videos.com/video/some-video/">
<p>master.m3u8 is the playlist format</p>
''';
    expect(StreamResolver.parseR34DirectLink(html), isNull);
  });

  test('直链 sanity 检查：几 KB 垃圾地址、带空格、带尖括号、非 https 一律作废', () {
    expect(StreamResolver.isSaneStreamUrl('https://r34content.b-cdn.net/videos/91018/360p.mp4'), isTrue);
    expect(StreamResolver.isSaneStreamUrl('https://rule34-videos.com/media/videos/91016/master.m3u8'), isTrue);
    expect(StreamResolver.isSaneStreamUrl('x' * 501), isFalse);
    expect(StreamResolver.isSaneStreamUrl('https://example.com/a b.mp4'), isFalse);
    expect(StreamResolver.isSaneStreamUrl('https://example.com/<script>.mp4'), isFalse);
    expect(StreamResolver.isSaneStreamUrl('http://example.com/a.mp4'), isFalse);
    expect(StreamResolver.isSaneStreamUrl(''), isFalse);
  });

  test('Eporner 签名 hash 转换：四组 8 位 hex 各自 16 进制转 36 进制拼起来', () {
    // 2026-11-09 VM 实测：embed 页 hash aa65263a860fec34d919bc5ecd094511，
    // 转换后调 xhr/video 返回 200，拿到签名 720p。
    expect(StreamResolver.convertEpornerHash('aa65263a860fec34d919bc5ecd094511'),
        '1ba11yy1173ygk1o8k1ge1kw1s7l');
    expect(StreamResolver.convertEpornerHash('00000000000000000000000000000000'), '0000');
  });

  test('Eporner xhr 解析：优先 default=true 的档，duration 也拿回来', () {
    const body = '''
{"vid":"UTf3NMDv6B2","duration":475,"available":true,
 "sources":{"mp4":{
   "720p HD":{"labelShort":"720p","src":"https://vid-s2-c50-ca-cdn.eporner.com/v2/xxx/18920540-720p.mp4","type":"video/mp4","default":true},
   "480p":{"labelShort":"480p","src":"https://vid-s2-c50-ca-cdn.eporner.com/v2/xxx/18920540-480p.mp4","type":"video/mp4","default":false}},
  "hls":{"auto":{"src":"https://dash-s2-c50-ca-cdn.eporner.com/hls/master.m3u8","type":"application/x-mpegURL","default":false}}}}''';
    final parsed = StreamResolver.parseEpornerXhr(body);
    expect(parsed, isNotNull);
    expect(parsed!.url, contains('18920540-720p.mp4'));
    expect(parsed.durationSec, 475);
    // 没有 default 时退到 720p。
    const noDefault = '''
{"duration":300,"sources":{"mp4":{
   "480p":{"src":"https://cdn.example.com/a-480p.mp4","default":false},
   "720p":{"src":"https://cdn.example.com/a-720p.mp4","default":false}}}}''';
    expect(StreamResolver.parseEpornerXhr(noDefault)!.url, contains('720p'));
    // 没有 mp4 源返回 null。
    expect(StreamResolver.parseEpornerXhr('{"duration":100,"sources":{}}'), isNull);
    expect(StreamResolver.parseEpornerXhr('not json'), isNull);
  });
}
