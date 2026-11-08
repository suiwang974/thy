import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/data/catalog.dart';
import 'package:taohuayuan/data/sources.dart';
import 'package:taohuayuan/models/video_item.dart';

void main() {
  test('目录 62 条：57 条有直链，03 批 5 条待补链', () {
    final raw = File('assets/catalog.json').readAsStringSync();
    final list = (jsonDecode(raw) as List).map((e) => VideoItem.fromCatalog(e as Map<String, dynamic>)).toList();
    expect(list.length, 62);
    expect(list.where((v) => v.playable).length, 57);
    expect(list.where((v) => v.needsRelink).length, 5);
    // 目录里没有任何“本地”字样（用户手机上没下过任何视频）。
    expect(raw.contains('本地'), isFalse);
    expect(raw.contains('localFile'), isFalse);
  });

  test('目录搜“足”能命中（关键词里有 足/足交/足控）', () {
    final raw = File('assets/catalog.json').readAsStringSync();
    final list = (jsonDecode(raw) as List).map((e) => VideoItem.fromCatalog(e as Map<String, dynamic>)).toList();
    final hits = Catalog.search(list, '足');
    expect(hits.length, greaterThan(10));
    // 搜作者名也能命中
    expect(Catalog.search(list, 'sugardust').length, greaterThan(0));
  });

  test('Eporner JSON 解析：有标题就收，没封面也不丢', () {
    final items = EpornerSource.parseVideos([
      {'id': 'abc', 'title': 'Test Video', 'length_sec': 125, 'url': 'https://www.eporner.com/video-abc/', 'default_thumb': {'src': 'https://example.com/t.jpg'}},
      {'id': 'def', 'title': 'No Thumb Video', 'length_sec': 60, 'url': 'https://www.eporner.com/video-def/'},
    ]);
    expect(items.length, 2);
    expect(items[0].durationSec, 125);
    expect(items[1].poster, '');
    expect(items[1].pageUrl, 'https://www.eporner.com/video-def/');
  });

  test('Rule34Video 搜索页解析：未加引号的 href 也能抓到', () {
    const html = '''
<a href=/video/test-slug-1><img alt="First Video" data-thumbnails="https://cdn.example.com/a.webp,https://cdn.example.com/b.webp"><span>10:23</span></a>
<a href="/video/test-slug-2"><img src="https://cdn.example.com/c.jpg" alt="Second Video"></a>
''';
    final items = Rule34VideosSource.parseSearchHtml(html);
    expect(items.length, 2);
    expect(items[0].title, 'First Video');
    expect(items[0].pageUrl, 'https://rule34-videos.com/video/test-slug-1');
    expect(items[0].poster, 'https://cdn.example.com/a.webp');
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
}
