import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'downloader.dart';

/// 应用内更新（第 50 条）：侧载包没有 Play 商店，in-app update API 用不了，
/// 自己走 GitHub Releases 查新版 → 多段下 APK → 调系统安装器装。
/// 版本号规则：pubspec 的 versionCode 就是发布号（v10 = versionCode 10），
/// 工作流按它打 tag（taohuayuan-v10）；App 读 releases/latest，
/// 拿 tag 里的数字跟本机 versionCode 比，大了就是有新版。
/// 本机版本号直接读 PackageManager（走 taohuayuan/update 通道），
/// 不用再加 package_info_plus 依赖。
class AppVersion {
  final String name; // versionName，如 2.9.0
  final int code; // versionCode，就是发布号，如 10
  const AppVersion(this.name, this.code);

  /// 给用户看的版本：v10（2.9.0）。
  String get display => 'v$code（$name）';
}

class AppUpdateInfo {
  final int remoteCode;
  final String tag;
  final String name;
  final String downloadUrl;
  final int sizeBytes;
  final String notes;
  final DateTime? publishedAt;
  const AppUpdateInfo({
    required this.remoteCode,
    required this.tag,
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.notes,
    this.publishedAt,
  });
}

/// 用户点了取消（不是下载失败）：调用方据此关进度条，别报“下载失败”。
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class AppUpdateService {
  AppUpdateService();

  static final instance = AppUpdateService();

  static const _channel = MethodChannel('taohuayuan/update');

  /// GitHub Releases 列表（取前 20 个）：公开仓库，不用登录就能读。
  /// 未登录限流 60 次/小时/IP——App 每天最多自动查一次 + 用户手动点，
  /// 够用了；超了就当检查失败，不拿“没新版”骗人。
  /// 注意：不要用 releases/latest——GitHub 的 latest 是按 created_at 排的，
  /// 2026-11-09 实测：v10 release 的 created_at（11-08）比旧固定 tag 的
  /// release（11-09）还早，latest 指向旧 tag，App 查不到新版。
  /// 所以拉列表、按 tag 里的发布号取最大的那一个，不依赖 GitHub 的排序。
  static const releasesListUrl =
      'https://api.github.com/repos/suiwang974/thy/releases?per_page=20';

  AppVersion? _cachedLocal;

  /// tag 里解析发布号：taohuayuan-v10 -> 10。
  /// 老的固定 tag（taohuayuan-v2.9.0）解析不到，返回 null——
  /// 那种 release 不认作新版，免得把 v9 的旧包当更新推给用户。
  static int? parseReleaseCode(String tag) {
    final m = RegExp(r'^taohuayuan-v(\d+)$').firstMatch(tag.trim());
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// release JSON 里挑 APK 附件，拼成更新信息。
  /// 没有 APK 附件（只有源码 zip 之类）返回 null，不拿源码包当更新。
  static AppUpdateInfo? parseLatestRelease(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String?;
    if (tag == null) return null;
    final code = parseReleaseCode(tag);
    if (code == null) return null;
    final assets = json['assets'];
    Map<String, dynamic>? apk;
    if (assets is List) {
      for (final a in assets) {
        if (a is Map<String, dynamic> &&
            ((a['name'] as String?) ?? '').endsWith('.apk')) {
          apk = a;
          break;
        }
      }
    }
    if (apk == null) return null;
    final url = apk['browser_download_url'] as String?;
    if (url == null || url.isEmpty) return null;
    return AppUpdateInfo(
      remoteCode: code,
      tag: tag,
      name: (json['name'] as String?) ?? tag,
      downloadUrl: url,
      sizeBytes: (apk['size'] as num?)?.toInt() ?? 0,
      notes: (json['body'] as String?) ?? '',
      publishedAt: DateTime.tryParse((json['published_at'] as String?) ?? ''),
    );
  }

  static bool isNewer(AppUpdateInfo info, int localCode) =>
      info.remoteCode > localCode;

  /// 21553447 -> 20.6 MB；0/负数写“未知大小”，不编数字。
  static String formatSize(int bytes) {
    if (bytes <= 0) return '未知大小';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 分段数：跟视频下载同一套数（Downloader 的常量）。
  /// 8MB 以下不分段；以上按每段至少 2MB 算，最多 8 段。
  static int computeParts(int totalBytes) {
    if (totalBytes < DownloadManager.minSegmentedSize) return 1;
    return (totalBytes ~/ DownloadManager.minSegmentSize)
        .clamp(2, DownloadManager.defaultParts);
  }

  Future<AppVersion?> localVersion() async {
    if (_cachedLocal != null) return _cachedLocal;
    try {
      final m = await _channel.invokeMethod<Map>('getVersion');
      if (m == null) return null;
      final v = AppVersion(
        (m['versionName'] as String?) ?? '',
        (m['versionCode'] as num?)?.toInt() ?? 0,
      );
      _cachedLocal = v;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// 查最新版：拉 releases 列表，取 tag 里发布号最大的那一个
  /// （不依赖 GitHub latest 的 created_at 排序，见 releasesListUrl 注释）。
  /// 返回 null = 查不到（没网、GitHub 限流、解析失败），
  /// 调用方显示“检查失败”，别写成“已是最新”。
  Future<AppUpdateInfo?> checkLatest({http.Client? client}) async {
    final c = client ?? http.Client();
    final owned = client == null;
    try {
      final res = await c
          .get(Uri.parse(releasesListUrl),
              headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return null;
      AppUpdateInfo? best;
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final info = parseLatestRelease(item);
        if (info == null) continue;
        if (best == null || info.remoteCode > best.remoteCode) best = info;
      }
      return best;
    } catch (_) {
      return null;
    } finally {
      if (owned) c.close();
    }
  }

  /// 下 APK（复用 Downloader 的多段 Range 引擎：1 字节探测 + 分段并行 + 单连接回退）。
  /// 下在 App 缓存目录 update/ 里（FileProvider 只开放这个目录给系统安装器）；
  /// 同一版已下完的直接用，不重复下；没下完的删了重下（21MB，5G 下就几秒，
  /// 不做跨会话断点续传——视频下载才有分段记账，APK 不值得再做一套）。
  /// 下完验大小，对不上就报错，别拿坏包去安装。
  Future<String> downloadApk(
    AppUpdateInfo info, {
    void Function(int downloaded, int total, double speedBps)? onProgress,
    required bool Function() isCancelled,
    // 测试用：指定下载目录（默认 App 缓存目录 update/）。
    Directory? downloadDir,
  }) async {
    final dir = downloadDir ??
        Directory('${(await getTemporaryDirectory()).path}/update');
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File('${dir.path}/taohuayuan-v${info.remoteCode}.apk');
    if (info.sizeBytes > 0 &&
        await target.exists() &&
        await target.length() == info.sizeBytes) {
      onProgress?.call(info.sizeBytes, info.sizeBytes, 0);
      return target.path;
    }
    if (await target.exists()) await target.delete();
    final speed = _SpeedMeter();
    var downloaded = 0;
    var total = info.sizeBytes;
    void report(int n) {
      downloaded += n;
      speed.add(n);
      onProgress?.call(downloaded, total, speed.bytesPerSecond);
    }
    try {
      final probe = await DownloadManager.probeRange(info.downloadUrl, const {});
      if (probe.totalBytes > 0) total = probe.totalBytes;
      if (probe.supported && total > 0) {
        final parts = computeParts(total);
        final raf = await target.open(mode: FileMode.write);
        await raf.truncate(total); // 预分配满大小（学 1DM：边下边扩容易掉速）
        await raf.close();
        final bounds = <(int, int)>[];
        for (var i = 0; i < parts; i++) {
          final a = i * total ~/ parts;
          final b = (i + 1) * total ~/ parts - 1;
          bounds.add((a, i == parts - 1 ? total - 1 : b));
        }
        await Future.wait(List.generate(parts, (i) async {
          final (a, b) = bounds[i];
          await DownloadManager.downloadRange(
            url: info.downloadUrl,
            headers: const {},
            start: a,
            end: b,
            targetPath: target.path,
            writeOffset: a,
            onBytes: report,
            isCancelled: isCancelled,
            retries: 3,
          );
        }));
      } else {
        // 服务器不支持 Range：单连接从头下。
        await DownloadManager.downloadSingle(
          url: info.downloadUrl,
          headers: const {},
          targetPath: target.path,
          onBytes: report,
          isCancelled: isCancelled,
        );
      }
    } on Object catch (_) {
      if (isCancelled()) throw const UpdateCancelled();
      rethrow;
    }
    final size = await target.length();
    if (total > 0 && size != total) {
      throw StateError('下载后大小不符 $size != $total，请重试');
    }
    return target.path;
  }

  /// 系统允不允许装未知来源应用（Android 8+ 的开关）。
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳到“允许安装未知来源应用”的系统设置页（只对本 App 开一次就行）。
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  /// 调系统安装器装指定 APK。返回 true = 安装器打开了，
  /// false = 没打开（看不到安装器时再点一次，或重下）。
  Future<bool> installApk(String path) async {
    try {
      return await _channel.invokeMethod<bool>(
              'installApk', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

/// 最近 3 秒的实际字节数算速度（跟视频下载同一口径，不许写假数字）。
class _SpeedMeter {
  final _samples = <(DateTime, int)>[];
  void add(int n) {
    final now = DateTime.now();
    _samples.add((now, n));
    while (_samples.isNotEmpty &&
        now.difference(_samples.first.$1) > const Duration(seconds: 3)) {
      _samples.removeAt(0);
    }
  }

  double get bytesPerSecond {
    if (_samples.isEmpty) return 0;
    var span = DateTime.now().difference(_samples.first.$1).inMilliseconds / 1000;
    if (span < 0.5) span = 0.5; // 刚开始样本少，别算出离谱的速度
    var total = 0;
    for (final (_, n) in _samples) {
      total += n;
    }
    return total / span;
  }
}
