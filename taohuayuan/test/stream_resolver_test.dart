import 'dart:io';

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

  test('全屏画质档位：xvideos 三档标签抠真实分辨率（第 14 条）', () {
    const html = '''
setVideoUrlHigh('https://xh2-cdn.example.com/video_1080p.mp4')
setVideoHLS('https://xh2-cdn.example.com/hls.m3u8')
setVideoUrlLow('https://xh2-cdn.example.com/video_360p.mp4')
''';
    final vs = StreamResolver.parseXvideosVariants(html);
    expect(vs.map((v) => v.label).toList(), ['1080p', 'HLS 自适应', '360p']);
    expect(vs.map((v) => v.url).toList(), [
      'https://xh2-cdn.example.com/video_1080p.mp4',
      'https://xh2-cdn.example.com/hls.m3u8',
      'https://xh2-cdn.example.com/video_360p.mp4',
    ]);
    // 只有低清时只有一档；什么都没有返回空。
    const lowOnly = "setVideoUrlLow('https://xh2-cdn.example.com/video_360p.mp4')";
    expect(StreamResolver.parseXvideosVariants(lowOnly).map((v) => v.label).toList(), ['360p']);
    expect(StreamResolver.parseXvideosVariants(''), isEmpty);
  });

  test('全屏画质档位：r34 只有 360p mp4 是真文件（第 14 条）', () {
    const html = '''
<script type="application/ld+json">
{"@type":"VideoObject","contentUrl":"https://r34content.b-cdn.net/videos/91018/360p.mp4"}
</script>
''';
    expect(StreamResolver.parseR34Mp4(html),
        'https://r34content.b-cdn.net/videos/91018/360p.mp4');
    expect(StreamResolver.parseR34Mp4('<html></html>'), isNull);
  });

  test('全屏画质档位：eporner xhr 全部档位都拿出来（第 14 条）', () {
    const body = '''
{"duration":475,"sources":{"mp4":{
   "720":{"src":"https://cdn.example.com/a-720.mp4"},
   "480p":{"src":"https://cdn.example.com/a-480.mp4"},
   "360":{"src":"https://cdn.example.com/a-360.mp4"}}}}''';
    final all = StreamResolver.parseEpornerXhrAll(body);
    expect(all.keys.toSet(), {'720p', '480p', '360p'});
    expect(all['720p'], 'https://cdn.example.com/a-720.mp4');
    expect(StreamResolver.parseEpornerXhrAll('{"sources":{}}'), isEmpty);
    expect(StreamResolver.parseEpornerXhrAll('not json'), isEmpty);
  });

  test('全屏画质档位：HLS 主播放列表的变体带分辨率标签（第 14 条）', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=854x480
480p.m3u8
''';
    final vs = StreamResolver.parseM3u8VariantList(
        master, 'https://rule34-videos.com/media/videos/91016/master.m3u8');
    expect(vs.map((v) => v.label).toList(), ['720p', '480p']);
    expect(vs[0].url, 'https://rule34-videos.com/media/videos/91016/720p.m3u8');
    // 已经是媒体播放列表（没有 STREAM-INF）返回空。
    const media = '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXTINF:10.0,\nseg1.ts\n';
    expect(StreamResolver.parseM3u8VariantList(media, 'https://example.com/master.m3u8'), isEmpty);
  });

  test('第 29 条：pornhub mediaDefinitions 夹具解析（真页抠的 5 条）', () async {
    final fixture = await File('test/fixtures/pornhub-mediadefinitions.json').readAsString();
    final html = '<script>var player={ "mediaDefinitions": $fixture };</script>';
    final defs = StreamResolver.parsePornhubMediaDefinitions(html);
    expect(defs.length, 5);
    // 1080 HLS 优先（最高档）。
    final hls1080 = defs.where((d) => d.format == 'hls' && d.quality == '1080').toList();
    expect(hls1080.length, 1);
    expect(hls1080.first.url, contains('1080P_4000K'));
    expect(hls1080.first.url, contains('master.m3u8'));
    // get_media 接口地址认出来（format mp4、quality 为空）。
    final mp4 = defs.where((d) => d.format == 'mp4').toList();
    expect(mp4.length, 1);
    expect(mp4.first.url, contains('/video/get_media'));
    // 没 mediaDefinitions 返回空。
    expect(StreamResolver.parsePornhubMediaDefinitions('<html>no json</html>'), isEmpty);
  });

  test('第 29 条：pornhub get_media JSON 数组 -> 签名 mp4', () {
    const body = '''[{"quality":"480","videoUrl":"https://ee.phncdn.com/videos/480P_2000K.mp4?validfrom=1&hash=abc"},'''
        '''{"quality":"720","videoUrl":"https://ee.phncdn.com/videos/720P_4000K.mp4?validfrom=1&hash=def"}]''';
    final got = StreamResolver.parsePornhubGetMedia(body);
    expect(got.length, 2);
    expect(got.map((e) => e.quality).toList(), ['480', '720']);
    expect(got[1].url, contains('720P_4000K.mp4'));
    expect(StreamResolver.parsePornhubGetMedia('not json'), isEmpty);
  });

  test('第 29 条：xhamster 合成夹具解析（noscript mp4 + HLS，thumb 预览排除）', () async {
    final html = await File('test/fixtures/xhamster-video.html').readAsString();
    final (mp4: mp4, hls: hls) = StreamResolver.parseXhamsterDirectLinks(html);
    expect(mp4, contains('video7.xhcdn.com'));
    expect(mp4, contains('720p.h264.mp4'));
    expect(hls, contains('video-nss.xhcdn.com'));
    expect(hls, endsWith('.m3u8'));
    // 缩略图预览不认：全是 thumb 的页返回 null。
    const thumbsOnly = '<video src="https://thumb-v1.xhcdn.com/abc/526x298/t.mp4"></video>';
    final (mp4: m2, hls: h2) = StreamResolver.parseXhamsterDirectLinks(thumbsOnly);
    expect(m2, isNull);
    expect(h2, isNull);
  });

  test('第 29 条：通用兜底扫描（排除 thumb/preview/广告域名）', () {
    const html = '''
      <script src="https://www.googletagmanager.com/gtag.js"></script>
      <video src="https://cdn.example.com/thumb-preview.mp4"></video>
      <a href="https://cdn.example.com/real-video.mp4?x=1">play</a>
    ''';
    expect(StreamResolver.genericMediaScan(html), 'https://cdn.example.com/real-video.mp4?x=1');
    expect(StreamResolver.genericMediaScan('<html>nothing here</html>'), isNull);
    expect(StreamResolver.genericMediaScan('https://doubleclick.net/ads/video.mp4'), isNull);
  });

  test('第 29 条：extractJsonArray 括号计数（字符串里的括号不算）', () {
    const html = 'x = {"mediaDefinitions": [{"a": "[not array]", "b": 1}, {"c": 2}]}; y=1';
    final raw = StreamResolver.extractJsonArray(html, '"mediaDefinitions"');
    expect(raw, startsWith('[{"a": "[not array]"'));
    expect(raw, endsWith('}]'));
    expect(StreamResolver.extractJsonArray(html, '"missing"'), isNull);
  });

  test('第 37 条：预览判定——15 分钟的实际不可能是预览（列表时长写错了）', () {
    // 用户真机案例：列表 320:18（19218 秒）、真实 15:41（941 秒）——正片不是预览。
    expect(StreamResolver.isPreviewDuration(listedSec: 19218, actualSec: 941), isFalse);
    // 列表 60 分钟、真实 4 分钟是预览（真实短）。
    expect(StreamResolver.isPreviewDuration(listedSec: 3600, actualSec: 240), isTrue);
    // 列表 60 分钟、真实 6 分钟不是预览（超过 5 分钟上限，按列表错处理）。
    expect(StreamResolver.isPreviewDuration(listedSec: 3600, actualSec: 360), isFalse);
  });

  test('第 42 条：视频页作者解析——pornhub/xvideos/r34/niacg/xhamster', () {
    expect(
      StreamResolver.parseVideoAuthor(
        '{"username":"Pink Pussy Creampie","viewkey":"6acf472d64e8e"}',
        'pornhub',
      ).author,
      'Pink Pussy Creampie',
    );
    expect(
      StreamResolver.parseVideoAuthor(
        '<a href="/darcy-dark-1" class="btn uploader-tag hover-name"><span class="name">DarcyDark <span>58k</span></span></a>',
        'xvideos',
      ).author,
      'DarcyDark',
    );
    expect(
      StreamResolver.parseVideoAuthor(
        '{"@type":"VideoObject","author": "LazyProcrastinator"}',
        'rule34videos',
      ).author,
      'LazyProcrastinator',
    );
    expect(
      StreamResolver.parseVideoAuthor(
        '<title>[AlphaG] Capture Yixuan + Naked [中文字幕]</title>',
        'niacg',
      ).author,
      'AlphaG',
    );
    final xh = StreamResolver.parseVideoAuthor(
      '{"author":{"id":58272582,"pageUrl":"https://xhamster.com/users/privatfeet20","isRetired":false,"isVerified":false,"name":"PrivatFeet20","thumbUrl":"https://ic-ut-nss.xhcdn.com/a/thumb.jpg"}}',
      'xhamster',
    );
    expect(xh.author, 'PrivatFeet20');
    expect(xh.authorAvatar, 'https://ic-ut-nss.xhcdn.com/a/thumb.jpg');
    // 没抠到返回空，不编一个。
    expect(StreamResolver.parseVideoAuthor('<html></html>', 'spankbang').author, '');
    expect(StreamResolver.parseVideoAuthor('<html></html>', 'eporner').author, '');
  });

  test('第 47 条：eporner 作者只认视频页 vit-uploader，相关视频的 mb-uploader 不误认', () {
    // VM 实测真片段：视频页 185,020 字节里上传者就在这里。
    expect(
      StreamResolver.parseVideoAuthor(
        '<li class="vit-uploader"><a href="/profile/fepaciw123/" title="Uploader">fepaciw123</a></li>',
        'eporner',
      ).author,
      'fepaciw123',
    );
    // 相关视频里的 mb-uploader 是别人的，别拿来当作者。
    expect(
      StreamResolver.parseVideoAuthor(
        '<div><span class="mb-uploader">SomeoneElse</span></div>',
        'eporner',
      ).author,
      '',
    );
    // vit-uploader 在，mb-uploader 也在时只取 vit-uploader 的。
    expect(
      StreamResolver.parseVideoAuthor(
        '<li class="vit-uploader"><a href="/profile/fepaciw123/" title="Uploader">fepaciw123</a></li>'
        '<div><span class="mb-uploader">SomeoneElse</span></div>',
        'eporner',
      ).author,
      'fepaciw123',
    );
  });

  // ---------- 第 51 条：xvideos 档位太低 ----------
  test('第 51 条：xvideos High/Low 同地址只留一档（1440p 标签那条 High=Low=mp4_sd.mp4）', () {
    // VM 实测：1440p 标签视频 video.omvtbcb4257 的 setVideoUrlHigh/Low 都是
    // https://gcore-vod.xvideos-cdn.com/videos/mp4_sd.mp4（地址里没分辨率）。
    const html = r'''
      setVideoUrlHigh('https://gcore-vod.xvideos-cdn.com/videos/mp4_sd.mp4');
      setVideoUrlLow('https://gcore-vod.xvideos-cdn.com/videos/mp4_sd.mp4');
      setVideoHLS('https://gcore-vod.xvideos-cdn.com/videos/hls.m3u8');
    ''';
    final variants = StreamResolver.parseXvideosVariants(html);
    // High/Low 同地址去重后只剩 HLS 自适应 + 一个 mp4 档（地址里没分辨率，
    // 标签按 fallback 叫“高清”，不是“原画”）。
    expect(variants.map((v) => v.label).toList(), ['高清', 'HLS 自适应']);
    expect(variants.where((v) => v.label == '高清').length, 1);
  });

  test('第 51 条：mergeHlsVariants——master 展开后菜单有 1080p，mp4 优先于同分辨率 HLS 变体', () {
    // VM 实测：1080p 标签视频 video.upltcpbcb6f 的 master 有 5 档
    // （1080p/720p/480p/360p/250p），最高 1920x1080。
    const master = '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080\n'
        'https://gcore-vod.xvideos-cdn.com/videos/hls/1080p.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1280x720\n'
        'https://gcore-vod.xvideos-cdn.com/videos/hls/720p.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=854x480\n'
        'https://gcore-vod.xvideos-cdn.com/videos/hls/480p.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=640x360\n'
        'https://gcore-vod.xvideos-cdn.com/videos/hls/360p.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=426x250\n'
        'https://gcore-vod.xvideos-cdn.com/videos/hls/250p.m3u8\n';
    final hls = StreamResolver.parseM3u8VariantList(
        master, 'https://gcore-vod.xvideos-cdn.com/videos/hls.m3u8');
    expect(hls.map((v) => v.label).toList(), ['1080p', '720p', '480p', '360p', '250p']);
    const base = [
      StreamVariant('HLS 自适应', 'https://gcore-vod.xvideos-cdn.com/videos/hls.m3u8'),
      StreamVariant('360p', 'https://gcore-vod.xvideos-cdn.com/videos/video_360p.mp4'),
      StreamVariant('240p', 'https://gcore-vod.xvideos-cdn.com/videos/video_240p.mp4'),
    ];
    final merged = StreamResolver.mergeHlsVariants(base, hls);
    // HLS 自适应最前，然后按画质从高到低；360p 只留 mp4 那条（不重复）。
    expect(merged.map((v) => v.label).toList(),
        ['HLS 自适应', '1080p', '720p', '480p', '360p', '250p', '240p']);
    expect(merged[4].url, contains('video_360p.mp4'));
  });

  // ---------- 第 54 条：详情页附加信息 ----------
  test('第 54 条：xvideos 视频页——标签 + 点赞率 + 相关视频 JSON', () {
    // VM 实测真片段：video.upltcpbcb6f/footjob_and_blowjob。
    const html = r'''
      <a href="/tags/teen" class="is-keyword">teen</a>
      <a href="/tags/blowjob" class="is-keyword">blowjob</a>
      <span class="rating-good-perc">99.0%</span>
      related=[{"u":"\/video.u4h9mbkf07c\/my_test_video","t":"My Test Video","i":"https:\/\/gcore-vod.xvideos-cdn.com\/thumb.jpg","d":"5 min","r":"99%","n":"187.2k","pn":"Darcy Dark"},{"u":"\/video.u9x1mbkf07d\/second_one","t":"Second One","i":"https:\/\/gcore-vod.xvideos-cdn.com\/thumb2.jpg","d":"12 min","r":"97%","n":"45.6k","pn":""}];
    ''';
    final ex = StreamResolver.parseXvideosDetailExtras(html);
    expect(ex.tags, ['teen', 'blowjob']);
    expect(ex.likeRate, 99);
    expect(ex.related.length, 2);
    expect(ex.related[0].title, 'My Test Video');
    expect(ex.related[0].durationSec, 300);
    expect(ex.related[0].views, 187200);
    expect(ex.related[0].likeRate, 99);
    expect(ex.related[0].author, 'Darcy Dark');
    expect(ex.related[1].durationSec, 720);
    expect(ex.related[1].views, 45600);
  });

  test('第 54 条：pornhub 标签 + 相关 API（related/topRated/mostViewed）', () {
    // VM 实测真片段：viewkey=681e308e37c7d 视频页的标签 + 相关 API 首条。
    const html = '''
      <a data-label="tag" href="/video/search?search=blonde"><span>blonde</span></a>
      <a data-label="tag" href="/video/search?search=big+tits"><span>big tits</span></a>
    ''';
    expect(StreamResolver.parsePornhubTags(html), ['blonde', 'big tits']);
    expect(
      StreamResolver.parsePornhubRelatedApiUrl(
          '... "player_related_datas?id=468422645" ...'),
      'https://www.pornhub.com/api/v1/video/player_related_datas?id=468422645',
    );
    const api = '''
      {"related": [["https://ci.phncdn.com/videos/202512/17/468422645/original/(m=eafTGgaaaa)(mh=kE7W7fF4l4xX)/thumb.jpg","Related One","27:21",91,"https://www.pornhub.com/view_video.php?viewkey=abc123",392006,[],"Channel A","https://www.pornhub.com/channels/channel-a",[],[]]],
      "topRated": [["https://ci.phncdn.com/t2.jpg","Top One","10:00",95,"https://www.pornhub.com/view_video.php?viewkey=def456",1000,[],"","",[],[]]],
      "mostViewed": []}''';
    final rel = StreamResolver.parsePornhubRelatedApi(api);
    expect(rel.length, 2);
    expect(rel[0].title, 'Related One');
    expect(rel[0].durationSec, 1641);
    expect(rel[0].views, 392006);
    expect(rel[0].likeRate, 91);
    expect(rel[0].author, 'Channel A');
    expect(rel[1].title, 'Top One');
  });

  test('第 54 条：pornhub 页内 relatedVideos JSON 备选（没封面没评分时也收）', () {
    const html = '''
      relatedVideos = [{"fields":{"id":468422645,"vkey":"681e308e37c7d","title":"Fallback One","duration":1641,"media_path":""}}];
    ''';
    final rel = StreamResolver.parsePornhubRelatedVideosJson(html);
    expect(rel.length, 1);
    expect(rel[0].title, 'Fallback One');
    expect(rel[0].durationSec, 1641);
    expect(rel[0].likeRate, 0); // 没给就是未知，不编。
  });

  test('第 54 条：eporner 相关视频卡片（#relateddiv 的 .mb 卡片）', () {
    // VM 实测真片段：video-3GjtIDYbZjD 视频页 relateddiv 首张卡片原文。
    const html = '''
      <div id="relateddiv"><div class="mb hdy" data-id="12365059" id="vf123650596883"><div class="mbimg"><div class="mbcontent"><a href="/video-rkWojtLwqWM/joymii-horny-redhead-loves-some-bdsm-fucking/"><img class="lazyimg" data-src="https://static-ca-cdn.eporner.com/thumbs/static4/1/12/123/12365059/7_240.jpg" alt="JOYMII - Horny Redhead Loves Some BDSM Fucking" /></a></div></div><div class="mbunder"><p class="mbtit"><a href="/video-rkWojtLwqWM/joymii-horny-redhead-loves-some-bdsm-fucking/">JOYMII - Horny Redhead Loves Some BDSM Fucking</a></p><p class="mbstats"><span class="mbtim" title="Duration">12:36</span><span class="mbrate" title="Rating">91%</span><span class="mbvie" title="Views">19,727</span><span class="mb-uploader ischannel"><a href="/channel/joymii/" title="Uploader">JOYMII</a></span></p></div></div></div>
    ''';
    final rel = StreamResolver.parseEpornerRelated(html);
    expect(rel.length, 1);
    expect(rel[0].title, 'JOYMII - Horny Redhead Loves Some BDSM Fucking');
    expect(rel[0].durationSec, 756);
    expect(rel[0].views, 19727);
    expect(rel[0].likeRate, 91);
    expect(rel[0].author, 'JOYMII');
  });

  test('第 54 条：r34 视频页——标签 + 相关视频卡片', () {
    // VM 实测真片段：video/yukari-maid-movie-jy/ 的标签区 + related-videos 首张卡片。
    const html = '''
      <div class=label>Tags</div><div class=wrap><a class=tag_item href=/tag/bedroom/> bedroom </a><a class=tag_item href=/tag/maid/> maid </a></div>
      <div class="container related-videos"><h2 class=section-title>Related Videos</h2><div class=post-list><div class="post-item card"><a href=/video/yukari-cooking-9a/> <div class=image-container><img alt="Yukari Cooking thumbnail"class=card-img-top data-thumbnails=/media/videos/91065/thumbnails/thumb-53ac0d6cbaad473fa402ca78bfc77fe9.webp,/media/videos/91065/thumbs/thumb_1.webp><span class=duration-badge>1:55</span></div> <div class=card-body><h3 class=card-title>Yukari Cooking</h3><div class=post-info><div class=likes-percentage><img alt="Thumbs Up Icon"class=icon src=/static/icons/thumbs-up-solid.svg> 100% (5)</div><div class=views-count><img alt="Eye Icon"class=icon src=/static/icons/eye-solid.svg> 969</div></div></div> </a></div></div></div>
    ''';
    final ex = StreamResolver.parseR34DetailExtras(html);
    expect(ex.tags, ['bedroom', 'maid']);
    expect(ex.related.length, 1);
    expect(ex.related[0].title, 'Yukari Cooking');
    expect(ex.related[0].durationSec, 115);
    expect(ex.related[0].views, 969);
    expect(ex.related[0].likeRate, 100);
  });

  test('第 54 条：时长/观看数文本解析（"5 min"、"1 h 5 min"、"187.2k"、"19,727"）', () {
    expect(StreamResolver.parseDurationText('5 min'), 300);
    expect(StreamResolver.parseDurationText('1 h 5 min'), 3900);
    expect(StreamResolver.parseDurationText('12:36'), 756);
    expect(StreamResolver.parseDurationText('1:55'), 115);
    expect(StreamResolver.parseDurationText(''), 0);
    expect(StreamResolver.parseCountText('187.2k'), 187200);
    expect(StreamResolver.parseCountText('469K'), 469000);
    expect(StreamResolver.parseCountText('19,727'), 19727);
    expect(StreamResolver.parseCountText('392006'), 392006);
    expect(StreamResolver.parseCountText('1.2M'), 1200000);
    expect(StreamResolver.parseCountText(''), 0);
  });

  test('第 54 条：parseDetailExtras 分发——未知源返回空 extras，不编数据', () {
    final ex = StreamResolver.parseDetailExtras('<html></html>', 'niacg');
    expect(ex.tags, isEmpty);
    expect(ex.likeRate, 0);
    expect(ex.authorVideoCount, 0);
    expect(ex.related, isEmpty);
  });
}
