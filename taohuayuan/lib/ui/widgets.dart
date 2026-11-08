import 'package:flutter/material.dart';

import '../models/video_item.dart';

/// 封面图：本地 asset 或网络图；没有封面就显示文字卡（标题 + 来源 + 时长），绝不丢掉这条。
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

/// 一张视频卡片：封面 + 标题 + 作者/批次/时长/来源。
class VideoCard extends StatelessWidget {
  final VideoItem item;
  final VoidCallback onTap;
  final VoidCallback? onAuthorTap;
  const VideoCard({super.key, required this.item, required this.onTap, this.onAuthorTap});

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
                if (!item.playable)
                  Positioned(
                    left: 6, top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.orange.shade800, borderRadius: BorderRadius.circular(4)),
                      child: const Text('直链待补', style: TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
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
                child: Text('${item.source}${item.batch.isEmpty ? '' : ' · ${item.batch}'}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
