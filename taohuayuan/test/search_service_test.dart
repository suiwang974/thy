import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/data/sources.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/search_service.dart';

class FakeSource implements Source {
  final String _id;
  final Duration delay;
  final List<VideoItem> items;
  final bool throwError;
  final bool webOnly;
  const FakeSource(this._id, {this.delay = Duration.zero, this.items = const [], this.throwError = false, this.webOnly = false});

  @override
  String get id => _id;
  @override
  String get name => _id;

  @override
  bool get webViewOnly => webOnly;

  @override
  String webSearchUrl(String query) => '';

  @override
  String get webHomeUrl => '';

  @override
  Future<SourceResult> search(String query) async {
    await Future.delayed(delay);
    if (throwError) throw Exception('boom');
    return SourceResult(sourceId: _id, sourceName: _id, items: items);
  }

  @override
  Future<SourceResult> home({int page = 1}) async => search('');

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    if (page > 1) return SourceResult(sourceId: _id, sourceName: _id);
    return search(query);
  }
}

VideoItem v(String id, {String title = '', List<String> keywords = const [], int durationSec = 0}) =>
    VideoItem(id: id, title: title, source: 'fake', keywords: keywords, durationSec: durationSec);

void main() {
  test('单源 8 秒超时跳过，不拖全场：慢源报超时，快源正常出结果', () async {
    final svc = SearchService(sources: [
      FakeSource('fast', items: [v('a', title: 'footjob')]),
      const FakeSource('slow', delay: Duration(seconds: 9)),
    ]);
    final sw = Stopwatch()..start();
    final results = await svc.searchAll('foot');
    sw.stop();
    expect(sw.elapsed.inSeconds, lessThan(9)); // 8 秒超时就返回，没等慢源跑完
    expect(results.length, 2);
    final slow = results.firstWhere((r) => r.sourceId == 'slow');
    expect(slow.error, contains('超时'));
    expect(slow.items, isEmpty);
    expect(results.firstWhere((r) => r.sourceId == 'fast').items.length, 1);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('结果流式上屏：每回一个源就调一次 onResult', () async {
    final svc = SearchService(sources: [
      FakeSource('s1', delay: const Duration(milliseconds: 50), items: [v('a')]),
      FakeSource('s2', delay: const Duration(milliseconds: 150), items: [v('b')]),
    ]);
    var calls = 0;
    var lastCount = 0;
    await svc.searchAll('x', onResult: (partial) {
      calls++;
      lastCount = partial.length;
    });
    expect(calls, 2);
    expect(lastCount, 2);
  });

  test('源多选 + 分类过滤都在 searchAll 里生效', () async {
    final svc = SearchService(sources: [
      FakeSource('s1', items: [v('a', title: 'footjob', keywords: ['footjob'])]),
      FakeSource('s2', items: [v('b', title: '3d', keywords: ['3d'])]),
    ]);
    final results = await svc.searchAll(
      'x',
      filters: const SearchFilters(sourceIds: {'s1'}, category: '足控'),
    );
    expect(results.length, 1);
    expect(results.first.sourceId, 's1');
    expect(results.first.items.length, 1);
    // 分类不命中时过滤掉
    final results2 = await svc.searchAll(
      'x',
      filters: const SearchFilters(category: '调教'),
    );
    expect(results2.expand((r) => r.items), isEmpty);
  });

  test('分页：第 1 页有结果，第 2 页按源的 searchPage 走（Fake 返回空）', () async {
    final svc = SearchService(sources: [
      FakeSource('s1', items: [v('a')]),
    ]);
    final page1 = await svc.searchPage('x', 1);
    expect(page1.length, 1);
    final page2 = await svc.searchPage('x', 2);
    expect(page2, isEmpty);
  });

  test('源开关真生效（2026-11-09 用户反馈）：关掉的源在搜索、翻页、推荐里一条都不出', () async {
    // 用户在“我的”里只开 Niacg/Lianzu11，推荐里照样出现 eporner——
    // 之前 homeFeed 根本没过开关。现在服务层强制过滤。
    final svc = SearchService(
      sources: [
        FakeSource('eporner', items: [v('e1', title: 'eporner video')]),
        FakeSource('niacg', items: [v('n1', title: 'niacg video')]),
        FakeSource('lianzu11', items: [v('l1', title: 'lianzu11 video')]),
      ],
      disabledSources: {'eporner'},
    );
    final results = await svc.searchAll('x');
    expect(results.map((r) => r.sourceId), ['niacg', 'lianzu11']);
    expect(results.expand((r) => r.items).map((i) => i.id), ['n1', 'l1']);
    final page = await svc.searchPage('x', 1);
    expect(page.map((i) => i.id), ['n1', 'l1']);
    final feed = await svc.homeFeed();
    expect(feed.map((i) => i.id), ['n1', 'l1']);
  });

  test('源开关：全部关掉就一个源都不查', () async {
    final svc = SearchService(
      sources: [FakeSource('s1', items: [v('a')])],
      disabledSources: {'s1'},
    );
    expect(svc.sources, isEmpty);
    expect(await svc.searchAll('x'), isEmpty);
    expect(await svc.homeFeed(), isEmpty);
  });

  test('搜索页“全部”切换：全不选标记下搜索、翻页、推荐都返回空', () async {
    final svc = SearchService(sources: [
      FakeSource('s1', items: [v('a', title: 'footjob')]),
      FakeSource('s2', items: [v('b', title: '3d')]),
    ]);
    const none = SearchFilters(sourceIds: {SearchFilters.noneMarker});
    expect(none.selectsNone, isTrue);
    expect(await svc.searchAll('x', filters: none), isEmpty);
    expect(await svc.searchPage('x', 1, filters: none), isEmpty);
    // 全选（空集）时两个源都查。
    const all = SearchFilters();
    expect(all.selectsNone, isFalse);
    expect((await svc.searchAll('x', filters: all)).length, 2);
  });

  test('每个源的耗时记下来：elapsedMs > 0，lastLatencies 里有记录', () async {
    final svc = SearchService(sources: [
      FakeSource('s1', delay: const Duration(milliseconds: 60), items: [v('a')]),
    ]);
    final results = await svc.searchAll('x');
    expect(results.first.elapsedMs, greaterThanOrEqualTo(50));
    expect(svc.lastLatencies['s1'], greaterThanOrEqualTo(50));
  });

  test('慢的源后台再试：第一次超时、第二次成功，通过 onRetried 补回来', () async {
    final flaky = FlakySource('flaky', items: [v('a', title: 'footjob')]);
    final svc = SearchService(sources: [flaky]);
    SourceResult? retried;
    final results = await svc.searchAll('x', onRetried: (r) => retried = r);
    // 第一次超时：首屏结果里是 error。
    expect(results.first.error, contains('超时'));
    expect(results.first.items, isEmpty);
    // 后台 2 秒后再试成功，onRetried 被调到。
    await Future.delayed(const Duration(seconds: 4));
    expect(retried, isNotNull);
    expect(retried!.items.length, 1);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('慢源第一次放宽到 15 秒：niacg 拖 9 秒也回得来', () async {
    final svc = SearchService(sources: [
      FakeSource('niacg', delay: const Duration(seconds: 9), items: [v('a', title: 'footjob')]),
    ]);
    final results = await svc.searchAll('x');
    expect(results.first.error, isNull);
    expect(results.first.items.length, 1);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('3 次都失败调 onRetryFailed，error 写明已试 3 次', () async {
    final svc = SearchService(sources: [
      const FakeSource('boom', throwError: true),
    ]);
    SourceResult? failed;
    final results = await svc.searchAll('x', onRetryFailed: (r) => failed = r);
    expect(results.first.error, isNotNull);
    // 后台重试：2 秒后第 2 次、再 8 秒后第 3 次，都失败才报 onRetryFailed。
    await Future.delayed(const Duration(seconds: 12));
    expect(failed, isNotNull);
    expect(failed!.error, contains('已试 3 次'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('webViewOnly 的源不进 HTTP 搜索/热门/翻页（第 12 条：不报误导人的“0 条”）', () async {
    final svc = SearchService(sources: [
      FakeSource('http-ok', items: [v('a', title: 'footjob')]),
      FakeSource('web-only', webOnly: true, items: [v('b', title: 'footjob')]),
    ]);
    // 构造函数就过滤掉 webViewOnly 的源。
    expect(svc.sources.map((s) => s.id), ['http-ok']);
    final results = await svc.searchAll('foot');
    expect(results.expand((r) => r.items).map((i) => i.id), ['a']);
    final feed = await svc.homeFeed();
    expect(feed.map((i) => i.id), ['a']);
    // 默认源表里 webViewOnly 的四个源只走 webSources（搜索页给它们放浏览器按钮）。
    final real = SearchService();
    expect(real.webSources.map((s) => s.id), ['niacg', 'lianzu11', 'hanime1', 'hanimeone']);
    expect(real.sources.map((s) => s.id), isNot(contains('niacg')));
    expect(real.sources.map((s) => s.id), isNot(contains('hanime1')));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('homeFeed 去重：两个源返回同一条只留一次（第 24 条）', () async {
    final svc = SearchService(sources: [
      FakeSource('s1', items: [v('a', title: 'one'), v('b', title: 'two')]),
      FakeSource('s2', items: [v('a', title: 'one'), v('c', title: 'three')]),
    ]);
    final feed = await svc.homeFeed();
    expect(feed.length, 3);
    expect(feed.map((i) => i.id).toSet(), {'a', 'b', 'c'});
  });

  test('homeFeed 轮换：rotation 换词、换页，同一批不反复出现（第 24 条）', () async {
    final svc = SearchService(sources: [QueryFakeSource('q')]);
    // rotation 0：走 home() 第 1 页。
    expect((await svc.homeFeed(rotation: 0)).map((i) => i.id), ['home-1-a']);
    // rotation 1：换词 3d、第 1 页走 searchPage。
    expect((await svc.homeFeed(rotation: 1)).map((i) => i.id), ['3d-1-a', '3d-1-b']);
    // rotation 2：换词 asian、第 1 页。
    expect((await svc.homeFeed(rotation: 2)).map((i) => i.id), ['asian-1-a', 'asian-1-b']);
    // rotation 6：词 3d、翻第 2 页——fake 的 searchPage 第 2 页为空，
    // 回落 home(page: 2)，照样是新一批，不是第 1 页那批。
    expect((await svc.homeFeed(rotation: 6)).map((i) => i.id), ['home-2-a']);
  });
}

/// 按词/页返回不同条目的假源：验 homeFeed 轮换是不是真换了批。
class QueryFakeSource implements Source {
  final String _id;
  const QueryFakeSource(this._id);

  @override
  String get id => _id;
  @override
  String get name => _id;
  @override
  bool get webViewOnly => false;
  @override
  String webSearchUrl(String query) => '';
  @override
  String get webHomeUrl => '';

  @override
  Future<SourceResult> search(String query) async => SourceResult(
      sourceId: _id, sourceName: _id, items: [v('search-$query-a'), v('search-$query-b')]);

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    if (page > 1) return SourceResult(sourceId: _id, sourceName: _id);
    return SourceResult(
        sourceId: _id, sourceName: _id, items: [v('$query-$page-a'), v('$query-$page-b')]);
  }

  @override
  Future<SourceResult> home({int page = 1}) async => SourceResult(
      sourceId: _id, sourceName: _id, items: [v('home-$page-a')]);
}

/// 第一次调用超时（拖 9 秒），之后每次都立刻成功：模拟“慢的源后台再试成功”。
class FlakySource implements Source {
  final String _id;
  final List<VideoItem> items;
  var _calls = 0;
  FlakySource(this._id, {this.items = const []});

  @override
  String get id => _id;
  @override
  String get name => _id;

  @override
  bool get webViewOnly => false;

  @override
  String webSearchUrl(String query) => '';

  @override
  String get webHomeUrl => '';

  @override
  Future<SourceResult> search(String query) async {
    _calls++;
    if (_calls == 1) {
      await Future.delayed(const Duration(seconds: 9));
    }
    return SourceResult(sourceId: _id, sourceName: _id, items: items);
  }

  @override
  Future<SourceResult> searchPage(String query, int page) async {
    if (page > 1) return SourceResult(sourceId: _id, sourceName: _id);
    return search(query);
  }

  @override
  Future<SourceResult> home({int page = 1}) async => search('');
}
