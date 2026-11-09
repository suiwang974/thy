import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';

/// 收藏（喜欢）、关注的作者、观看记录、口味画像、缓存。存在手机本地，不上传。
/// 口味画像只存本地：点赞、看完比例、关注作者、搜过的词、不喜欢的标签。
class Store {
  static const _likesKey = 'taohuayuan_likes';
  static const _followsKey = 'taohuayuan_follows';
  static const _historyKey = 'taohuayuan_history';
  static const _disabledSourcesKey = 'taohuayuan_disabled_sources';
  static const _searchTermsKey = 'taohuayuan_search_terms';
  static const _dislikedTagsKey = 'taohuayuan_disliked_tags';
  static const _feedCacheKey = 'taohuayuan_feed_cache';
  static const _feedCacheTimeKey = 'taohuayuan_feed_cache_time';

  /// 首页缓存有效期：30 分钟。过期后后台刷新。
  static const feedCacheTtl = Duration(minutes: 30);

  final SharedPreferences _prefs;
  Store(this._prefs);

  static Future<Store> load() async => Store(await SharedPreferences.getInstance());

  List<String> _strList(String key) => _prefs.getStringList(key) ?? [];

  // ---- 喜欢 ----
  Set<String> get likedIds => _strList(_likesKey).toSet();

  Future<void> toggleLike(VideoItem item) async {
    final ids = likedIds;
    if (ids.contains(item.id)) {
      ids.remove(item.id);
      await _prefs.setStringList(_likesKey, ids.toList());
      await _removeLikedItem(item.id);
    } else {
      ids.add(item.id);
      await _prefs.setStringList(_likesKey, ids.toList());
      await _prefs.setString('taohuayuan_liked_${item.id}', jsonEncode(item.toJson()));
    }
  }

  Future<void> _removeLikedItem(String id) async => _prefs.remove('taohuayuan_liked_$id');

  List<VideoItem> likedItems() {
    final out = <VideoItem>[];
    for (final id in likedIds) {
      final raw = _prefs.getString('taohuayuan_liked_$id');
      if (raw != null) {
        try {
          out.add(VideoItem.fromJson(jsonDecode(raw) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    return out;
  }

  // ---- 关注作者 ----
  Set<String> get followedAuthors => _strList(_followsKey).toSet();

  Future<void> toggleFollow(String author) async {
    final s = followedAuthors;
    if (s.contains(author)) {
      s.remove(author);
    } else {
      s.add(author);
    }
    await _prefs.setStringList(_followsKey, s.toList());
  }

  // ---- 观看记录（最近 100 条）----
  Future<void> addHistory(VideoItem item) async {
    final list = _strList(_historyKey);
    list.remove(item.id);
    list.insert(0, item.id);
    await _prefs.setStringList(_historyKey, list.take(100).toList());
    await _prefs.setString('taohuayuan_hist_${item.id}', jsonEncode(item.toJson()));
  }

  List<VideoItem> historyItems() {
    final out = <VideoItem>[];
    for (final id in _strList(_historyKey)) {
      final raw = _prefs.getString('taohuayuan_hist_$id');
      if (raw != null) {
        try {
          out.add(VideoItem.fromJson(jsonDecode(raw) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    return out;
  }

  // ---- 看完比例 + 观看位置：recordWatch(条目, 已看秒数)，只在知道总时长时记 ----
  // 位置（秒）单独存一份，续播用：点开接着看。
  Future<void> recordWatch(VideoItem item, int watchedSec) async {
    if (item.durationSec <= 0 || watchedSec <= 0) return;
    final ratio = (watchedSec / item.durationSec).clamp(0.0, 1.0);
    await _prefs.setDouble('taohuayuan_watch_${item.id}', ratio);
    await _prefs.setInt('taohuayuan_watchpos_${item.id}', watchedSec);
  }

  double watchRatio(String itemId) => _prefs.getDouble('taohuayuan_watch_$itemId') ?? 0.0;

  /// 上次看到第几秒（续播用）；没看过返回 0。
  int watchPosition(String itemId) => _prefs.getInt('taohuayuan_watchpos_$itemId') ?? 0;

  // ---- 搜过的词（最近 20 个，进推荐画像）----
  Future<void> recordSearchTerm(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    final list = _strList(_searchTermsKey);
    list.remove(q);
    list.insert(0, q);
    await _prefs.setStringList(_searchTermsKey, list.take(20).toList());
  }

  List<String> get searchTerms => _strList(_searchTermsKey);

  // ---- 不喜欢的标签（点“不喜欢”就降权这类推荐）----
  Set<String> get dislikedTags => _strList(_dislikedTagsKey).toSet();

  /// 已降权的条目 id（持久保存，图标亮不亮就看这个）。
  static const _dislikedItemsKey = 'taohuayuan_disliked_items';

  Set<String> get dislikedItemIds => _strList(_dislikedItemsKey).toSet();

  bool isDisliked(VideoItem item) => dislikedItemIds.contains(item.id);

  Future<void> dislikeItem(VideoItem item) async {
    if (isDisliked(item)) return;
    await toggleDislike(item);
  }

  /// 点一下降权、再点一下取消（切换），状态持久保存。
  /// 降权时把这条的关键词按条目 id 存下来，取消时只撤掉这条贡献的标签——
  /// 别的已降权条目共用的标签不会被误撤。返回切换后的状态（true=已降权）。
  Future<bool> toggleDislike(VideoItem item) async {
    final ids = dislikedItemIds;
    final tagKey = 'taohuayuan_disliked_tags_${item.id}';
    if (ids.contains(item.id)) {
      ids.remove(item.id);
      await _prefs.setStringList(_dislikedItemsKey, ids.toList());
      await _prefs.remove(tagKey);
      await _rebuildDislikedTags();
      return false;
    }
    ids.add(item.id);
    await _prefs.setStringList(_dislikedItemsKey, ids.toList());
    final tags = <String>{};
    for (final k in item.keywords) {
      final t = k.trim().toLowerCase();
      if (t.isNotEmpty) tags.add(t);
    }
    if (item.author.isNotEmpty) tags.add('author:${item.author.toLowerCase()}');
    await _prefs.setStringList(tagKey, tags.toList());
    await _rebuildDislikedTags();
    return true;
  }

  /// 降权标签 = 所有仍在降权状态的条目贡献的标签的并集。
  Future<void> _rebuildDislikedTags() async {
    final tags = <String>{};
    for (final id in dislikedItemIds) {
      tags.addAll(_prefs.getStringList('taohuayuan_disliked_tags_$id') ?? []);
    }
    await _prefs.setStringList(_dislikedTagsKey, tags.toList());
  }

  Future<void> dislikeTag(String tag) async {
    final tags = dislikedTags..add(tag.trim().toLowerCase());
    await _prefs.setStringList(_dislikedTagsKey, tags.toList());
  }

  // ---- 首页缓存：先读缓存立刻显示，后台再刷新 ----
  Future<void> saveFeedCache(List<VideoItem> items) async {
    final capped = items.take(100).toList();
    await _prefs.setString(_feedCacheKey, jsonEncode(capped.map((v) => v.toJson()).toList()));
    await _prefs.setInt(_feedCacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 返回 (条目, 缓存时间戳毫秒)。没有缓存返回 ([], 0)。
  (List<VideoItem>, int) loadFeedCache() {
    final raw = _prefs.getString(_feedCacheKey);
    final time = _prefs.getInt(_feedCacheTimeKey) ?? 0;
    if (raw == null) return (<VideoItem>[], 0);
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => VideoItem.fromJson(e as Map<String, dynamic>))
          .toList();
      return (list, time);
    } catch (_) {
      return (<VideoItem>[], 0);
    }
  }

  bool get isFeedCacheFresh {
    final (_, time) = loadFeedCache();
    if (time == 0) return false;
    return DateTime.now().millisecondsSinceEpoch - time < feedCacheTtl.inMilliseconds;
  }

  // ---- 搜索缓存：按原词存一份，搜过的词先显示缓存再刷新 ----
  Future<void> saveSearchCache(String query, List<VideoItem> items) async {
    final capped = items.take(100).toList();
    await _prefs.setString(
        'taohuayuan_search_${query.trim()}', jsonEncode(capped.map((v) => v.toJson()).toList()));
  }

  List<VideoItem> loadSearchCache(String query) {
    final raw = _prefs.getString('taohuayuan_search_${query.trim()}');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => VideoItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---- 关掉的源 ----
  Set<String> get disabledSources => _strList(_disabledSourcesKey).toSet();

  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final s = disabledSources;
    if (enabled) {
      s.remove(sourceId);
    } else {
      s.add(sourceId);
    }
    await _prefs.setStringList(_disabledSourcesKey, s.toList());
  }

  // ---- 清除口味数据（喜欢/关注/记录/搜过的词/不喜欢），源开关不动 ----
  Future<void> clearTaste() async {
    await _prefs.remove(_likesKey);
    await _prefs.remove(_followsKey);
    await _prefs.remove(_historyKey);
    await _prefs.remove(_searchTermsKey);
    await _prefs.remove(_dislikedTagsKey);
  }
}
