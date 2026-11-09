import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/data/sources.dart';

void main() {
  test('Eporner JSON 解析：有标题就收，没封面也不丢', () {
    final items = EpornerSource.parseVideos([
      {'id': 'abc', 'title': 'Test Video', 'length_sec': 125, 'url': 'https://www.eporner.com/video-abc/', 'default_thumb': {'src': 'https://example.com/t.jpg'}, 'views': 1234, 'keywords': 'footjob, asian', 'added': '2026-11-01 10:00:00'},
      {'id': 'def', 'title': 'No Thumb Video', 'length_sec': 60, 'url': 'https://www.eporner.com/video-def/'},
    ]);
    expect(items.length, 2);
    expect(items[0].durationSec, 125);
    expect(items[1].poster, '');
    expect(items[1].pageUrl, 'https://www.eporner.com/video-def/');
    expect(items[0].views, 1234);
    expect(items[0].keywords, contains('footjob'));
    expect(items[0].publishedAtMs, greaterThan(0));
    expect(items[1].views, 0);
    expect(items[1].publishedAtMs, 0);
  });

  test('Rule34Video 搜索页解析：未加引号的 href 也能抓到，时长进 durationSec', () {
    const html = '''
<a href=/video/test-slug-1><img alt="First Video" data-thumbnails="https://cdn.example.com/a.webp,https://cdn.example.com/b.webp"><span>10:23</span></a>
<a href="/video/test-slug-2"><img src="https://cdn.example.com/c.jpg" alt="Second Video"></a>
''';
    final items = Rule34VideosSource.parseSearchHtml(html);
    expect(items.length, 2);
    expect(items[0].title, 'First Video');
    expect(items[0].pageUrl, 'https://rule34-videos.com/video/test-slug-1');
    expect(items[0].poster, 'https://cdn.example.com/a.webp');
    expect(items[0].durationSec, 623);
    expect(items[1].durationSec, 0);
  });

  test('Niacg 搜索页解析：抓 showinfo 链接与标题', () {
    const html = '''
<a href="/showinfo-21-12345-0.html" title="测试标题一">x</a>
<a href="/showinfo-21-12345-0.html" title="测试标题一">重复</a>
<a href="/showinfo-21-67890-0.html" title="测试标题二">y</a>
''';
    final items = NiacgSource.parseSearchHtml(html);
    expect(items.length, 2); // 重复去重
    expect(items[0].pageUrl, 'https://www.niacg.com/showinfo-21-12345-0.html');
  });

  test('第 45 条：Niacg 解析容错——title 在 href 前面、只有 img alt 也收', () {
    const html = '''
<a title="标题在前" href="/showinfo-21-11111-0.html"><img src="https://x.com/a.jpg"></a>
<a href="/showinfo-21-22222-0.html"><img src="https://x.com/b.jpg" alt="只有 alt 的标题"></a>
<a href="/showinfo-21-33333-0.html"></a>
''';
    final items = NiacgSource.parseSearchHtml(html);
    expect(items.map((v) => v.title).toList(), ['标题在前', '只有 alt 的标题']);
  });

  test('Lianzu11 搜索页解析：排除分页/分类链接', () {
    const html = '''
<a href="https://lianzu11.com/post-1"><img src="https://lianzu11.com/t.jpg">恋足视频一</a>
<a href="https://lianzu11.com/page/2/">下一页</a>
<a href="https://lianzu11.com/category/xx/">分类</a>
''';
    final items = Lianzu11Source.parseSearchHtml(html);
    expect(items.length, 1);
    expect(items[0].title, '恋足视频一');
  });

  test('第 45 条：Lianzu11 解析容错——首页链接本身不成视频', () {
    const html = '''
<a href="https://lianzu11.com/">首页</a>
<a href="https://lianzu11.com/post-9"><img src="https://lianzu11.com/t9.jpg">恋足视频九</a>
''';
    final items = Lianzu11Source.parseSearchHtml(html);
    expect(items.length, 1);
    expect(items[0].title, '恋足视频九');
  });

  test('10 个在线源，没有本地目录源', () {
    final ids = allSources().map((s) => s.id).toList();
    expect(ids, ['eporner', 'rule34videos', 'niacg', 'lianzu11', 'hanime1', 'hanimeone', 'xvideos', 'xhamster', 'pornhub', 'spankbang']);
    expect(ids, isNot(contains('catalog')));
  });

  test('xvideos 解析：真封面在 data-src 里，src 只是 blank.gif；导航链接不混进来', () {
    const html = '''
<div class="thumb"><a href="/videos-i-like">Liked videos</a></div>
<div class="thumb-block"><div class="thumb"><a href="/video.opltcuib319/chill_cherry_pov_footjob"><img src="https://assets-cdn77.xvideos-cdn.com/img/lightbox/lightbox-blank.gif" data-src="https://thumb-cdn77.xvideos-cdn.com/abc/5/xv_14_t.jpg"></a><span class="duration">12:34</span></div></div>
''';
    final items = HtmlSearchSource.parseHtml(html, 'https://www.xvideos.com', 'xvideos', r'\/video\.[^"]+');
    expect(items.length, 1); // /videos-i-like 导航链接被 pattern 挡掉
    expect(items[0].title, 'chill cherry pov footjob'); // slug 当标题
    expect(items[0].poster, 'https://thumb-cdn77.xvideos-cdn.com/abc/5/xv_14_t.jpg'); // data-src 的真图，不是 blank.gif
    expect(items[0].durationSec, 754); // 锚点外面的兄弟节点里的时长也抓到
  });

  test('pornhub 解析：标题取 <a> 的 title 属性（解实体），不是锚点里的时长', () {
    const html = '''
<a href="/view_video.php?viewkey=abc123" title="Public Agent - Thai beauty says &quot;It&#039;s so hard&quot;" class="linkVideoThumb"><img src="https://pix-cdn77.phncdn.com/x.jpg"><var class="duration">17:12</var></a>
''';
    final items = HtmlSearchSource.parseHtml(html, 'https://www.pornhub.com', 'pornhub', r'\/view_video\.php\?viewkey=[^"]+');
    expect(items.length, 1);
    expect(items[0].title, 'Public Agent - Thai beauty says "It\'s so hard"');
    expect(items[0].durationSec, 1032);
    expect(items[0].poster, 'https://pix-cdn77.phncdn.com/x.jpg');
  });

  test('xhamster 锚点解析：*** 占位标题和只有时长的不要，宁可少几条', () {
    const html = '''
<a href="https://xhamster.com/videos/aaa111" aria-label="Surprise Guest"><img src="https://ic-vt-nss.xhcdn.com/a/xyz/s(w:526,h:298),webp/023/362/709/sfw/hq.36.webp" alt="Surprise Guest"></a>
<a href="https://xhamster.com/videos/bbb222"><span>***************</span></a>
<a href="https://xhamster.com/videos/ccc333"><span>20:08</span></a>
''';
    final items = HtmlSearchSource.parseHtml(html, 'https://xhamster.com', 'xhamster', r'https:\/\/xhamster\.com\/videos\/[^"]+');
    expect(items.length, 1);
    expect(items[0].title, 'Surprise Guest');
  });

  test('xhamster JSON 解析：videoThumbProps 里有真实标题、时长、封面、播放量、作者', () {
    const html = '''
{"searchResult":{"videoThumbProps":[{"id":23362709,"duration":1208,"created":1685512081,"title":"Surprise Guest","thumbId":36,"pageURL":"https://xhamster.com/videos/xhu72iL","thumbURL":"https://ic-vt-nss.xhcdn.com/a/abc/023/362/709/sfw/hq.36.webp","isUHD":true,"views":1037347,"landing":{"name":"Love Her Feet"}}],"other":{}}}
''';
    final items = XhamsterSource.parseJson(html);
    expect(items.length, 1);
    expect(items[0].title, 'Surprise Guest');
    expect(items[0].durationSec, 1208);
    expect(items[0].poster, contains('hq.36.webp'));
    expect(items[0].views, 1037347);
    expect(items[0].author, 'Love Her Feet');
    expect(items[0].resolution, '2160p');
    expect(items[0].publishedAtMs, 1685512081 * 1000);
    expect(XhamsterSource.parseJson('<html>no json here</html>'), isEmpty);
  });

  test('时长解析："30 sec" 和 "5 min" 都能算', () {
    const html = '''
<a href="/video.abc123/test_video"><img data-src="https://example.com/t.jpg"></a><span class="duration">30 sec</span>
<a href="/video.def456/test_video2"><img data-src="https://example.com/t2.jpg"></a><span class="duration">5 min</span>
''';
    final items = HtmlSearchSource.parseHtml(html, 'https://www.xvideos.com', 'xvideos', r'\/video\.[^"]+');
    expect(items.length, 2);
    expect(items[0].durationSec, 30);
    expect(items[1].durationSec, 300);
  });

  test('标题乱码修复：Eporner API 里的 \\u00e2\\u0080\\u0099 其实是 ’，进屏前修回来', () {
    // 2026-11-09 用户截图：标题显示成 "(RM) Iâ€™m Getting In Shape For You, My Belovedâ€¦"。
    // API 的 JSON 里直接写着 \u00e2\u0080\u0099（UTF-8 字节被当 latin1 转义进来的），
    // 乱码长在数据里，光改解码不够，标题进屏前必须修。
    final items = EpornerSource.parseVideos([
      {
        'id': 'tYHgyWTFB3A',
        'title': '(RM) Iâ\u0080\u0099m Getting In Shape For You, My Belovedâ\u0080¦ But My Trainerâ\u0080\u0099s Intense Back Piston Is So Amazing',
        'length_sec': 9412,
        'url': 'https://www.eporner.com/video-tYHgyWTFB3A/',
      },
    ]);
    expect(items.length, 1);
    expect(items[0].title,
        "(RM) I’m Getting In Shape For You, My Beloved… But My Trainer’s Intense Back Piston Is So Amazing");
    // 乱码特征不许再出现。
    expect(items[0].title.contains('â'), isFalse);
  });

  test('标题清洗：r34 相关视频 alt 里末尾的 " thumbnail" 要去掉', () {
    const html = '''
<a href=/video/chun-li-gym-doggy-da><img alt="Chun-Li Gym Doggy! thumbnail"><span>3:56</span></a>
<a href=/video/other><img alt="Plain Title"><span>1:02</span></a>
''';
    final items = Rule34VideosSource.parseSearchHtml(html);
    expect(items.length, 2);
    expect(items[0].title, 'Chun-Li Gym Doggy!');
    expect(items[1].title, 'Plain Title');
  });

  test('标题清洗：标题里的画质词是标题本身，不动（真机截图里就是 "4k ultra hd"）', () {
    final items = EpornerSource.parseVideos([
      {
        'id': 'x1',
        'title': 'milf footjob and long cumshot tasty blowjob 4k ultra hd alena lamlam',
        'length_sec': 860,
        'url': 'https://www.eporner.com/video-x1/',
      },
    ]);
    expect(items[0].title,
        'milf footjob and long cumshot tasty blowjob 4k ultra hd alena lamlam');
  });

  test('Hanime1 解析：按 Kazumi 规则结构（href 带 watch 的链接 + div.title）', () {
    // 注意：这是按 Kazumi Hanime1.json v0.3 结构写的假 HTML；
    // 真页没见过（VM 下 hanime1.me 被 Cloudflare 403），手机上若 HTTP 通了按此解析。
    const html = '''
<a href="/watch?v=12345"><div class="title">Test Hentai Title</div><img src="https://cdn.example.com/poster.jpg"><span>24:36</span></a>
<a href="/watch?v=67890"><div class="home-rows-videos-title">Second Title</div></a>
<a href="/videos/999"><div class="title">Videos Form Title</div></a>
''';
    final items = HanimeSource.parseSearchHtml(html, 'hanime1.me', 'hanime1');
    expect(items.length, 3);
    expect(items[0].title, 'Test Hentai Title');
    expect(items[0].pageUrl, 'https://hanime1.me/watch?v=12345');
    expect(items[0].poster, 'https://cdn.example.com/poster.jpg');
    expect(items[0].durationSec, 1476);
    expect(items[0].source, 'hanime1');
    expect(items[1].title, 'Second Title');
    // 第 45 条：/videos/ 形式的视频链接也收（旧解析只认 watch 会漏）。
    expect(items[2].title, 'Videos Form Title');
    expect(items[2].pageUrl, 'https://hanime1.me/videos/999');
  });

  test('第 45 条：Hanime 解析容错——/videos/hentai/ 形式的视频链接也收', () {
    const html = '''
<a href="/videos/hentai/12345"><div class="title">Videos Hentai Title</div></a>
<a href="/watch?v=67890"><div class="title">Watch Form Title</div></a>
''';
    final items = HanimeSource.parseSearchHtml(html, 'hanime1.me', 'hanime1');
    expect(items.length, 2);
    expect(items[0].title, 'Videos Hentai Title');
    expect(items[1].title, 'Watch Form Title');
  });

  test('Hanime 源：webViewOnly，搜索地址带 genre=裏番', () {
    final h1 = HanimeSource('hanime1.me');
    final hone = HanimeSource('hanimeone.me');
    expect(h1.id, 'hanime1');
    expect(hone.id, 'hanimeone');
    expect(h1.webViewOnly, isTrue);
    expect(hone.webViewOnly, isTrue);
    expect(h1.webSearchUrl('foot'),
        'https://hanime1.me/search?query=foot&page=1&genre=%E8%A3%8F%E7%95%AA');
    expect(hone.webHomeUrl, 'https://hanimeone.me/');
    // 10 个源里有它俩。
    final ids = allSources().map((s) => s.id).toList();
    expect(ids.length, 10);
    expect(ids, containsAll(['hanime1', 'hanimeone']));
    // webViewOnly 的是 niacg、lianzu11、hanime1、hanimeone 四个
    // （niacg/lianzu11 2026-11-09 也标了 webViewOnly：WAF/Cloudflare 拦 Dart 请求）。
    expect(allSources().where((s) => s.webViewOnly).map((s) => s.id),
        ['niacg', 'lianzu11', 'hanime1', 'hanimeone']);
  });

  test('Hanime 镜像：两个域名是同一站（第 20 条），一个打不开切另一个', () {
    // 能进的那个优先：hanimeone.me 可以，hanime1.me 常被验证拦住。
    expect(HanimeSource.preferredHost, 'hanimeone.me');
    expect(HanimeSource.isHanimeHost('hanime1.me'), isTrue);
    expect(HanimeSource.isHanimeHost('hanimeone.me'), isTrue);
    expect(HanimeSource.isHanimeHost('www.niacg.com'), isFalse);
    // 换镜像：路径/query 不变，只换域名。
    expect(
      HanimeSource.mirrorUrl('https://hanime1.me/search?query=foot&page=1&genre=%E8%A3%8F%E7%95%AA'),
      'https://hanimeone.me/search?query=foot&page=1&genre=%E8%A3%8F%E7%95%AA',
    );
    expect(
      HanimeSource.mirrorUrl('https://hanimeone.me/watch?v=123'),
      'https://hanime1.me/watch?v=123',
    );
    // 不是 hanime 地址，原样返回。
    expect(HanimeSource.mirrorUrl('https://www.niacg.com/'), 'https://www.niacg.com/');
  });

  test('第 36 条：videoKey——同一视频换参数/换 slug 还是同一条', () {
    // pornhub：viewkey 是唯一标识，参数不同也一样。
    expect(
      HtmlSearchSource.videoKey(
          'https://www.pornhub.com/view_video.php?viewkey=6acf472d64e8e'),
      HtmlSearchSource.videoKey(
          'https://www.pornhub.com/view_video.php?viewkey=6acf472d64e8e&foo=bar'),
    );
    expect(
      HtmlSearchSource.videoKey(
          'https://www.pornhub.com/view_video.php?viewkey=6acf472d64e8e'),
      isNot(HtmlSearchSource.videoKey(
          'https://www.pornhub.com/view_video.php?viewkey=aaaaaaaaaaaa')),
    );
    // xvideos：/video.<id> 是标识，slug 换了也一样。
    expect(
      HtmlSearchSource.videoKey('https://www.xvideos.com/video.omicikt9ece/slug-a'),
      HtmlSearchSource.videoKey('https://www.xvideos.com/video.omicikt9ece/slug-b'),
    );
    // xhamster：/videos/<id> 是标识。
    expect(
      HtmlSearchSource.videoKey('https://xhamster.com/videos/xhu72iL'),
      HtmlSearchSource.videoKey('https://xhamster.com/videos/xhu72iL?foo=1'),
    );
  });

  test('第 36 条：parseHtml——pornhub 同一 viewkey 出现两次只收一条', () {
    const html = '''
<a href="https://www.pornhub.com/view_video.php?viewkey=6acf472d64e8e" title="Foot Massage Fun">10:00</a>
<a href="https://www.pornhub.com/view_video.php?viewkey=6acf472d64e8e&extra=1" title="Foot Massage Fun">10:00</a>
<a href="https://www.pornhub.com/view_video.php?viewkey=aaaaaaaaaaaa" title="Other Video">05:00</a>
''';
    final items = HtmlSearchSource.parseHtml(
      html,
      'https://www.pornhub.com',
      'pornhub',
      r'https://www\.pornhub\.com/view_video\.php\?viewkey=[A-Za-z0-9]+[^"]*',
    );
    expect(items.length, 2);
    expect(items.map((v) => v.id).toSet().length, 2);
    expect(items.first.id, 'pornhub-viewkey:6acf472d64e8e');
  });

  test('第 37 条：pornhub 时长只认 <var class="duration">，不认 img 地址里的 320:180', () {
    const html = """
<a href="/view_video.php?viewkey=6acf472d64e8e" title="Gym-Clothed Wife Fucks Husband" class="fade img">
<img src="https://pix-cdn77.phncdn.com/c6541/videos/202610/14/65758345/original/01a.jpg/plain/rs:fit:320:180?hash=abc" alt="Gym-Clothed Wife Fucks Husband">
<div class="marker-overlays"><var class="duration">15:41</var></div>
</a>
""";
    final items = HtmlSearchSource.parseHtml(
      html,
      'https://www.pornhub.com',
      'pornhub',
      r'/view_video\.php\?viewkey=[A-Za-z0-9]+',
    );
    expect(items.length, 1);
    // 15:41 = 941 秒；旧代码先命中 img 地址里的 320:18，错成 19218 秒。
    expect(items[0].durationSec, 941);
  });

  test('第 37 条：没有时长元素时，img 地址里的 320:180 不能当成时长', () {
    const html = """
<a href="/view_video.php?viewkey=6acf472d64e8e" title="Test Video"><img src="https://pix-cdn77.phncdn.com/x.jpg/plain/rs:fit:320:180?hash=abc" alt="Test Video"></a>
""";
    final items = HtmlSearchSource.parseHtml(
      html,
      'https://www.pornhub.com',
      'pornhub',
      r'/view_video\.php\?viewkey=[A-Za-z0-9]+',
    );
    expect(items.length, 1);
    expect(items[0].durationSec, 0);
  });

  test('第 42 条：pornhub 搜索时抠上传者（usernameWrap 里的 thumb_username）', () {
    const html = """
<a href="/view_video.php?viewkey=6acf472d64e8e" title="Test Video" class="img"><img src="https://example.com/t.jpg" alt="Test Video"><var class="duration">10:05</var></a>
<div class="thumbnail-info-wrapper"><div class="thumbnail-info"><span class="title"><a href="/view_video.php?viewkey=6acf472d64e8e">Test Video</a></span><div class="usernameWrap"><a href="/model/pink-pussy-creampie" title="Pink Pussy Creampie" data-label="thumb_username">Pink Pussy Creampie</a></div></div></div>
""";
    final items = HtmlSearchSource.parseHtml(
      html,
      'https://www.pornhub.com',
      'pornhub',
      r'/view_video\.php\?viewkey=[A-Za-z0-9]+',
    );
    expect(items.length, 1);
    expect(items[0].author, 'Pink Pussy Creampie');
    expect(items[0].durationSec, 605);
  });

  test('第 42 条：xvideos 搜索时抠上传者（metadata 里的 <span class="name">）', () {
    const html = """
<a href="/video.upltcpbcb6f/footjob_and_blowjob"><img src="https://example.com/blank.gif" data-src="https://example.com/r.jpg"><span class="top-right-tags"><span class="video-hd-mark">1080p</span></span></a>
<div class="thumb-under"><p class="title"><a href="/video.upltcpbcb6f/footjob_and_blowjob" title="Footjob and blowjob">Footjob and blowjob <span class="duration">9 min</span></a></p><p class="metadata"><span class="bg"><span class="duration">9 min</span><span><a href="/darcy-dark-1"><span class="name">DarcyDark</span></a></span></span></p></div>
""";
    final items = HtmlSearchSource.parseHtml(
      html,
      'https://www.xvideos.com',
      'xvideos',
      r'/video\.[^"]+',
    );
    expect(items.length, 1);
    expect(items[0].author, 'DarcyDark');
    expect(items[0].durationSec, 540); // 9 min
    expect(items[0].resolution, '1080p');
  });

  test('第 42 条：niacg 标题里的 [作者] 前缀就是发布者，[中文字幕] 不是', () {
    const html = """
<a href="/showinfo-21-10702-0.html" title="[AlphaG] Capture Yixuan + Naked [中文字幕]">x</a>
<a href="/showinfo-21-10703-0.html" title="[中文字幕] 普通标题">y</a>
""";
    final items = NiacgSource.parseSearchHtml(html);
    expect(items.length, 2);
    expect(items[0].author, 'AlphaG');
    expect(items[1].author, '');
  });

  test('第 37 条：lianzu11 时长只认可见文本，不认属性里的假时长', () {
    const html = """
<a href="https://lianzu11.com/post-1"><img src="https://lianzu11.com/t.jpg" data-time="99:99">恋足视频一 12:34</a>
""";
    final items = Lianzu11Source.parseSearchHtml(html);
    expect(items.length, 1);
    expect(items[0].durationSec, 754);
  });

  test('第 37 条：hanime 时长只认可见文本', () {
    const html = """
<a href="https://hanimeone.me/watch?v=abc"><img src="https://example.com/t.jpg"><div class="title">Test Title</div><span>25:10</span></a>
""";
    final items = HanimeSource.parseSearchHtml(html, 'hanimeone.me', 'hanimeone');
    expect(items.length, 1);
    expect(items[0].durationSec, 1510);
  });

  test('第 41 条：WebView 搜索分页地址 + 解析入口', () {
    expect(NiacgSource().webSearchUrlPage('foot', 2), contains('page=2'));
    expect(Lianzu11Source().webSearchUrlPage('foot', 2),
        'https://lianzu11.com/page/2/?s=foot');
    expect(HanimeSource('hanimeone.me').webSearchUrlPage('foot', 2),
        contains('page=2'));
    expect(
        HanimeSource('hanimeone.me').parseWebSearchHtml(
            '<a href="https://hanimeone.me/watch?v=x"><div class="title">T</div></a>').length,
        1);
    expect(
        NiacgSource().parseWebSearchHtml(
            '<a href="/showinfo-21-1-0.html" title="[A] T">x</a>').length,
        1);
  });
}
