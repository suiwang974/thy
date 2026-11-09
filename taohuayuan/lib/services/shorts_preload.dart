import 'dart:async';

import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import 'stream_resolver.dart';

/// 第 66 条：真预加载——提前给后面 1–2 条建播放器并 initialize，
/// 滑过去直接用现成的播，不用等 initialize。
/// 只解析地址不算预加载（v15 的教训）：`StreamResolver.prefetch` 只把
/// 直链地址解析进缓存，滑过去后 `_init` 仍要现做
/// `VideoPlayerController.networkUrl(...).initialize()`（打开流、拉头、
/// 缓冲前几秒），慢网下这一步就是转圈圈。initialize 才是慢的那一步，
/// 所以预加载必须把 initialize 也提前做完。
/// 预建的播放器只缓冲不播放（静音、循环待命）；滑远及时释放，省内存和流量。
/// 注意：签名直链的源（eporner/pornhub/xhamster）解析结果不进缓存，
/// resolve 本身也要现算——预加载把解析和 initialize 一起提前做了。

/// 要提前建播放器的下标：当前往后 1、2 条（越界的不要）。
/// 供单元测试直接验。
List<int> preloadIndices(int current, int total, {int ahead = 2}) {
  final out = <int>[];
  for (var k = 1; k <= ahead; k++) {
    if (current + k < total) out.add(current + k);
  }
  return out;
}

/// 预加载窗口：当前 ±2 段以内才留着，滑远了就释放。
/// 和第 64 条的保活窗口同一半径：页面本身在 ±2 内保活，
/// 预加载的播放器只给还没建页面的那两段准备。
/// 供单元测试直接验。
bool keepPreloaded(int index, int current, {int radius = 2}) =>
    (index - current).abs() <= radius;

/// 预加载好的一段：播放器已 initialize，只等被页面接手。
/// stream 是解析出来的直链（页面拿它当当前地址、切画质用）。
class PreloadedShort {
  final VideoPlayerController controller;
  final ResolvedStream stream;
  const PreloadedShort(this.controller, this.stream);
}

/// 建一个预加载播放器：解析直链 -> 建播放器 -> initialize -> 静音循环待命。
/// 解析不到 / 是预览 / 初始化失败返回 null，页面走老路（官方播放器兜底）。
typedef ShortControllerBuilder = Future<PreloadedShort?> Function(VideoItem item);

class _PreloadEntry {
  final Future<PreloadedShort?> future;
  /// 页面已接手（take 等过这个 future）：建好直接归页面，别进缓存、别释放。
  bool taken = false;
  /// 已废弃（retry/换流时调 drop/reset）：建好也直接释放。
  bool dropped = false;
  _PreloadEntry(this.future);
}

class ShortsPreloader {
  ShortsPreloader({ShortControllerBuilder? builder})
      : _builder = builder ?? _defaultBuilder;

  final ShortControllerBuilder _builder;
  final Map<String, _PreloadEntry> _building = {};
  final Map<String, PreloadedShort> _ready = {};
  Set<String> _windowIds = {};

  /// 预加载当前往后 1–2 条（不 await，fire-and-forget）；
  /// 窗口外的现成播放器释放掉。滑到新位置、刷新、切标签时都调一次。
  void precache(List<VideoItem> items, int current) {
    _windowIds = {
      for (final i in preloadIndices(current, items.length)) items[i].id
    };
    for (final id in _ready.keys.toList()) {
      if (!_windowIds.contains(id)) {
        final gone = _ready.remove(id);
        if (gone != null) unawaited(gone.controller.dispose());
      }
    }
    for (final i in preloadIndices(current, items.length)) {
      final item = items[i];
      if (_ready.containsKey(item.id) || _building.containsKey(item.id)) {
        continue;
      }
      final entry = _PreloadEntry(_builder(item));
      _building[item.id] = entry;
      unawaited(entry.future.then((built) {
        _building.remove(item.id);
        if (built == null) return;
        // 已被页面接手：所有权归页面，不进缓存、不释放。
        if (entry.taken) return;
        // 已废弃、或建好的时候已经滑远了：直接释放，别留着占内存和流量。
        if (entry.dropped || !_windowIds.contains(item.id)) {
          unawaited(built.controller.dispose());
          return;
        }
        _ready[item.id] = built;
      }));
    }
  }

  /// 页面 _init 时调：有现成的直接接手（所有权转给页面，从缓存里拿掉）；
  /// 正在建的等它建好（和预加载共用同一个 Future，不重复建）；
  /// 都没有就现建一个（兜底，和以前一样）。
  Future<PreloadedShort?> take(VideoItem item) async {
    final ready = _ready.remove(item.id);
    if (ready != null) return ready;
    final entry = _building.remove(item.id);
    if (entry != null) {
      entry.taken = true;
      return entry.future;
    }
    return _builder(item);
  }

  /// 废弃某条的预加载（重试直链时调：旧地址可能已过期/被限流，别再拿它播）。
  void drop(String itemId) {
    final ready = _ready.remove(itemId);
    if (ready != null) unawaited(ready.controller.dispose());
    final entry = _building[itemId];
    if (entry != null) entry.dropped = true;
  }

  /// 流换了一批（点栏刷新）：旧的预加载全废，新流按新位置重新预加载。
  /// 在建的也标记废弃，建好直接释放；已被页面接手的不动（归页面所有）。
  void reset() {
    for (final p in _ready.values) {
      unawaited(p.controller.dispose());
    }
    _ready.clear();
    for (final e in _building.values) {
      e.dropped = true;
    }
    _windowIds = {};
  }

  /// 现成（已 initialize、等接手）的有几段（测试/调试用）。
  int get readyCount => _ready.length;

  void dispose() {
    for (final p in _ready.values) {
      unawaited(p.controller.dispose());
    }
    _ready.clear();
    for (final e in _building.values) {
      e.dropped = true;
    }
    _building.clear();
    _windowIds = {};
  }

  /// 默认建造：解析直链 -> 建播放器 -> initialize -> 静音循环待命。
  static Future<PreloadedShort?> _defaultBuilder(VideoItem item) async {
    final stream = await StreamResolver.resolve(item);
    if (stream == null || stream.isPreview) return null;
    VideoPlayerController? c;
    try {
      c = VideoPlayerController.networkUrl(Uri.parse(stream.url),
          httpHeaders: stream.headers);
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(0);
      return PreloadedShort(c, stream);
    } catch (_) {
      try {
        await c?.dispose();
      } catch (_) {}
      return null;
    }
  }
}
