import '../transfer/download_candidate.dart';

/// 候选仓库（编排层 D5c）：去重、按 confidence 排序、按任务缓存。
/// 与 Kotlin 侧 CandidateNormalizer 的去重规则一致：
/// 同规范化 id 只留 confidence 最高者；多源命中升权 0.05（上限 1.0）。
class CandidateStore {
  final int maxCandidates;
  final Map<String, DownloadCandidate> _byId = {};
  final Map<String, Set<String>> _sourcesById = {};

  CandidateStore({this.maxCandidates = 50});

  static String normalizeId(String url) {
    final hash = url.indexOf('#');
    final base = hash == -1 ? url : url.substring(0, hash);
    return base.toLowerCase();
  }

  void addAll(List<DownloadCandidate> candidates) {
    for (final c in candidates) {
      final id = normalizeId(c.url);
      _sourcesById.putIfAbsent(id, () => <String>{}).add(c.source);
      final prev = _byId[id];
      if (prev == null || c.confidence > prev.confidence) {
        _byId[id] = c;
      }
    }
    if (_byId.length > maxCandidates) {
      final ordered = sorted;
      _byId
        ..clear()
        ..addEntries(ordered.take(maxCandidates).map((c) => MapEntry(normalizeId(c.url), c)));
      _sourcesById.removeWhere((id, _) => !_byId.containsKey(id));
    }
  }

  /// 按 confidence 降序；多源命中的升权 0.05（上限 1.0）。
  List<DownloadCandidate> get sorted {
    final list = _byId.values.map((c) {
      final n = _sourcesById[normalizeId(c.url)]?.length ?? 1;
      if (n >= 2 && c.confidence < 1.0) {
        return DownloadCandidate(
          url: c.url,
          headers: c.headers,
          referer: c.referer,
          cookies: c.cookies,
          mime: c.mime,
          confidence: (c.confidence + 0.05).clamp(0.0, 1.0),
          source: c.source,
          expiresAt: c.expiresAt,
        );
      }
      return c;
    }).toList();
    list.sort((a, b) => b.confidence.compareTo(a.confidence));
    return list;
  }

  int get length => _byId.length;

  bool get isEmpty => _byId.isEmpty;

  void clear() {
    _byId.clear();
    _sourcesById.clear();
  }
}
