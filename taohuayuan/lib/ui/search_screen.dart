import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/search_map.dart';
import '../data/sources.dart';
import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/search_status.dart';
import '../services/store.dart';
import '../services/web_search.dart';
import 'player_screen.dart';
import 'web_source_browser.dart';
import 'widgets.dart';

/// 搜索页：输入中文词，先映射成英文，再默认查全部已启用的源（不单选）。
/// - 源多选（默认全选）：点芯片开关某个源；
/// - 分类 / 时长 / 画质 1080p+ / 排序（相关/最新/最多看/最长）；
/// - 中文映射走所有搜索路径（搜、翻页都先过 mapSearchQuery）；
/// - 无封面也收；结果流式上屏（先回来的源先显示）；
/// - 搜过的词先读缓存立刻显示，后台再刷新；底部“加载更多”分页加载。
/// - 结果列表用 CustomScrollView + SliverGrid：整页一起滚（2026-11-09 修第 11 条——
///   之前 Column 里固定内容太多，Expanded 的 ListView 被挤到约 0 高，根本划不动）；
/// - 逐源状态默认只显示一行汇总，点开才看逐源（失败的源点一下进内置浏览器看）。
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
  // 但默认只显示一行汇总（第 11 条：日志式状态不许占满屏），点开才看逐源。
  Map<String, String> _sourceStatus = {};
  List<String> _queriedNames = [];
  bool _statusExpanded = false;
  bool _searching = false;
  bool _loadingMore = false;
  String _mappedQuery = '';
  String? _lastQuery;
  int _page = 1;
  bool _hasMore = false;
  // 第 36 条：搜索代际——两次 _doSearch 并发时，旧搜索的回调直接忽略，
  // 不许互相覆盖结果/计数。
  int _searchGen = 0;
  // 各源返回的原始总数（去重前）；显示数永远从 _items 派生，两边恒一致，
  // 差额写明口径（“各源返回 X 条，去重后显示 Y 条”）。
  int _rawReturned = 0;

  SearchFilters _filters = const SearchFilters();

  // 第 41 条：WebView 内搜索用的隐藏 WebView（1x1 藏在页里，不占地方）：
  // niacg/lianzu11/hanime 的纯 HTTP 请求会被 WAF/Cloudflare 拦，
  // 只有真浏览器指纹能过验证，所以搜索页挂一个隐藏 WebView 替它们搜。
  late final WebViewController _webController;
  late final WebSearchRunner _webRunner;

  @override
  void initState() {
    super.initState();
    _webController = WebViewController();
    _webRunner = WebSearchRunner(_webController);
    _service.webSearch = _webRunner;
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _controller.text = widget.initialQuery!;
      _doSearch(widget.initialQuery!);
    }
  }

  List<Source> get _enabledSources =>
      _service.sources.where((s) => !widget.store.disabledSources.contains(s.id)).toList();

  /// 逐源状态汇总（一行）：共 X 个源：Y 个有结果 · Z 个还在搜 · W 个失败 · V 个没结果。
  /// 第 45 条：只有真有条目的状态才算“有结果”（"0 条" 不算，见 search_status.dart）。
  String _statusSummary() {
    if (_queriedNames.isEmpty) return '';
    var ok = 0, searching = 0, failed = 0, empty = 0;
    for (final n in _queriedNames) {
      final s = _sourceStatus[n] ?? '';
      if (s.contains('已试') || s.contains('失败')) {
        failed++;
      } else if (s.contains('还在搜') || s.contains('再试')) {
        searching++;
      } else if (s == '没结果') {
        empty++;
      } else if (statusHasResults(s)) {
        ok++;
      } else {
        searching++;
      }
    }
    final parts = <String>[];
    if (ok > 0) parts.add('$ok 个有结果');
    if (searching > 0) parts.add('$searching 个还在搜');
    if (failed > 0) parts.add('$failed 个失败');
    if (empty > 0) parts.add('$empty 个没结果');
    return '共 ${_queriedNames.length} 个源：${parts.join(' · ')}';
  }

  /// 显示列表里各源的条数（第 36 条：计数一律从 _items 派生，
  /// 各源计数之和恒等于总数，不再由 onResult/onRetried 各自加）。
  Map<String, int> _countsFromItems(List<VideoItem> items) {
    final counts = <String, int>{};
    for (final v in items) {
      final name = _sourceNameById(v.source);
      counts[name] = (counts[name] ?? 0) + 1;
    }
    return counts;
  }

  String _sourceNameById(String id) {
    for (final s in allSources()) {
      if (s.id == id) return s.name;
    }
    return id;
  }

  Future<void> _doSearch(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    final gen = ++_searchGen;
    await widget.store.recordSearchTerm(q);
    setState(() {
      _searching = true;
      _items = [];
      _perSource = {};
      _sourceStatus = {};
      _queriedNames = [];
      _statusExpanded = false;
      _mappedQuery = mapSearchQuery(q);
      _lastQuery = q;
      _page = 1;
      _hasMore = false;
      _rawReturned = 0;
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
        sources: enabled.where((s) => _filters.sourceIds.isEmpty || _filters.sourceIds.contains(s.id)).toList(),
        // 第 41 条：每轮搜索都带上 WebView 搜索入口，否则 niacg/lianzu11/hanime
        // 又会被构造器当成纯 HTTP 源滤掉。
        webSearch: _webRunner);
    // 先把要查的源都标成“还在搜”，回来的源再逐个改状态。
    final queried = svc.sources;
    setState(() {
      _queriedNames = queried.map((s) => s.name).toList();
      _sourceStatus = {for (final s in queried) s.name: '还在搜…'};
    });
    final results = await svc.searchAll(q,
        filters: _filters,
        onResult: (partial) {
          if (!mounted || gen != _searchGen) return;
          final merged = SearchService.dedupeById(partial.expand((r) => r.items).toList());
          final status = Map<String, String>.from(_sourceStatus);
          for (final r in partial) {
            // 第 45 条：0 条就是“没结果”，别写“0 条”——写了就会被汇总当成“有结果”。
            status[r.sourceName] = statusTextForResult(r);
          }
          setState(() {
            _items = merged;
            _perSource = _countsFromItems(merged);
            _rawReturned = partial.fold(0, (s, r) => s + r.returnedCount);
            _sourceStatus = status;
          });
        },
        // 慢的源后台再试回来：去重后并进结果，状态改成补回的条数。
        onRetried: (retried) {
          if (!mounted || gen != _searchGen) return;
          setState(() {
            final seen = _items.map((v) => v.id).toSet();
            _items = [..._items, ...retried.items.where((v) => !seen.contains(v.id))];
            _perSource = _countsFromItems(_items);
            _rawReturned += retried.returnedCount;
            _sourceStatus[retried.sourceName] = '${retried.items.length} 条（后台补回）';
          });
        },
        // 3 次都失败：状态从“后台再试”改成最终原因，不让用户一直等。
        onRetryFailed: (failed) {
          if (!mounted || gen != _searchGen) return;
          setState(() {
            _sourceStatus[failed.sourceName] = failed.error ?? '失败';
          });
        });
    if (!mounted || gen != _searchGen) return;
    final merged = SearchService.dedupeById(results.expand((r) => r.items).toList());
    if (merged.isNotEmpty) await widget.store.saveSearchCache(q, merged);
    setState(() {
      _items = merged;
      _perSource = _countsFromItems(merged);
      _rawReturned = results.fold(0, (s, r) => s + r.returnedCount);
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
        _perSource = _countsFromItems(_items);
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

  /// Hanime：两个镜像域名是同一站，内容一样（第 20 条），只显示一个按钮；
  /// 先走能进的 hanimeone.me，打不开浏览器里自动切 hanime1.me。
  void _openHanime() {
    final q = _lastQuery ?? '';
    final mapped = q.isEmpty ? '' : mapSearchQuery(q);
    final url = q.isEmpty
        ? 'https://${HanimeSource.preferredHost}/'
        : 'https://${HanimeSource.preferredHost}/search?query=${Uri.encodeComponent(mapped)}&page=1&genre=%E8%A3%8F%E7%95%AA';
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WebSourceBrowser(
        title: q.isEmpty ? 'Hanime（成人动漫）' : 'Hanime：$q',
        url: url,
        sourceId: 'hanimeone',
        store: widget.store,
      ),
    ));
  }

  /// 失败的源 chip 点一下：按源名找到源，用它的搜索地址进内置浏览器看
  /// （第 11 条：失败的源不能只剩一行死状态，要能点进去看）。
  void _openWebSourceByName(String name) {
    final all = allSources().where((s) => !widget.store.disabledSources.contains(s.id)).toList();
    final match = all.where((s) => s.name == name).toList();
    if (match.isEmpty) return;
    _openWebSource(match.first);
  }

  bool _isFailedStatus(String s) => s.contains('已试') || s.contains('失败') || s.contains('超时');

  @override
  Widget build(BuildContext context) {
    final sources = _enabledSources;
    // 要过验证的源（niacg、lianzu11、hanime1、hanimeone）不走 HTTP 搜索，
    // 只给内置浏览器按钮；_service.webSources 是已启用、webViewOnly 的源
    // （_service.sources 里已经没有它们了，之前按 sources.where(webViewOnly)
    // 取是空的，按钮根本出不来）。
    final webSources = _service.webSources;
    final hasHanime = webSources.any((s) => s.id == 'hanime1' || s.id == 'hanimeone');
    final otherWeb = webSources.where((s) => s.id != 'hanime1' && s.id != 'hanimeone').toList();
    final summary = _statusSummary();
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        title: const Text('搜索', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: CustomScrollView(
        slivers: [
          // 第 41 条：WebView 内搜索用的隐藏 WebView（1x1 藏着，不占地方不挡手）。
          SliverToBoxAdapter(
            child: Offstage(
              offstage: true,
              child: SizedBox(
                width: 1,
                height: 1,
                child: WebViewWidget(controller: _webController),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
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
          ),
          if (_mappedQuery.isNotEmpty && _mappedQuery != _lastQuery)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('已按“$_lastQuery → $_mappedQuery”去各源搜',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ),
          // 源多选（默认全选）。
          SliverToBoxAdapter(
            child: _chipRow(
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
          ),
          // 第 41 条：这三个源现在也一起搜（隐藏 WebView 过验证），结果直接进列表；
          // 下面这排按钮是“直接逛站”的入口，不是搜不到的替代品。
          if (webSources.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('上面三个源也会一起搜；想直接逛站就点这里：',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (hasHanime)
                          OutlinedButton(
                            onPressed: _openHanime,
                            child: const Text('打开 Hanime 浏览'),
                          ),
                        ...otherWeb.map((s) => OutlinedButton(
                              onPressed: () => _openWebSource(s),
                              child: Text('打开 ${s.name} 浏览'),
                            )),
                      ],
                    ),
                    if (hasHanime)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('Hanime1 和 HanimeOne 是同一站的两个镜像，hanimeone.me 能进，hanime1.me 打不开自动切。',
                            style: TextStyle(color: Colors.white38, fontSize: 11)),
                      ),
                  ],
                ),
              ),
            ),
          // 分类。
          SliverToBoxAdapter(
            child: _chipRow(
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
          ),
          // 时长 + 画质 + 排序。
          SliverToBoxAdapter(
            child: _chipRow(
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
          ),
          SliverToBoxAdapter(
            child: _chipRow(
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
          ),
          if (_searching)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.pinkAccent)),
                    SizedBox(width: 10),
                    Text('正在查全部源…先回来的先显示', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ),
          // 逐源状态：默认只显示一行汇总，点开才看逐源（第 11 条）；
          // 失败的源点一下进内置浏览器看（不是死状态）。
          if (summary.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () => setState(() => _statusExpanded = !_statusExpanded),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(summary,
                                style: const TextStyle(color: Colors.white70, fontSize: 13)),
                          ),
                          Icon(_statusExpanded ? Icons.expand_less : Icons.expand_more,
                              color: Colors.white54, size: 18),
                        ],
                      ),
                    ),
                    if (_statusExpanded)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: _queriedNames
                              .where((n) => _sourceStatus.containsKey(n))
                              .map((n) {
                            final s = _sourceStatus[n]!;
                            final failed = _isFailedStatus(s);
                            final chip = Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('$n $s',
                                      style: TextStyle(color: _statusColor(s), fontSize: 12)),
                                  if (failed) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.open_in_browser,
                                        color: Colors.white54, size: 12),
                                  ],
                                ],
                              ),
                            );
                            return failed
                                ? InkWell(
                                    onTap: () => _openWebSourceByName(n),
                                    child: chip,
                                  )
                                : chip;
                          }).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (!_searching && _items.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  // 第 36 条：总数 = 显示的条数，各源计数之和恒等于它；
                  // 去重/过滤掉的写明口径，不再出现“总数比单源还小”。
                  '共 ${_items.length} 条${_perSource.isEmpty ? '' : '（${_perSource.entries.map((e) => '${e.key} ${e.value}').join(' · ')}）'}'
                  '${_rawReturned > _items.length ? ' · 各源返回 $_rawReturned 条，去重后显示 ${_items.length} 条' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ),
          if (_items.isEmpty && !_searching)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
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
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => VideoCard(item: _items[i], onTap: () => _open(_items[i])),
                  childCount: _items.length,
                ),
              ),
            ),
          if (_hasMore && !_searching && _items.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
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
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }

  Color _statusColor(String s) {
    if (s.contains('已试') || s.contains('失败')) return Colors.redAccent;
    if (s.contains('超时') || s.contains('还在搜') || s.contains('再试')) {
      return Colors.orange;
    }
    // 第 45 条："0 条" 不是有结果，按没结果算（灰色）。
    if (statusHasResults(s)) return Colors.greenAccent;
    return Colors.white54; // 没结果
  }

  /// 空结果时写明原因：是源超时/失败了，还是源回来了但确实没结果，
  /// 还是搜到了但被筛选条件滤掉了。不要只剩空白页。
  /// 第 45 条：只有真有条目的状态才算“搜到了”（statusHasResults），
  /// "0 条" 不算；三个走 WebView 的源回来了但没解析出条目时，告诉用户
  /// 去内置浏览器里直接搜，别再赖筛选条件。
  List<String> _emptyReasonLines() {
    final lines = <String>[];
    final failed = <String>[];
    final webEmpty = <String>[];
    var anyEmpty = false;
    var anyOk = false;
    for (final n in _queriedNames) {
      final s = _sourceStatus[n];
      if (s == null) continue;
      if (s.contains('已试') || s.contains('超时') || s.contains('失败')) {
        failed.add('$n：$s');
      } else if (s == '没结果') {
        anyEmpty = true;
        if (_isWebOnlySource(n)) webEmpty.add(n);
      } else if (statusHasResults(s)) {
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
    if (webEmpty.isNotEmpty) {
      lines.add('${webEmpty.join(' / ')}在内置浏览器里能打开，点上面状态条进去直接搜这个词看看。');
    }
    return lines;
  }

  bool _isWebOnlySource(String name) {
    for (final s in allSources()) {
      if (s.name == name) return s.webViewOnly;
    }
    return false;
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
