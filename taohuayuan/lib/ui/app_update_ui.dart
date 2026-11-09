import 'dart:io';

import 'package:flutter/material.dart';

import '../services/apk_verify.dart';
import '../services/app_update.dart';
import '../services/store.dart';

/// 应用内更新的 UI（第 50 条）：「我的」里的版本卡片 + 发现新版弹窗 +
/// 下载安装流程。下载走 AppUpdateService（复用视频下载的多段 Range 引擎），
/// 安装走系统安装器（FileProvider + ACTION_VIEW）。
/// 启动时每天最多自动查一次（见 maybeCheckUpdateOnStartup），
/// 用户点了“稍后”就记下这个 tag，同一版不再弹窗。

/// 启动时查一次新版（每天最多一次；查不到不记时间，下次启动再试）。
/// 有新版且用户没点过“稍后”才弹窗；点“立即更新”直接进下载安装流程。
Future<void> maybeCheckUpdateOnStartup(BuildContext context, Store store) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - store.lastUpdateCheckMs <
      const Duration(hours: 24).inMilliseconds) {
    return;
  }
  final svc = AppUpdateService.instance;
  final info = await svc.checkLatest();
  if (info == null) return; // 检查失败：不记时间，下次启动再试
  await store.setLastUpdateCheckMs(now);
  final local = await svc.localVersion();
  if (local == null) return;
  if (!AppUpdateService.isNewer(info, local.code)) return;
  if (store.skippedUpdateTag == info.tag) return;
  if (!context.mounted) return;
  final go = await showUpdateAvailableDialog(context, store, info, local);
  if (go == true && context.mounted) {
    await showUpdateDownloadSheet(context, store, info);
  }
}

/// “发现新版本”弹窗。返回 true = 点了“立即更新”。
Future<bool?> showUpdateAvailableDialog(
  BuildContext context,
  Store store,
  AppUpdateInfo info,
  AppVersion local,
) {
  final notes = info.notes.trim();
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF1C1C22),
      title: Text('发现新版本 v${info.remoteCode}',
          style: const TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前版本 ${local.display} · 新版 ${AppUpdateService.formatSize(info.sizeBytes)}',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('更新内容', style: TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(height: 4),
              Text(
                notes.length > 500 ? '${notes.substring(0, 500)}…' : notes,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await store.setSkippedUpdateTag(info.tag);
            if (context.mounted) Navigator.of(context).pop(false);
          },
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('立即更新'),
        ),
      ],
    ),
  );
}

/// 下载 + 安装流程（底部弹层，自己管状态，哪里都能调）。
/// 先看安装权限 → 下 APK（多段并行，带速度）→ 下完自动调系统安装器。
/// 返回下好的安装包路径（没下完返回 null），调用方据此刷新按钮状态。
Future<String?> showUpdateDownloadSheet(
  BuildContext context,
  Store store,
  AppUpdateInfo info,
) {
  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1C1C22),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _UpdateDownloadSheet(store: store, info: info),
  );
}

class _UpdateDownloadSheet extends StatefulWidget {
  final Store store;
  final AppUpdateInfo info;
  const _UpdateDownloadSheet({required this.store, required this.info});

  @override
  State<_UpdateDownloadSheet> createState() => _UpdateDownloadSheetState();
}

class _UpdateDownloadSheetState extends State<_UpdateDownloadSheet> {
  final _svc = AppUpdateService.instance;
  bool _checkingPermission = true;
  bool _canInstall = false;
  bool _downloading = false;
  bool _cancelled = false;
  int _downloaded = 0;
  int _total = 0;
  double _speedBps = 0;
  String? _apkPath;
  String? _error;
  String? _doneText;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  /// 已下好的包先验 ZIP 再复用，不重复下；权限没开先提示去设置。
  /// 第 57 条：只看大小会把坏包当好包一直复用（用户缓存里的坏 v11
  /// 就是这么来的），验不过的清掉记录，重新下载。
  Future<void> _prepare() async {
    final storedPath = widget.store.updateApkPath;
    final storedTag = widget.store.updateApkTag;
    if (storedPath != null &&
        storedTag == widget.info.tag &&
        await File(storedPath).exists()) {
      final bad = await verifyApkFile(storedPath,
          expectedSize:
              widget.info.sizeBytes > 0 ? widget.info.sizeBytes : null);
      if (bad == null) {
        _apkPath = storedPath;
      } else {
        // 缓存里的包坏了：清掉记录和文件，别再拿它去安装。
        await widget.store.clearUpdateApk();
        try {
          await File(storedPath).delete();
        } catch (_) {}
      }
    }
    final ok = await _svc.canInstall();
    if (!mounted) return;
    setState(() {
      _checkingPermission = false;
      _canInstall = ok;
    });
  }

  Future<void> _startDownload() async {
    setState(() {
      _downloading = true;
      _cancelled = false;
      _error = null;
      _downloaded = 0;
      _total = widget.info.sizeBytes;
      _speedBps = 0;
    });
    try {
      final path = await _svc.downloadApk(
        widget.info,
        onProgress: (d, t, s) {
          if (!mounted) return;
          setState(() {
            _downloaded = d;
            _total = t;
            _speedBps = s;
          });
        },
        isCancelled: () => _cancelled,
      );
      await widget.store.setUpdateApk(widget.info.tag, path);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _apkPath = path;
      });
      await _install();
    } on UpdateCancelled {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '已取消下载，下次再下不用从头来（已下完的包会留着）。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '下载失败：${_shortError(e)}，检查网络后重试。';
      });
    }
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) return;
    final ok = await _svc.installApk(path);
    if (!mounted) return;
    setState(() {
      _doneText = ok
          ? '已打开系统安装器，按提示完成安装（装完不用删旧版，直接覆盖）。'
          : '安装器没打开，再点一次“安装”，或检查安装包还在不在。';
    });
  }

  static String _shortError(Object e) {
    final s = e.toString().replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final progress =
        _total > 0 ? (_downloaded / _total).clamp(0.0, 1.0) : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('更新到 v${info.remoteCode}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('安装包 ${AppUpdateService.formatSize(info.sizeBytes)} · 下在 App 缓存里，装完可删',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 16),
          if (_checkingPermission)
            const Row(children: [
              SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text('正在检查安装权限…', style: TextStyle(color: Colors.white70)),
            ])
          else if (!_canInstall) ...[
            const Text('要先允许安装未知来源应用（只开一次，以后更新不用再开）：',
                style: TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    await _svc.openInstallSettings();
                    // 从设置页回来不会自动回调：用户点“我已开启”再查一次。
                    if (!mounted) return;
                    setState(() => _checkingPermission = true);
                    final ok = await _svc.canInstall();
                    if (!mounted) return;
                    setState(() {
                      _checkingPermission = false;
                      _canInstall = ok;
                    });
                  },
                  child: const Text('去设置开启'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(_apkPath),
                  child: const Text('先不更新'),
                ),
              ),
            ]),
          ] else if (_downloading) ...[
            LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: Colors.white24,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Colors.pinkAccent),
            ),
            const SizedBox(height: 8),
            Text(
              _total > 0
                  ? '已下 ${AppUpdateService.formatSize(_downloaded)} / ${AppUpdateService.formatSize(_total)}'
                      ' · ${(_speedBps / (1024 * 1024)).toStringAsFixed(1)} MB/s'
                  : '已下 ${AppUpdateService.formatSize(_downloaded)}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => setState(() => _cancelled = true),
                child: const Text('取消下载'),
              ),
            ),
          ] else if (_apkPath != null) ...[
            // 第 57 条：走到这里的包一定是验过 ZIP 的（复用前验过，
            // 新下的下完也验过），直接装，不怕再报「安装包已损坏」。
            const Text('安装包已验证 ✓，可直接安装',
                style: TextStyle(color: Colors.greenAccent, fontSize: 13)),
            const SizedBox(height: 12),
            if (_doneText != null) ...[
              Text(_doneText!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _install,
                child: Text('安装 v${info.remoteCode}'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(_apkPath),
                child: const Text('稍后再装'),
              ),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _startDownload,
                child: const Text('下载并安装'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(_apkPath),
                child: const Text('先不更新'),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Colors.orange, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

/// 「我的」里的版本卡片：当前版本、最新版本、一键检查更新、下载安装入口。
class AppUpdateCard extends StatefulWidget {
  final Store store;
  const AppUpdateCard({super.key, required this.store});

  @override
  State<AppUpdateCard> createState() => _AppUpdateCardState();
}

class _AppUpdateCardState extends State<AppUpdateCard> {
  final _svc = AppUpdateService.instance;
  AppVersion? _local;
  AppUpdateInfo? _latest;
  bool _checking = false;
  bool _checkFailed = false;
  String? _apkPath;
  int? _apkCode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final local = await _svc.localVersion();
    String? apkPath;
    int? apkCode;
    final storedPath = widget.store.updateApkPath;
    final storedTag = widget.store.updateApkTag;
    if (storedPath != null && storedTag != null) {
      final code = AppUpdateService.parseReleaseCode(storedTag);
      if (code != null && await File(storedPath).exists()) {
        // 第 57 条：存着的包先验 ZIP 再认，坏的清掉，别显示成“已下载”。
        if (await verifyApkFile(storedPath) == null) {
          apkPath = storedPath;
          apkCode = code;
        } else {
          await widget.store.clearUpdateApk();
          try {
            await File(storedPath).delete();
          } catch (_) {}
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _local = local;
      _apkPath = apkPath;
      _apkCode = apkCode;
    });
  }

  Future<void> _check({bool showUpToDate = true}) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _checkFailed = false;
    });
    final info = await _svc.checkLatest();
    if (!mounted) return;
    if (info == null) {
      setState(() {
        _checking = false;
        _checkFailed = true;
      });
      return;
    }
    await widget.store.setLastUpdateCheckMs(DateTime.now().millisecondsSinceEpoch);
    final local = _local ?? await _svc.localVersion();
    setState(() {
      _checking = false;
      _latest = info;
      _local = local;
    });
    if (local != null &&
        AppUpdateService.isNewer(info, local.code) &&
        mounted) {
      final go = await showUpdateAvailableDialog(context, widget.store, info, local);
      if (go == true && mounted) {
        await _openSheet(info);
      }
    } else if (showUpToDate && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已是最新版本')),
      );
    }
  }

  Future<void> _openSheet(AppUpdateInfo info) async {
    final path = await showUpdateDownloadSheet(context, widget.store, info);
    if (!mounted) return;
    if (path != null) {
      setState(() {
        _apkPath = path;
        _apkCode = info.remoteCode;
      });
    } else {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final local = _local;
    final latest = _latest;
    final hasUpdate = local != null &&
        latest != null &&
        AppUpdateService.isNewer(latest, local.code);
    final downloadedCode = _apkCode;
    return Card(
      color: const Color(0xFF1C1C22),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('版本更新',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            const Text('不用删了重装，App 里直接升新版',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            Text(
              '当前版本：${local == null ? '加载中…' : local.display}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              _checkFailed
                  ? '最新版本：检查失败，检查网络后重试'
                  : latest == null
                      ? '最新版本：还没检查'
                      : hasUpdate
                          ? '最新版本：v${latest.remoteCode}（有新版，${AppUpdateService.formatSize(latest.sizeBytes)}）'
                          : '最新版本：已是最新',
              style: TextStyle(
                  color: hasUpdate ? Colors.amber : Colors.white70,
                  fontSize: 13),
            ),
            if (hasUpdate && latest.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                latest.notes.trim().length > 120
                    ? '${latest.notes.trim().substring(0, 120)}…'
                    : latest.notes.trim(),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
            // 第 57 条：走到这里的已下载包是验过 ZIP 的，直接装。
            if (_apkPath != null && downloadedCode != null) ...[
              const SizedBox(height: 4),
              Text(
                '安装包 v$downloadedCode 已下载并验证 ✓，可直接安装',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _checking ? null : () => _check(),
                  child: Text(_checking ? '正在检查…' : '检查更新'),
                ),
              ),
              if (hasUpdate) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _openSheet(latest),
                    child: Text(
                      downloadedCode == latest.remoteCode && _apkPath != null
                          ? '安装 v${latest.remoteCode}'
                          : '下载并安装',
                    ),
                  ),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}
