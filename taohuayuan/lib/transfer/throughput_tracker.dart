/// 一次下载的实测记录（纯数据，由 TransferEngine 在每次下载结束时填）。
class RunMeasurement {
  /// 本次下载落盘的总字节数。
  final int bytes;

  /// 本次下载的墙钟耗时。
  final Duration elapsed;

  /// 本次实际用的并发数。
  final int concurrency;

  /// 本次遇到的 429 次数（服务端压制信号）。
  final int status429;

  /// 本次遇到的 403 次数（服务端压制信号）。
  final int status403;

  /// 失败的分片/段数。
  final int failedSegments;

  /// 分片/段总数。
  final int totalSegments;

  const RunMeasurement({
    required this.bytes,
    required this.elapsed,
    required this.concurrency,
    this.status429 = 0,
    this.status403 = 0,
    this.failedSegments = 0,
    this.totalSegments = 0,
  });

  /// 本次字节速率（字节/秒）。耗时为 0 时按 0 计。
  double get bytesPerSecond {
    if (elapsed.inMicroseconds <= 0) return 0;
    return bytes / (elapsed.inMicroseconds / 1e6);
  }

  /// 本次失败率。总数为 0 时按 0 计。
  double get failureRate {
    if (totalSegments <= 0) return 0;
    return failedSegments / totalSegments;
  }

  /// 是否被服务端压制（429/403 任一出现即算）。
  bool get suppressed => status429 > 0 || status403 > 0;
}

/// 吞吐跟踪器：攒每次下载的实测，算吞吐倍率与稳定达标。
/// - 基线：单连接（concurrency == 1）跑出的字节速率；没有基线时
///   ratioVsBaseline 为 null（倍率未知，只能看“相对上次是否提升”）。
/// - 基线按 D3 做法建立：同一候选、同一 CDN、同一网络，先用单连接
///   跑一遍——这一步是真机手动测量流程，本地回环服务器测出的
///   倍率没有意义，所以引擎默认不自动建基线。
class ThroughputTracker {
  /// 单连接基线速率（字节/秒），未建立时为 null。
  double? baselineBytesPerSecond;

  final List<RunMeasurement> _history = [];

  List<RunMeasurement> get history => List.unmodifiable(_history);

  RunMeasurement? get last => _history.isEmpty ? null : _history.last;

  void record(RunMeasurement measurement) {
    if (measurement.concurrency == 1 &&
        baselineBytesPerSecond == null) {
      baselineBytesPerSecond = measurement.bytesPerSecond;
    }
    _history.add(measurement);
  }

  /// 本次相对单连接基线的吞吐倍率；无基线时为 null。
  double? ratioVsBaseline(RunMeasurement measurement) {
    final base = baselineBytesPerSecond;
    if (base == null || base <= 0) return null;
    return measurement.bytesPerSecond / base;
  }

  /// 本次相对上一次的速率提升比例；没有上一次时为 null。
  double? improvementVsLast(RunMeasurement measurement) {
    if (_history.length < 2) return null;
    final prev = _history[_history.length - 2].bytesPerSecond;
    if (prev <= 0) return null;
    return (measurement.bytesPerSecond - prev) / prev;
  }

  /// 最近 [runs] 次是否全部达标：倍率 ≥ target、失败率 ≤ maxFailure、
  /// 且无压制信号。无基线时倍率未知，算不达标（不谎报稳定）。
  bool stableAtTarget({
    required int runs,
    required double targetRatio,
    required double maxFailureRate,
  }) {
    if (_history.length < runs) return false;
    final recent = _history.sublist(_history.length - runs);
    for (final m in recent) {
      final ratio = ratioVsBaseline(m);
      if (ratio == null || ratio < targetRatio) return false;
      if (m.failureRate > maxFailureRate) return false;
      if (m.suppressed) return false;
    }
    return true;
  }

  void clear() {
    baselineBytesPerSecond = null;
    _history.clear();
  }
}
