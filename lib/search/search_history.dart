// 全局搜索历史：地址栏提交过的搜索词/地址，最近的在前，上限 200 条，存手机本地。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一条搜索历史：用户输入的原文 + 解析后要加载的地址。
class SearchHistoryEntry {
  const SearchHistoryEntry({required this.label, required this.url});

  final String label;
  final String url;

  Map<String, dynamic> toJson() => {'label': label, 'url': url};

  factory SearchHistoryEntry.fromJson(Map<String, dynamic> json) {
    final String label = json['label'] as String? ?? '';
    final String url = json['url'] as String? ?? '';
    if (url.isEmpty) {
      throw const FormatException('搜索历史条目缺少 url');
    }
    return SearchHistoryEntry(label: label, url: url);
  }

  @override
  bool operator ==(Object other) =>
      other is SearchHistoryEntry && other.label == label && other.url == url;

  @override
  int get hashCode => Object.hash(label, url);
}

/// 历史存储接口：单测用假实现，不碰 SharedPreferences。
abstract class SearchHistoryStorage {
  List<String> loadRaw();
  Future<void> saveRaw(List<String> raw);
}

/// SharedPreferences 实现。
class SharedPreferencesSearchHistoryStorage implements SearchHistoryStorage {
  SharedPreferencesSearchHistoryStorage(this._prefs);

  static const String key = 'taohuayuan_global_search_history';

  final SharedPreferences _prefs;

  @override
  List<String> loadRaw() => _prefs.getStringList(key) ?? [];

  @override
  Future<void> saveRaw(List<String> raw) => _prefs.setStringList(key, raw);
}

/// 搜索历史本体。
class SearchHistory {
  SearchHistory._(this._storage, this._entries);

  /// 正常入口：读手机本地存储。
  static Future<SearchHistory> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final storage = SharedPreferencesSearchHistoryStorage(prefs);
    return SearchHistory._fromStorage(storage);
  }

  /// 单测入口：不给 initial 时从 storage 恢复（可测坏条目跳过）；
  /// 给了 initial 就用给定的条目，不读 storage。
  factory SearchHistory.withStorage(
    SearchHistoryStorage storage, [
    List<SearchHistoryEntry>? initial,
  ]) {
    if (initial != null) {
      return SearchHistory._(storage, List<SearchHistoryEntry>.from(initial));
    }
    return SearchHistory._fromStorage(storage);
  }

  static const int maxEntries = 200;

  final SearchHistoryStorage _storage;
  final List<SearchHistoryEntry> _entries;

  /// 最近的在前；返回不可修改的副本。
  List<SearchHistoryEntry> get entries => List<SearchHistoryEntry>.unmodifiable(_entries);

  /// 首条（最近一次）的地址；没有历史返回 null。
  String? get firstUrl => _entries.isEmpty ? null : _entries.first.url;

  /// 记一条：去重（同 url 的旧条目先删掉），插到最前面，超上限截尾。
  Future<void> add(String label, String url) async {
    final String l = label.trim();
    final String u = url.trim();
    if (l.isEmpty || u.isEmpty) {
      return;
    }
    _entries.removeWhere((e) => e.url == u);
    _entries.insert(0, SearchHistoryEntry(label: l, url: u));
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    await _persist();
  }

  /// 按 url 精确删一条；不存在就不写存储。
  Future<void> remove(String url) async {
    final int before = _entries.length;
    _entries.removeWhere((e) => e.url == url);
    if (_entries.length != before) {
      await _persist();
    }
  }

  /// 清空全部。补全缓存目前不存在，无需额外清理。
  Future<void> clear() async {
    if (_entries.isEmpty) {
      return;
    }
    _entries.clear();
    await _persist();
  }

  Future<void> _persist() async {
    await _storage.saveRaw(
      _entries.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  /// 从存储恢复：逐条解析，坏条目跳过，不让一条坏数据毁掉整个历史。
  static SearchHistory _fromStorage(SearchHistoryStorage storage) {
    final entries = <SearchHistoryEntry>[];
    for (final raw in storage.loadRaw()) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          entries.add(SearchHistoryEntry.fromJson(decoded));
        }
      } catch (_) {
        // 坏条目跳过。
      }
    }
    return SearchHistory._(storage, entries.take(maxEntries).toList());
  }
}
