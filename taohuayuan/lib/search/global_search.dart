// 全局搜索与地址解析：判定地址栏输入是网址还是搜索词，并提供搜索引擎选择与失败回退逻辑。

/// 支持的搜索引擎。
enum SearchEngine {
  bing,
  google,
  duckduckgo;

  /// 界面上展示的引擎名称。
  String get displayName => switch (this) {
        SearchEngine.bing => 'Bing',
        SearchEngine.google => 'Google',
        SearchEngine.duckduckgo => 'DuckDuckGo',
      };

  /// 把搜索词拼成该引擎的搜索页地址。
  String searchUrl(String query) {
    final String encoded = Uri.encodeQueryComponent(query);
    return switch (this) {
      SearchEngine.bing => 'https://www.bing.com/search?q=$encoded',
      SearchEngine.google => 'https://www.google.com/search?q=$encoded',
      SearchEngine.duckduckgo => 'https://duckduckgo.com/?q=$encoded',
    };
  }
}

/// 地址栏输入解析后的导航结果。
class ResolvedNavigation {
  const ResolvedNavigation({
    required this.url,
    required this.isSearch,
    this.engine,
    this.query,
  });

  /// 最终要加载的地址。
  final String url;

  /// true 表示这是搜索词拼出的搜索页，false 表示用户直接输入的地址。
  final bool isSearch;

  /// isSearch 为 true 时使用的引擎，否则为 null。
  final SearchEngine? engine;

  /// isSearch 为 true 时的原始搜索词，否则为 null。
  final String? query;
}

/// 地址栏输入的解析器。
class GlobalSearch {
  const GlobalSearch._();

  /// 默认的搜索引擎顺序。
  static const List<SearchEngine> defaultEngineOrder = <SearchEngine>[
    SearchEngine.bing,
    SearchEngine.google,
    SearchEngine.duckduckgo,
  ];

  /// 把地址栏输入解析成一次导航；空输入返回 null。
  /// 判定顺序：空串 → 含空格当搜索词 → http/https 且 host 含 '.' 当直接地址 →
  /// 无 scheme 的已知源域名补 https 打开 → 其余当搜索词。
  static ResolvedNavigation? resolve(
    String input, {
    SearchEngine engine = SearchEngine.bing,
    bool Function(String host)? isKnownHost,
  }) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    // 含空格：整体当搜索词。
    if (trimmed.contains(' ')) {
      return ResolvedNavigation(
        url: engine.searchUrl(trimmed),
        isSearch: true,
        engine: engine,
        query: trimmed,
      );
    }

    // 带 http/https scheme 且 host 含 '.'：直接打开。
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.contains('.')) {
      return ResolvedNavigation(url: trimmed, isSearch: false);
    }

    // 无 scheme 的裸域名，且是已知的源域名：补 https 打开。
    if (!trimmed.contains('/') &&
        trimmed.contains('.') &&
        isKnownHost != null &&
        isKnownHost(trimmed)) {
      return ResolvedNavigation(url: 'https://$trimmed/', isSearch: false);
    }

    // 其余一律当搜索词。
    return ResolvedNavigation(
      url: engine.searchUrl(trimmed),
      isSearch: true,
      engine: engine,
      query: trimmed,
    );
  }

  /// 返回 order 里 current 的下一个引擎；不在 order 里或已是最后一个返回 null。
  static SearchEngine? nextEngine(SearchEngine current, List<SearchEngine> order) {
    final int index = order.indexOf(current);
    if (index == -1 || index + 1 >= order.length) {
      return null;
    }
    return order[index + 1];
  }
}

/// 搜索引擎打不开时按顺序换下一个。
class SearchEngineFallback {
  SearchEngineFallback(
    this.query, {
    List<SearchEngine> order = GlobalSearch.defaultEngineOrder,
  }) : _order = List<SearchEngine>.unmodifiable(order);

  final String query;
  final List<SearchEngine> _order;

  int _tried = 0;

  /// 已尝试过的引擎数（firstUrl 不计，advance 每调一次加 1）。
  int get triedCount => _tried;

  /// 是否已无引擎可试（firstUrl 用掉第一个后，advance 再无下一个）。
  bool get exhausted => _tried + 1 >= _order.length;

  /// 第一个引擎的搜索页地址。
  String firstUrl() {
    if (_order.isEmpty) {
      throw StateError('没有可用的搜索引擎');
    }
    return _order.first.searchUrl(query);
  }

  /// 下一个引擎的搜索页地址；耗尽返回 null。
  String? advance() {
    if (_order.isEmpty) {
      throw StateError('没有可用的搜索引擎');
    }
    if (_tried + 1 >= _order.length) {
      return null;
    }
    _tried++;
    return _order[_tried].searchUrl(query);
  }
}
