import 'package:flutter/material.dart';

import '../data/search_map.dart';
import '../data/sources.dart';
import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'web_source_browser.dart';
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
  // 翻页也走开关：_loadMore 用的就是这个 service，之前没过开关，
  // 搜完翻页会把已关掉的源又翻回来。
  late final _service = SearchService(disabledSources: widget.store.disabledSources);
  List<VideoItem> _items = [];
  Map<String, int> _perSource = {};
  // 逐源状态（源名 -> 状态）：还在搜… / 12 条 / 超时（15秒），后台再试… /
  // 超时（15秒），已试 3 次 / 没结果。搜了几秒就停、页面一片空白、
  // 用户不知道哪个源在搜、哪个死了——状态必须逐源显示出来。
  Map<String, String> _sourceStatus = {};
  List<String> _queriedNames = [];
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
      _sourceStatus = {};
      _queriedNames = [];
      _mappedQuery = mapSearchQuery(q);
      _lastQuery = q;
      _page = 1;
      _hasMore = false;
    });
    // 先读缓存：搜过的词立刻显示，后台再刷新。缓存里可能有已关掉的源的旧条目，
    // 先按开关过滤掉。
    final cached = widget.store.loadSearchCache(q);
    if (cached.isNotEmpty && mounted) {
      final visible = cached.where((v) => !widget.store.disabledSources.contains(v.source)).toList();
      setState(() => _items = _filters.apply(visible));
    }
    final enabled = _enabledSources;
    final svc = SearchService(
        sources: enabled.where((s) => _filters.sourceIds.isEmpty || _filters.sourceIds.contains(s.id)).toList());
    // 先把要查的源都标成“还在搜”，回来的源再逐个改状态。
    final queried = svc.sources;
    setState(() {
      _queriedNames = queried.map((s) => s.name).toList();
      _sourceStatus = {for (final s in queried) s.name: '还在搜…'};
    });
    final results = await svc.searchAll(q,
        filters: _filters,
        onResult: (partial) {
          if (!mounted) return;
          final merged = partial.expand((r) => r.items).toList();
          final counts = <String, int>{};
          final status = Map<String, String>.from(_sourceStatus);
          for (final r in partial) {
            counts[r.sourceName] = r.items.length;
            status[r.sourceName] =
                r.error != null ? '${r.error}，后台再试…' : '${r.items.length} 条';
          }
          setState(() {
            _items = merged;
            _perSource = counts;
            _sourceStatus = status;
          });
        },
        // 慢的源后台再试回来：去重后并进结果，状态改成补回的条数。
        onRetried: (retried) {
          if (!mounted) return;
          setState(() {
            final seen = _items.map((v) => v.id).toSet();
            _items = [..._items, ...retried.items.where((v) => !seen.contains(v.id))];
            _perSource[retried.sourceName] = (_perSource[retried.sourceName] ?? 0) + retried.items.length;
            _sourceStatus[retried.sourceName] = '${retried.items.length} 条（后台补回）';
          });
        },
        // 3 次都失败：状态从“后台再试”改成最终原因，不让用户一直等。
        onRetryFailed: (failed) {
          if (!mounted) return;
          setState(() {
            _sourceStatus[failed.sourceName] = failed.error ?? '失败';
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

  void _openWebSource(Source s) {
    final q = _lastQuery ?? '';
    final url = q.isEmpty ? s.webHomeUrl : s.webSearchUrl(q);
    if (url.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WebSourceBrowser(
        title: q.isEmpty ? s.name : '${s.name}：$q',
        url: url,
        sourceId: s.id,
        store: widget.store,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final sources = _enabledSources;
    // 成人动漫源（Hanime1/HanimeOne）要过 Cloudflare 验证，App 里直接搜不到，
    // 只能去内置浏览器里搜；按钮放这里，有词就带词搜，没词就开首页。
    final webSources = sources.where((s) => s.webViewOnly).toList();
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
                // “全部”是切换：全选时点一下取消全选（一个都不选），
                // 再点一次恢复全选；只选了部分时点一下也是恢复全选。
                onSelected: (_) => setState(() {
                  _filters = _filters.copyWith(
                      sourceIds: _filters.sourceIds.isEmpty
                          ? const {SearchFilters.noneMarker}
                          : <String>{});
                }),
              ),
              ...sources.map((s) => FilterChip(
                    label: Text(s.name),
                    selected: _filters.sourceIds.isEmpty || _filters.sourceIds.contains(s.id),
                    onSelected: (on) {
                      final ids = Set<String>.from(_filters.sourceIds)
                        ..remove(SearchFilters.noneMarker);
                      if (_filters.sourceIds.isEmpty) {
                        ids.addAll(sources.map((e) => e.id));
                      }
                      if (on) {
                        ids.add(s.id);
                      } else {
                        ids.remove(s.id);
                      }
                      setState(() {
                        // 全选了就回到“空 = 全部”；一个都不剩就记成全不选标记。
                        _filters = _filters.copyWith(
                            sourceIds: ids.isEmpty
                                ? const {SearchFilters.noneMarker}
                                : ids.length == sources.length
                                    ? <String>{}
                                    : ids);
                      });
                    },
                  )),
            ],
          ),
          // 成人动漫源走内置浏览器（要过 Cloudflare 验证，App 里直接搜不到）。
          if (webSources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('成人动漫源要过验证，App 里直接搜不到，去内置浏览器里看：',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: webSources
                        .map((s) => OutlinedButton(
                              onPressed: () => _openWebSource(s),
                              child: Text(_lastQuery == null || _lastQuery!.isEmpty
                                  ? '打开 ${s.name}'
                                  : '去 ${s.name} 搜「$_lastQuery」'),
                            ))
                        .toList(),
                  ),
                ],
              ),
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
          // 逐源状态：搜到多少条 / 还在搜 / 超时 / 失败，一眼看清哪个源死了。
          if (_sourceStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _queriedNames
                    .where((n) => _sourceStatus.containsKey(n))
                    .map((n) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('$n ${_sourceStatus[n]}',
                              style: TextStyle(color: _statusColor(_sourceStatus[n]!), fontSize: 12)),
                        ))
                    .toList(),
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
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _filters.selectsNone
                          ? const Text('没选任何源，点“全部”恢复全选再搜',
                              style: TextStyle(color: Colors.white38))
                          : _lastQuery == null
                              ? const Text('输入关键词搜全部源',
                                  style: TextStyle(color: Colors.white38))
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('没搜到结果',
                                        style: TextStyle(
                                            color: Colors.white, fontSize: 16)),
                                    const SizedBox(height: 10),
                                    ..._emptyReasonLines().map((l) => Padding(
                                          padding: const EdgeInsets.only(bottom: 4),
                                          child: Text(l,
                                              style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 13)),
                                        )),
                                  ],
                                ),
                    ),
                  )
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

  Color _statusColor(String s) {
    if (s.contains('已试') || s.contains('失败')) return Colors.redAccent;
    if (s.contains('超时') || s.contains('还在搜') || s.contains('再试')) {
      return Colors.orange;
    }
    if (s.contains('条')) return Colors.greenAccent;
    return Colors.white54; // 没结果
  }

  /// 空结果时写明原因：是源超时/失败了，还是源回来了但确实没结果，
  /// 还是搜到了但被筛选条件滤掉了。不要只剩空白页。
  List<String> _emptyReasonLines() {
    final lines = <String>[];
    final failed = <String>[];
    var anyEmpty = false;
    var anyOk = false;
    for (final n in _queriedNames) {
      final s = _sourceStatus[n];
      if (s == null) continue;
      if (s.contains('已试') || s.contains('超时') || s.contains('失败')) {
        failed.add('$n：$s');
      } else if (s == '没结果') {
        anyEmpty = true;
      } else if (s.contains('条')) {
        anyOk = true;
      }
    }
    if (anyOk) {
      lines.add('搜到了结果，但都被筛选条件（时长 / 画质 / 分类）滤掉了，');
      lines.add('试试放宽条件再搜。');
      return lines;
    }
    lines.addAll(failed);
    if (failed.isNotEmpty) {
      lines.add('不是没这个片，是源没回来；换个词或等一会儿再试。');
    } else if (anyEmpty) {
      lines.add('各源都回来了，确实没有匹配「$_lastQuery」的片，换个词试试。');
    } else {
      lines.add('换个词试试。');
    }
    return lines;
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
