import 'package:flutter/material.dart';

import 'services/store.dart';
import 'ui/author_screen.dart';
import 'ui/following_screen.dart';
import 'ui/home_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/search_screen.dart';
import 'ui/shorts_screen.dart';

/// 桃花源：从零重写的视频片库，不套 SkyStream。
/// 底部五栏：推荐 / 短视频 / 搜索 / 追番 / 我的
/// （第三栏先按“搜索”，时间表以后再说）。
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
      SearchScreen(store: widget.store),
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
          BottomNavigationBarItem(icon: Icon(Icons.search), label: '搜索'),
          BottomNavigationBarItem(icon: Icon(Icons.bookmark), label: '追番'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
        ],
      ),
    );
  }
}
