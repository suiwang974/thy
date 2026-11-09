import 'package:flutter/material.dart';

import '../models/video_item.dart';
import 'download_button.dart';

/// 封面图：网络图；没有封面就显示文字卡（标题 + 来源 + 时长），绝不丢掉这条。
class PosterThumb extends StatelessWidget {
  final VideoItem item;
  final double? height;
  final double? width;
  const PosterThumb({super.key, required this.item, this.height, this.width});

  @override
  Widget build(BuildContext context) {
    final poster = item.poster;
    Widget child;
    if (poster.startsWith('assets/')) {
      child = Image.asset(poster,
          width: width, height: height, fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _textCard(context));
    } else if (poster.startsWith('http')) {
      child = Image.network(poster,
          width: width, height: height, fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _textCard(context));
    } else {
      child = _textCard(context);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: width,
        height: height,
        color: const Color(0xFF2A2A35),
        child: child,
      ),
    );
  }

  Widget _textCard(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: const Color(0xFF2A2A35),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 没封面的标清楚：不是图挂了，是源站没给封面，标题照样能看。
          const Text('无封面', style: TextStyle(color: Colors.white38, fontSize: 10)),
          const SizedBox(height: 4),
          Text(item.title, maxLines: 3, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('${item.source}${item.durationText.isEmpty ? '' : ' · ${item.durationText}'}',
              style: const TextStyle(color: Colors.white60, fontSize: 11)),
        ],
      ),
    );
  }
}

/// 一张视频卡片：图片占大头（16:9 宽卡），标题只一行放下面，
/// 再一行小字（推荐理由，没有理由时是作者/来源/时长），不要大段文字抢位置。
/// 推荐流里图片面积要大于文字面积：图片 16:9，文字最多两行小字。
class VideoCard extends StatelessWidget {
  final VideoItem item;
  final VoidCallback onTap;
  final VoidCallback? onAuthorTap;
  final String? reason; // 推荐理由（有就显示，没有就显示作者/来源/时长）
  const VideoCard({super.key, required this.item, required this.onTap, this.onAuthorTap, this.reason});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              children: [
                Positioned.fill(child: PosterThumb(item: item)),
                if (item.durationText.isNotEmpty)
                  Positioned(
                    right: 6, bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                      child: Text(item.durationText, style: const TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ),
                // 下载入口（第 27 条：每个视频都要有，点一下就开始下；
                // 点它不进播放页——IconButton 的手势赢了外层卡片的 onTap）。
                Positioned(
                  left: 6, bottom: 6,
                  child: Container(
                    decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
                    padding: const EdgeInsets.all(2),
                    child: DownloadButton(item: item, size: 18),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 标题最多两行：一条标题中途截断看着像源站标题被砍了（2026-11-09
          // 用户反馈“Foot...j”中间被截掉——其实那是 eporner 源标题本身就
          // 叫这个名字，但 App 自己也不许再截标题）；两行还放不下的才截。
          Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Row(
            children: [
              if (item.author.isNotEmpty)
                GestureDetector(
                  onTap: onAuthorTap,
                  child: Text('👤 ${item.author}', style: const TextStyle(color: Colors.amber, fontSize: 12)),
                ),
              if (item.author.isNotEmpty) const SizedBox(width: 8),
              Expanded(
                child: Text(
                    reason ??
                        '${item.source}${item.durationText.isEmpty ? '' : ' · ${item.durationText}'}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: reason != null ? Colors.pink.shade200 : Colors.white54, fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 顶部标题行。
class SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const SectionTitle(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}
