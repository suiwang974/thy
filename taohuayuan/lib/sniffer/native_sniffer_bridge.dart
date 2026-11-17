import '../services/sniffer.dart';
import '../source/source_registry.dart';
import '../source/source_session_policy.dart';
import '../transfer/download_candidate.dart';
import 'candidate_store.dart';
import 'sniffer_channel.dart';

/// 原生嗅探桥（集成任务）：浏览器用的桥接层。
/// 可见浏览器不动（webview_flutter + 旧 Dart 嗅探当保底），原生无头会话
/// 在后台并行跑同一地址；这里负责起会话、跟导航、轮询取候选、进仓库、
/// 转成界面展示的 SniffedMedia、给下载提供真实请求头。
/// 通道抛错一律内部吞掉（返回 false/空列表），浏览器不能因为原生会话
/// 起不来就崩。未知站（binding 为 null）默认六路全开——全局搜索进来的
/// 任意站就是未知站，通用嗅探不挑站。
class NativeSnifferBridge {
  NativeSnifferBridge({SnifferChannel? channel, CandidateStore? store})
      : channel = channel ?? SnifferChannel(),
        store = store ?? CandidateStore();

  final SnifferChannel channel;
  final CandidateStore store;

  bool _running = false;

  bool get isRunning => _running;

  static List<String> adapterChannelNames(List<AdapterKind> kinds) {
    final names = <String>[];
    for (final kind in kinds) {
      switch (kind) {
        case AdapterKind.network:
          names.add('NETWORK');
          break;
        case AdapterKind.serviceWorker:
          names.add('SERVICE_WORKER');
          break;
        case AdapterKind.pageScript:
          names.add('PAGE_SCRIPT');
          break;
        case AdapterKind.videoListen:
          names.add('VIDEO_LISTENER');
          break;
        case AdapterKind.ruleConcat:
          names.add('RULE');
          break;
        case AdapterKind.blobMse:
          names.add('BLOB_MSE');
          break;
      }
    }
    return names;
  }

  static SniffedMedia? candidateToSniffed(DownloadCandidate c) {
    final url = c.url;
    if (url.isEmpty) return null;

    final mime = (c.mime ?? '').toLowerCase();
    final lower = url.toLowerCase();
    var bare = lower;
    final hashIndex = bare.indexOf('#');
    if (hashIndex >= 0) bare = bare.substring(0, hashIndex);
    final queryIndex = bare.indexOf('?');
    if (queryIndex >= 0) bare = bare.substring(0, queryIndex);

    String? kind;
    if (bare.endsWith('.m3u8') || mime.contains('mpegurl')) {
      kind = 'm3u8';
    } else if (bare.endsWith('.mp4') || mime == 'video/mp4') {
      kind = 'mp4';
    } else if (bare.endsWith('.webm') || mime == 'video/webm') {
      kind = 'webm';
    } else if (bare.endsWith('.ts')) {
      kind = 'ts';
    }

    if (kind == null) return null;

    return SniffedMedia(
      url: c.url,
      kind: kind,
      playableOnly: false,
    );
  }

  Future<bool> startSession(String url, SourceBinding? binding) async {
    // 未知站默认能嗅（sniffEnabledFor(null) 为 true）；整源下线才不起。
    if (!sniffEnabledFor(binding)) return false;

    final adapters = adapterChannelNames(activeAdaptersFor(binding));
    try {
      await channel.start(url, adapters: adapters);
      _running = true;
      return true;
    } catch (_) {
      _running = false;
      return false;
    }
  }

  Future<bool> navigateTo(String url, SourceBinding? binding) async {
    if (!sniffEnabledFor(binding)) {
      await stopSession();
      return false;
    }

    if (!_running) {
      return startSession(url, binding);
    }

    final adapters = adapterChannelNames(activeAdaptersFor(binding));
    try {
      await channel.navigate(url, adapters: adapters);
      store.clear();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopSession() async {
    if (!_running) return;
    try {
      await channel.stop();
    } catch (_) {}
    store.clear();
    _running = false;
  }

  Future<void> dispose() async {
    try {
      await channel.dispose();
    } catch (_) {}
    store.clear();
    _running = false;
  }

  Future<List<DownloadCandidate>> pollCandidates() async {
    if (!_running) return <DownloadCandidate>[];
    try {
      final candidates = await channel.getCandidates();
      store.addAll(candidates);
      return store.sorted;
    } catch (_) {
      return store.sorted;
    }
  }

  Map<String, String>? headersFor(String url) {
    final target = _normalizeUrl(url);
    for (final candidate in store.sorted) {
      if (_normalizeUrl(candidate.url) == target) {
        return candidate.effectiveHeaders();
      }
    }
    return null;
  }

  List<SniffedMedia> get sniffedMedia {
    final media = <SniffedMedia>[];
    for (final candidate in store.sorted) {
      final item = candidateToSniffed(candidate);
      if (item != null) media.add(item);
    }
    return media;
  }

  String _normalizeUrl(String url) {
    final lower = url.toLowerCase();
    final hashIndex = lower.indexOf('#');
    return hashIndex >= 0 ? lower.substring(0, hashIndex) : lower;
  }
}
