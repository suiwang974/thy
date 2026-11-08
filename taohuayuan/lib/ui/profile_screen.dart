import 'package:flutter/material.dart';

import '../data/sources.dart';
import '../models/video_item.dart';
import '../services/store.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 我的页：源开关、观看记录、关于。
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
              subtitle: Text(s.id == 'catalog' ? '片库 · 62 条在线目录' : '网络源',
                  style: const TextStyle(color: Colors.white54)),
              value: enabled,
              activeThumbColor: Colors.pinkAccent,
              onChanged: (v) async {
                await widget.store.setSourceEnabled(s.id, v);
                setState(() {});
              },
            );
          }),
          const SectionTitle('观看记录'),
          if (_history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('还没看过片', style: TextStyle(color: Colors.white54)),
            )
          else
            ..._history.take(20).map((v) => ListTile(
                  leading: SizedBox(width: 96, child: PosterThumb(item: v, height: 54)),
                  title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: Text('${v.source}${v.durationText.isEmpty ? '' : ' · ${v.durationText}'}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  onTap: () => _open(v),
                )),
          const SectionTitle('关于'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('桃花源 2.9.0 · 从零重写版\n片库 62 条是在线目录，点开走直链在线播，手机上没有下载过任何视频。',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
