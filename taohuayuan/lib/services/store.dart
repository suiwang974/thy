import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';

/// 收藏（喜欢）、关注的作者、观看记录。存在手机本地，不上传。
class Store {
  static const _likesKey = 'taohuayuan_likes';
  static const _followsKey = 'taohuayuan_follows';
  static const _historyKey = 'taohuayuan_history';
  static const _disabledSourcesKey = 'taohuayuan_disabled_sources';

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
}
