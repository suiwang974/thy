import 'package:flutter/material.dart';

import 'services/store.dart';
import 'ui/author_screen.dart';
import 'ui/browser_sources_screen.dart';
import 'ui/home_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/shorts_screen.dart';

/// 桃花源：从零重写的视频 App，不套 SkyStream。
/// 数据走 10 个在线源实时搜，没有本地目录。
/// 底部四栏：推荐 / 短视频 / 浏览器 / 我的
/// （2026-11-09 用户定：第 19 条时间表栏去掉换成浏览器栏；
///  第 21 条追番栏也去掉并进「我的」，所以最后剩四栏。
///  搜索放推荐页顶部，不占一栏）。
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
      // 短视频栏不可见时（用户在推荐页），短视频不许自动播出声（第 15 条）。
      ShortsScreen(store: widget.store, visible: _index == 1),
      BrowserSourcesScreen(store: widget.store),
      ProfileScreen(store: widget.store, onAuthorTap: _openAuthor),
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
          BottomNavigationBarItem(icon: Icon(Icons.public), label: '浏览器'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
        ],
      ),
    );
  }
}
