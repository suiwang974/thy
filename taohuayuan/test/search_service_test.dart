import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/data/sources.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/search_service.dart';

class FakeSource implements Source {
  final String _id;
  final Duration delay;
  final List<VideoItem> items;
  final bool throwError;
  const FakeSource(this._id, {this.delay = Duration.zero, this.items = const [], this.throwError = false});

  @override
  String get id => _id;
  @override
  String get name => _id;

  @override
  Future<SourceResult> search(String query) async {
    await Future.delayed(delay);
    if (throwError) throw Exception('boom');
    return SourceResult(sourceId: _id, sourceName: _id, items: items);
  }

  @override
  Future<SourceResult> home() async => search('');

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
  Future<SourceResult> home() async => search('');
}
