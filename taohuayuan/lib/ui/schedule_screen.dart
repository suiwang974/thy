import 'package:flutter/material.dart';

import '../services/store.dart';
import 'widgets.dart';

/// 时间表页：占位页，现在没数据源。
/// 以后有了新片上架数据、或者用户自己记录的东西，再往里填；
/// 不要因为没数据就砍掉这栏，先把架子做出来。
/// 眼下这里只放真实存在的东西：关注的作者（点名字进作者页）。
class ScheduleScreen extends StatelessWidget {
  final Store store;
  final void Function(String author) onAuthorTap;
  const ScheduleScreen({super.key, required this.store, required this.onAuthorTap});

  @override
  Widget build(BuildContext context) {
    final follows = store.followedAuthors.toList()..sort();
    return Scaffold(
      backgroundColor: const Color(0xFF141419),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        title: const Text('时间表', style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        children: [
          const SectionTitle('时间表', subtitle: '新片上架时间线，以后有了数据源再往里填'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '现在还没有新片上架的数据源，所以这里是空的——先留着这栏，'
              '以后接上各源的新片上架数据，或者你自己记录的东西，再按时间列出来。',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          const SectionTitle('关注的作者', subtitle: '以后这里会按时间列出他们的新片上架；现在先点名字进作者页'),
          if (follows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('还没关注作者，在视频卡片上点作者名就能关注',
                  style: TextStyle(color: Colors.white54)),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: follows.map((a) => InputChip(
                  label: Text('👤 $a'),
                  backgroundColor: const Color(0xFF2A2A35),
                  labelStyle: const TextStyle(color: Colors.amber),
                  onPressed: () => onAuthorTap(a),
                )).toList(),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
