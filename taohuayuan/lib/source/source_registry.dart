// 源绑定层（编排层 D5c §3）：每个源一行绑定数据。
// 嗅探器核心不读这里——绑定只决定“某源用哪几路适配器、按什么顺序、能不能回滚”。
// 新加源只加一行绑定 + 一份规则 JSON，不改核心代码。
// 数据来源：lib/data/sources.dart 的 allSources()（id/域名/搜索方式）与队列里的 10 源表。

/// 六路适配器（与 Kotlin 侧 CandidateSource 一一对应）。
enum AdapterKind {
  network,
  serviceWorker,
  pageScript,
  videoListen,
  ruleConcat,
  blobMse,
}

/// 搜索方式：http = 走 HTTP 搜索；sniffOnly = 不走 HTTP 搜索，
/// 只走内置浏览器（entryUrl 导航后嗅探）；both = 两者都行。
enum SearchMode { http, sniffOnly, both }

class SourceBinding {
  final String id;
  final String displayName;
  final List<String> hosts;
  final List<AdapterKind> adapterPath;
  final SearchMode searchMode;
  final String entryUrl;
  final List<String> mirrors;
  final Map<AdapterKind, bool> flags;
  final String rollbackKey;
  final bool enabled;

  const SourceBinding({
    required this.id,
    required this.displayName,
    required this.hosts,
    required this.adapterPath,
    required this.searchMode,
    required this.entryUrl,
    this.mirrors = const [],
    required this.flags,
    required this.rollbackKey,
    this.enabled = true,
  });

  SourceBinding copyWith({bool? enabled, Map<AdapterKind, bool>? flags}) {
    return SourceBinding(
      id: id,
      displayName: displayName,
      hosts: hosts,
      adapterPath: adapterPath,
      searchMode: searchMode,
      entryUrl: entryUrl,
      mirrors: mirrors,
      flags: flags ?? this.flags,
      rollbackKey: rollbackKey,
      enabled: enabled ?? this.enabled,
    );
  }

  /// 该源当前启用的适配器（按 adapterPath 顺序，flags 关掉的跳过）。
  List<AdapterKind> get activeAdapters =>
      adapterPath.where((k) => flags[k] != false).toList();
}

const List<AdapterKind> _defaultPath = [
  AdapterKind.network,
  AdapterKind.serviceWorker,
  AdapterKind.pageScript,
  AdapterKind.videoListen,
  AdapterKind.ruleConcat,
  AdapterKind.blobMse,
];

Map<AdapterKind, bool> _allEnabled() => {
      for (final k in AdapterKind.values) k: true,
    };

class SourceRegistry {
  static final List<SourceBinding> _bindings = [
    SourceBinding(
      id: 'xhamster',
      displayName: 'XHamster',
      hosts: ['xhamster.com', 'www.xhamster.com'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.both,
      entryUrl: 'https://xhamster.com/',
      flags: _allEnabled(),
      rollbackKey: 'xhamster-v1',
    ),
    SourceBinding(
      id: 'eporner',
      displayName: 'Eporner',
      hosts: ['eporner.com', 'www.eporner.com'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.http,
      entryUrl: 'https://www.eporner.com/',
      flags: _allEnabled(),
      rollbackKey: 'eporner-v1',
    ),
    SourceBinding(
      id: 'rule34videos',
      displayName: 'Rule34Video',
      hosts: ['rule34-videos.com', 'www.rule34-videos.com'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.both,
      entryUrl: 'https://rule34-videos.com/',
      flags: _allEnabled(),
      rollbackKey: 'rule34videos-v1',
    ),
    SourceBinding(
      id: 'xvideos',
      displayName: 'XVideos',
      hosts: ['xvideos.com', 'www.xvideos.com'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.http,
      entryUrl: 'https://www.xvideos.com/',
      flags: _allEnabled(),
      rollbackKey: 'xvideos-v1',
    ),
    SourceBinding(
      id: 'pornhub',
      displayName: 'Pornhub',
      hosts: ['pornhub.com', 'www.pornhub.com'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.http,
      entryUrl: 'https://www.pornhub.com/',
      flags: _allEnabled(),
      rollbackKey: 'pornhub-v1',
    ),
    SourceBinding(
      id: 'spankbang',
      displayName: 'SpankBang',
      hosts: ['spankbang.com', 'www.spankbang.com'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.http,
      entryUrl: 'https://spankbang.com/',
      flags: _allEnabled(),
      rollbackKey: 'spankbang-v1',
    ),
    SourceBinding(
      id: 'hanime1',
      displayName: 'Hanime1 (hanime1.me)',
      hosts: ['hanime1.me', 'www.hanime1.me'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.sniffOnly,
      entryUrl: 'https://hanime1.me/',
      mirrors: ['hanimeone.me'],
      flags: _allEnabled(),
      rollbackKey: 'hanime1-v1',
    ),
    SourceBinding(
      id: 'hanimeone',
      displayName: 'HanimeOne (hanimeone.me)',
      hosts: ['hanimeone.me', 'www.hanimeone.me'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.sniffOnly,
      entryUrl: 'https://hanimeone.me/',
      mirrors: ['hanime1.me'],
      flags: _allEnabled(),
      rollbackKey: 'hanimeone-v1',
    ),
    SourceBinding(
      id: 'niacg',
      displayName: 'Niacg',
      hosts: ['niacg.com', 'www.niacg.com'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.sniffOnly,
      entryUrl: 'https://www.niacg.com/',
      flags: _allEnabled(),
      rollbackKey: 'niacg-v1',
    ),
    SourceBinding(
      id: 'lianzu11',
      displayName: 'Lianzu11',
      hosts: ['lianzu11.com', 'www.lianzu11.com'],
      adapterPath: _defaultPath,
      searchMode: SearchMode.sniffOnly,
      entryUrl: 'https://lianzu11.com/',
      flags: _allEnabled(),
      rollbackKey: 'lianzu11-v1',
    ),
  ];

  /// 运行时覆盖（回滚开关）：id -> 覆盖后的绑定。会话启动时热读取。
  static final Map<String, SourceBinding> _overrides = {};

  static List<SourceBinding> get bindings =>
      _bindings.map((b) => _overrides[b.id] ?? b).toList();

  static SourceBinding? bindingFor(String id) {
    for (final b in bindings) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// 按域名找绑定（精确匹配或子域名后缀匹配）。
  static SourceBinding? bindingForHost(String host) {
    final h = host.toLowerCase();
    for (final b in bindings) {
      for (final known in b.hosts) {
        if (h == known || h.endsWith('.$known')) return b;
      }
    }
    return null;
  }

  /// 整源下线（回滚开关一级）。
  static void disable(String sourceId) {
    final b = bindingFor(sourceId);
    if (b != null) _overrides[sourceId] = b.copyWith(enabled: false);
  }

  static void enable(String sourceId) {
    _overrides.remove(sourceId);
  }

  /// 只关某一路适配器（回滚开关二级）。
  static void disableAdapter(String sourceId, AdapterKind kind) {
    final b = bindingFor(sourceId);
    if (b == null) return;
    final flags = Map<AdapterKind, bool>.from(b.flags)..[kind] = false;
    _overrides[sourceId] = b.copyWith(flags: flags);
  }

  static void enableAdapter(String sourceId, AdapterKind kind) {
    final b = bindingFor(sourceId);
    if (b == null) return;
    final flags = Map<AdapterKind, bool>.from(b.flags)..[kind] = true;
    _overrides[sourceId] = b.copyWith(flags: flags);
  }

  /// 测试/重置用：清掉全部运行时覆盖。
  static void resetAll() {
    _overrides.clear();
  }
}
