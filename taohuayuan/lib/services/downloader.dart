import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';
import 'stream_resolver.dart';

/// 视频下载（第 27、28 条）+ 下载管理。
///
/// 调研结论落到实现（见 ~/memory/projects/taohuayuan/feedback-2026-11-09.md
/// 调研结论 B/E 节）：
/// - 不调 yt-dlp：App 里已经解析出了直链（eporner 签名 mp4、r34 HLS、
///   xvideos mp4），直接拿直链下，比 Seal 少了「抓信息 + 调 yt-dlp 进程」
///   整整一层；
/// - 提速按 1DM / SniffDL 的办法：HTTP Range 分段并行（mp4 整文件默认 8 段，
///   可调 16；HLS 按分片 8 并行取 .ts 再拼），不要单线程慢慢下；
/// - 参数照抄 SniffDL 的 range_download（它实测过的）：默认 8 段、每段至少
///   2MB、8MB 以下不分段、1 字节 Range 探测（`bytes=0-0`，比 HEAD 可靠，
///   AList/网盘直链常对 HEAD 返 403 却正常支持 206）、每段完整性校验、
///   合并后验总大小、进度节流、失败回落单连接；
/// - 断点续传：每段已下字节数记账（持久化），暂停/被杀后继续下未完成的分段；
///   HLS 按已下分片序号记账；
/// - 落盘：先写应用缓存临时文件（预分配满大小，学 1DM「Create empty file」），
///   下完经 MethodChannel（MediaStore）写进系统 Downloads/桃花源/，
///   用户在文件管理器里能直接找到；播放走本地文件路径。
///
/// 限制（写明，不假装）：HLS 加密分片（#EXT-X-KEY AES-128）下不了
/// （没 ffmpeg、没解密库），报错写明；eporner 签名地址约 2 小时过期还绑 IP，
/// 下载必须在解析后尽快开始，暂停太久续传会失败；HLS 无加密时拼成 .ts
/// （没 ffmpeg 重封装，TS 直拼；fMP4 分片则拼成 .mp4）。
enum DownloadStatus { queued, downloading, paused, done, error }

enum DownloadKind { mp4, hls }

class DownloadTask {
  final String id; // 视频条目 id
  final String title;
  final String source;
  final String poster;
  final int durationSec;
  DownloadKind kind;
  // 续传/重解析用：原视频页（eporner 签名过期后重算直链要它）与最后一次解析到的直链。
  final String? pageUrl;
  String? streamUrl;
  DownloadStatus status;
  double progress; // 0..1
  int downloadedBytes;
  int totalBytes; // 0 = 未知
  double speedBps;
  String? filePath; // 系统 Downloads 里的最终路径
  String? contentUri; // MediaStore Uri
  String? error;
  final int createdAtMs;
  // 断点续传记账：mp4 是每段已下字节数；HLS 是已下完的分片序号。
  List<int> segmentDone;
  // HLS 分片总数（mp4 为 0）。
  int segmentTotal;

  DownloadTask({
    required this.id,
    required this.title,
    required this.source,
    this.poster = '',
    this.durationSec = 0,
    required this.kind,
    this.pageUrl,
    this.streamUrl,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speedBps = 0,
    this.filePath,
    this.contentUri,
    this.error,
    int? createdAtMs,
    List<int>? segmentDone,
    this.segmentTotal = 0,
  }) : createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
       segmentDone = segmentDone ?? [];

  String get statusText {
    switch (status) {
      case DownloadStatus.queued:
        return '排队中';
      case DownloadStatus.downloading:
        return '下载中';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.done:
        return '已下载';
      case DownloadStatus.error:
        return '失败：${error ?? ''}';
    }
  }

  String get sizeText {
    String fmt(int n) {
      if (n <= 0) return '';
      if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
      return '${(n / 1024).toStringAsFixed(0)} KB';
    }

    if (totalBytes > 0) return '${fmt(downloadedBytes)} / ${fmt(totalBytes)}';
    return fmt(downloadedBytes);
  }

  String get speedText {
    if (status != DownloadStatus.downloading || speedBps <= 0) return '';
    if (speedBps >= 1024 * 1024) {
      return '${(speedBps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    return '${(speedBps / 1024).toStringAsFixed(0)} KB/s';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'source': source,
        'poster': poster,
        'durationSec': durationSec,
        'kind': kind.name,
        'pageUrl': pageUrl,
        'streamUrl': streamUrl,
        'status': status.name,
        'progress': progress,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'filePath': filePath,
        'contentUri': contentUri,
        'error': error,
        'createdAtMs': createdAtMs,
        'segmentDone': segmentDone,
        'segmentTotal': segmentTotal,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        source: (j['source'] ?? '') as String,
        poster: (j['poster'] ?? '') as String,
        durationSec: ((j['durationSec'] ?? 0) as num).toInt(),
        kind: (j['kind'] as String?) == 'hls' ? DownloadKind.hls : DownloadKind.mp4,
        pageUrl: j['pageUrl'] as String?,
        streamUrl: j['streamUrl'] as String?,
        status: DownloadStatus.values.firstWhere(
          (s) => s.name == (j['status'] as String?),
          orElse: () => DownloadStatus.paused,
        ),
        progress: ((j['progress'] ?? 0) as num).toDouble(),
        downloadedBytes: ((j['downloadedBytes'] ?? 0) as num).toInt(),
        totalBytes: ((j['totalBytes'] ?? 0) as num).toInt(),
        filePath: j['filePath'] as String?,
        contentUri: j['contentUri'] as String?,
        error: j['error'] as String?,
        createdAtMs: ((j['createdAtMs'] ?? 0) as num).toInt(),
        segmentDone: ((j['segmentDone'] ?? []) as List)
            .map((e) => (e as num).toInt())
            .toList(),
        segmentTotal: ((j['segmentTotal'] ?? 0) as num).toInt(),
      );
}

/// 1 字节 Range 探测结果（供单元测试 + benchmark 直接用）。
/// SniffDL 的教训：HEAD 不可靠，AList/网盘直链常对 HEAD 返 403 却正常支持 206，
/// 所以用 `Range: bytes=0-0` 的 GET 探。
class RangeProbe {
  final bool supported;
  final int totalBytes; // 0 = 未知
  const RangeProbe(this.supported, this.totalBytes);
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  static const _prefsKey = 'taohuayuan_downloads';
  static const _channel = MethodChannel('taohuayuan/downloads');
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 默认分段数（SniffDL range_download 的默认值；1DM 免费版上限 16）。
  static const defaultParts = 8;
  static const maxParts = 16;
  static const minSegmentedSize = 8 * 1024 * 1024; // 8MB 以下不分段
  static const minSegmentSize = 2 * 1024 * 1024; // 每段至少 2MB
  static const maxConcurrentDownloads = 2;

  final List<DownloadTask> tasks = [];
  final Map<String, _DownloadJob> _jobs = {};
  bool _loaded = false;

  List<DownloadTask> get activeTasks =>
      tasks.where((t) => t.status == DownloadStatus.downloading || t.status == DownloadStatus.queued).toList();

  List<DownloadTask> get doneTasks =>
      tasks.where((t) => t.status == DownloadStatus.done).toList();

  DownloadTask? taskFor(String videoId) {
    for (final t in tasks) {
      if (t.id == videoId) return t;
    }
    return null;
  }

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List)
            .map((e) => DownloadTask.fromJson(e as Map<String, dynamic>))
            .toList();
        for (final t in list) {
          // 上次被杀时正在下的，这次进来算暂停（可续传），不自动重下。
          if (t.status == DownloadStatus.downloading ||
              t.status == DownloadStatus.queued) {
            t.status = DownloadStatus.paused;
          }
          tasks.add(t);
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey, jsonEncode(tasks.map((t) => t.toJson()).toList()));
    } catch (_) {}
  }

  void _notifyAndPersist({bool persist = false}) {
    notifyListeners();
    if (persist) unawaited(_persist());
  }

  /// 点一下就开始下载（第 27 条定死：每个视频都要有下载入口，点一下就开始）。
  /// 画质：多档时默认最高档（mp4 优先于同清晰度的 HLS；没档位就用解析到的直链）。
  Future<DownloadTask?> startDownload(VideoItem item) async {
    await init();
    final existing = taskFor(item.id);
    if (existing != null) {
      if (existing.status == DownloadStatus.done) return existing;
      if (existing.status == DownloadStatus.paused) {
        resumeTask(existing.id);
        return existing;
      }
      return existing; // 正在下/排队中，不重复建任务
    }
    // 先解析直链 + 档位（eporner 签名现算，2 小时过期，下完前不缓存）。
    final variants = await StreamResolver.variantsFor(item);
    String? url;
    Map<String, String> headers = {};
    var kind = DownloadKind.mp4;
    if (variants.isNotEmpty) {
      final best = _pickBestVariant(variants);
      url = best.url;
      headers = best.headers;
      kind = best.url.contains('.m3u8') ? DownloadKind.hls : DownloadKind.mp4;
    } else {
      final resolved = await StreamResolver.resolve(item);
      if (resolved == null) return null; // 没直链，下不了（不假装能下）
      url = resolved.url;
      headers = resolved.headers;
      kind = url.contains('.m3u8') ? DownloadKind.hls : DownloadKind.mp4;
    }
    final task = DownloadTask(
      id: item.id,
      title: item.title,
      source: item.source,
      poster: item.poster,
      durationSec: item.durationSec,
      kind: kind,
      pageUrl: item.pageUrl,
      streamUrl: url,
    );
    tasks.insert(0, task);
    _jobs[task.id] = _DownloadJob(url: url, headers: headers, task: task);
    _notifyAndPersist(persist: true);
    _pumpQueue();
    return task;
  }

  /// 内置浏览器嗅到的直链直接下（不用再解析一次）。
  Future<DownloadTask?> startDownloadFromUrl({
    required String id,
    required String title,
    required String source,
    required String url,
    Map<String, String> headers = const {},
    String poster = '',
    int durationSec = 0,
  }) async {
    await init();
    final existing = taskFor(id);
    if (existing != null) return existing;
    final task = DownloadTask(
      id: id,
      title: title,
      source: source,
      poster: poster,
      durationSec: durationSec,
      kind: url.contains('.m3u8') ? DownloadKind.hls : DownloadKind.mp4,
      streamUrl: url,
    );
    tasks.insert(0, task);
    _jobs[task.id] = _DownloadJob(url: url, headers: headers, task: task);
    _notifyAndPersist(persist: true);
    _pumpQueue();
    return task;
  }

  /// 档位排序：清晰度数字高的在前；同清晰度 mp4 优先于 HLS；
  /// 没数字的标签按叫法估（原画最高、HLS 自适应按 720p 算、高清 720p、标清 360p）。
  static StreamVariant _pickBestVariant(List<StreamVariant> variants) {
    int rank(StreamVariant v) {
      final m = RegExp(r'(\d+)p').firstMatch(v.label);
      if (m != null) return int.parse(m.group(1)!);
      final u = RegExp(r'video_(\d+)p').firstMatch(v.url);
      if (u != null) return int.parse(u.group(1)!);
      if (v.label.contains('原画')) return 9999;
      if (v.label.contains('HLS') || v.label.contains('自适应')) return 720;
      if (v.label.contains('高清')) return 720;
      if (v.label.contains('标清')) return 360;
      return 0;
    }

    final sorted = [...variants];
    sorted.sort((a, b) {
      final r = rank(b).compareTo(rank(a));
      if (r != 0) return r;
      final aMp4 = !a.url.contains('.m3u8');
      final bMp4 = !b.url.contains('.m3u8');
      return (bMp4 ? 1 : 0).compareTo(aMp4 ? 1 : 0);
    });
    return sorted.first;
  }

  void _pumpQueue() {
    final running = tasks.where((t) => t.status == DownloadStatus.downloading).length;
    if (running >= maxConcurrentDownloads) return;
    for (final t in tasks) {
      if (t.status == DownloadStatus.queued) {
        unawaited(_runTask(t));
        if (tasks.where((x) => x.status == DownloadStatus.downloading).length >=
            maxConcurrentDownloads) {
          break;
        }
      }
    }
  }

  Future<void> _runTask(DownloadTask task) async {
    final job = _jobs[task.id];
    if (job == null) {
      task.status = DownloadStatus.error;
      task.error = '任务丢失';
      _notifyAndPersist(persist: true);
      return;
    }
    task.status = DownloadStatus.downloading;
    task.error = null;
    _notifyAndPersist();
    try {
      final tmpDir = await getTemporaryDirectory();
      final dir = Directory('${tmpDir.path}/downloads');
      await dir.create(recursive: true);
      final ext = task.kind == DownloadKind.hls ? '.ts' : '.mp4';
      final tmpPath = '${dir.path}/${task.id}$ext.tmp';
      String finalPath;
      if (task.kind == DownloadKind.hls) {
        finalPath = await _downloadHls(job, tmpPath, task);
      } else {
        finalPath = await _downloadMp4(job, tmpPath, task);
      }
      // fMP4 的 HLS 拼出来是 .mp4（_downloadHls 会改后缀），落盘扩展名按实际文件取，
      // 别按 kind 写死，否则 .mp4 文件会被存成 .ts。
      final savedExt = finalPath.endsWith('.mp4.tmp') ? '.mp4' : '.ts';
      // 落盘到系统 Downloads/桃花源/（MediaStore，见 MainActivity.kt）。
      final saved = await _saveToDownloads(finalPath, _fileName(task, savedExt));
      var path = saved['path'] as String?;
      final uri = saved['uri'] as String?;
      if (path == null && uri != null) {
        // MediaStore insert 成功但 DATA 列取不到路径：再调一次 resolvePath
        // （按 DISPLAY_NAME 拼约定路径验存在）。
        try {
          path = await _channel.invokeMethod<String>('resolvePath', {'uri': uri});
        } catch (_) {}
      }
      task.filePath = path;
      task.contentUri = uri;
      task.status = DownloadStatus.done;
      task.progress = 1.0;
      task.downloadedBytes = task.totalBytes > 0 ? task.totalBytes : task.downloadedBytes;
      try {
        await File(finalPath).delete();
      } catch (_) {}
    } on _Paused {
      task.status = DownloadStatus.paused;
    } catch (e) {
      task.status = DownloadStatus.error;
      task.error = _shortError(e);
    }
    _jobs.remove(task.id);
    _notifyAndPersist(persist: true);
    _pumpQueue();
  }

  /// mp4：Range 分段并行（默认 8 段）或单连接回退。
  /// 断点续传：task.segmentDone 记每段已下字节数，暂停/被杀后只下未完成的分段。
  Future<String> _downloadMp4(_DownloadJob job, String tmpPath, DownloadTask task) async {
    final probe = await probeRange(job.url, job.headers);
    final total = probe.totalBytes;
    task.totalBytes = total;
    if (!probe.supported) {
      // 服务器不支持 Range：单连接从头下（续传不了——Range 都不支持，
      // 暂停后只能重下；记账清零，别拿旧数字骗进度条）。
      task.segmentDone = [0];
      task.downloadedBytes = 0;
      task.progress = 0;
      var downloaded = 0;
      await downloadSingle(
        url: job.url,
        headers: job.headers,
        targetPath: tmpPath,
        onBytes: (n) {
          downloaded += n;
          task.downloadedBytes = downloaded;
          if (total > 0) task.progress = downloaded / total;
          _throttledNotify(task);
        },
        isCancelled: () => job.cancelled,
      );
      return tmpPath;
    }
    final useSegments = total >= minSegmentedSize;
    final parts = useSegments
        ? (total ~/ minSegmentSize).clamp(2, defaultParts)
        : 1;
    if (task.segmentDone.length != parts) {
      task.segmentDone = List<int>.filled(parts, 0);
    }
    if (total > 0) {
      // 预分配满大小（学 1DM「Create empty file」：边下边扩容易掉速）。
      final raf = await File(tmpPath).open(mode: FileMode.write);
      await raf.truncate(total);
      await raf.close();
    }
    final bounds = <(int, int)>[];
    for (var i = 0; i < parts; i++) {
      final a = i * total ~/ parts;
      final b = (i + 1) * total ~/ parts - 1;
      bounds.add((a, i == parts - 1 ? total - 1 : b));
    }
    final job2 = job;
    await _runSegments(
      parts: parts,
      task: task,
      work: (i) async {
        final (a, b) = bounds[i];
        final done = task.segmentDone[i];
        if (done >= b - a + 1) return; // 这段已下完，跳过（续传）
        final start = a + done;
        await _downloadRange(
          url: job2.url,
          headers: job2.headers,
          start: start,
          end: b,
          targetPath: tmpPath,
          writeOffset: start,
          onBytes: (n) {
            task.segmentDone[i] += n;
            task.downloadedBytes = task.segmentDone.fold(0, (s, e) => s + e);
            if (total > 0) task.progress = task.downloadedBytes / total;
          },
          isCancelled: () => job2.cancelled,
          retries: 3,
        );
      },
    );
    final size = await File(tmpPath).length();
    if (total > 0 && size != total) {
      throw StateError('合并后大小不符 $size != $total');
    }
    return tmpPath;
  }

  /// HLS：取媒体播放列表，分片 8 并行取，顺序拼成一个文件。
  /// 加密分片（#EXT-X-KEY AES-128）直接报错，不假装能下。
  /// fMP4 分片（有 #EXT-X-MAP）拼成 .mp4，否则拼成 .ts。
  /// 静态方法：供单元测试和 benchmark 直接用（不依赖任务状态）。
  /// alreadyDone 只在分片临时文件还在磁盘上时才认（App 重启后缓存被清掉
  /// 的分片不认，重新下——否则拼的时候会读到不存在的文件）。
  static Future<String> downloadHlsFile({
    required String masterUrl,
    required Map<String, String> headers,
    required String targetPath,
    Set<int>? alreadyDone,
    void Function(int doneCount, int totalCount, int bytesDownloaded)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final mediaUrl = await _resolveMediaPlaylist(masterUrl, headers);
    final playlistBody = await _fetchText(mediaUrl, headers);
    if (playlistBody.contains('#EXT-X-KEY') &&
        !playlistBody.contains('METHOD=NONE')) {
      throw StateError('这条是加密 HLS（AES-128），App 里下不了，只能在线看');
    }
    final segments = parseHlsSegments(playlistBody, mediaUrl);
    if (segments.isEmpty) throw StateError('播放列表里没有分片');
    final isFmp4 = playlistBody.contains('#EXT-X-MAP');
    final tmpDir = Directory('$targetPath.segs');
    await tmpDir.create(recursive: true);
    final segPaths = List<String>.generate(
        segments.length, (i) => '${tmpDir.path}/$i.ts');
    final done = <int>{
      for (final i in (alreadyDone ?? {}))
        if (i < segments.length && File(segPaths[i]).existsSync()) i
    };
    var completed = done.length;
    var downloaded = 0;
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        if (isCancelled != null && isCancelled()) throw _Paused();
        var i = -1;
        for (var k = 0; k < segments.length; k++) {
          final idx = (cursor + k) % segments.length;
          if (!done.contains(idx)) {
            i = idx;
            break;
          }
        }
        if (i < 0) return;
        cursor = (i + 1) % segments.length;
        done.add(i); // 正在下（防重复取）
        var ok = false;
        for (var attempt = 0; attempt < 3 && !ok; attempt++) {
          try {
            final bytes = await _fetchBytes(segments[i], headers);
            if (bytes.isEmpty) throw StateError('分片 $i 为空');
            await File(segPaths[i]).writeAsBytes(bytes);
            completed++;
            downloaded += bytes.length;
            onProgress?.call(completed, segments.length, downloaded);
            ok = true;
          } catch (e) {
            if (isCancelled != null && isCancelled()) throw _Paused();
            if (attempt == 2) rethrow;
            await Future.delayed(Duration(seconds: 1 << attempt));
          }
        }
      }
    }

    await Future.wait(List.generate(8, (_) => worker()));
    // 顺序拼：fMP4 先写 init 段，再按序号拼；TS 直接按序号拼。
    final out = await File(targetPath).open(mode: FileMode.write);
    try {
      if (isFmp4) {
        final mapUri = _parseExtXMap(playlistBody, mediaUrl);
        if (mapUri != null) {
          final init = await _fetchBytes(mapUri, headers);
          await out.writeFrom(init);
        }
      }
      for (var i = 0; i < segments.length; i++) {
        final bytes = await File(segPaths[i]).readAsBytes();
        await out.writeFrom(bytes);
      }
    } finally {
      await out.close();
    }
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
    // fMP4 拼出来的是 .mp4，改一下扩展名再落盘（调用方按 tmpPath 后缀定名）。
    if (isFmp4) {
      final mp4Path = targetPath.replaceAll(RegExp(r'\.ts\.tmp$'), '.mp4.tmp');
      await File(targetPath).rename(mp4Path);
      return mp4Path;
    }
    return targetPath;
  }

  /// 任务层薄壳：把任务的断点记账（segmentDone）翻译成静态函数能用的
  /// alreadyDone，进度回写到任务上。
  Future<String> _downloadHls(
      _DownloadJob job, String tmpPath, DownloadTask task) async {
    final alreadyDone = <int>{
      for (var i = 0; i < task.segmentDone.length; i++)
        if (task.segmentDone[i] == 1) i
    };
    final out = await downloadHlsFile(
      masterUrl: job.url,
      headers: job.headers,
      targetPath: tmpPath,
      alreadyDone: alreadyDone,
      onProgress: (doneCount, totalCount, bytes) {
        task.segmentTotal = totalCount;
        task.downloadedBytes = bytes;
        task.progress = totalCount > 0 ? doneCount / totalCount : 0;
        _throttledNotify(task);
      },
      isCancelled: () => job.cancelled,
    );
    task.segmentDone = List<int>.filled(task.segmentTotal, 1);
    task.progress = 1.0;
    return out;
  }

  /// 主播放列表 -> 选 BANDWIDTH 最大的变体；已经是媒体播放列表就原样返回。
  static Future<String> _resolveMediaPlaylist(
      String url, Map<String, String> headers) async {
    final body = await _fetchText(url, headers);
    if (!body.contains('#EXT-X-STREAM-INF')) return url;
    final variant = pickHlsVariant(body, url);
    if (variant == null) return url;
    return variant;
  }

  static Future<String> _fetchText(String url, Map<String, String> headers) async {
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': _ua, ...headers})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw StateError('拉播放列表失败：HTTP ${res.statusCode}');
    return utf8.decode(res.bodyBytes);
  }

  static Future<List<int>> _fetchBytes(String url, Map<String, String> headers) async {
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': _ua, ...headers})
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
    return res.bodyBytes;
  }
  static String? _parseExtXMap(String body, String baseUrl) {
    final m = RegExp(r'#EXT-X-MAP:URI="([^"]+)"').firstMatch(body);
    if (m == null) return null;
    return Uri.parse(baseUrl).resolve(m.group(1)!).toString();
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  void _throttledNotify(DownloadTask task) {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 500 && task.progress < 1) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }

  /// 分段执行器：parts 路并行跑 work(i)，任一失败抛错（调用方回退或报错）；
  /// 暂停时抛 _Paused。
  Future<void> _runSegments({
    required int parts,
    required DownloadTask task,
    required Future<void> Function(int i) work,
  }) async {
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= parts) return;
        await work(i);
      }
    }

    await Future.wait(List.generate(parts, (_) => worker()));
  }

  /// 一段 Range 下载（带 3 次重试）；写到 targetPath 的 writeOffset 处。
  /// 供单元测试 + benchmark 直接用。
  static Future<void> downloadRange({
    required String url,
    required Map<String, String> headers,
    required int start,
    required int end,
    required String targetPath,
    required int writeOffset,
    required void Function(int n) onBytes,
    required bool Function() isCancelled,
    int retries = 3,
  }) async {
    await _downloadRange(
      url: url,
      headers: headers,
      start: start,
      end: end,
      targetPath: targetPath,
      writeOffset: writeOffset,
      onBytes: onBytes,
      isCancelled: isCancelled,
      retries: retries,
    );
  }

  static Future<void> _downloadRange({
    required String url,
    required Map<String, String> headers,
    required int start,
    required int end,
    required String targetPath,
    required int writeOffset,
    required void Function(int n) onBytes,
    required bool Function() isCancelled,
    int retries = 3,
  }) async {
    Object? lastError;
    var written = 0; // 本次调用已写入的字节数（重试时从这里接着要，不重复计进度）
    for (var attempt = 0; attempt < retries; attempt++) {
      if (isCancelled()) throw _Paused();
      try {
        final client = HttpClient();
        try {
          final req = await client.getUrl(Uri.parse(url));
          req.headers.set('User-Agent', _ua);
          headers.forEach((k, v) => req.headers.set(k, v));
          req.headers.set('Range', 'bytes=${start + written}-$end');
          final res = await req.close().timeout(const Duration(seconds: 60));
          if (res.statusCode != 206) {
            throw StateError('分段响应码 ${res.statusCode}（服务器不支持 Range）');
          }
          final raf = await File(targetPath).open(mode: FileMode.write);
          try {
            var offset = writeOffset + written;
            await for (final chunk in res.timeout(const Duration(seconds: 60))) {
              if (isCancelled()) throw _Paused();
              await raf.setPosition(offset);
              await raf.writeFrom(chunk);
              offset += chunk.length;
              written += chunk.length;
              onBytes(chunk.length);
            }
          } finally {
            await raf.close();
          }
        } finally {
          client.close(force: true);
        }
        // 每段完整性校验（抄 SniffDL：got[i] 必须等于 want，否则这段不算完）。
        if (written != end - start + 1) {
          throw StateError('分段不完整 $written/${end - start + 1}');
        }
        return;
      } catch (e) {
        if (e is _Paused) rethrow;
        lastError = e;
        if (attempt < retries - 1) {
          await Future.delayed(Duration(seconds: 1 << attempt));
        }
      }
    }
    throw lastError ?? StateError('分段下载失败');
  }

  /// 1 字节 Range 探测（供单元测试 + benchmark 直接用）。
  static Future<RangeProbe> probeRange(
      String url, Map<String, String> headers) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', _ua);
      headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.set('Range', 'bytes=0-0');
      final res = await req.close().timeout(const Duration(seconds: 25));
      // 必须把 body 读掉（或关掉），不然连接挂起。
      await res.drain<void>().catchError((_) {});
      if (res.statusCode == 206) {
        final cr = res.headers.value('content-range') ?? '';
        final tail = cr.contains('/') ? cr.split('/').last.trim() : '';
        final total = int.tryParse(tail) ?? 0;
        return RangeProbe(true, total);
      }
      final cl = res.headers.value('content-length') ?? '';
      return RangeProbe(false, int.tryParse(cl.trim()) ?? 0);
    } catch (_) {
      return const RangeProbe(false, 0);
    } finally {
      client.close(force: true);
    }
  }

  /// 媒体播放列表正文 -> 分片地址列表（相对地址按 baseUrl 拼）。
  /// 供单元测试直接验。
  static List<String> parseHlsSegments(String body, String baseUrl) {
    final out = <String>[];
    for (final line in body.split('\n')) {
      final u = line.trim();
      if (u.isEmpty || u.startsWith('#')) continue;
      out.add(u.startsWith('http') ? u : Uri.parse(baseUrl).resolve(u).toString());
    }
    return out;
  }

  /// 主播放列表正文 -> BANDWIDTH 最大的变体地址（相对地址按 baseUrl 拼）。
  /// 供单元测试直接验。
  static String? pickHlsVariant(String body, String baseUrl) {
    final lines = body.split('\n').map((e) => e.trim()).toList();
    String? best;
    var bestBw = -1;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      final bw = int.tryParse(
              RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i])?.group(1) ?? '') ??
          0;
      for (var j = i + 1; j < lines.length; j++) {
        final u = lines[j];
        if (u.isEmpty || u.startsWith('#')) continue;
        if (bw >= bestBw) {
          bestBw = bw;
          best = u.startsWith('http') ? u : Uri.parse(baseUrl).resolve(u).toString();
        }
        break;
      }
    }
    return best;
  }

  /// 单连接下载（分段不可用时的回退：服务器不支持 Range / 文件太小 / 探测失败）。
  /// 供 benchmark 对照用（1 线程基线）。
  static Future<void> downloadSingle({
    required String url,
    required Map<String, String> headers,
    required String targetPath,
    required void Function(int n) onBytes,
    required bool Function() isCancelled,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', _ua);
      headers.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
      final raf = await File(targetPath).open(mode: FileMode.write);
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 60))) {
          if (isCancelled()) throw _Paused();
          await raf.writeFrom(chunk);
          onBytes(chunk.length);
        }
      } finally {
        await raf.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  /// 分段并行下载整文件（供 benchmark 直接用：1 段 vs 8 段对照）。
  /// 探测 Range；支持且够大就分段，否则单连接；返回实际用的段数。
  static Future<int> downloadSegmented({
    required String url,
    required Map<String, String> headers,
    required String targetPath,
    required int parts,
    required void Function(int downloaded, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final cancelled = isCancelled ?? () => false;
    final probe = await probeRange(url, headers);
    final total = probe.totalBytes;
    var usedParts = 1;
    if (probe.supported && total >= minSegmentedSize) {
      usedParts = (total ~/ minSegmentSize).clamp(2, parts);
      final raf = await File(targetPath).open(mode: FileMode.write);
      await raf.truncate(total);
      await raf.close();
      final done = List<int>.filled(usedParts, 0);
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= usedParts) return;
          final a = i * total ~/ usedParts;
          final b = (i + 1) * total ~/ usedParts - 1;
          final end = i == usedParts - 1 ? total - 1 : b;
          await downloadRange(
            url: url,
            headers: headers,
            start: a,
            end: end,
            targetPath: targetPath,
            writeOffset: a,
            onBytes: (n) {
              done[i] += n;
              onProgress(done.fold(0, (s, e) => s + e), total);
            },
            isCancelled: cancelled,
          );
        }
      }

      await Future.wait(List.generate(usedParts, (_) => worker()));
      final size = await File(targetPath).length();
      if (size != total) throw StateError('合并后大小不符 $size != $total');
      return usedParts;
    }
    var downloaded = 0;
    await downloadSingle(
      url: url,
      headers: headers,
      targetPath: targetPath,
      onBytes: (n) {
        downloaded += n;
        onProgress(downloaded, total);
      },
      isCancelled: cancelled,
    );
    return usedParts;
  }

  String _fileName(DownloadTask task, String ext) {
    var base = task.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (base.isEmpty) base = task.id;
    if (base.length > 100) base = base.substring(0, 100);
    return '$base$ext';
  }

  Future<Map<String, Object?>> _saveToDownloads(String tmpPath, String fileName) async {
    final mime = fileName.endsWith('.ts')
        ? 'video/mp2t'
        : fileName.endsWith('.mp4')
            ? 'video/mp4'
            : 'video/*';
    final res = await _channel.invokeMethod<Map<Object?, Object?>>(
      'saveToDownloads',
      {'tempPath': tmpPath, 'fileName': fileName, 'mimeType': mime},
    );
    if (res == null || res['path'] == null) {
      throw StateError('保存到系统 Downloads 失败（MediaStore 写入失败）');
    }
    return {'uri': res['uri'] as String?, 'path': res['path'] as String?};
  }

  /// 暂停（记账已持久化，继续时只下未完成的分段）。
  Future<void> pauseTask(String id) async {
    final job = _jobs[id];
    if (job != null) job.cancelled = true;
    final t = taskFor(id);
    if (t != null && t.status == DownloadStatus.downloading) {
      t.status = DownloadStatus.paused;
      _notifyAndPersist(persist: true);
    }
  }

  Future<void> resumeTask(String id) async {
    final t = taskFor(id);
    if (t == null || t.status != DownloadStatus.paused) return;
    var job = _jobs[t.id];
    if (job == null) {
      // App 重启后 job 丢了：重新解析直链（eporner 签名约 2 小时过期还绑 IP，
      // 必须现算，不能拿存的旧地址续传；其他源重解析也无害）。
      // pageUrl 存在任务里，解析不用重新搜。
      final item = VideoItem(
        id: t.id,
        title: t.title,
        source: t.source,
        poster: t.poster,
        durationSec: t.durationSec,
        pageUrl: t.pageUrl,
        streamUrl: t.streamUrl,
      );
      String? url;
      var headers = <String, String>{};
      var kind = t.kind;
      final variants = await StreamResolver.variantsFor(item);
      if (variants.isNotEmpty) {
        final best = _pickBestVariant(variants);
        url = best.url;
        headers = best.headers;
        kind = url.contains('.m3u8') ? DownloadKind.hls : DownloadKind.mp4;
      } else {
        final resolved = await StreamResolver.resolve(item);
        if (resolved != null) {
          url = resolved.url;
          headers = resolved.headers;
          kind = url.contains('.m3u8') ? DownloadKind.hls : DownloadKind.mp4;
        }
      }
      if (url == null) {
        t.status = DownloadStatus.error;
        t.error = '直链过期了，删掉重新下载';
        _notifyAndPersist(persist: true);
        return;
      }
      // 直链换了地址，文件内容是同一个（同一直链视频），按字节续传仍然成立；
      // 但 kind 变了（mp4 变 HLS 这种极少数情况）记账对不上，记账清零重下。
      if (kind != t.kind) {
        t.segmentDone = [];
        t.downloadedBytes = 0;
        t.progress = 0;
        t.kind = kind;
      }
      t.streamUrl = url;
      job = _DownloadJob(url: url, headers: headers, task: t);
      _jobs[t.id] = job;
    }
    job.cancelled = false;
    t.status = DownloadStatus.queued;
    _notifyAndPersist(persist: true);
    _pumpQueue();
  }

  /// 取消下载中/排队中的任务（删临时文件，不删已下完的成品）。
  Future<void> cancelTask(String id) async {
    final job = _jobs[id];
    if (job != null) job.cancelled = true;
    final t = taskFor(id);
    if (t == null) return;
    // 等当前任务退出（最多 2 秒），再删任务；不等它也行，_runTask 结束后会发现任务没了。
    tasks.remove(t);
    _jobs.remove(id);
    _notifyAndPersist(persist: true);
    try {
      final tmpDir = await getTemporaryDirectory();
      final dir = Directory('${tmpDir.path}/downloads');
      final tmpPath = '${dir.path}/${t.id}.ts.tmp';
      final tmpPath2 = '${dir.path}/${t.id}.mp4.tmp';
      for (final p in [tmpPath, tmpPath2]) {
        final f = File(p);
        if (await f.exists()) await f.delete();
      }
      final segDir = Directory('${dir.path}/${t.id}.ts.tmp.segs');
      if (await segDir.exists()) await segDir.delete(recursive: true);
    } catch (_) {}
  }

  /// 删除已下完的任务（连同系统 Downloads 里的文件一起删；删前由 UI 确认）。
  Future<void> deleteTask(String id) async {
    final t = taskFor(id);
    if (t == null) return;
    if (t.contentUri != null) {
      try {
        await _channel.invokeMethod('deleteFromDownloads', {'uri': t.contentUri});
      } catch (_) {}
    }
    if (t.filePath != null) {
      try {
        final f = File(t.filePath!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    tasks.remove(t);
    _notifyAndPersist(persist: true);
  }

  String _shortError(Object e) {
    final s = e.toString().replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}

class _DownloadJob {
  final String url;
  final Map<String, String> headers;
  final DownloadTask task;
  bool cancelled = false;
  _DownloadJob({required this.url, required this.headers, required this.task});
}

/// 暂停抛出的内部信号（不是下载失败，记账已保存，继续时接着下）。
class _Paused implements Exception {}
