import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'concurrency_ramp.dart';
import 'download_candidate.dart';
import 'hls_playlist.dart';
import 'segment_downloader.dart';
import 'throughput_tracker.dart';
import 'transfer_config.dart';

/// 传输进度事件。totalBytes 为 -1 表示总量未知（HLS 分片大小事先不知道）。
class TransferProgress {
  final int doneBytes;
  final int totalBytes;
  final String? outputPath;
  final bool done;
  const TransferProgress({
    required this.doneBytes,
    required this.totalBytes,
    this.outputPath,
    this.done = false,
  });
}

/// Dart 传输层：DownloadCandidate -> 文件路径 + 进度流。
/// - 直链文件：Range 探测后多段并行（默认 4 段），不支持 Range 则单连接。
/// - HLS：拉列表 -> 选最高码率变体 -> 并发下分片 -> AES-128 解密 -> 按序合并。
/// - 403：列表/密钥拉取时按请求头轮换重试（原样 -> 去 Referer+备用 UA ->
///   origin Referer+备用 UA），分片 403 走 SegmentDownloader 同一套轮换。
/// - 速度：每次下载结束记一次实测（字节/耗时/429/403/失败率）进
///   ThroughputTracker，ConcurrencyRamp 按实测逐档调下一轮并发数
///   （起步值见 TransferConfig.startConcurrency，默认 4）。
/// - 失败只抛带人话的 StateError，不甩原始堆栈。
class TransferEngine {
  final SegmentDownloader downloader;
  final int partCount;
  final TransferConfig config;
  final ThroughputTracker tracker;
  final ConcurrencyRamp ramp;

  static const _fetchTimeout = Duration(seconds: 20);

  factory TransferEngine({
    SegmentDownloader? downloader,
    int? partCount,
    TransferConfig config = const TransferConfig(),
    ThroughputTracker? tracker,
    ConcurrencyRamp? ramp,
  }) {
    // tracker 与 ramp 必须共用同一个 ThroughputTracker 实例，
    // 否则 ramp 读不到引擎记的实测。
    final t = tracker ?? ThroughputTracker();
    return TransferEngine._internal(
      downloader: downloader ?? SegmentDownloader(),
      partCount: partCount ?? config.directPartCount,
      config: config,
      tracker: t,
      ramp: ramp ?? ConcurrencyRamp(config: config, tracker: t),
    );
  }

  const TransferEngine._internal({
    required this.downloader,
    required this.partCount,
    required this.config,
    required this.tracker,
    required this.ramp,
  });

  /// 下一轮下载要用的并发数（自适应调整后的当前值）。
  int get currentConcurrency => ramp.current;

  Stream<TransferProgress> download(
      DownloadCandidate candidate, String targetPath) async* {
    final stopwatch = Stopwatch()..start();
    final agg = _StatsAgg();
    var failed = false;
    try {
      yield* _downloadInner(candidate, targetPath, agg);
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      stopwatch.stop();
      final size = await File(targetPath).exists()
          ? await File(targetPath).length()
          : 0;
      final total = agg.totalSegments;
      tracker.record(RunMeasurement(
        bytes: size,
        elapsed: stopwatch.elapsed,
        concurrency: ramp.current,
        status429: agg.status429,
        status403: agg.status403,
        failedSegments: failed
            ? (total > 0 ? total : 1)
            : agg.failedSegments,
        totalSegments: failed && total == 0 ? 1 : total,
      ));
      ramp.next();
    }
  }

  Stream<TransferProgress> _downloadInner(
      DownloadCandidate candidate, String targetPath, _StatsAgg agg) async* {
    final uri = Uri.parse(candidate.url);
    final isPlaylist = uri.path.toLowerCase().endsWith('.m3u8') ||
        uri.path.toLowerCase().endsWith('.m3u');
    if (isPlaylist) {
      yield* _downloadHls(candidate, targetPath, agg);
      return;
    }
    // 非 .m3u8 地址也可能是列表：HEAD 看 Content-Type 再定。
    final contentType = await _probeContentType(candidate);
    if (contentType != null && contentType.contains('mpegurl')) {
      yield* _downloadHls(candidate, targetPath, agg);
      return;
    }
    yield* _downloadDirect(candidate, targetPath, agg);
  }

  /// 把最近一次 downloadAll 的统计累进本次下载的总账。
  void _trackStats(_StatsAgg agg) {
    final st = downloader.lastStats;
    if (st == null) return;
    agg.status403 += st.status403;
    agg.status429 += st.status429;
    agg.failedSegments += st.failed;
    agg.totalSegments += st.tasks;
  }

  // ---------- HLS ----------

  Stream<TransferProgress> _downloadHls(
      DownloadCandidate candidate, String targetPath, _StatsAgg agg) async* {
    var playlistText = await _fetchText(candidate.url, candidate);
    if (HlsPlaylist.isMaster(playlistText)) {
      final variants = HlsPlaylist.parseMaster(
          playlistText, candidate.url);
      final variant = HlsPlaylist.pickVariant(variants);
      if (variant == null) {
        throw StateError('播放列表里没有可选的清晰度');
      }
      playlistText = await _fetchText(variant.url, candidate);
    }
    final playlist = HlsPlaylist.parseMedia(playlistText, candidate.url);
    if (playlist.segments.isEmpty) {
      throw StateError('播放列表里没有分片');
    }

    final partsDir = Directory('$targetPath.parts');
    if (await partsDir.exists()) {
      await partsDir.delete(recursive: true);
    }
    await partsDir.create(recursive: true);
    var doneBytes = 0;
    try {
      // init 分片（EXT-X-MAP，fMP4 用）先下，合并时放最前面。
      String? initPath;
      if (playlist.mapUri != null) {
        initPath = '${partsDir.path}/init.mp4';
        await downloader.downloadAll([
          SegmentTask(
            url: playlist.mapUri!,
            savePath: initPath,
            index: -1,
            headers: candidate.headers,
            referer: candidate.referer,
          ),
        ], concurrency: ramp.current);
        _trackStats(agg);
        doneBytes += await File(initPath).length();
        yield TransferProgress(doneBytes: doneBytes, totalBytes: -1);
      }

      final tasks = <SegmentTask>[];
      for (var i = 0; i < playlist.segments.length; i++) {
        final seg = playlist.segments[i];
        tasks.add(SegmentTask(
          url: seg.url,
          savePath: '${partsDir.path}/seg_$i.ts',
          index: i,
          headers: candidate.headers,
          referer: candidate.referer,
          rangeStart: seg.byteRangeOffset,
          rangeEnd: seg.byteRangeOffset != null && seg.byteRangeLength != null
              ? seg.byteRangeOffset! + seg.byteRangeLength! - 1
              : null,
          expectedSize: seg.byteRangeLength,
        ));
      }
      await downloader.downloadAll(tasks, concurrency: ramp.current);
      _trackStats(agg);
      // 分片下完后按实际大小汇总进度（下之前不知道总量）。
      for (final task in tasks) {
        final f = File(task.savePath);
        if (await f.exists()) doneBytes += await f.length();
      }
      yield TransferProgress(doneBytes: doneBytes, totalBytes: -1);

      // 解密（AES-128）：密钥按 URI 缓存；IV 缺省时用分片序号推导。
      final keyCache = <String, Uint8List>{};
      for (var i = 0; i < playlist.segments.length; i++) {
        final seg = playlist.segments[i];
        final key = seg.key;
        if (key == null || key.method == 'NONE') continue;
        if (key.method != 'AES-128') {
          throw StateError('不支持的加密方式：${key.method}');
        }
        var keyBytes = keyCache[key.uri];
        keyBytes ??= await _fetchBytes(key.uri, candidate);
        keyCache[key.uri] = keyBytes;
        final iv = key.iv ?? deriveIv(seg.sequence);
        final file = File('${partsDir.path}/seg_$i.ts');
        final cipherBytes = await file.readAsBytes();
        final plain = decryptAes128Cbc(cipherBytes, keyBytes, Uint8List.fromList(iv));
        await file.writeAsBytes(plain);
      }

      // 按序合并。
      final out = File(targetPath).openWrite();
      try {
        if (initPath != null) {
          await out.addStream(File(initPath).openRead());
        }
        for (var i = 0; i < playlist.segments.length; i++) {
          await out.addStream(File('${partsDir.path}/seg_$i.ts').openRead());
        }
      } finally {
        await out.close();
      }
      final total = await File(targetPath).length();
      yield TransferProgress(
          doneBytes: total, totalBytes: total, outputPath: targetPath, done: true);
    } finally {
      if (await partsDir.exists()) {
        await partsDir.delete(recursive: true);
      }
    }
  }

  // ---------- 直链文件 ----------

  Stream<TransferProgress> _downloadDirect(
      DownloadCandidate candidate, String targetPath, _StatsAgg agg) async* {
    final probe = await _probeRange(candidate);
    final total = probe.totalBytes;
    if (probe.supportsRange && total != null && total > 0 && partCount > 1) {
      yield* _downloadDirectMultipart(candidate, targetPath, total, agg);
      return;
    }
    // 单连接：直接下到目标文件（断点续传靠 SegmentDownloader 的
    // expectedSize 判定；总量未知时 expectedSize 为 null）。
    // 注意：单连接只有开始/结束两个进度点，中间进度由调用方按需要补。
    yield TransferProgress(doneBytes: 0, totalBytes: total ?? -1);
    await downloader.downloadAll([
      SegmentTask(
        url: candidate.url,
        savePath: targetPath,
        index: 0,
        expectedSize: total,
        headers: candidate.headers,
        referer: candidate.referer,
      ),
    ], concurrency: ramp.current);
    _trackStats(agg);
    final size = await File(targetPath).length();
    yield TransferProgress(
        doneBytes: size, totalBytes: size, outputPath: targetPath, done: true);
  }

  Stream<TransferProgress> _downloadDirectMultipart(
      DownloadCandidate candidate, String targetPath, int total, _StatsAgg agg) async* {
    final partsDir = Directory('$targetPath.parts');
    if (await partsDir.exists()) {
      await partsDir.delete(recursive: true);
    }
    await partsDir.create(recursive: true);
    try {
      final partSize = (total / partCount).ceil();
      final tasks = <SegmentTask>[];
      for (var i = 0; i < partCount; i++) {
        final start = i * partSize;
        if (start >= total) break;
        var end = start + partSize - 1;
        if (end >= total) end = total - 1;
        tasks.add(SegmentTask(
          url: candidate.url,
          savePath: '${partsDir.path}/part_$i',
          index: i,
          expectedSize: end - start + 1,
          headers: candidate.headers,
          referer: candidate.referer,
          rangeStart: start,
          rangeEnd: end,
        ));
      }
      var doneBytes = 0;
      await downloader.downloadAll(tasks, concurrency: ramp.current);
      _trackStats(agg);
      for (final task in tasks) {
        doneBytes += await File(task.savePath).length();
        yield TransferProgress(doneBytes: doneBytes, totalBytes: total);
      }
      final out = File(targetPath).openWrite();
      try {
        for (var i = 0; i < tasks.length; i++) {
          await out.addStream(File('${partsDir.path}/part_$i').openRead());
        }
      } finally {
        await out.close();
      }
      final size = await File(targetPath).length();
      if (size != total) {
        throw StateError('下载不完整：得到 $size 字节，期望 $total 字节');
      }
      yield TransferProgress(
          doneBytes: size, totalBytes: total, outputPath: targetPath, done: true);
    } finally {
      if (await partsDir.exists()) {
        await partsDir.delete(recursive: true);
      }
    }
  }

  // ---------- 网络小件 ----------

  Future<String?> _probeContentType(DownloadCandidate candidate) async {
    final client = HttpClient()..connectionTimeout = _fetchTimeout;
    try {
      final request = await client.headUrl(Uri.parse(candidate.url));
      candidate.effectiveHeaders().forEach(request.headers.set);
      final response = await request.close().timeout(_fetchTimeout);
      final type = response.headers.contentType?.mimeType;
      await response.drain<void>();
      return type;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<({bool supportsRange, int? totalBytes})> _probeRange(
      DownloadCandidate candidate) async {
    final client = HttpClient()..connectionTimeout = _fetchTimeout;
    try {
      final request = await client.getUrl(Uri.parse(candidate.url));
      candidate.effectiveHeaders().forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close().timeout(_fetchTimeout);
      final total = _parseTotal(response);
      final supports = response.statusCode == HttpStatus.partialContent;
      await response.drain<void>();
      return (supportsRange: supports, totalBytes: total);
    } catch (_) {
      return (supportsRange: false, totalBytes: null);
    } finally {
      client.close(force: true);
    }
  }

  int? _parseTotal(HttpClientResponse response) {
    final contentRange = response.headers.value('content-range');
    if (contentRange != null) {
      final m = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
      if (m != null) return int.tryParse(m.group(1)!);
    }
    return int.tryParse(response.headers.value('content-length') ?? '');
  }

  /// 拉文本（播放列表/密钥 URI 是文本时也走这里）：403 时轮换请求头重试。
  Future<String> _fetchText(String url, DownloadCandidate candidate) async {
    final bytes = await _fetchBytesWithRecovery(url, candidate);
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  Future<Uint8List> _fetchBytes(String url, DownloadCandidate candidate) async {
    return _fetchBytesWithRecovery(url, candidate);
  }

  Future<Uint8List> _fetchBytesWithRecovery(
      String url, DownloadCandidate candidate) async {
    final variants = SegmentDownloader().headerVariants(SegmentTask(
      url: url,
      savePath: '',
      index: 0,
      headers: candidate.headers,
      referer: candidate.referer,
    ));
    Object? lastError;
    for (var attempt = 0; attempt < variants.length; attempt++) {
      final client = HttpClient()..connectionTimeout = _fetchTimeout;
      try {
        final request = await client.getUrl(Uri.parse(url));
        variants[attempt].forEach(request.headers.set);
        final response = await request.close().timeout(_fetchTimeout);
        if (response.statusCode == HttpStatus.ok) {
          final chunks = <List<int>>[];
          await for (final chunk in response) {
            chunks.add(chunk);
          }
          return Uint8List.fromList(chunks.expand((e) => e).toList());
        }
        await response.drain<void>();
        lastError = HttpException('HTTP ${response.statusCode}');
      } catch (e) {
        lastError = e;
      } finally {
        client.close(force: true);
      }
      if (attempt < variants.length - 1) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw StateError('拉取失败：$url（$lastError）');
  }

  // ---------- AES-128 ----------

  /// AES-128-CBC 解密（PKCS7 去填充）。key 与 iv 必须各 16 字节。
  static Uint8List decryptAes128Cbc(
      Uint8List data, Uint8List key, Uint8List iv) {
    if (key.length != 16) throw ArgumentError('AES-128 key 必须是 16 字节');
    if (iv.length != 16) throw ArgumentError('IV 必须是 16 字节');
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7');
    cipher.init(
        false,
        PaddedBlockCipherParameters(
            ParametersWithIV(KeyParameter(key), iv), null));
    return cipher.process(data);
  }

  /// AES-128-CBC 加密（测试造加密分片用；与 decrypt 配对）。
  static Uint8List encryptAes128Cbc(
      Uint8List data, Uint8List key, Uint8List iv) {
    if (key.length != 16) throw ArgumentError('AES-128 key 必须是 16 字节');
    if (iv.length != 16) throw ArgumentError('IV 必须是 16 字节');
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7');
    cipher.init(
        true,
        PaddedBlockCipherParameters(
            ParametersWithIV(KeyParameter(key), iv), null));
    return cipher.process(data);
  }

  /// IV 缺省时用分片序号推导：序号的 16 字节大端表示。
  static List<int> deriveIv(int sequence) {
    final iv = List<int>.filled(16, 0);
    var n = sequence;
    for (var i = 15; i >= 8; i--) {
      iv[i] = n & 0xff;
      n >>= 8;
    }
    return iv;
  }
}

/// 一次下载内多次 downloadAll 的统计总账（init + 分片、或多段直链）。
class _StatsAgg {
  int status403 = 0;
  int status429 = 0;
  int failedSegments = 0;
  int totalSegments = 0;
}
