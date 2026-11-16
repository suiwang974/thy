import 'throughput_tracker.dart';
import 'transfer_config.dart';

/// 自适应并发（AIMD 式）：从保守起步值开始，按每次下载的实测逐档调。
/// - 被压制（429/403）或失败率超限：立刻减半回退（向 min 靠），并冷却。
/// - 已达目标倍率：保持（不再往上探，免得自找压制）。
/// - 未达目标且速率还在提升：上调一档。
/// - 未达目标但速率已平台（提升 < 阈值）：保持（再加并发也没收益）。
/// - 无基线时倍率未知：只看“相对上次是否提升”来决定上调/保持。
/// 纯逻辑，不碰网络，单测可全覆盖。
class ConcurrencyRamp {
  final TransferConfig config;
  final ThroughputTracker tracker;

  int _current;
  int _cooldownLeft = 0;

  ConcurrencyRamp({
    required this.config,
    required this.tracker,
  }) : _current = config.startConcurrency;

  int get current => _current;

  /// 根据刚记入 tracker 的最新一次实测，算出下一轮并发数。
  /// 调用方应在 tracker.record(measurement) 之后调。
  int next() {
    final m = tracker.last;
    if (m == null) return _current;

    // 冷却期内：不做新的调整决定。
    if (_cooldownLeft > 0) {
      _cooldownLeft--;
      return _current;
    }

    // 压制或失败率超限：减半回退。
    if (m.suppressed || m.failureRate > config.maxFailureRate) {
      final down = (_current ~/ 2).clamp(config.minConcurrency, _current);
      if (down < _current) {
        _current = down;
        _cooldownLeft = config.cooldownRuns;
      }
      return _current;
    }

    // 已达目标倍率：保持。
    final ratio = tracker.ratioVsBaseline(m);
    if (ratio != null && ratio >= config.targetRatio) {
      return _current;
    }

    // 还在提升：上调一档。
    final improvement = tracker.improvementVsLast(m);
    if (improvement == null || improvement >= config.improvementThreshold) {
      if (_current < config.maxConcurrency) {
        _current = (_current + config.rampStep)
            .clamp(config.minConcurrency, config.maxConcurrency);
        _cooldownLeft = config.cooldownRuns;
      }
      return _current;
    }

    // 平台期：保持。
    return _current;
  }

  /// 是否已“连续多次稳定达标”（D5d §4 的完成标志）。
  bool get isStableAtTarget {
    return tracker.stableAtTarget(
      runs: config.stableRuns,
      targetRatio: config.targetRatio,
      maxFailureRate: config.maxFailureRate,
    );
  }
}
