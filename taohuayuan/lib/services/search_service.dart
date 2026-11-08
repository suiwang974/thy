import 'dart:async';

import '../data/search_map.dart';
import '../data/sources.dart';
import '../models/video_item.dart';

/// 多源搜索：默认查全部已启用的源，并行发出，结果随到随回。
/// 片库是本地目录，瞬间出结果，先显示；网络源陆续流进来，不用等最慢的。
class SearchService {
  final List<Source> sources;

  SearchService({List<Source>? sources}) : sources = sources ?? allSources();

  /// 搜一次：先把中文词映射成英文，再并行查所有源。
  /// 每当某个源返回，就调一次 onResult（带着目前为止的全部结果）。
  Future<List<SourceResult>> searchAll(
    String rawQuery, {
    void Function(List<SourceResult> partial)? onResult,
  }) async {
    final query = mapSearchQuery(rawQuery);
    final done = <SourceResult>[];
    final futures = sources.map((s) async {
      final r = await s.search(query);
      done.add(r);
      onResult?.call(List.of(done));
      return r;
    });
    await Future.wait(futures);
    return done;
  }

  /// 首页推荐流：片库全量 + Eporner 热门（失败也不影响片库显示）。
  Future<List<VideoItem>> homeFeed() async {
    final results = await Future.wait([
      CatalogSource().home(),
      EpornerSource().home(),
    ]);
    final items = <VideoItem>[];
    for (final r in results) {
      items.addAll(r.items);
    }
    return items;
  }
}
