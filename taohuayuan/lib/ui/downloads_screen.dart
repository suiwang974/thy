import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/downloader.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 下载管理（第 27 条定死：「我的」里加下载管理，可以看到下载了什么，
/// 也能直接点开看）。
/// - 正在下载：进度条、大小、速度、暂停/继续/取消；
/// - 已下载：点开直接播本地文件（不走网络）；长按/点垃圾桶删除
///   （连同系统 Downloads 里的文件一起删，删前确认）；
/// - 失败的：写明原因，可删掉重新下。
/// 文件存在系统 Downloads/桃花源/ 里，用户在文件管理器里也能直接找到。
class DownloadsScreen extends StatelessWidget {
  final DownloadManager manager;
  final Store store;
  const DownloadsScreen({super.key, required this.manager, required this.store});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        title: const Text('下载管理', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (_, _) {
          final active = manager.tasks
              .where((t) =>
                  t.status == DownloadStatus.downloading ||
                  t.status == DownloadStatus.queued ||
                  t.status == DownloadStatus.paused ||
                  t.status == DownloadStatus.error)
              .toList();
          final done = manager.doneTasks;
          if (active.isEmpty && done.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没下载过视频\n在推荐、短视频、搜索结果或详情页点下载图标就开始下，\n下完的文件存在手机 Downloads/桃花源/ 里。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),
            );
          }
          return ListView(
            children: [
              if (active.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('正在下载', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                ...active.map((t) => _activeTile(context, t)),
              ],
              if (done.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('已下载', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                ...done.map((t) => _doneTile(context, t)),
              ],
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text('文件存在系统 Downloads/桃花源/ 里，文件管理器里也能直接找到。',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _activeTile(BuildContext context, DownloadTask t) {
    return Card(
      color: const Color(0xFF1C1C22),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14)),
                ),
                if (t.status == DownloadStatus.downloading)
                  IconButton(
                    icon: const Icon(Icons.pause, color: Colors.white70),
                    tooltip: '暂停',
                    onPressed: () => manager.pauseTask(t.id),
                  )
                else if (t.status == DownloadStatus.paused)
                  IconButton(
                    icon: const Icon(Icons.play_arrow, color: Colors.white70),
                    tooltip: '继续',
                    onPressed: () => manager.resumeTask(t.id),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  tooltip: '取消下载',
                  onPressed: () => manager.cancelTask(t.id),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: t.progress > 0 ? t.progress : null,
              minHeight: 4,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation<Color>(
                  t.status == DownloadStatus.error ? Colors.redAccent : Colors.pinkAccent),
            ),
            const SizedBox(height: 4),
            Text(
              t.status == DownloadStatus.error
                  ? t.statusText
                  : '${t.statusText} ${(t.progress * 100).round()}% · ${t.sizeText}${t.speedText.isEmpty ? '' : ' · ${t.speedText}'}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            if (t.status == DownloadStatus.error) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  // 第 38 条：失败了能重试（先重新解析直链再下，签名过期/换 CDN 节点
                  // 都能顺带修掉；已下完的部分接着续传，不用从头下）。
                  OutlinedButton(
                    onPressed: () => manager.retryTask(t.id),
                    child: const Text('重试'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () async {
                      await manager.cancelTask(t.id);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已删掉失败的任务，重新点下载图标再下')),
                        );
                      }
                    },
                    child: const Text('删掉这条'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _doneTile(BuildContext context, DownloadTask t) {
    final item = VideoItem(
      id: t.id,
      title: t.title,
      source: t.source,
      poster: t.poster,
      durationSec: t.durationSec,
    );
    return Card(
      color: const Color(0xFF1C1C22),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: SizedBox(width: 96, child: PosterThumb(item: item, height: 54)),
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        subtitle: Text(
          '${t.source}${t.durationSec > 0 ? ' · ${item.durationText}' : ''} · ${t.sizeText}'
          '${t.kind == DownloadKind.hls ? (t.remuxedToMp4 ? ' · 已转 mp4' : ' · HLS 分段拼成 .ts') : ''}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.white54),
          tooltip: '删除（连同文件一起删）',
          onPressed: () => _confirmDelete(context, t),
        ),
        // 点开直接播本地文件（不走网络）。
        onTap: () => _openLocal(context, t, item),
      ),
    );
  }

  Future<void> _openLocal(BuildContext context, DownloadTask t, VideoItem item) async {
    var path = t.filePath;
    if (path == null && t.contentUri != null) {
      try {
        path = await const MethodChannel('taohuayuan/downloads')
            .invokeMethod<String>('resolvePath', {'uri': t.contentUri});
      } catch (_) {}
    }
    if (path == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本地文件路径拿不到，文件可能已被系统清掉')),
        );
      }
      return;
    }
    if (context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: item,
          store: store,
          localFilePath: path,
        ),
      ));
    }
  }

  Future<void> _confirmDelete(BuildContext context, DownloadTask t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除这段已下载的视频？'),
        content: Text('${t.title}\n连同系统 Downloads 里的文件一起删掉。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) await manager.deleteTask(t.id);
  }
}
