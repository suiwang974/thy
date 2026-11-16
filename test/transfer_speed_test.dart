import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/transfer/concurrency_ramp.dart';
import 'package:taohuayuan/transfer/download_candidate.dart';
import 'package:taohuayuan/transfer/segment_downloader.dart';
import 'package:taohuayuan/transfer/throughput_tracker.dart';
import 'package:taohuayuan/transfer/transfer_config.dart';
import 'package:taohuayuan/transfer/transfer_engine.dart';

RunMeasurement m({
  required int bytes,
  required int ms,
  required int concurrency,
  int status429 = 0,
  int status403 = 0,
  int failed = 0,
  int total = 0,
}) =>
    RunMeasurement(
      bytes: bytes,
      elapsed: Duration(milliseconds: ms),
      concurrency: concurrency,
      status429: status429,
      status403: status403,
      failedSegments: failed,
      totalSegments: total,
    );

void main() {
  group('TransferConfig 默认值（保守起步）', () {
    test('起步 4 / 下限 1 / 上限 16 / 目标 2.0x / 稳定 3 次', () {
      const c = TransferConfig();
      expect(c.startConcurrency, 4);
      expect(c.minConcurrency, 1);
      expect(c.maxConcurrency, 16);
      expect(c.rampStep, 1);
      expect(c.directPartCount, 4);
      expect(c.targetRatio, 2.0);
      expect(c.stableRuns, 3);
      expect(c.maxFailureRate, 0.05);
    });
  });

  group('ThroughputTracker', () {
    test('速率/失败率/压制标志', () {
      final t = ThroughputTracker();
      final x = m(bytes: 2000000, ms: 1000, concurrency: 4,
          failed: 1, total: 20, status429: 2);
      expect(x.bytesPerSecond, 2000000);
      expect(x.failureRate, 0.05);
      expect(x.suppressed, isTrue);
      expect(t.ratioVsBaseline(x), isNull); // 无基线
      t.record(x);
      expect(t.last, x);
    });

    test('单连接跑一遍建基线，倍率 = 本次速率 ÷ 基线', () {
      final t = ThroughputTracker();
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 1));
      expect(t.baselineBytesPerSecond, 1000000);
      final fast = m(bytes: 3000000, ms: 1000, concurrency: 4);
      t.record(fast);
      expect(t.ratioVsBaseline(fast), closeTo(3.0, 0.001));
      expect(t.improvementVsLast(fast), closeTo(2.0, 0.001));
    });

    test('连续 3 次达标算稳定；一次压制就不稳定；无基线不算稳定', () {
      final t = ThroughputTracker();
      // 无基线：3 次“快”也不算稳定（倍率未知，不谎报）。
      for (var i = 0; i < 3; i++) {
        t.record(m(bytes: 3000000, ms: 1000, concurrency: 4));
      }
      expect(t.stableAtTarget(runs: 3, targetRatio: 2.0, maxFailureRate: 0.05),
          isFalse);
      // 建基线后再来 3 次达标。
      final t2 = ThroughputTracker();
      t2.record(m(bytes: 1000000, ms: 1000, concurrency: 1));
      for (var i = 0; i < 3; i++) {
        t2.record(m(bytes: 2500000, ms: 1000, concurrency: 4));
      }
      expect(t2.stableAtTarget(runs: 3, targetRatio: 2.0, maxFailureRate: 0.05),
          isTrue);
      // 一次压制就破稳定。
      t2.record(m(bytes: 2500000, ms: 1000, concurrency: 4, status429: 1));
      expect(t2.stableAtTarget(runs: 3, targetRatio: 2.0, maxFailureRate: 0.05),
          isFalse);
    });
  });

  group('ConcurrencyRamp', () {
    test('起步值 = config.startConcurrency', () {
      final r = ConcurrencyRamp(
          config: const TransferConfig(), tracker: ThroughputTracker());
      expect(r.current, 4);
    });

    test('速率提升就上调一档；平台期保持', () {
      final t = ThroughputTracker();
      final r = ConcurrencyRamp(
          config: const TransferConfig(cooldownRuns: 0), tracker: t);
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 4));
      expect(r.next(), 5); // 首次无上次可比，视为可探
      t.record(m(bytes: 1500000, ms: 1000, concurrency: 5));
      expect(r.next(), 6); // 提升 50%
      t.record(m(bytes: 1520000, ms: 1000, concurrency: 6));
      expect(r.next(), 6); // 提升 1.3% < 5%，平台期保持
    });

    test('压制立刻减半回退，不低于下限', () {
      final t = ThroughputTracker();
      final r = ConcurrencyRamp(
          config: const TransferConfig(cooldownRuns: 0), tracker: t);
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 4));
      r.next(); // 4 -> 5
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 5, status429: 1));
      expect(r.next(), 2); // 5 ~/ 2 = 2
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 2, status403: 1));
      expect(r.next(), 1); // 2 ~/ 2 = 1（下限）
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 1, status429: 3));
      expect(r.next(), 1); // 已到下限，不再降
    });

    test('失败率超限也回退；达目标倍率保持不上调', () {
      final t = ThroughputTracker();
      final r = ConcurrencyRamp(
          config: const TransferConfig(cooldownRuns: 0), tracker: t);
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 1)); // 基线
      t.record(m(bytes: 2500000, ms: 1000, concurrency: 4, failed: 2, total: 10));
      expect(r.next(), 2); // 失败率 20% > 5%，回退
      final t2 = ThroughputTracker();
      final r2 = ConcurrencyRamp(
          config: const TransferConfig(cooldownRuns: 0), tracker: t2);
      t2.record(m(bytes: 1000000, ms: 1000, concurrency: 1));
      t2.record(m(bytes: 3000000, ms: 1000, concurrency: 4));
      expect(r2.next(), 4); // 倍率 3.0 ≥ 2.0，保持
      expect(r2.isStableAtTarget, isFalse); // 才 1 次达标，未满 3 次
    });

    test('冷却期内不做新的调整', () {
      final t = ThroughputTracker();
      final r = ConcurrencyRamp(
          config: const TransferConfig(cooldownRuns: 1), tracker: t);
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 4));
      expect(r.next(), 5); // 上调，冷却 1
      t.record(m(bytes: 1500000, ms: 1000, concurrency: 5));
      expect(r.next(), 5); // 冷却中，保持
      t.record(m(bytes: 1600000, ms: 1000, concurrency: 5));
      expect(r.next(), 6); // 冷却结束，继续上调
    });

    test('不超过上限', () {
      final t = ThroughputTracker();
      final r = ConcurrencyRamp(
          config: const TransferConfig(
              startConcurrency: 16, maxConcurrency: 16, cooldownRuns: 0),
          tracker: t);
      t.record(m(bytes: 1000000, ms: 1000, concurrency: 16));
      expect(r.next(), 16);
    });
  });

  group('SegmentDownloader 统计', () {
    late HttpServer server;
    late String base;

    setUpAll(() async {
      final body = Uint8List.fromList(List.generate(1000, (i) => i % 251));
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      server.listen((req) async {
        if (req.uri.path == '/bad') {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('成功一次：lastStats 记 tasks/done；403 三次重试都计数', () async {
      final dir = await Directory.systemTemp.createTemp('speed-test');
      try {
        final dl = SegmentDownloader();
        await dl.downloadAll([
          SegmentTask(
              url: '$base/ok', savePath: '${dir.path}/a', index: 0,
              expectedSize: 1000),
        ]);
        expect(dl.lastStats?.tasks, 1);
        expect(dl.lastStats?.done, 1);
        expect(dl.lastStats?.failed, 0);
        expect(dl.lastStats?.status403, 0);

        final dl2 = SegmentDownloader();
        await expectLater(
            dl2.downloadAll([
              SegmentTask(url: '$base/bad', savePath: '${dir.path}/b', index: 0),
            ]),
            throwsA(anything));
        expect(dl2.lastStats?.tasks, 1);
        expect(dl2.lastStats?.failed, 1);
        expect(dl2.lastStats?.status403, 3); // maxAttempts 3 次都 403
        expect(dl2.lastStats?.attempts, 3);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('TransferEngine 接线', () {
    late HttpServer server;
    late String base;
    late Uint8List fileBytes;

    setUpAll(() async {
      fileBytes = Uint8List.fromList(
          List.generate(200 * 1024, (i) => i % 251));
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      server.listen((req) async {
        if (req.method == 'HEAD') {
          req.response.headers.contentLength = fileBytes.length;
          await req.response.close();
          return;
        }
        final range = req.headers.value('range');
        if (range == null) {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentLength = fileBytes.length;
          req.response.add(fileBytes);
          await req.response.close();
          return;
        }
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        final start = int.parse(match!.group(1)!);
        final end = match.group(2)!.isEmpty
            ? fileBytes.length - 1
            : int.parse(match.group(2)!);
        final slice = fileBytes.sublist(start, end + 1);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers
            .set('Content-Range', 'bytes $start-$end/${fileBytes.length}');
        req.response.headers.contentLength = slice.length;
        req.response.add(slice);
        await req.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('两次下载记两次实测，并发按爬坡从 4 调到 5', () async {
      final dir = await Directory.systemTemp.createTemp('speed-engine');
      try {
        final engine = TransferEngine();
        expect(engine.currentConcurrency, 4);
        for (var i = 0; i < 2; i++) {
          final target = '${dir.path}/file_$i.bin';
          await engine
              .download(DownloadCandidate(url: '$base/file'), target)
              .last;
          expect(await File(target).length(), fileBytes.length);
        }
        expect(engine.tracker.history.length, 2);
        expect(engine.tracker.history.first.bytes, fileBytes.length);
        expect(engine.tracker.history.first.concurrency, 4);
        expect(engine.currentConcurrency, 5);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
