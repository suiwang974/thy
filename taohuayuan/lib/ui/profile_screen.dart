import 'package:flutter/material.dart';

import '../data/sources.dart';
import '../models/video_item.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 我的页：源开关、观看记录、口味画像、关于。
/// 源默认全部启用；关掉某个源后搜索就不再查它。
class ProfileScreen extends StatefulWidget {
  final Store store;
  const ProfileScreen({super.key, required this.store});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<VideoItem> _history = [];

  @override
  void initState() {
    super.initState();
    _history = widget.store.historyItems();
  }

  void _open(VideoItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, store: widget.store),
    )).then((_) => setState(() => _history = widget.store.historyItems()));
  }

  String _fmtPos(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final sources = allSources();
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        title: const Text('我的', style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        children: [
          const SectionTitle('启用的源', subtitle: '默认全部启用；关掉后搜索不再查它'),
          ...sources.map((s) {
            final enabled = !widget.store.disabledSources.contains(s.id);
            return SwitchListTile(
              title: Text(s.name, style: const TextStyle(color: Colors.white)),
              subtitle: const Text('网络源 · 实时搜索', style: TextStyle(color: Colors.white54)),
              value: enabled,
              activeThumbColor: Colors.pinkAccent,
              onChanged: (v) async {
                await widget.store.setSourceEnabled(s.id, v);
                setState(() {});
              },
            );
          }),
          const SectionTitle('我的口味', subtitle: '只存手机本地，不上传；推荐就按这些算'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '喜欢 ${widget.store.likedIds.length} 条 · 关注 ${widget.store.followedAuthors.length} 位作者 · 搜过 ${widget.store.searchTerms.length} 个词',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    await widget.store.clearTaste();
                    setState(() => _history = widget.store.historyItems());
                  },
                  child: const Text('清除口味数据（回到冷启动：足控 / 3D / 亚洲）'),
                ),
              ],
            ),
          ),
          const SectionTitle('观看记录', subtitle: '点开能接着看（续播）'),
          if (_history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('还没看过片', style: TextStyle(color: Colors.white54)),
            )
          else
            ..._history.take(20).map((v) {
              final ratio = widget.store.watchRatio(v.id);
              final pos = widget.store.watchPosition(v.id);
              return ListTile(
                leading: SizedBox(width: 96, child: PosterThumb(item: v, height: 54)),
                title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${v.source}${v.durationText.isEmpty ? '' : ' · ${v.durationText}'}'
                      '${ratio > 0 ? ' · 已看到 ${_fmtPos(pos)}（${(ratio * 100).round()}%）' : ''}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    if (ratio > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 3,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.pinkAccent),
                        ),
                      ),
                  ],
                ),
                onTap: () => _open(v),
              );
            }),
          const SectionTitle('关于'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('桃花源 2.9.0 · 从零重写版\n8 个在线源实时搜索，视频均在线播，手机上没有下载过任何视频。',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
