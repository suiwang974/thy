import 'package:flutter/material.dart';

import '../services/downloader.dart';
import '../services/sniffer.dart';
import '../services/store.dart';

/// 嗅到的媒体清单（第 34 条，按 1DM“查找到文件”弹窗的样子做）：
/// - 每条列地址、大小、时长（分段的按同一视频归成一条，不几十条刷屏）；
/// - 能多选、能全选、能排序；
/// - 底部有“ts 转成 mp4”勾选项（下 .ts 分段时勾上就重封装成 mp4，
///   转不了就保留 .ts，不标下载失败）；
/// - 底部 [清除全部] [排序] [关闭] + [下载所选]。
/// blob（浏览器内播放、拿不到地址）和播放列表拉不到的条目不能选，
/// 原因写在条目下面，不假装能下。
class SniffSheet {
  static Future<void> show(
    BuildContext context, {
    required List<SniffedMedia> items,
    required String pageTitle,
    required String sourceId,
    required String pageUrl,
    required Store store,
  }) async {
    if (items.isEmpty) return;
    final selected = <String>{for (final m in items) if (m.downloadable) m.url};
    var sortMode = 0; // 0 按大小 · 1 按时长 · 2 按地址
    var tsToMp4 = store.tsToMp4;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final sorted = [...items];
          switch (sortMode) {
            case 0:
              sorted.sort((a, b) => (b.sizeBytes ?? 0).compareTo(a.sizeBytes ?? 0));
              break;
            case 1:
              sorted.sort((a, b) => (b.durationSec ?? 0).compareTo(a.durationSec ?? 0));
              break;
            case 2:
              sorted.sort((a, b) => a.url.compareTo(b.url));
              break;
          }
          final sortLabel = ['按大小', '按时长', '按地址'][sortMode];
          final downloadable = items.where((m) => m.downloadable).toList();
          final allSelected =
              downloadable.isNotEmpty && selected.length == downloadable.length;
          return DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('查找到文件（${items.length} 个）',
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          if (allSelected) {
                            selected.clear();
                          } else {
                            selected.addAll(downloadable.map((m) => m.url));
                          }
                        }),
                        child: Text(allSelected ? '取消全选' : '全选'),
                      ),
                      TextButton(
                        onPressed: () => setState(() => sortMode = (sortMode + 1) % 3),
                        child: Text('排序：$sortLabel'),
                      ),
                    ],
                  ),
                ),
                if (pageTitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(pageTitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                  ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: sorted.length,
                    itemBuilder: (_, i) {
                      final m = sorted[i];
                      final canPick = m.downloadable;
                      return CheckboxListTile(
                        value: canPick && selected.contains(m.url),
                        onChanged: canPick
                            ? (v) => setState(() {
                                  if (v == true) {
                                    selected.add(m.url);
                                  } else {
                                    selected.remove(m.url);
                                  }
                                })
                            : null,
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                        title: Text(m.url,
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: canPick ? Colors.white : Colors.white38,
                                fontSize: 12)),
                        subtitle: Text(
                          '${_kindLabel(m.kind)}${m.detailLine.isEmpty ? '' : ' · ${m.detailLine}'}',
                          style: TextStyle(
                              color: m.note != null ? Colors.orange : Colors.white54,
                              fontSize: 12),
                        ),
                      );
                    },
                  ),
                ),
                // ts 转 mp4 勾选项（1DM 同款）：勾上时 HLS 的 .ts 分段下完重封装成 mp4。
                CheckboxListTile(
                  value: tsToMp4,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  title: const Text('将 ts 文件转换为 mp4（视频）和 aac（音频）',
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: const Text('转不了就保留 .ts，不标下载失败',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                  onChanged: (v) async {
                    final nv = v ?? true;
                    await store.setTsToMp4(nv);
                    setState(() => tsToMp4 = nv);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: () => setState(selected.clear),
                        child: const Text('清除全部'),
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('关闭'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: selected.isEmpty
                            ? null
                            : () async {
                                final messenger = ScaffoldMessenger.of(context);
                                final urls = selected.toList();
                                final navigator = Navigator.of(ctx);
                                var started = 0;
                                for (final url in urls) {
                                  final m = items.firstWhere((e) => e.url == url);
                                  final t = await DownloadManager.instance.startDownloadFromUrl(
                                    id: 'sniff-${url.hashCode.abs()}',
                                    title: pageTitle.isEmpty ? '嗅到的视频' : pageTitle,
                                    source: sourceId,
                                    url: url,
                                    headers: {'Referer': pageUrl},
                                    durationSec: m.durationSec ?? 0,
                                  );
                                  if (t != null) started++;
                                }
                                navigator.pop();
                                messenger.showSnackBar(
                                  SnackBar(
                                      content: Text(started > 0
                                          ? '开始下载 $started 个，去「我的 · 下载管理」看进度'
                                          : '没下成，地址可能已过期')),
                                );
                              },
                        child: Text('下载所选（${selected.length}）'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _kindLabel(String kind) {
    switch (kind) {
      case 'm3u8':
        return 'HLS 播放列表';
      case 'ts':
        return 'TS 分段';
      case 'webm':
        return 'WebM';
      case 'blob':
        return '浏览器内播放';
      default:
        return 'MP4';
    }
  }
}
