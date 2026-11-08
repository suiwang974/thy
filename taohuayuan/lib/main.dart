import 'package:flutter/material.dart';

import 'services/store.dart';
import 'ui/author_screen.dart';
import 'ui/following_screen.dart';
import 'ui/home_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/schedule_screen.dart';
import 'ui/shorts_screen.dart';

/// 桃花源：从零重写的视频 App，不套 SkyStream。
/// 数据走 8 个在线源实时搜，没有本地目录。
/// 底部五栏：推荐 / 短视频 / 时间表 / 追番 / 我的
/// （第三栏是“时间表”，不是“搜索”；搜索放推荐页顶部）。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.load();
  runApp(TaohuayuanApp(store: store));
}

class TaohuayuanApp extends StatelessWidget {
  final Store store;
  const TaohuayuanApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '桃花源',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF141419),
        colorScheme: const ColorScheme.dark(primary: Colors.pinkAccent),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF141419)),
      ),
      home: HomeShell(store: store),
    );
  }
}

class HomeShell extends StatefulWidget {
  final Store store;
  const HomeShell({super.key, required this.store});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _openAuthor(String author) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AuthorScreen(author: author, store: widget.store),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(store: widget.store, onAuthorTap: _openAuthor),
      ShortsScreen(store: widget.store),
      ScheduleScreen(store: widget.store, onAuthorTap: _openAuthor),
      FollowingScreen(store: widget.store, onAuthorTap: _openAuthor),
      ProfileScreen(store: widget.store),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFF1C1C22),
        selectedItemColor: Colors.pinkAccent,
        unselectedItemColor: Colors.white54,
        selectedFontSize: 12,
        unselectedFontSize: 12,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: '推荐'),
          BottomNavigationBarItem(icon: Icon(Icons.play_circle), label: '短视频'),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: '时间表'),
          BottomNavigationBarItem(icon: Icon(Icons.bookmark), label: '追番'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
        ],
      ),
    );
  }
}
