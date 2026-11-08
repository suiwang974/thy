import 'package:flutter/material.dart';

import '../data/search_map.dart';
import '../data/sources.dart';
import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 搜索页：输入中文词，先映射成英文，再默认查全部已启用的源（不单选）。
/// - 源多选（默认全选）：点芯片开关某个源；
/// - 分类 / 时长 / 画质 1080p+ / 排序（相关/最新/最多看/最长）；
/// - 中文映射走所有搜索路径（搜、翻页都先过 mapSearchQuery）；
/// - 无封面也收；结果流式上屏（先回来的源先显示）；
/// - 搜过的词先读缓存立刻显示，后台再刷新；底部“加载更多”分页加载。
class SearchScreen extends StatefulWidget {
  final Store store;
  final String? initialQuery;
  const SearchScreen({super.key, required this.store, this.initialQuery});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _service = SearchService();
  List<VideoItem> _items = [];
  Map<String, int> _perSource = {};
  List<String> _slowSources = []; // 超时/失败的源（后台再试中）
  bool _searching = false;
  bool _loadingMore = false;
  String _mappedQuery = '';
  String? _lastQuery;
  int _page = 1;
  bool _hasMore = false;

  SearchFilters _filters = const SearchFilters();

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _controller.text = widget.initialQuery!;
      _doSearch(widget.initialQuery!);
    }
  }

  List<Source> get _enabledSources =>
      _service.sources.where((s) => !widget.store.disabledSources.contains(s.id)).toList();

  Future<void> _doSearch(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    await widget.store.recordSearchTerm(q);
    setState(() {
      _searching = true;
      _items = [];
      _perSource = {};
      _slowSources = [];
      _mappedQuery = mapSearchQuery(q);
      _lastQuery = q;
      _page = 1;
      _hasMore = false;
    });
    // 先读缓存：搜过的词立刻显示，后台再刷新。
    final cached = widget.store.loadSearchCache(q);
    if (cached.isNotEmpty && mounted) {
      setState(() => _items = _filters.apply(cached));
    }
    final enabled = _enabledSources;
    final svc = SearchService(
        sources: enabled.where((s) => _filters.sourceIds.isEmpty || _filters.sourceIds.contains(s.id)).toList());
    final results = await svc.searchAll(q,
        filters: _filters,
        onResult: (partial) {
          if (!mounted) return;
          final merged = partial.expand((r) => r.items).toList();
          final counts = <String, int>{};
          final slow = <String>[];
          for (final r in partial) {
            counts[r.sourceName] = r.items.length;
            if (r.error != null) slow.add(r.sourceName);
          }
          setState(() {
            _items = merged;
            _perSource = counts;
            _slowSources = slow;
          });
        },
        // 慢的源后台再试回来：去重后并进结果，慢源状态里去掉它。
        onRetried: (retried) {
          if (!mounted) return;
          setState(() {
            final seen = _items.map((v) => v.id).toSet();
            _items = [..._items, ...retried.items.where((v) => !seen.contains(v.id))];
            _perSource[retried.sourceName] = (_perSource[retried.sourceName] ?? 0) + retried.items.length;
            _slowSources = _slowSources.where((n) => n != retried.sourceName).toList();
          });
        });
    if (!mounted) return;
    final merged = results.expand((r) => r.items).toList();
    if (merged.isNotEmpty) await widget.store.saveSearchCache(q, merged);
    setState(() {
      _items = merged;
      _searching = false;
      _hasMore = merged.isNotEmpty;
    });
  }

  Future<void> _loadMore() async {
    final q = _lastQuery;
    if (q == null || q.isEmpty || _loadingMore) return;
    setState(() => _loadingMore = true);
    final next = _page + 1;
    final more = await _service.searchPage(q, next, filters: _filters);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (more.isNotEmpty) {
        _page = next;
        final seen = _items.map((v) => v.id).toSet();
        _items = [..._items, ...more.where((v) => !seen.contains(v.id))];
        _hasMore = true;
      } else {
        _hasMore = false;
      }
    });
  }

  void _open(VideoItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, playlist: _items, store: widget.store),
    ));
  }

  void _applyFilters() {
    // 过滤条件变了就按当前条件重新搜（缓存的也按新条件过滤）。
    if (_lastQuery != null && _lastQuery!.isNotEmpty) {
      _doSearch(_lastQuery!);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _enabledSources;
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        title: const Text('搜索', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '搜作者名 / 演员名 / 足、足交、八重神子…',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, color: Colors.white54),
                  onPressed: () => _controller.clear(),
                ),
                filled: true,
                fillColor: const Color(0xFF2A2A35),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: _doSearch,
            ),
          ),
          if (_mappedQuery.isNotEmpty && _mappedQuery != _lastQuery)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('已按“$_lastQuery → $_mappedQuery”去各源搜',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          // 源多选（默认全选）。
          _chipRow(
            label: '源',
            children: [
              FilterChip(
                label: const Text('全部'),
                selected: _filters.sourceIds.isEmpty,
                onSelected: (_) => setState(() {
                  _filters = _filters.copyWith(sourceIds: <String>{});
                }),
              ),
              ...sources.map((s) => FilterChip(
                    label: Text(s.name),
                    selected: _filters.sourceIds.isEmpty || _filters.sourceIds.contains(s.id),
                    onSelected: (on) {
                      final ids = Set<String>.from(
                          _filters.sourceIds.isEmpty ? sources.map((e) => e.id) : _filters.sourceIds);
                      if (on) {
                        ids.add(s.id);
                      } else {
                        ids.remove(s.id);
                      }
                      setState(() {
                        // 全选了就回到“空 = 全部”，省得一个个记。
                        _filters = _filters.copyWith(
                            sourceIds: ids.length == sources.length ? <String>{} : ids);
                      });
                    },
                  )),
            ],
          ),
          // 分类。
          _chipRow(
            label: '分类',
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: _filters.category.isEmpty,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(category: ''));
                  _applyFilters();
                },
              ),
              ...kCategories.keys.map((c) => ChoiceChip(
                    label: Text(c),
                    selected: _filters.category == c,
                    onSelected: (_) {
                      setState(() => _filters = _filters.copyWith(category: c));
                      _applyFilters();
                    },
                  )),
            ],
          ),
          // 时长 + 画质 + 排序。
          _chipRow(
            label: '时长',
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: _filters.minDurationSec == 0 && _filters.maxDurationSec == 0,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(minDurationSec: 0, maxDurationSec: 0));
                  _applyFilters();
                },
              ),
              ChoiceChip(
                label: const Text('短片 <5分'),
                selected: _filters.maxDurationSec == 300 && _filters.minDurationSec == 0,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(minDurationSec: 0, maxDurationSec: 300));
                  _applyFilters();
                },
              ),
              ChoiceChip(
                label: const Text('5–20分'),
                selected: _filters.minDurationSec == 300 && _filters.maxDurationSec == 1200,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(minDurationSec: 300, maxDurationSec: 1200));
                  _applyFilters();
                },
              ),
              ChoiceChip(
                label: const Text('长片 >20分'),
                selected: _filters.minDurationSec == 1200 && _filters.maxDurationSec == 0,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(minDurationSec: 1200, maxDurationSec: 0));
                  _applyFilters();
                },
              ),
              FilterChip(
                label: const Text('1080p+'),
                selected: _filters.hdOnly,
                onSelected: (on) {
                  setState(() => _filters = _filters.copyWith(hdOnly: on));
                  _applyFilters();
                },
              ),
            ],
          ),
          _chipRow(
            label: '排序',
            children: [
              ChoiceChip(
                label: const Text('相关'),
                selected: _filters.sort == SortOrder.relevance,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(sort: SortOrder.relevance));
                  _applyFilters();
                },
              ),
              ChoiceChip(
                label: const Text('最新'),
                selected: _filters.sort == SortOrder.newest,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(sort: SortOrder.newest));
                  _applyFilters();
                },
              ),
              ChoiceChip(
                label: const Text('最多看'),
                selected: _filters.sort == SortOrder.mostViewed,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(sort: SortOrder.mostViewed));
                  _applyFilters();
                },
              ),
              ChoiceChip(
                label: const Text('最长'),
                selected: _filters.sort == SortOrder.longest,
                onSelected: (_) {
                  setState(() => _filters = _filters.copyWith(sort: SortOrder.longest));
                  _applyFilters();
                },
              ),
            ],
          ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.pinkAccent)),
                  SizedBox(width: 10),
                  Text('正在查全部源…先回来的先显示', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          if (_slowSources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('${_slowSources.join('、')} 超时，后台再试…',
                        style: const TextStyle(color: Colors.orange, fontSize: 12)),
                  ),
                ],
              ),
            ),
          if (!_searching && _items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '共 ${_items.length} 条${_perSource.isEmpty ? '' : '（${_perSource.entries.map((e) => '${e.key} ${e.value}').join(' · ')}）'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _items.isEmpty && !_searching
                ? const Center(child: Text('输入关键词搜全部源', style: TextStyle(color: Colors.white38)))
                : ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (_, i) => VideoCard(item: _items[i], onTap: () => _open(_items[i])),
                        ),
                      ),
                      if (_hasMore && !_searching)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator(color: Colors.pinkAccent)
                                : OutlinedButton(
                                    onPressed: _loadMore,
                                    child: const Text('加载更多'),
                                  ),
                          ),
                        ),
                      const SizedBox(height: 16),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chipRow({required String label, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 0, 2),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: children
                    .map((c) => Padding(padding: const EdgeInsets.only(right: 6), child: c))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
