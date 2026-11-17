// 全局搜索单测：地址解析、引擎切换/回退、搜索历史。
import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/search/global_search.dart';
import 'package:taohuayuan/search/search_history.dart';

class _FakeStorage implements SearchHistoryStorage {
  List<String> raw;
  int saveCalls = 0;

  _FakeStorage([this.raw = const []]);

  @override
  List<String> loadRaw() => List<String>.from(raw);

  @override
  Future<void> saveRaw(List<String> next) async {
    raw = List<String>.from(next);
    saveCalls++;
  }
}

void main() {
  group('GlobalSearch.resolve', () {
    test('http 地址直接打开', () {
      final r = GlobalSearch.resolve('http://example.com/a?x=1');
      expect(r, isNotNull);
      expect(r!.url, 'http://example.com/a?x=1');
      expect(r.isSearch, isFalse);
      expect(r.engine, isNull);
      expect(r.query, isNull);
    });

    test('https 地址直接打开', () {
      final r = GlobalSearch.resolve('https://xhamster.com/videos');
      expect(r!.url, 'https://xhamster.com/videos');
      expect(r.isSearch, isFalse);
    });

    test('含空格一律当搜索词', () {
      final r = GlobalSearch.resolve('sparkle dance');
      expect(r!.isSearch, isTrue);
      expect(r.url, 'https://www.bing.com/search?q=sparkle+dance');
      expect(r.engine, SearchEngine.bing);
      expect(r.query, 'sparkle dance');
    });

    test('单个词默认走 Bing 并编码', () {
      final r = GlobalSearch.resolve('a&b');
      expect(r!.url, 'https://www.bing.com/search?q=a%26b');
      expect(r.query, 'a&b');
    });

    test('空输入返回 null', () {
      expect(GlobalSearch.resolve(''), isNull);
      expect(GlobalSearch.resolve('   '), isNull);
    });

    test('指定引擎走该引擎', () {
      final r = GlobalSearch.resolve(
        'hello world',
        engine: SearchEngine.google,
      );
      expect(r!.url, 'https://www.google.com/search?q=hello+world');
      expect(r.engine, SearchEngine.google);
    });

    test('duckduckgo 模板', () {
      final r = GlobalSearch.resolve(
        'test',
        engine: SearchEngine.duckduckgo,
      );
      expect(r!.url, 'https://duckduckgo.com/?q=test');
    });

    test('裸域名是已知源域名时补 https 打开', () {
      final r = GlobalSearch.resolve(
        'niacg.com',
        isKnownHost: (h) => h == 'niacg.com',
      );
      expect(r!.url, 'https://niacg.com/');
      expect(r.isSearch, isFalse);
    });

    test('裸域名不是已知源域名时当搜索词', () {
      final r = GlobalSearch.resolve(
        'niacg.com',
        isKnownHost: (_) => false,
      );
      expect(r!.isSearch, isTrue);
      expect(r.url, contains('niacg.com'));
    });

    test('不给 isKnownHost 时裸域名当搜索词', () {
      final r = GlobalSearch.resolve('niacg.com');
      expect(r!.isSearch, isTrue);
    });

    test('非 http(s) scheme 当搜索词', () {
      final r = GlobalSearch.resolve('ftp://example.com/x');
      expect(r!.isSearch, isTrue);
    });

    test('非法地址当搜索词，不抛错', () {
      final r = GlobalSearch.resolve('://bad');
      expect(r, isNotNull);
      expect(r!.isSearch, isTrue);
    });

    test('前后空格先去掉再判定', () {
      final r = GlobalSearch.resolve('  https://example.com/  ');
      expect(r!.url, 'https://example.com/');
      expect(r.isSearch, isFalse);
    });
  });

  group('GlobalSearch.nextEngine', () {
    test('按默认顺序递进，末尾返回 null', () {
      const order = GlobalSearch.defaultEngineOrder;
      expect(
        GlobalSearch.nextEngine(SearchEngine.bing, order),
        SearchEngine.google,
      );
      expect(
        GlobalSearch.nextEngine(SearchEngine.google, order),
        SearchEngine.duckduckgo,
      );
      expect(
        GlobalSearch.nextEngine(SearchEngine.duckduckgo, order),
        isNull,
      );
    });

    test('不在顺序里返回 null', () {
      expect(
        GlobalSearch.nextEngine(SearchEngine.bing, [SearchEngine.google]),
        isNull,
      );
    });
  });

  group('SearchEngineFallback', () {
    test('先 Bing，再 Google，再 DuckDuckGo，耗尽返回 null', () {
      final fb = SearchEngineFallback('hello world');
      expect(fb.firstUrl(), 'https://www.bing.com/search?q=hello+world');
      expect(fb.exhausted, isFalse);
      expect(fb.advance(), 'https://www.google.com/search?q=hello+world');
      expect(fb.triedCount, 1);
      expect(fb.advance(), 'https://duckduckgo.com/?q=hello+world');
      expect(fb.triedCount, 2);
      expect(fb.exhausted, isTrue);
      expect(fb.advance(), isNull);
    });

    test('空顺序抛错', () {
      final fb = SearchEngineFallback('x', order: []);
      expect(() => fb.firstUrl(), throwsStateError);
      expect(() => fb.advance(), throwsStateError);
    });

    test('自定义顺序只在该顺序内换', () {
      final fb = SearchEngineFallback(
        'x',
        order: [SearchEngine.duckduckgo, SearchEngine.bing],
      );
      expect(fb.firstUrl(), 'https://duckduckgo.com/?q=x');
      expect(fb.advance(), 'https://www.bing.com/search?q=x');
      expect(fb.advance(), isNull);
    });
  });

  group('SearchHistory', () {
    test('新增在前，同 url 去重移到最前', () async {
      final storage = _FakeStorage();
      final history = SearchHistory.withStorage(storage, []);
      await history.add('a', 'https://a.example/');
      await history.add('b', 'https://b.example/');
      await history.add('a2', 'https://a.example/');
      expect(history.entries.length, 2);
      expect(history.entries.first.url, 'https://a.example/');
      expect(history.entries.first.label, 'a2');
      expect(history.firstUrl, 'https://a.example/');
      expect(storage.saveCalls, 3);
    });

    test('空 label 或空 url 不记', () async {
      final storage = _FakeStorage();
      final history = SearchHistory.withStorage(storage, []);
      await history.add('', 'https://a.example/');
      await history.add('a', '');
      await history.add('  ', '  ');
      expect(history.entries, isEmpty);
      expect(storage.saveCalls, 0);
    });

    test('上限 200 条，超了截尾', () async {
      final storage = _FakeStorage();
      final history = SearchHistory.withStorage(storage, []);
      for (var i = 0; i < 201; i++) {
        await history.add('t$i', 'https://x.example/$i');
      }
      expect(history.entries.length, SearchHistory.maxEntries);
      expect(history.entries.first.url, 'https://x.example/200');
      expect(
        history.entries.any((e) => e.url == 'https://x.example/0'),
        isFalse,
      );
    });

    test('按 url 删一条，不存在不写存储', () async {
      final storage = _FakeStorage();
      final history = SearchHistory.withStorage(storage, []);
      await history.add('a', 'https://a.example/');
      await history.add('b', 'https://b.example/');
      final savesBefore = storage.saveCalls;
      await history.remove('https://nope.example/');
      expect(history.entries.length, 2);
      expect(storage.saveCalls, savesBefore);
      await history.remove('https://a.example/');
      expect(history.entries.length, 1);
      expect(history.entries.first.url, 'https://b.example/');
    });

    test('清空', () async {
      final storage = _FakeStorage();
      final history = SearchHistory.withStorage(storage, []);
      await history.add('a', 'https://a.example/');
      await history.clear();
      expect(history.entries, isEmpty);
      expect(history.firstUrl, isNull);
      expect(storage.raw, isEmpty);
    });

    test('从存储恢复：坏条目跳过，好条目保留', () async {
      final storage = _FakeStorage([
        '{"label":"a","url":"https://a.example/"}',
        'not-json{{{',
        '{"label":"no-url"}',
        '{"label":"b","url":"https://b.example/"}',
      ]);
      final history = SearchHistory.withStorage(storage);
      expect(history.entries.length, 2);
      expect(history.entries.first.label, 'a');
      expect(history.entries.last.label, 'b');
    });

    test('fromJson 缺 url 抛错', () {
      expect(
        () => SearchHistoryEntry.fromJson({'label': 'x'}),
        throwsFormatException,
      );
    });
  });
}
