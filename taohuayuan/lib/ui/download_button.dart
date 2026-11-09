import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/downloader.dart';

/// 下载按钮（第 27 条定死：每个视频都要有下载入口，点一下就开始下载）。
/// 四处共用：推荐卡片、搜索结果卡片、短视频右下角、详情页右上角。
/// 状态：没下过 = 下载图标；下载中/排队 = 进度环；已下完 = 打勾；
/// 失败 = 红色感叹号（点一下重新下）。
/// 点一下就开始（画质默认最高档，不先弹选项）；下载管理在「我的」里。
/// 尺寸（第 30 条）：IconButton 默认最小点按目标是 48×48，光设 constraints
/// 压不小，图标 18px、按钮还是 48px 大圆圈挡画面——必须加
/// tapTargetSize: shrinkWrap，视觉尺寸才跟得上 size。
class DownloadButton extends StatelessWidget {
  final VideoItem item;
  final double size;
  final Color color;
  const DownloadButton({
    super.key,
    required this.item,
    this.size = 20,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final manager = DownloadManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (_, _) {
        final task = manager.taskFor(item.id);
        Widget icon;
        String tip;
        if (task == null) {
          icon = Icon(Icons.download, color: color, size: size);
          tip = '下载这段';
        } else if (task.status == DownloadStatus.done) {
          icon = Icon(Icons.download_done, color: Colors.greenAccent, size: size);
          tip = '已下载，去「我的 · 下载管理」看';
        } else if (task.status == DownloadStatus.error) {
          icon = Icon(Icons.error_outline, color: Colors.redAccent, size: size);
          tip = '下载失败：${task.error ?? ''}，点一下重新下';
        } else if (task.status == DownloadStatus.paused) {
          icon = Icon(Icons.download, color: Colors.amber, size: size);
          tip = '已暂停，点一下继续下';
        } else {
          // 下载中/排队：进度环 + 百分比（小尺寸只画环，不挤数字）。
          icon = SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: task.progress > 0 ? task.progress : null,
                  strokeWidth: 2.5,
                  color: Colors.pinkAccent,
                  backgroundColor: Colors.white24,
                ),
                if (size >= 24)
                  Text('${(task.progress * 100).round()}',
                      style: const TextStyle(color: Colors.white, fontSize: 8)),
              ],
            ),
          );
          tip = '下载中 ${(task.progress * 100).round()}%${task.speedText.isEmpty ? '' : ' · ${task.speedText}'}';
        }
        return IconButton(
          icon: icon,
          tooltip: tip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          // 第 30 条：不加这个，按钮最小 48×48，图标再小也没用。
          // IconButton 没有直接的 tapTargetSize 参数，走 style。
          style: IconButton.styleFrom(
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            if (task != null && task.status == DownloadStatus.error) {
              await manager.cancelTask(item.id);
            }
            final started = await manager.startDownload(item);
            if (started == null && context.mounted) {
              // 第 29 条：写明具体原因（哪个源、为什么没给直链），
              // 不要只给一句“下不了”。
              messenger.showSnackBar(
                SnackBar(
                    content: Text(manager.lastFailureReason ?? '这段拿不到直链，下不了，只能在线看')),
              );
            } else if (context.mounted) {
              messenger.showSnackBar(
                SnackBar(content: Text('开始下载：${item.title}')),
              );
            }
          },
        );
      },
    );
  }
}
