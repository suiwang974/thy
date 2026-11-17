import 'dart:async';
import 'dart:io';

/// 单个分片下载任务。expectedSize 为空表示未知大小（不做完成判定）；
/// 非空时只有文件长度恰好等于它才算已完成，否则走 Range 续传。
class SegmentTask {
  final String url;
  final String savePath;
  final int index;
  final int? expectedSize;
  final Map<String, String> headers;
  final String? referer;

  /// BYTERANGE 分片用：要取的字节区间 [rangeStart, rangeEnd]（rangeEnd 含）。
  /// 都为空时按普通分片处理。续传时 Range 从 rangeStart + 已有长度开始。
  final int? rangeStart;
  final int? rangeEnd;

  const SegmentTask({
    required this.url,
    required this.savePath,
    required this.index,
    this.expectedSize,
    this.headers = const {},
    this.referer,
    this.rangeStart,
    this.rangeEnd,
  });
}

/// 一次 downloadAll 的实测统计：供 ThroughputTracker/ConcurrencyRamp
/// 判断是否被服务端压制（429/403）或失败率超限。
class SegmentRunStats {
  final int tasks;
  final int done;
  final int failed;
  final int status403;
  final int status429;
  final int attempts;

  const SegmentRunStats({
    required this.tasks,
    required this.done,
    required this.failed,
    required this.status403,
    required this.status429,
    required this.attempts,
  });
}

/// 多分片并发下载器：按 concurrency 分批并行；断点续传以 expectedSize
/// 为准；403 时按 headerVariants 轮换请求头重试。
class SegmentDownloader {
  final int concurrency;
  final int maxAttempts;

  /// 最近一次 downloadAll 的统计；还没跑过时为 null。
  SegmentRunStats? lastStats;

  int _runStatus403 = 0;
  int _runStatus429 = 0;
  int _runAttempts = 0;

  static const String altUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  SegmentDownloader({this.concurrency = 4, this.maxAttempts = 3});

  Future<void> downloadAll(
    List<SegmentTask> tasks, {
    int? concurrency,
    void Function(int done, int total)? onProgress,
  }) async {
    if (tasks.isEmpty) return;
    final client = HttpClient();
    final limit = (concurrency ?? this.concurrency) < 1
        ? 1
        : (concurrency ?? this.concurrency);
    var done = 0;
    _runStatus403 = 0;
    _runStatus429 = 0;
    _runAttempts = 0;
    try {
      for (var i = 0; i < tasks.length; i += limit) {
        final end = i + limit < tasks.length ? i + limit : tasks.length;
        final batch = tasks.sublist(i, end);
        await Future.wait([
          for (final task in batch)
            _download(client, task).then((_) {
              done++;
              onProgress?.call(done, tasks.length);
            }),
        ]);
      }
    } finally {
      client.close(force: true);
      lastStats = SegmentRunStats(
        tasks: tasks.length,
        done: done,
        failed: tasks.length - done,
        status403: _runStatus403,
        status429: _runStatus429,
        attempts: _runAttempts,
      );
    }
  }

  /// 三组请求头轮换：[0] 原样；[1] 去掉 Referer、换备用 UA；
  /// [2] Referer 只留 origin、换备用 UA。attempt 超出时用最后一组。
  List<Map<String, String>> headerVariants(SegmentTask task) {
    final original = Map<String, String>.from(task.headers);
    if (task.referer != null && task.referer!.isNotEmpty) {
      original['Referer'] = task.referer!;
    }
    final noReferer = Map<String, String>.from(task.headers)
      ..remove('Referer')
      ..['User-Agent'] = altUserAgent;
    final originReferer = Map<String, String>.from(task.headers)
      ..['User-Agent'] = altUserAgent;
    if (task.referer != null && task.referer!.isNotEmpty) {
      final uri = Uri.tryParse(task.referer!);
      if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
        originReferer['Referer'] = '${uri.scheme}://${uri.host}';
      } else {
        originReferer.remove('Referer');
      }
    } else {
      originReferer.remove('Referer');
    }
    return [original, noReferer, originReferer];
  }

  Future<void> _download(HttpClient client, SegmentTask task) async {
    final file = File(task.savePath);
    if (task.expectedSize != null &&
        await file.exists() &&
        await file.length() == task.expectedSize) {
      return;
    }

    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      _runAttempts++;
      try {
        var start = 0;
        if (await file.exists()) {
          start = await file.length();
          if (task.expectedSize != null && start > task.expectedSize!) {
            await file.delete();
            start = 0;
          }
        }
        final variants = headerVariants(task);
        final headers = variants[attempt < variants.length
            ? attempt
            : variants.length - 1];
        final request = await client.getUrl(Uri.parse(task.url));
        headers.forEach(request.headers.set);
        // Range 计算：BYTERANGE 分片从 rangeStart 起；普通分片从已有长度起。
        final rangeBase = task.rangeStart ?? 0;
        final rangeEnd = task.rangeEnd;
        final rangeRequested =
            rangeBase > 0 || rangeEnd != null || start > 0;
        if (rangeRequested) {
          final from = rangeBase + start;
          request.headers.set(HttpHeaders.rangeHeader,
              'bytes=$from-${rangeEnd ?? ''}');
        }
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          if (response.statusCode == HttpStatus.forbidden) _runStatus403++;
          if (response.statusCode == 429) _runStatus429++;
          await response.drain<void>();
          throw HttpException('HTTP ${response.statusCode}');
        }
        if (response.statusCode == HttpStatus.ok && rangeRequested) {
          // 服务器忽略 Range 回 200：整包读下来再切出要的区间，
          // 不能直接追加（会把整文件拼进分片里）。
          final all = await response.fold<List<int>>(
              <int>[], (list, chunk) => list..addAll(chunk));
          final from = rangeBase + start;
          final to = rangeEnd ?? all.length - 1;
          if (from > to || from >= all.length) {
            throw StateError('segment size mismatch');
          }
          final sliceEnd = to < all.length - 1 ? to : all.length - 1;
          final slice = all.sublist(from, sliceEnd + 1);
          await file.writeAsBytes(slice,
              mode: start > 0 ? FileMode.append : FileMode.write);
        } else {
          // 服务器忽略 Range 回 200 时，已有部分内容必须先截断再从头写，
          // 否则新旧数据会拼错。
          final mode = response.statusCode == HttpStatus.ok && start > 0
              ? FileMode.write
              : FileMode.append;
          await response.pipe(file.openWrite(mode: mode));
        }
        if (task.expectedSize != null &&
            await file.length() != task.expectedSize) {
          throw StateError('segment size mismatch');
        }
        return;
      } catch (e) {
        lastError = e;
        if (attempt < maxAttempts - 1) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }
    throw Exception(
        'Segment ${task.index} failed after $maxAttempts attempts: $lastError');
  }
}
