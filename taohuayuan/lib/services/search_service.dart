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

  /// “一个都不选”的标记：sourceIds 里只有这个值时表示全不选。
  /// 空集 = 全选（历史约定），所以全不选不能用空集表示，只能用标记。
  /// 搜索页点“全部”就是在“全选”和“全不选”之间切换。
  static const noneMarker = '__none__';

  /// 当前是不是“一个源都没选”。
  bool get selectsNone => sourceIds.length == 1 && sourceIds.contains(noneMarker);
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
/// - 每个源单独超时：普通源 8 秒，慢源（niacg、lianzu11、hanime1、hanimeone）
///   15 秒；超时的源跳过、不拖全场（返回一条带 error 的结果）；
/// - 慢源后台继续试：第一次失败后 2 秒试第 2 次、再 8 秒后试第 3 次，
///   成功了通过 onRetried 补回来，3 次都失败通过 onRetryFailed 告诉界面；
/// - 中文词映射走所有搜索路径（searchAll / searchPage / homeFeed 的兜底搜索
///   都先过 mapSearchQuery，33a1582 只接一条路导致供应商页搜“足” 0 结果的教训）。
class SearchService {
  final List<Source> sources;

  /// 单个源最多等 8 秒，超时就跳过，不拖全场。
  static const sourceTimeout = Duration(seconds: 8);

  /// 慢源（niacg、lianzu11、hanime1、hanimeone：抓页面慢、还常被墙）
  /// 第一次放宽到 15 秒——用户只开这两个源时，8 秒一刀切会让两个都超时、
  /// 看起来全死了。放宽后首屏慢一点，但状态会显示“还在搜”，不无声停掉。
  static const slowSourceTimeout = Duration(seconds: 15);
  static const _slowSourceIds = {'niacg', 'lianzu11', 'hanime1', 'hanimeone'};

  /// 慢源后台最多再试次数（不含第一次）：第 1 次失败后 2 秒试第 2 次，
  /// 再失败 8 秒后试第 3 次；3 次都失败才算死，通过 onRetryFailed 告诉界面。
  static const maxRetries = 2;
  static const _retryDelays = [Duration(seconds: 2), Duration(seconds: 8)];

  Duration _timeoutFor(Source s) =>
      _slowSourceIds.contains(s.id) ? slowSourceTimeout : sourceTimeout;

  /// 最近一次搜索/热门流里每个源花了多少毫秒（源 id -> 毫秒）。
  final Map<String, int> lastLatencies = {};

  /// 关掉的源（“我的”里的开关）：这些源不查、不出现在任何结果里。
  /// 之前只在搜索页过滤，推荐页和短视频用的 homeFeed 根本没过开关，
  /// 用户只开 Niacg/Lianzu11，推荐里照样出现 eporner——开关只是摆设。
  /// 现在服务层强制生效：推荐、短视频、搜索、追番、作者页全走这一道。
  final Set<String> disabledSources;

  /// HTTP 能查的源（已启用、且不是 webViewOnly）。
  /// webViewOnly 的源（niacg、lianzu11、hanime1、hanimeone）会被 WAF/
  /// Cloudflare 按 TLS 指纹拦，纯 HTTP 请求永远拿不到真结果，只会产出
  /// 误导人的“0 条”——所以 HTTP 搜索/热门根本不查它们（2026-11-09 定），
  /// 它们只走内置浏览器（见 webSources）。
  SearchService({List<Source>? sources, Set<String> disabledSources = const {}})
      : disabledSources = disabledSources,
        sources = (sources ?? allSources())
            .where((s) => !disabledSources.contains(s.id) && !s.webViewOnly)
            .toList();

  /// 需要走内置浏览器的源（已启用、webViewOnly）：搜索页给它们放按钮，
  /// 不参与 HTTP 搜索，不在状态条里报“0 条”。
  List<Source> get webSources => (allSources())
      .where((s) => !disabledSources.contains(s.id) && s.webViewOnly)
      .toList();

  /// 搜一次：先把中文词映射成英文，再并行查所有源。
  /// 每当某个源返回，就调一次 onResult（带着目前为止的全部结果，先回来的先显示）。
  /// 慢的源后台继续试：超时/失败的源不挡首屏，2 秒后试第 2 次、再 8 秒后试
  /// 第 3 次，成功了通过 onRetried 补回来；3 次都失败通过 onRetryFailed
  /// 告诉界面“已试 3 次”，不让用户对着空白页猜。
  Future<List<SourceResult>> searchAll(
    String rawQuery, {
    SearchFilters? filters,
    void Function(List<SourceResult> partial)? onResult,
    void Function(SourceResult retried)? onRetried,
    void Function(SourceResult failed)? onRetryFailed,
  }) async {
    final query = mapSearchQuery(rawQuery);
    final active = _activeSources(filters);
    final done = <SourceResult>[];
    // 第 36 条：跨源/跨页合并时去重（同一视频在多源/多页出现，id 现在
    // 是归一化的视频 key，dedupeById 能认出来；不去重总数会对不上）。
    final seenIds = <String>{};
    await Future.wait(active.map((s) async {
      final sw = Stopwatch()..start();
      SourceResult r;
      try {
        r = await s.search(query).timeout(_timeoutFor(s));
      } on TimeoutException {
        r = SourceResult(
            sourceId: s.id,
            sourceName: s.name,
            error: '超时（${_timeoutFor(s).inSeconds}秒）');
      } catch (e) {
        r = SourceResult(sourceId: s.id, sourceName: s.name, error: e.toString());
      }
      sw.stop();
      lastLatencies[s.id] = sw.elapsedMilliseconds;
      final filtered = filters != null ? filters.apply(r.items) : r.items;
      final items = filtered.where((v) => seenIds.add(v.id)).toList();
      r = SourceResult(sourceId: r.sourceId, sourceName: r.sourceName, items: items, error: r.error, elapsedMs: sw.elapsedMilliseconds, rawItemCount: filtered.length);
      done.add(r);
      onResult?.call(List.of(done));
    }));
    if (onRetried != null || onRetryFailed != null) {
      for (final r in done.where((r) => r.error != null)) {
        final s = active.firstWhere((e) => e.id == r.sourceId);
        unawaited(_retrySearch(s, query, filters, onRetried, onRetryFailed));
      }
    }
    return done;
  }

  Future<void> _retrySearch(Source s, String query, SearchFilters? filters,
      void Function(SourceResult)? onRetried,
      void Function(SourceResult)? onRetryFailed) async {
    String lastError = '失败';
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      await Future.delayed(_retryDelays[attempt]);
      try {
        final sw = Stopwatch()..start();
        final r = await s.search(query).timeout(_timeoutFor(s));
        sw.stop();
        lastLatencies[s.id] = sw.elapsedMilliseconds;
        if (r.items.isEmpty && r.error == null) {
          // 空结果不是失败：确实没结果，不继续试了。
          onRetryFailed?.call(SourceResult(
              sourceId: s.id, sourceName: s.name, error: '没结果'));
          return;
        }
        if (r.items.isEmpty) {
          lastError = r.error ?? '失败';
          continue;
        }
        onRetried?.call(SourceResult(
          sourceId: r.sourceId,
          sourceName: r.sourceName,
          items: filters != null ? filters.apply(r.items) : r.items,
          elapsedMs: sw.elapsedMilliseconds,
        ));
        return;
      } on TimeoutException {
        lastError = '超时（${_timeoutFor(s).inSeconds}秒）';
      } catch (e) {
        lastError = e.toString();
      }
    }
    // 3 次都失败：把最终原因告诉界面，状态从“后台再试”改成“已试 3 次”。
    onRetryFailed?.call(SourceResult(
        sourceId: s.id,
        sourceName: s.name,
        error: '$lastError，已试 ${maxRetries + 1} 次'));
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
        return await s.searchPage(query, page).timeout(_timeoutFor(s));
      } catch (_) {
        return SourceResult(sourceId: s.id, sourceName: s.name);
      }
    }));
    var items = results.expand((r) => r.items).toList();
    if (filters != null) items = filters.apply(items);
    // 第 36 条：翻页合并也去重（同一视频可能在第 1 页和第 2 页都出现）。
    return dedupeById(items);
  }

  /// 首页推荐流：各源并行取热门。
  /// 有 home() 的源走 home()；没有的（niacg 首页无列表、xvideos 等）走默认词搜索兜底，
  /// 默认词按源的站内偏好分（3D 站搜 3d、综合站搜足控/亚洲），冷启动口味一致。
  /// 每当某个源回结果就调一次 onResult，先回来的先显示；单个源 8 秒超时跳过。
  /// 慢的源后台再试：没回结果的源 2 秒后再试一次，成功了通过 onRetried 把新条目补回来。
  /// 按 id 去重（同一条不要在推荐流里出现两次）：保留第一次出现的位置。
  static List<VideoItem> dedupeById(List<VideoItem> items) {
    final seen = <String>{};
    return items.where((v) => seen.add(v.id)).toList();
  }

  /// 轮换用的词：每次刷新按 rotation 换词、换页，别每次都拿同一批最热。
  /// rotation 1–5 换词（第 1 页），6–10 同批词翻第 2 页，11–15 第 3 页，
  /// 之后循环。eporner 的 home(page) 直接翻最热页，其他源走 searchPage。
  static const _rotationQueries = ['footjob', '3d', 'asian', 'foot', 'femdom'];
  static String _rotationQuery(int rotation) =>
      _rotationQueries[rotation % _rotationQueries.length];
  static int _rotationPage(int rotation) =>
      1 + (rotation ~/ _rotationQueries.length) % 3;

  /// 某个源的一次推荐取数：rotation 0 走老路（home + 默认词兜底）；
  /// rotation > 0 走轮换（换词翻页搜，空了回落 home(page)，再空回落默认词）。
  Future<SourceResult> _fetchHome(Source s, int rotation) async {
    if (rotation <= 0) {
      var r = await s.home().timeout(_timeoutFor(s));
      if (r.items.isEmpty) {
        r = await s.search(mapSearchQuery(_defaultQueryFor(s.id))).timeout(_timeoutFor(s));
      }
      return r;
    }
    var r = await s
        .searchPage(mapSearchQuery(_rotationQuery(rotation)), _rotationPage(rotation))
        .timeout(_timeoutFor(s));
    if (r.items.isEmpty) {
      r = await s.home(page: _rotationPage(rotation)).timeout(_timeoutFor(s));
    }
    if (r.items.isEmpty) {
      r = await s.search(mapSearchQuery(_defaultQueryFor(s.id))).timeout(_timeoutFor(s));
    }
    return r;
  }

  Future<List<VideoItem>> homeFeed({
    void Function(List<VideoItem> partial)? onResult,
    void Function(List<VideoItem> extra)? onRetried,
    int rotation = 0,
  }) async {
    final items = <VideoItem>[];
    final failed = <Source>[];
    await Future.wait(sources.map((s) async {
      final sw = Stopwatch()..start();
      SourceResult r;
      try {
        r = await _fetchHome(s, rotation);
      } catch (_) {
        r = SourceResult(sourceId: s.id, sourceName: s.name);
      }
      sw.stop();
      lastLatencies[s.id] = sw.elapsedMilliseconds;
      if (r.items.isNotEmpty) {
        items.addAll(r.items);
        onResult?.call(dedupeById(List.of(items)));
      } else {
        failed.add(s);
      }
    }));
    if (onRetried != null) {
      for (final s in failed) {
        unawaited(_retryHome(s, onRetried, rotation));
      }
    }
    return dedupeById(items);
  }

  Future<void> _retryHome(
      Source s, void Function(List<VideoItem>) onRetried, int rotation) async {
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      await Future.delayed(_retryDelays[attempt]);
      try {
        final sw = Stopwatch()..start();
        final r = await _fetchHome(s, rotation);
        sw.stop();
        lastLatencies[s.id] = sw.elapsedMilliseconds;
        if (r.items.isNotEmpty) {
          onRetried(dedupeById(r.items));
          return;
        }
      } catch (_) {
        // 3 次都失败就安静收尾，不打扰用户。
      }
    }
  }

  List<Source> _activeSources(SearchFilters? filters) {
    if (filters == null || filters.sourceIds.isEmpty) return sources;
    if (filters.selectsNone) return [];
    return sources.where((s) => filters.sourceIds.contains(s.id)).toList();
  }

  static String _defaultQueryFor(String sourceId) {
    switch (sourceId) {
      case 'niacg':
      case 'lianzu11':
      case 'rule34videos':
      case 'hanime1':
      case 'hanimeone':
        return '3d';
      case 'xhamster':
      case 'spankbang':
        return 'asian';
      default:
        return 'footjob';
    }
  }
}
