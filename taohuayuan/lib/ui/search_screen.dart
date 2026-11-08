import 'package:flutter/material.dart';

import '../data/search_map.dart';
import '../data/sources.dart';
import '../models/video_item.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 搜索页：输入中文词，先映射成英文，再默认查全部已启用的源（不单选）。
/// 片库是本地目录，瞬间出结果；网络源陆续流进来，按源分组显示条数。
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
  List<SourceResult> _results = [];
  bool _searching = false;
  String _mappedQuery = '';
  String? _lastQuery;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _controller.text = widget.initialQuery!;
      _doSearch(widget.initialQuery!);
    }
  }

  Future<void> _doSearch(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _results = [];
      _mappedQuery = mapSearchQuery(q);
      _lastQuery = q;
    });
    final enabled = _service.sources.where((s) => !widget.store.disabledSources.contains(s.id)).toList();
    final svc = SearchService(sources: enabled);
    await svc.searchAll(q, onResult: (partial) {
      if (mounted) setState(() => _results = partial);
    });
    if (mounted) setState(() => _searching = false);
  }

  void _open(VideoItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, store: widget.store),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final total = _results.fold<int>(0, (n, r) => n + r.items.length);
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
            padding: const EdgeInsets.all(16),
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
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.pinkAccent)),
                  SizedBox(width: 10),
                  Text('正在查全部源…', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          if (!_searching && _results.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [Text('共 $total 条', style: const TextStyle(color: Colors.white70, fontSize: 13))],
              ),
            ),
          Expanded(
            child: _results.isEmpty && !_searching
                ? const Center(child: Text('输入关键词搜全部源', style: TextStyle(color: Colors.white38)))
                : ListView(
                    children: _results.map((r) {
                      if (r.items.isEmpty && r.error == null) return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SectionTitle('${r.sourceName} · ${r.items.length} 条',
                              subtitle: r.error != null ? '该源暂不可用' : null),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                              ),
                              itemCount: r.items.length,
                              itemBuilder: (_, i) => VideoCard(item: r.items[i], onTap: () => _open(r.items[i])),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}
