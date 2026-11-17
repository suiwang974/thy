/// 传输速度配置：所有速度旋钮集中在这里，起步值保守，
// 按真机压制实测逐档上调（见 ConcurrencyRamp）。
// 数字的来历：D3 基线“吞吐倍率 = 单连接耗时 ÷ 当前并发耗时”，
// 起步 4 是 1DM+ 类工具的常见保守值；上限 16 是单机再往上
// 收益递减、反而容易触发 429/403 的经验值——最终以真机实测为准。
class TransferConfig {
  /// 起步并发分片数（HLS 分片并发 / 直链多段数共用此值时取其一）。
  final int startConcurrency;

  /// 并发下限：压制回退到的最低值（1 = 单连接）。
  final int minConcurrency;

  /// 并发上限：再往上不探。
  final int maxConcurrency;

  /// 每次上调的档位（1 档）。
  final int rampStep;

  /// 直链多段下载的段数（与 HLS 分片并发独立）。
  final int directPartCount;

  /// 目标吞吐倍率（相对单连接基线）。
  final double targetRatio;

  /// 连续多少次达标算“稳定达标”。
  final int stableRuns;

  /// 失败率上限：超过就回退。
  final double maxFailureRate;

  /// 每次调整后冷却几轮（期间不做新的调整决定）。
  final int cooldownRuns;

  /// 吞吐提升多少才算“有提升”（低于此值视为平台期）。
  final double improvementThreshold;

  const TransferConfig({
    this.startConcurrency = 4,
    this.minConcurrency = 1,
    this.maxConcurrency = 16,
    this.rampStep = 1,
    this.directPartCount = 4,
    this.targetRatio = 2.0,
    this.stableRuns = 3,
    this.maxFailureRate = 0.05,
    this.cooldownRuns = 1,
    this.improvementThreshold = 0.05,
  })  : assert(startConcurrency >= 1),
        assert(minConcurrency >= 1),
        assert(maxConcurrency >= startConcurrency),
        assert(minConcurrency <= startConcurrency),
        assert(rampStep >= 1),
        assert(directPartCount >= 1),
        assert(targetRatio >= 1.0),
        assert(stableRuns >= 1),
        assert(maxFailureRate >= 0 && maxFailureRate <= 1),
        assert(cooldownRuns >= 0);

  TransferConfig copyWith({
    int? startConcurrency,
    int? minConcurrency,
    int? maxConcurrency,
    int? rampStep,
    int? directPartCount,
    double? targetRatio,
    int? stableRuns,
    double? maxFailureRate,
    int? cooldownRuns,
    double? improvementThreshold,
  }) {
    return TransferConfig(
      startConcurrency: startConcurrency ?? this.startConcurrency,
      minConcurrency: minConcurrency ?? this.minConcurrency,
      maxConcurrency: maxConcurrency ?? this.maxConcurrency,
      rampStep: rampStep ?? this.rampStep,
      directPartCount: directPartCount ?? this.directPartCount,
      targetRatio: targetRatio ?? this.targetRatio,
      stableRuns: stableRuns ?? this.stableRuns,
      maxFailureRate: maxFailureRate ?? this.maxFailureRate,
      cooldownRuns: cooldownRuns ?? this.cooldownRuns,
      improvementThreshold:
          improvementThreshold ?? this.improvementThreshold,
    );
  }
}
