import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_video_thumbnail/get_video_thumbnail.dart';
// get_video_thumbnail 0.9.1 只导出了 XFile，没有导出 ImageFormat，只能直接引
// 它的 src 文件；这是该包的缺陷（连它自己 README 的示例都因此编不过）。
// ignore: implementation_imports
import 'package:get_video_thumbnail/src/image_format.dart';

import '../models/video_item.dart';
import 'store.dart';
import 'stream_resolver.dart';
import '../transfer/concurrency_ramp.dart';
import '../transfer/throughput_tracker.dart';
import '../transfer/transfer_config.dart';
import 'ts_remuxer.dart';

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
  String poster;
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
  // HLS 下完后 ts 转 mp4 是否成功（第 34 条）：成功了管理页写“已转 mp4”。
  bool remuxedToMp4;
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
    this.remuxedToMp4 = false,
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
        'remuxedToMp4': remuxedToMp4,
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
        remuxedToMp4: (j['remuxedToMp4'] as bool?) ?? false,
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
  static const minSegmentedSize = 2 * 1024 * 1024; // 2MB 以下不分段
  static const minSegmentSize = 2 * 1024 * 1024; // 每段至少 2MB
  static const maxConcurrentDownloads = 2;

  /// HLS 分片并发起点（具名常量；自适应并发 _ramp 会按实测逐档调下一轮）。
  static const hlsDefaultConcurrency = 8;

  /// 403 换请求头恢复用的备用 UA（和传输层 SegmentDownloader.altUserAgent
  /// 同一个：去 Referer 时顺手换个移动端 UA，别光秃秃只剩桌面 UA）。
  static const _altUa =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 自适应并发（传输层 ConcurrencyRamp + ThroughputTracker 的原样接线，
  /// 不是另起炉灶：每次下载结束记一次实测，下一轮并发按实测逐档调，
  /// 起步 8、下限 4、上限 16；被 429/403 压制或失败率超限就减半回退。
  /// SegmentDownloader / TransferEngine 整体没接——它们是另一套任务模型
  /// （自带 HttpClient、批量 API、AES 解密），替换现有 _downloadMp4 /
  /// downloadHlsFile 会丢掉 v11 合并修复、逐段记账、签名过期重拉这些
  /// 已修好的行为；只把 ramp 这一个纯逻辑类接进来。
  final ThroughputTracker _tracker = ThroughputTracker();
  late final ConcurrencyRamp _ramp = ConcurrencyRamp(
    config: const TransferConfig(
        startConcurrency: 8, minConcurrency: 4, maxConcurrency: 16),
    tracker: _tracker,
  );

  /// 记一次实测进跟踪器，并让自适应并发算下一轮的并发数。
  void _recordRun({
    required int bytes,
    required Duration elapsed,
    required int concurrency,
    int status429 = 0,
    int status403 = 0,
    int failedSegments = 0,
    int totalSegments = 0,
  }) {
    _tracker.record(RunMeasurement(
      bytes: bytes,
      elapsed: elapsed,
      concurrency: concurrency,
      status429: status429,
      status403: status403,
      failedSegments: failedSegments,
      totalSegments: totalSegments,
    ));
    _ramp.next();
  }

  final List<DownloadTask> tasks = [];
  final Map<String, _DownloadJob> _jobs = {};
  bool _loaded = false;

  /// 最近一次点下载却下不了的原因（第 29 条）：具体原因，不只一句“下不了”。
  /// 失败时 DownloadButton 的 SnackBar 显示它。
  String? lastFailureReason;

  /// 速度取样（第 31 条）：每任务最近 3 秒的（时间, 累计字节）取样点。
  /// 速度 = 窗口内实际字节数 / 窗口秒数，不写死、不估算。
  final Map<String, List<(int, int)>> _speedSamples = {};

  /// 每下来一块字节就记一笔（onBytes 回调里调），顺带算出当前速度。
  void _recordBytes(DownloadTask task) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = _speedSamples.putIfAbsent(task.id, () => []);
    list.add((now, task.downloadedBytes));
    while (list.length > 2 && now - list.first.$1 > 3000) {
      list.removeAt(0);
    }
    if (list.length > 60) list.removeRange(0, list.length - 60);
    if (list.length >= 2) {
      final dt = list.last.$1 - list.first.$1;
      final db = list.last.$2 - list.first.$2;
      task.speedBps = dt > 0 ? db * 1000 / dt : 0;
    }
  }

  /// 任务停了（暂停/完成/失败）：速度清零，取样丢掉。
  void _clearSpeed(DownloadTask task) {
    task.speedBps = 0;
    _speedSamples.remove(task.id);
  }

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
      if (resolved == null) {
        // 没直链：把具体原因记下来（哪个源、为什么没给直链），
        // 别只给一句“下不了”。解析不到的再走 WebView 嗅探（见第 34 条）。
        lastFailureReason = StreamResolver.lastFailureReason ?? '这个源站没给直链';
        return null;
      }
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
    // 海报存本地（不阻塞下载）：存下来后把任务的 poster 指到本地路径。
    savePosterLocally(
      taskId: task.id,
      posterUrl: item.poster,
      referer: item.pageUrl,
    ).then((local) {
      if (local != null && local.isNotEmpty && task.poster == item.poster) {
        task.poster = local;
        _notifyAndPersist(persist: true);
      }
    }).catchError((_) {});
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
    // 海报存本地（不阻塞下载）：存下来后把任务的 poster 指到本地路径。
    savePosterLocally(
      taskId: task.id,
      posterUrl: poster,
      referer: headers['Referer'],
    ).then((local) {
      if (local != null && local.isNotEmpty && task.poster == poster) {
        task.poster = local;
        _notifyAndPersist(persist: true);
      }
    }).catchError((_) {});
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
      var finalPath = '';
      if (task.kind == DownloadKind.hls) {
        finalPath = await _downloadHls(job, tmpPath, task);
      } else {
        finalPath = await _downloadMp4(job, tmpPath, task);
      }
      // HLS 的 .ts 分段下完后转 mp4（第 34 条，1DM 同款勾选项，默认开）：
      // 纯 Dart 重封装（TsRemuxer，没 ffmpeg 也能转）；转不了就保留 .ts，
      // 不标下载失败（文件本身能播）。
      if (task.kind == DownloadKind.hls && finalPath.endsWith('.ts.tmp')) {
        try {
          final store = await Store.load();
          if (store.tsToMp4) {
            final mp4Path = finalPath.replaceAll(RegExp(r'\.ts\.tmp$'), '.mp4.tmp');
            await TsRemuxer.remuxFile(finalPath, mp4Path);
            await File(finalPath).delete();
            finalPath = mp4Path;
            task.remuxedToMp4 = true;
          }
        } catch (_) {
          // 转失败：保留 .ts，照常落盘。
        }
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
      _clearSpeed(task);
      // 封面兜底：下完的是 mp4、且海报还是空或远程地址时，从视频里抽一帧当封面。
      // 本地海报已存下来时不动它；.ts 不抽（抽帧只认 mp4）；失败静默跳过。
      if (finalPath.endsWith('.mp4.tmp') &&
          (task.poster.isEmpty || task.poster.startsWith('http'))) {
        try {
          final docs = await getApplicationDocumentsDirectory();
          final frame = await extractPosterFrame(
            videoPath: finalPath,
            thumbDirPath: '${docs.path}/posters',
          );
          if (frame != null && frame.isNotEmpty) {
            task.poster = frame;
          }
        } catch (_) {}
      }
      try {
        await File(finalPath).delete();
      } catch (_) {}
    } on _Paused {
      task.status = DownloadStatus.paused;
      _clearSpeed(task);
    } catch (e) {
      task.status = DownloadStatus.error;
      task.error = _shortError(e);
      _clearSpeed(task);
    }
    _jobs.remove(task.id);
    _notifyAndPersist(persist: true);
    _pumpQueue();
  }

  /// mp4：Range 分段并行（默认 8 段）或单连接回退。
  /// 断点续传：task.segmentDone 记每段已下字节数，暂停/被杀后只下未完成的分段。
  /// 第 57 条：每段写自己的 part 文件（`${tmpPath}.part$i`），下完再按序拼成
  /// tmpPath——绝不能多段同时往同一个文件里写（FileMode.write 打开就截断，
  /// 后开的段会把先开的段已写好的数据清掉，拼出来大小对、内容是 0 洞）。
  /// 分段失败（比如中途某段拿不到 206）：删掉分段残留，单连接重下一次。
  Future<String> _downloadMp4(_DownloadJob job, String tmpPath, DownloadTask task) async {
    final sw = Stopwatch()..start();
    final probe = await probeRange(job.url, job.headers);
    final total = probe.totalBytes;
    task.totalBytes = total;
    if (!probe.supported) {
      return _downloadSingleMp4(job, tmpPath, task, total);
    }
    final useSegments = total >= minSegmentedSize;
    // parts 上限取 defaultParts 与自适应并发当前值的较小值（起步都是 8；
    // 上一轮被压制回退到 4 时，下一轮就只开 4 段）。
    final partsCap = defaultParts < _ramp.current ? defaultParts : _ramp.current;
    final parts = useSegments
        ? (total ~/ minSegmentSize).clamp(2, partsCap)
        : 1;
    if (task.segmentDone.length != parts) {
      task.segmentDone = List<int>.filled(parts, 0);
    }
    final bounds = <(int, int)>[];
    for (var i = 0; i < parts; i++) {
      final a = i * total ~/ parts;
      final b = (i + 1) * total ~/ parts - 1;
      bounds.add((a, i == parts - 1 ? total - 1 : b));
    }
    final job2 = job;
    // 分段下载整程共用一个 HttpClient（连接复用/keep-alive）：
    // 原来每段每次重试都新建 HttpClient、用完 close(force: true)，
    // 几十个段就是几十次 TCP+TLS 握手，握手比传数据还慢。
    final sharedClient = HttpClient();
    try {
      await _runSegments(
        parts: parts,
        task: task,
        work: (i) async {
          final (a, b) = bounds[i];
          final done = task.segmentDone[i];
          if (done >= b - a + 1) return; // 这段已下完，跳过（续传）
          final partPath = '$tmpPath.part$i';
          // 续传文件丢了或长度对不上记账：这段重下，别拿旧数字骗进度。
          if (done > 0) {
            final part = File(partPath);
            if (!await part.exists() || await part.length() != done) {
              task.segmentDone[i] = 0;
              try {
                await part.delete();
              } catch (_) {}
            }
          }
          await _downloadRange(
            url: job2.url,
            headers: job2.headers,
            start: a,
            end: b,
            targetPath: partPath,
            writeOffset: task.segmentDone[i],
            onBytes: (n) {
              task.segmentDone[i] += n;
              task.downloadedBytes = task.segmentDone.fold(0, (s, e) => s + e);
              if (total > 0) task.progress = task.downloadedBytes / total;
              _recordBytes(task);
              _throttledNotify(task);
            },
            isCancelled: () => job2.cancelled,
            retries: 3,
            client: sharedClient,
          );
        },
      );
    } catch (e) {
      if (e is _Paused) rethrow;
      // 分段失败：记一次失败实测（下一轮并发减半），删掉分段残留，单连接重下一次。
      _recordRun(
          bytes: task.downloadedBytes,
          elapsed: sw.elapsed,
          concurrency: parts,
          failedSegments: 1,
          totalSegments: 1);
      await deleteParts(tmpPath, parts);
      return _downloadSingleMp4(job, tmpPath, task, total);
    } finally {
      sharedClient.close(force: true);
    }
    await mergeParts(tmpPath, parts);
    final size = await File(tmpPath).length();
    if (total > 0 && size != total) {
      _recordRun(
          bytes: size,
          elapsed: sw.elapsed,
          concurrency: parts,
          failedSegments: 1,
          totalSegments: 1);
      throw StateError('合并后大小不符 $size != $total');
    }
    _recordRun(
        bytes: total,
        elapsed: sw.elapsed,
        concurrency: parts,
        totalSegments: parts);
    return tmpPath;
  }

  /// mp4 单连接从头下（服务器不支持 Range，或分段失败后的回退）。
  /// 续传不了——Range 都不支持，暂停后只能重下；记账清零，别拿旧数字骗进度条。
  Future<String> _downloadSingleMp4(
      _DownloadJob job, String tmpPath, DownloadTask task, int total) async {
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
        _recordBytes(task);
        _throttledNotify(task);
      },
      isCancelled: () => job.cancelled,
    );
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
    void Function(int index)? onSegmentDone,
    Future<List<String>?> Function()? refreshSegments,
    http.Client? client,
    bool Function()? isCancelled,
    int? concurrency,
    void Function(
            {required int status429,
            required int status403,
            required int totalSegments})? onRunStats,
  }) async {
    final ownsClient = client == null;
    final sharedClient = client ?? http.Client();
    // 并发 worker 数：调用方（任务层）按自适应并发给，没给就用默认 8。
    final workers = (concurrency ?? hlsDefaultConcurrency).clamp(1, 32);
    var seen429 = 0;
    var seen403 = 0;
    void countStatus(int s) {
      if (s == 429) seen429++;
      if (s == 403) seen403++;
    }

    void reportStats(int totalSegments) {
      onRunStats?.call(
          status429: seen429, status403: seen403, totalSegments: totalSegments);
    }
    try {
      final mediaUrl =
          await _resolveMediaPlaylist(masterUrl, headers, client: sharedClient);
      final playlistBody =
          await _fetchText(mediaUrl, headers, client: sharedClient);
      if (playlistBody.contains('#EXT-X-KEY') &&
          !playlistBody.contains('METHOD=NONE')) {
        throw StateError('这条是加密 HLS（AES-128），App 里下不了，只能在线看');
      }
      var segments = parseHlsSegments(playlistBody, mediaUrl);
      if (segments.isEmpty) throw StateError('播放列表里没有分片');
      final isFmp4 = playlistBody.contains('#EXT-X-MAP');
      final tmpDir = Directory('$targetPath.segs');
      await tmpDir.create(recursive: true);
      var segPaths = List<String>.generate(
          segments.length, (i) => '${tmpDir.path}/$i.ts');
      final done = <int>{
        for (final i in (alreadyDone ?? {}))
          if (i < segments.length && File(segPaths[i]).existsSync()) i
      };
      var completed = done.length;
      var downloaded = 0;
      var cursor = 0;
      // 403/连接被掐时重拉分片列表：整条下载最多重拉 1 次（多个 worker
      // 并发时先抢到的那一个拉，标记先占上、再等结果，不重复拉）。
      var refreshedOnce = false;
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
              // 流式写盘：边收边写，不把整段先缓存在内存里。
              final n = await _fetchBytesToFile(segments[i], headers,
                  segPaths[i],
                  client: sharedClient, onHttpStatus: countStatus);
              completed++;
              downloaded += n;
              onSegmentDone?.call(i);
              onProgress?.call(completed, segments.length, downloaded);
              ok = true;
            } catch (e) {
              if (isCancelled != null && isCancelled()) throw _Paused();
              if (attempt == 2) {
                // 最后一次还失败：只对 403/连接被掐重拉一次分片列表再续传，
                // 其他错误直接重抛。
                if (!_isRefreshableError(e) ||
                    refreshSegments == null ||
                    refreshedOnce) {
                  rethrow;
                }
                refreshedOnce = true;
                final fresh = await refreshSegments.call();
                if (fresh == null || fresh.isEmpty) rethrow;
                segments = fresh;
                segPaths = List<String>.generate(
                    segments.length, (i) => '${tmpDir.path}/$i.ts');
                done.removeWhere((idx) => idx >= segments.length);
                completed = done.length;
                if (i >= segments.length) return;
                try {
                  final n = await _fetchBytesToFile(segments[i], headers,
                      segPaths[i],
                      client: sharedClient, onHttpStatus: countStatus);
                  completed++;
                  downloaded += n;
                  onSegmentDone?.call(i);
                  onProgress?.call(completed, segments.length, downloaded);
                  ok = true;
                } catch (e2) {
                  if (isCancelled != null && isCancelled()) throw _Paused();
                  rethrow;
                }
              } else {
                await Future.delayed(Duration(seconds: 1 << attempt));
              }
            }
          }
        }
      }

      await Future.wait(List.generate(workers, (_) => worker()));
      // 顺序拼：fMP4 先写 init 段，再按序号拼；TS 直接按序号拼。
      final out = await File(targetPath).open(mode: FileMode.write);
      try {
        if (isFmp4) {
          final mapUri = _parseExtXMap(playlistBody, mediaUrl);
          if (mapUri != null) {
            final init = await _fetchBytes(mapUri, headers, client: sharedClient);
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
        reportStats(segments.length);
        return mp4Path;
      }
      reportStats(segments.length);
      return targetPath;
    } finally {
      if (ownsClient) sharedClient.close();
    }
  }

  /// 403 或连接被掐（服务端中途断开）时才值得重拉分片列表再续传。
  static bool _isRefreshableError(Object e) {
    final s = e.toString();
    return s.contains('HTTP 403') || s.contains('Connection closed');
  }

  /// 任务层薄壳：把任务的断点记账（segmentDone）翻译成静态函数能用的
  /// alreadyDone，进度回写到任务上。
  Future<String> _downloadHls(
      _DownloadJob job, String tmpPath, DownloadTask task) async {
    final alreadyDone = <int>{
      for (var i = 0; i < task.segmentDone.length; i++)
        if (task.segmentDone[i] == 1) i
    };
    var persistedSegments = 0;
    final sw = Stopwatch()..start();
    var run429 = 0;
    var run403 = 0;
    var runTotal = 0;
    // 自适应并发：本轮用 ramp 当前值，跑完按实测调下一轮。
    final usedConcurrency = _ramp.current;
    try {
      final result = await downloadHlsFile(
        masterUrl: job.url,
        headers: job.headers,
        targetPath: tmpPath,
        alreadyDone: alreadyDone,
        concurrency: usedConcurrency,
        onRunStats: (
            {required status429,
            required status403,
            required totalSegments}) {
          run429 = status429;
          run403 = status403;
          runTotal = totalSegments;
        },
        onProgress: (doneCount, totalCount, bytes) {
          task.segmentTotal = totalCount;
          task.downloadedBytes = bytes;
          task.progress = totalCount > 0 ? doneCount / totalCount : 0;
          _recordBytes(task);
          _throttledNotify(task);
        },
        onSegmentDone: (index) {
          // 每下一好一段就记账（失败重试只补没下的段），每 10 段持久化一次。
          while (task.segmentDone.length <= index) {
            task.segmentDone.add(0);
          }
          task.segmentDone[index] = 1;
          persistedSegments++;
          if (persistedSegments % 10 == 0) {
            _notifyAndPersist(persist: true);
          }
        },
        refreshSegments: () async {
          // 重拉同一条已签名的播放列表地址：临时性失败能救回来；
          // 签名本身过期时重拉也会失败，外层会换成用户看得懂的错误。
          try {
            final mediaUrl =
                await _resolveMediaPlaylist(job.url, job.headers);
            final body = await _fetchText(mediaUrl, job.headers);
            final fresh = parseHlsSegments(body, mediaUrl);
            return fresh.isEmpty ? null : fresh;
          } catch (_) {
            return null;
          }
        },
        isCancelled: () => job.cancelled,
      );
      task.segmentDone = List<int>.filled(task.segmentTotal, 1);
      task.progress = 1.0;
      _recordRun(
          bytes: task.downloadedBytes,
          elapsed: sw.elapsed,
          concurrency: usedConcurrency,
          status429: run429,
          status403: run403,
          totalSegments: runTotal);
      return result;
    } catch (e) {
      // 暂停不是失败，不记实测、不动并发。
      if (e is! _Paused) {
        _recordRun(
            bytes: task.downloadedBytes,
            elapsed: sw.elapsed,
            concurrency: usedConcurrency,
            status429: run429,
            status403: run403,
            failedSegments: 1,
            totalSegments: 1);
      }
      final s = e.toString();
      if (s.contains('HTTP 403') || s.contains('Connection closed')) {
        throw StateError(
            '分片拉取失败：服务器拒绝了连接，可能是链接过期，重新打开视频页再下载');
      }
      rethrow;
    }
  }

  /// 主播放列表 -> 选 BANDWIDTH 最大的变体；已经是媒体播放列表就原样返回。
  static Future<String> _resolveMediaPlaylist(
      String url, Map<String, String> headers,
      {http.Client? client}) async {
    final body = await _fetchText(url, headers, client: client);
    if (!body.contains('#EXT-X-STREAM-INF')) return url;
    final variant = pickHlsVariant(body, url);
    if (variant == null) return url;
    return variant;
  }

  static Future<String> _fetchText(String url, Map<String, String> headers,
      {http.Client? client}) async {
    final uri = Uri.parse(url);
    final requestHeaders = {'User-Agent': _ua, ...headers};
    final res = await (client != null
            ? client.get(uri, headers: requestHeaders)
            : http.get(uri, headers: requestHeaders))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw StateError('拉播放列表失败：HTTP ${res.statusCode}');
    return utf8.decode(res.bodyBytes);
  }

  /// 读响应头 retry-after（不区分大小写；解析不到或 ≤0 按 2 秒，超 10 秒按 10 秒封顶）。
  static int _parseRetryAfter(Map<String, String> responseHeaders) {
    String? raw;
    for (final entry in responseHeaders.entries) {
      if (entry.key.toLowerCase() == 'retry-after') {
        raw = entry.value;
        break;
      }
    }
    final seconds = int.tryParse((raw ?? '').trim());
    if (seconds == null || seconds <= 0) return 2;
    return seconds > 10 ? 10 : seconds;
  }

  /// 403 换请求头恢复用的第二组头（传输层 SegmentDownloader 的轮换第 2 组）：
  /// 去掉 Referer、换备用 UA。
  static Map<String, String> _altHeaders(Map<String, String> headers) {
    return Map<String, String>.from(headers)
      ..remove('Referer')
      ..['User-Agent'] = _altUa;
  }

  static Future<List<int>> _fetchBytes(String url, Map<String, String> headers,
      {http.Client? client, void Function(int status)? onHttpStatus}) async {
    final uri = Uri.parse(url);
    final requestHeaders = {'User-Agent': _ua, ...headers};

    Future<http.Response> send([Map<String, String>? hdrs]) {
      final future = client != null
          ? client.get(uri, headers: hdrs ?? requestHeaders)
          : http.get(uri, headers: hdrs ?? requestHeaders);
      return future.timeout(const Duration(seconds: 30));
    }

    var res = await send();
    if (res.statusCode != 200) onHttpStatus?.call(res.statusCode);
    if (res.statusCode == 429 || res.statusCode == 503) {
      final retryAfter = _parseRetryAfter(res.headers);
      await Future<void>.delayed(Duration(seconds: retryAfter));
      res = await send();
      if (res.statusCode != 200) {
        onHttpStatus?.call(res.statusCode);
        throw StateError('HTTP ${res.statusCode} (retry-after $retryAfter)');
      }
      return res.bodyBytes;
    }
    if (res.statusCode == 403) {
      // 403 换请求头恢复：去 Referer + 备用 UA 再试一次，仍 403 再抛。
      res = await send(_altHeaders(headers));
      if (res.statusCode != 200) {
        onHttpStatus?.call(res.statusCode);
        throw StateError('HTTP ${res.statusCode}');
      }
      return res.bodyBytes;
    }
    if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
    return res.bodyBytes;
  }

  /// 流式下分片：边收边写文件，不把整段先缓存在内存里（HLS 分片几百个，
  /// 每段几百 KB，全缓冲既占内存又慢）。语义与 _fetchBytes 一致：
  /// 429/503 按 retry-after 重发一次；403 去 Referer + 备用 UA 重发一次；
  /// 非 200 或 0 字节时删掉不完整文件再抛错（别留 0 字节段冒充下好的段）；
  /// 返回写好的字节数。
  static Future<int> _fetchBytesToFile(
    String url,
    Map<String, String> headers,
    String targetPath, {
    http.Client? client,
    void Function(int status)? onHttpStatus,
  }) async {
    final uri = Uri.parse(url);
    final ownsClient = client == null;
    final sharedClient = client ?? http.Client();
    try {
      Future<http.StreamedResponse> send(Map<String, String> hdrs) {
        final req = http.Request('GET', uri)..headers.addAll(hdrs);
        return sharedClient.send(req).timeout(const Duration(seconds: 30));
      }

      final requestHeaders = {'User-Agent': _ua, ...headers};
      Future<int> writeStream(http.StreamedResponse res) async {
        final sink = File(targetPath).openWrite();
        var n = 0;
        try {
          await for (final chunk
              in res.stream.timeout(const Duration(seconds: 60))) {
            sink.add(chunk);
            n += chunk.length;
          }
        } finally {
          await sink.close();
        }
        return n;
      }

      Future<void> dropIncomplete() async {
        try {
          await File(targetPath).delete();
        } catch (_) {}
      }

      var res = await send(requestHeaders);
      if (res.statusCode != 200) onHttpStatus?.call(res.statusCode);
      if (res.statusCode == 429 || res.statusCode == 503) {
        final retryAfter = _parseRetryAfter(res.headers);
        await res.stream.drain<void>();
        await Future<void>.delayed(Duration(seconds: retryAfter));
        res = await send(requestHeaders);
        if (res.statusCode != 200) {
          onHttpStatus?.call(res.statusCode);
          await res.stream.drain<void>();
          throw StateError('HTTP ${res.statusCode} (retry-after $retryAfter)');
        }
        final n = await writeStream(res);
        if (n == 0) {
          await dropIncomplete();
          throw StateError('分片为空');
        }
        return n;
      }
      if (res.statusCode == 403) {
        await res.stream.drain<void>();
        res = await send(_altHeaders(headers));
        if (res.statusCode != 200) {
          onHttpStatus?.call(res.statusCode);
          await res.stream.drain<void>();
          throw StateError('HTTP ${res.statusCode}');
        }
        final n = await writeStream(res);
        if (n == 0) {
          await dropIncomplete();
          throw StateError('分片为空');
        }
        return n;
      }
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        throw StateError('HTTP ${res.statusCode}');
      }
      final n = await writeStream(res);
      if (n == 0) {
        await dropIncomplete();
        throw StateError('分片为空');
      }
      return n;
    } finally {
      if (ownsClient) sharedClient.close();
    }
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

  /// 一段 Range 下载（带 3 次重试）。
  /// 第 57 条：targetPath 必须是这段专属的 part 文件，绝不能是多段共用的
  /// 目标文件——`FileMode.write` 打开就截断，多段同时往一个文件里写时，
  /// 后开的段会把先开的段已写好的数据清掉，拼出来大小对、内容是 0 洞
  /// （v11 的 App 内更新就是这么坏的；复现见 test/update_download_test.dart）。
  /// writeOffset = part 文件里已有的字节数（断点续传；全新下为 0）：
  /// 为 0 时截断重建；>0 时先验长度对不对得上，再以追加模式接着写。
  /// 同一次调用内重试共用一个文件句柄，不重复打开、不重复截断；
  /// 写操作全程顺序追加，不用 setPosition，不存在段间互相覆盖。
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
    HttpClient? client,
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
      client: client,
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
    HttpClient? client,
  }) async {
    Object? lastError;
    var written = 0; // 本次调用新写入的字节数
    final expected = end - start + 1 - writeOffset; // 本次调用要下的字节数
    if (expected <= 0) return; // 这段已经下完了（续传时）
    if (writeOffset > 0) {
      // 续传：part 文件必须正好是 writeOffset 字节，否则删了重下。
      final part = File(targetPath);
      if (!await part.exists() || await part.length() != writeOffset) {
        throw StateError('分段续传文件不对（缺失或长度不符），删了重下');
      }
    }
    // 共享连接：调用方传了 client 就复用它（_downloadMp4 整程共用一个，
    // 连接复用/keep-alive）；没传就自己建一个、用完关掉（老行为）。
    final ownsClient = client == null;
    final sharedClient = client ?? HttpClient();
    RandomAccessFile? raf;
    try {
      // 打开一次、用到底：重试不重复打开（重复打开会再截断一次）。
      // 全新下截断重建；续传用追加模式（O_APPEND，只往文件尾写，
      // 本调用只顺序追加，所以位置一定对）。
      raf = await File(targetPath).open(
          mode: writeOffset == 0 ? FileMode.write : FileMode.append);
      for (var attempt = 0; attempt < retries; attempt++) {
        if (isCancelled()) throw _Paused();
        try {
          final req = await sharedClient.getUrl(Uri.parse(url));
          req.headers.set('User-Agent', _ua);
          headers.forEach((k, v) => req.headers.set(k, v));
          req.headers
              .set('Range', 'bytes=${start + writeOffset + written}-$end');
          final res = await req.close().timeout(const Duration(seconds: 60));
          if (res.statusCode != 206) {
            throw StateError('分段响应码 ${res.statusCode}（服务器不支持 Range）');
          }
          await for (final chunk in res.timeout(const Duration(seconds: 60))) {
            if (isCancelled()) throw _Paused();
            await raf.writeFrom(chunk);
            written += chunk.length;
            onBytes(chunk.length);
          }
          // 注意：这里不关 sharedClient——重试还要复用它；自有连接在
          // 外层 finally 里统一关，调用方传进来的绝不关。
          // 每段完整性校验（抄 SniffDL：got 必须等于 want，否则这段不算完）。
          if (written != expected) {
            throw StateError('分段不完整 $written/$expected');
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
    } finally {
      if (ownsClient) sharedClient.close(force: true);
      await raf?.close();
    }
    throw lastError ?? StateError('分段下载失败');
  }

  /// 分段 part 文件按序拼成目标文件（第 57 条）。
  /// 每个 part 只被自己的段写过，拼的时候单句柄顺序写，没有并发截断。
  /// 拼完删 part 文件。
  static Future<void> mergeParts(String targetPath, int parts) async {
    final out = await File(targetPath).open(mode: FileMode.write);
    try {
      for (var i = 0; i < parts; i++) {
        final part = File('$targetPath.part$i');
        await out.writeFrom(await part.readAsBytes());
        await part.delete();
      }
    } finally {
      await out.close();
    }
  }

  /// 删掉分段残留（失败回退/重下前调用，别把旧 part 当新数据拼进去）。
  static Future<void> deleteParts(String targetPath, int parts) async {
    for (var i = 0; i < parts; i++) {
      try {
        await File('$targetPath.part$i').delete();
      } catch (_) {}
    }
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

  /// 海报图存本地（封面本地化）：把远程 poster URL 的图片用带 UA + Referer
  /// 的请求下到应用文档目录 `posters/<taskId>.jpg`，返回本地绝对路径；
  /// 拿不到（空地址、data: 占位、非 200、非图片、异常）返回 null，不抛错。
  /// fetchImage 可注入（单元测试用假响应，不真联网）。
  static Future<String?> savePosterLocally({
    required String taskId,
    required String posterUrl,
    String? referer,
    Future<http.Response> Function(Uri url, Map<String, String> headers)?
        fetchImage,
  }) async {
    try {
      if (posterUrl.isEmpty || posterUrl.startsWith('data:')) return null;
      final uri = Uri.tryParse(posterUrl);
      if (uri == null) return null;
      final headers = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        if (referer != null && referer.isNotEmpty) 'Referer': referer,
      };
      final res = fetchImage != null
          ? await fetchImage(uri, headers).timeout(const Duration(seconds: 8))
          : await http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final contentType = (res.headers['content-type'] ??
              res.headers['Content-Type'] ??
              '')
          .toLowerCase()
          .trim();
      if (!contentType.startsWith('image/')) return null;
      final safeId = taskId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final docs = await getApplicationDocumentsDirectory();
      final posterDir = Directory('${docs.path}/posters');
      if (!await posterDir.exists()) {
        await posterDir.create(recursive: true);
      }
      final file = File('${posterDir.path}/$safeId.jpg');
      await file.writeAsBytes(res.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 从本地 mp4 里抽一帧当封面（下载完成后的封面兜底）。
  /// videoPath 为空、抽帧失败、产出路径为空时返回 null，不抛错。
  static Future<String?> extractPosterFrame({
    required String videoPath,
    required String thumbDirPath,
  }) async {
    try {
      if (videoPath.isEmpty) return null;
      final thumbDir = Directory(thumbDirPath);
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      final thumb = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: thumbDir.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 640,
        quality: 75,
        timeMs: 1000,
      );
      if (thumb.path.isEmpty) return null;
      return thumb.path;
    } catch (_) {
      return null;
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

    Future<int> single() async {
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
      return 1;
    }

    var usedParts = 1;
    if (probe.supported && total >= minSegmentedSize) {
      // 第 57 条：每段写自己的 part 文件，下完再按序拼——绝不能多段
      // 同时往同一个目标文件里写（FileMode.write 打开就截断，拼出来
      // 大小对、内容是 0 洞）。
      usedParts = (total ~/ minSegmentSize).clamp(2, parts);
      final done = List<int>.filled(usedParts, 0);
      var next = 0;
      // 分段整程共用一个 HttpClient（连接复用），同 _downloadMp4。
      final sharedClient = HttpClient();
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
            targetPath: '$targetPath.part$i',
            writeOffset: 0,
            onBytes: (n) {
              done[i] += n;
              onProgress(done.fold(0, (s, e) => s + e), total);
            },
            isCancelled: cancelled,
            client: sharedClient,
          );
        }
      }

      try {
        await Future.wait(List.generate(usedParts, (_) => worker()));
      } catch (e) {
        if (e is _Paused) rethrow;
        // 分段失败（比如中途某段拿不到 206）：删掉残留，单连接重下一次。
        await deleteParts(targetPath, usedParts);
        return single();
      } finally {
        sharedClient.close(force: true);
      }
      await mergeParts(targetPath, usedParts);
      final size = await File(targetPath).length();
      if (size != total) throw StateError('合并后大小不符 $size != $total');
      return usedParts;
    }
    return single();
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
        t.error = StreamResolver.lastFailureReason ?? '直链过期了，删掉重新下载';
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

  /// 失败的任务重试（第 38 条）：先丢掉旧直链地址（签名可能过期、CDN 可能轮换），
  /// 再走 resumeTask 的重解析路径；已下完的部分接着续传，不用从头下。
  Future<void> retryTask(String id) async {
    final t = taskFor(id);
    if (t == null || t.status != DownloadStatus.error) return;
    _jobs.remove(id);
    t.status = DownloadStatus.paused;
    t.error = null;
    _notifyAndPersist(persist: true);
    await resumeTask(id);
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

  /// 第 38 条：下载失败不许把原始异常堆栈直接甩给用户看（之前
  /// `HandshakeException: ... CERTIFICATE_VERIFY_FAILED: Hostname mismatch
  /// (handshake.cc:320)` 就这么原样上了下载管理页）。按原因写人话：
  /// 证书错、断网、源站拒绝各给一句话 + 能怎么办；其他错误才截断原文。
  static String humanDownloadError(Object e) {
    final s = e.toString();
    if (s.contains('CERTIFICATE_VERIFY_FAILED') || s.contains('HandshakeException')) {
      return '证书验证失败：直链域名和证书对不上（可能是源站换了 CDN 节点，或手机开了代理/VPN）。重试会重新解析直链，也可去内置浏览器里嗅探下载';
    }
    if (s.contains('SocketException') ||
        s.contains('Connection refused') ||
        s.contains('Network is unreachable') ||
        s.contains('Connection reset')) {
      return '网络连不上（断网或源站连不上），检查网络后重试';
    }
    if (s.contains('403')) return '源站拒绝了这次下载（403），直链可能过期了，重试会重新解析';
    if (s.contains('404')) return '直链找不到了（404），重试会重新解析';
    final flat = s.replaceAll(RegExp(r'\s+'), ' ');
    return flat.length > 120 ? '${flat.substring(0, 120)}…' : flat;
  }

  String _shortError(Object e) => humanDownloadError(e);
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
