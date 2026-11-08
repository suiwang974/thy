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

  test('8 个在线源，没有本地目录源', () {
    final ids = allSources().map((s) => s.id).toList();
    expect(ids, ['eporner', 'rule34videos', 'niacg', 'lianzu11', 'xvideos', 'xhamster', 'pornhub', 'spankbang']);
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
}
