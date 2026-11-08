import 'dart:async';

import '../data/search_map.dart';
import '../data/sources.dart';
import '../models/video_item.dart';

/// 排序方式。
enum SortOrder { relevance, newest, mostViewed, longest }

/// 搜索过滤条件（搜索页的过滤栏）。
/// - sourceIds 为空 = 查全部已启用的源（默认全选）。
/// - category 为空 = 不限分类。
/// - 时长：min/max 为 0 表示不限；时长未知的条目（durationSec=0）不被时长过滤掉，
///   因为源站没给数据，不能直接丢。
/// - hdOnly：只留 1080p+；分辨率未知的条目同样不丢（源站没给数据）。
class SearchFilters {
  final Set<String> sourceIds;
  final String category;
  final int minDurationSec;
  final int maxDurationSec;
  final bool hdOnly;
  final SortOrder sort;

  const SearchFilters({
    this.sourceIds = const {},
    this.category = '',
    this.minDurationSec = 0,
    this.maxDurationSec = 0,
    this.hdOnly = false,
    this.sort = SortOrder.relevance,
  });

  bool matches(VideoItem v) {
    if (category.isNotEmpty) {
      final terms = kCategories[category] ?? const [];
      final hay = '${v.title.toLowerCase()} ${v.keywords.join(' ').toLowerCase()}';
      final hit = hay.contains(category.toLowerCase()) ||
          terms.any((t) => hay.contains(t));
      if (!hit) return false;
    }
    if (minDurationSec > 0 && v.durationSec > 0 && v.durationSec < minDurationSec) return false;
    if (maxDurationSec > 0 && v.durationSec > 0 && v.durationSec > maxDurationSec) return false;
    if (hdOnly && v.resolution.isNotEmpty && !v.isHd) return false;
    return true;
  }

  /// 先过滤再按排序排。relevance 保持源站原顺序（不重排）。
  List<VideoItem> apply(List<VideoItem> items) {
    final out = items.where(matches).toList();
    switch (sort) {
      case SortOrder.newest:
        out.sort((a, b) => b.publishedAtMs.compareTo(a.publishedAtMs));
      case SortOrder.mostViewed:
        out.sort((a, b) => b.views.compareTo(a.views));
      case SortOrder.longest:
        out.sort((a, b) => b.durationSec.compareTo(a.durationSec));
      case SortOrder.relevance:
        break;
    }
    return out;
  }

  SearchFilters copyWith({
    Set<String>? sourceIds,
    String? category,
    int? minDurationSec,
    int? maxDurationSec,
    bool? hdOnly,
    SortOrder? sort,
  }) =>
      SearchFilters(
        sourceIds: sourceIds ?? this.sourceIds,
        category: category ?? this.category,
        minDurationSec: minDurationSec ?? this.minDurationSec,
        maxDurationSec: maxDurationSec ?? this.maxDurationSec,
        hdOnly: hdOnly ?? this.hdOnly,
        sort: sort ?? this.sort,
      );
}

/// 多源搜索：默认查全部已启用的源，并行发出，结果随到随回。
/// - 每个源单独 8 秒超时：超时的源跳过、不拖全场（返回一条带 error 的结果）；
/// - 中文词映射走所有搜索路径（searchAll / searchPage / homeFeed 的兜底搜索
///   都先过 mapSearchQuery，33a1582 只接一条路导致供应商页搜“足” 0 结果的教训）。
class SearchService {
  final List<Source> sources;

  /// 单个源最多等 8 秒，超时就跳过，不拖全场。
  static const sourceTimeout = Duration(seconds: 8);

  /// 最近一次搜索/热门流里每个源花了多少毫秒（源 id -> 毫秒）。
  final Map<String, int> lastLatencies = {};

  SearchService({List<Source>? sources}) : sources = sources ?? allSources();

  /// 搜一次：先把中文词映射成英文，再并行查所有源。
  /// 每当某个源返回，就调一次 onResult（带着目前为止的全部结果，先回来的先显示）。
  /// 慢的源后台再试：超时/失败的源不挡首屏，2 秒后再试一次，成功了通过 onRetried 补回来。
  Future<List<SourceResult>> searchAll(
    String rawQuery, {
    SearchFilters? filters,
    void Function(List<SourceResult> partial)? onResult,
    void Function(SourceResult retried)? onRetried,
  }) async {
    final query = mapSearchQuery(rawQuery);
    final active = _activeSources(filters);
    final done = <SourceResult>[];
    await Future.wait(active.map((s) async {
      final sw = Stopwatch()..start();
      SourceResult r;
      try {
        r = await s.search(query).timeout(sourceTimeout);
      } on TimeoutException {
        r = SourceResult(sourceId: s.id, sourceName: s.name, error: '超时（8秒）');
      } catch (e) {
        r = SourceResult(sourceId: s.id, sourceName: s.name, error: e.toString());
      }
      sw.stop();
      lastLatencies[s.id] = sw.elapsedMilliseconds;
      final items = filters != null ? filters.apply(r.items) : r.items;
      r = SourceResult(sourceId: r.sourceId, sourceName: r.sourceName, items: items, error: r.error, elapsedMs: sw.elapsedMilliseconds);
      done.add(r);
      onResult?.call(List.of(done));
    }));
    if (onRetried != null) {
      for (final r in done.where((r) => r.error != null)) {
        final s = active.firstWhere((e) => e.id == r.sourceId);
        unawaited(_retrySearch(s, query, filters, onRetried));
      }
    }
    return done;
  }

  Future<void> _retrySearch(Source s, String query, SearchFilters? filters, void Function(SourceResult) onRetried) async {
    await Future.delayed(const Duration(seconds: 2));
    try {
      final sw = Stopwatch()..start();
      final r = await s.search(query).timeout(sourceTimeout);
      sw.stop();
      lastLatencies[s.id] = sw.elapsedMilliseconds;
      if (r.items.isEmpty) return;
      onRetried(SourceResult(
        sourceId: r.sourceId,
        sourceName: r.sourceName,
        items: filters != null ? filters.apply(r.items) : r.items,
        elapsedMs: sw.elapsedMilliseconds,
      ));
    } catch (_) {
      // 后台再试失败也不打扰用户。
    }
  }

  /// 分页搜第 page 页（搜索页“加载更多”用）：每个源只抓这一页，并行返回合并后的条目。
  Future<List<VideoItem>> searchPage(
    String rawQuery,
    int page, {
    SearchFilters? filters,
  }) async {
    final query = mapSearchQuery(rawQuery);
    final active = _activeSources(filters);
    final results = await Future.wait(active.map((s) async {
      try {
        return await s.searchPage(query, page).timeout(sourceTimeout);
      } catch (_) {
        return SourceResult(sourceId: s.id, sourceName: s.name);
      }
    }));
    var items = results.expand((r) => r.items).toList();
    if (filters != null) items = filters.apply(items);
    return items;
  }

  /// 首页推荐流：8 个源并行取热门。
  /// 有 home() 的源走 home()；没有的（niacg 首页无列表、xvideos 等）走默认词搜索兜底，
  /// 默认词按源的站内偏好分（3D 站搜 3d、综合站搜足控/亚洲），冷启动口味一致。
  /// 每当某个源回结果就调一次 onResult，先回来的先显示；单个源 8 秒超时跳过。
  /// 慢的源后台再试：没回结果的源 2 秒后再试一次，成功了通过 onRetried 把新条目补回来。
  Future<List<VideoItem>> homeFeed({
    void Function(List<VideoItem> partial)? onResult,
    void Function(List<VideoItem> extra)? onRetried,
  }) async {
    final items = <VideoItem>[];
    final failed = <Source>[];
    await Future.wait(sources.map((s) async {
      final sw = Stopwatch()..start();
      SourceResult r;
      try {
        r = await s.home().timeout(sourceTimeout);
        if (r.items.isEmpty) {
          r = await s.search(mapSearchQuery(_defaultQueryFor(s.id))).timeout(sourceTimeout);
        }
      } catch (_) {
        r = SourceResult(sourceId: s.id, sourceName: s.name);
      }
      sw.stop();
      lastLatencies[s.id] = sw.elapsedMilliseconds;
      if (r.items.isNotEmpty) {
        items.addAll(r.items);
        onResult?.call(List.of(items));
      } else {
        failed.add(s);
      }
    }));
    if (onRetried != null) {
      for (final s in failed) {
        unawaited(_retryHome(s, onRetried));
      }
    }
    return items;
  }

  Future<void> _retryHome(Source s, void Function(List<VideoItem>) onRetried) async {
    await Future.delayed(const Duration(seconds: 2));
    try {
      final sw = Stopwatch()..start();
      var r = await s.home().timeout(sourceTimeout);
      if (r.items.isEmpty) {
        r = await s.search(mapSearchQuery(_defaultQueryFor(s.id))).timeout(sourceTimeout);
      }
      sw.stop();
      lastLatencies[s.id] = sw.elapsedMilliseconds;
      if (r.items.isNotEmpty) onRetried(r.items);
    } catch (_) {
      // 后台再试失败也不打扰用户。
    }
  }

  List<Source> _activeSources(SearchFilters? filters) {
    if (filters == null || filters.sourceIds.isEmpty) return sources;
    return sources.where((s) => filters.sourceIds.contains(s.id)).toList();
  }

  static String _defaultQueryFor(String sourceId) {
    switch (sourceId) {
      case 'niacg':
      case 'lianzu11':
      case 'rule34videos':
        return '3d';
      case 'xhamster':
      case 'spankbang':
        return 'asian';
      default:
        return 'footjob';
    }
  }
}
