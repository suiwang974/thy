// 基线指标聚合单测（合成数据）。
import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/baseline/baseline.dart';

BaselinePageResult page(
  String id, {
  bool success = true,
  int? ttcMs,
  bool hadFallback = false,
  bool recovered = false,
  double? throughputRatio,
}) =>
    BaselinePageResult(
      pageId: id,
      sourceId: id.split('-').first,
      success: success,
      ttcMs: ttcMs,
      hadFallback: hadFallback,
      recovered: recovered,
      throughputRatio: throughputRatio,
    );

void main() {
  group('BaselineReport.compute', () {
    test('空列表：全部指标 null，总数 0', () {
      final r = BaselineReport.compute([]);
      expect(r.totalPages, 0);
      expect(r.succeededPages, 0);
      expect(r.successRate, isNull);
      expect(r.ttcP50Ms, isNull);
      expect(r.ttcP90Ms, isNull);
      expect(r.recoveryRate, isNull);
      expect(r.throughputMedian, isNull);
      expect(r.throughputMin, isNull);
    });

    test('成功率与 TTC p50/p90（nearest-rank）', () {
      final r = BaselineReport.compute([
        page('a-1', ttcMs: 100),
        page('a-2', ttcMs: 200),
        page('a-3', ttcMs: 300),
        page('a-4', ttcMs: 400),
        page('a-5', success: false),
      ]);
      expect(r.totalPages, 5);
      expect(r.succeededPages, 4);
      expect(r.successRate, closeTo(0.8, 1e-9));
      // TTC 样本 [100,200,300,400]：p50 取第 ceil(0.5*4)=2 个 = 200；
      // p90 取第 ceil(0.9*4)=4 个 = 400。
      expect(r.ttcP50Ms, 200);
      expect(r.ttcP90Ms, 400);
    });

    test('TTC 只取成功页的样本，失败页的 ttc 不计', () {
      final r = BaselineReport.compute([
        page('a-1', success: false, ttcMs: 9999),
        page('a-2', ttcMs: 500),
      ]);
      expect(r.ttcP50Ms, 500);
      expect(r.ttcP90Ms, 500);
    });

    test('恢复率：只在触发过回退的页里算', () {
      final r = BaselineReport.compute([
        page('a-1', success: true, hadFallback: true, recovered: true),
        page('a-2', success: false, hadFallback: true, recovered: false),
        page('a-3', success: true),
      ]);
      expect(r.recoveryRate, closeTo(0.5, 1e-9));
    });

    test('没有触发回退的页时恢复率 null', () {
      final r = BaselineReport.compute([page('a-1'), page('a-2')]);
      expect(r.recoveryRate, isNull);
    });

    test('吞吐倍率中位数与最小值', () {
      final r = BaselineReport.compute([
        page('a-1', throughputRatio: 1.2),
        page('a-2', throughputRatio: 2.0),
        page('a-3', throughputRatio: 3.0),
        page('a-4', throughputRatio: 4.0),
      ]);
      expect(r.throughputMedian, closeTo(2.5, 1e-9));
      expect(r.throughputMin, closeTo(1.2, 1e-9));
    });

    test('奇数个倍率时中位数取中间值', () {
      final r = BaselineReport.compute([
        page('a-1', throughputRatio: 1.0),
        page('a-2', throughputRatio: 2.0),
        page('a-3', throughputRatio: 9.0),
      ]);
      expect(r.throughputMedian, closeTo(2.0, 1e-9));
    });

    test('toJson 字段齐全', () {
      final r = BaselineReport.compute([page('a-1', ttcMs: 123)]);
      final j = r.toJson();
      expect(j['totalPages'], 1);
      expect(j['successRate'], closeTo(1.0, 1e-9));
      expect(j['ttcP50Ms'], 123);
      expect(j['recoveryRate'], isNull);
    });
  });
}
