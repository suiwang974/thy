// 基线指标聚合（实现 6）：D3 定义的四项指标，用纯函数从一页页的实测结果算出来。
// 测量本身（真机 + 真站）留待早上按 baseline-runbook 跑；这里是算数的工具与
// 归档格式，单测用合成数据验。分母为 0 的指标记 null（D3：记 N/A，不计入均值）。

/// 一页的实测结果（一次打开目标视频页并起播）。
class BaselinePageResult {
  const BaselinePageResult({
    required this.pageId,
    required this.sourceId,
    required this.success,
    this.ttcMs,
    this.hadFallback = false,
    this.recovered = false,
    this.throughputRatio,
  });

  /// 页标识（源 id + 序号，如 xhamster-1）。
  final String pageId;

  final String sourceId;

  /// 15 秒内是否产出 confidence ≥ 0.5 且分片能 200 取回的候选。
  final bool success;

  /// 成功时的耗时（onPageStarted → 首个合格候选进 UI 的毫秒数）；失败时 null。
  final int? ttcMs;

  /// 是否触发过回退或重试。
  final bool hadFallback;

  /// 首轮未达标、经回退/重试后最终达标。
  final bool recovered;

  /// 吞吐倍率（单连接耗时 ÷ 并发耗时）；只在测速页上有值。
  final double? throughputRatio;
}

/// 四项基线指标的汇总。
class BaselineReport {
  const BaselineReport({
    required this.totalPages,
    required this.succeededPages,
    required this.successRate,
    required this.ttcP50Ms,
    required this.ttcP90Ms,
    required this.recoveryRate,
    required this.throughputMedian,
    required this.throughputMin,
  });

  final int totalPages;
  final int succeededPages;

  /// 成功率（达标页数 / 尝试页数）；没有页数时 null。
  final double? successRate;

  /// 耗时 p50/p90（毫秒，只取成功页的 TTC）；没有成功样本时 null。
  final int? ttcP50Ms;
  final int? ttcP90Ms;

  /// 恢复率（回退后达标页数 / 触发过回退的页数）；没有触发回退的页时 null。
  final double? recoveryRate;

  /// 吞吐倍率的中位数与最小值；没有测速样本时 null。
  final double? throughputMedian;
  final double? throughputMin;

  /// 从一页页的实测结果算出四项指标。
  /// 分位数用 nearest-rank：排序后取第 ceil(p*n) 个。
  static BaselineReport compute(List<BaselinePageResult> pages) {
    final total = pages.length;
    final succeeded = pages.where((p) => p.success).length;
    final double? successRate = total == 0 ? null : succeeded / total;

    final ttcs = pages
        .where((p) => p.success && p.ttcMs != null)
        .map((p) => p.ttcMs!)
        .toList()
      ..sort();
    final int? ttcP50Ms = _percentile(ttcs, 0.5);
    final int? ttcP90Ms = _percentile(ttcs, 0.9);

    final fallbackPages = pages.where((p) => p.hadFallback).toList();
    final double? recoveryRate = fallbackPages.isEmpty
        ? null
        : fallbackPages.where((p) => p.recovered).length /
            fallbackPages.length;

    final ratios = pages
        .where((p) => p.throughputRatio != null)
        .map((p) => p.throughputRatio!)
        .toList()
      ..sort();
    double? throughputMedian;
    double? throughputMin;
    if (ratios.isNotEmpty) {
      throughputMin = ratios.first;
      final mid = ratios.length ~/ 2;
      throughputMedian = ratios.length.isOdd
          ? ratios[mid]
          : (ratios[mid - 1] + ratios[mid]) / 2;
    }

    return BaselineReport(
      totalPages: total,
      succeededPages: succeeded,
      successRate: successRate,
      ttcP50Ms: ttcP50Ms,
      ttcP90Ms: ttcP90Ms,
      recoveryRate: recoveryRate,
      throughputMedian: throughputMedian,
      throughputMin: throughputMin,
    );
  }

  static int? _percentile(List<int> sorted, double p) {
    if (sorted.isEmpty) return null;
    var rank = (p * sorted.length).ceil();
    if (rank < 1) rank = 1;
    if (rank > sorted.length) rank = sorted.length;
    return sorted[rank - 1];
  }

  /// 归档格式：直接 jsonEncode 存文件。
  Map<String, dynamic> toJson() => {
        'totalPages': totalPages,
        'succeededPages': succeededPages,
        'successRate': successRate,
        'ttcP50Ms': ttcP50Ms,
        'ttcP90Ms': ttcP90Ms,
        'recoveryRate': recoveryRate,
        'throughputMedian': throughputMedian,
        'throughputMin': throughputMin,
      };
}
