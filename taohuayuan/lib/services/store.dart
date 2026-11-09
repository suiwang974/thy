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
  static const _shortsMutedKey = 'taohuayuan_shorts_muted';
  static const _searchTermsKey = 'taohuayuan_search_terms';
  static const _dislikedTagsKey = 'taohuayuan_disliked_tags';
  static const _feedCacheKey = 'taohuayuan_feed_cache';
  static const _feedCacheTimeKey = 'taohuayuan_feed_cache_time';
  static const _feedRotationKey = 'taohuayuan_feed_rotation';

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

  // ---- 短视频默认静音（2026-11-09 用户定：打开 App 不许自动出声）----
  // 默认 true：短视频加载完自动播，但不出声；点喇叭图标才出声，选择持久保存。
  bool get shortsMuted => _prefs.getBool(_shortsMutedKey) ?? true;

  Future<void> setShortsMuted(bool muted) async {
    await _prefs.setBool(_shortsMutedKey, muted);
  }

  // ---- 推荐轮换计数（2026-11-09 用户反馈：推荐页同一批反复出现）----
  // 下拉刷新就 +1，homeFeed 按它换词、换页取新一批；存在本地，重启也不丢。
  int get feedRotation => _prefs.getInt(_feedRotationKey) ?? 0;

  Future<void> setFeedRotation(int value) async {
    await _prefs.setInt(_feedRotationKey, value);
  }

  // ---- 短视频轮换计数 + 各标签位置（第 46/48 条）----
  // 打开短视频栏就 +1，homeFeed 按它换词、换页取新一批；每次打开都是新一批，
  // 不再固定 1–200 条。位置按标签各记各的（推荐/最新/最热门），切标签再切回来、
  // 退出重进都从这个位置继续，互不干扰。
  static const _shortsRotationKey = 'taohuayuan_shorts_rotation';
  static const _shortsPosPrefix = 'taohuayuan_shorts_pos_';

  int get shortsRotation => _prefs.getInt(_shortsRotationKey) ?? 0;

  Future<void> setShortsRotation(int value) async {
    await _prefs.setInt(_shortsRotationKey, value);
  }

  int shortsPosition(String tab) => _prefs.getInt('$_shortsPosPrefix$tab') ?? 0;

  Future<void> setShortsPosition(String tab, int index) async {
    await _prefs.setInt('$_shortsPosPrefix$tab', index);
  }

  // ---- 内置浏览器默认翻译成中文（第 35 条，用户定）----
  // 默认 true：浏览器打开页面就走 translate.goog 翻成中文；
  // AppBar 里的翻译按钮可随时切回原文，选择持久保存。
  static const _translateKey = 'taohuayuan_translate_enabled';

  bool get translateEnabled => _prefs.getBool(_translateKey) ?? true;

  Future<void> setTranslateEnabled(bool v) async {
    await _prefs.setBool(_translateKey, v);
  }

  // ---- 下载的 ts 转 mp4（第 34 条，1DM 同款勾选项）----
  // 默认 true：HLS 的 .ts 分段下完后重封装成 mp4（纯 Dart 解包，
  // 没 ffmpeg）；转不了就保留 .ts，不标下载失败。
  static const _tsToMp4Key = 'taohuayuan_ts_to_mp4';

  bool get tsToMp4 => _prefs.getBool(_tsToMp4Key) ?? true;

  Future<void> setTsToMp4(bool v) async {
    await _prefs.setBool(_tsToMp4Key, v);
  }

  // ---- 应用内更新（第 50 条）----
  // 启动时每天最多自动查一次新版（GitHub 未登录限流 60 次/小时/IP，别每启动都查）；
  // 用户点了“稍后”就记下这个 tag，同一版不再弹窗；下好的安装包路径也记下来，
  // 下次打开「我的」直接点“安装”，不用重下。
  static const _updateCheckKey = 'taohuayuan_update_check_ms';
  static const _updateSkipKey = 'taohuayuan_update_skip_tag';
  static const _updateApkPathKey = 'taohuayuan_update_apk_path';
  static const _updateApkTagKey = 'taohuayuan_update_apk_tag';

  int get lastUpdateCheckMs => _prefs.getInt(_updateCheckKey) ?? 0;

  Future<void> setLastUpdateCheckMs(int ms) async {
    await _prefs.setInt(_updateCheckKey, ms);
  }

  String? get skippedUpdateTag => _prefs.getString(_updateSkipKey);

  Future<void> setSkippedUpdateTag(String tag) async {
    await _prefs.setString(_updateSkipKey, tag);
  }

  String? get updateApkPath => _prefs.getString(_updateApkPathKey);

  String? get updateApkTag => _prefs.getString(_updateApkTagKey);

  Future<void> setUpdateApk(String tag, String path) async {
    await _prefs.setString(_updateApkTagKey, tag);
    await _prefs.setString(_updateApkPathKey, path);
  }

  Future<void> clearUpdateApk() async {
    await _prefs.remove(_updateApkTagKey);
    await _prefs.remove(_updateApkPathKey);
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
