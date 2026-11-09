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
  // 全局兜底：任何 widget 构建/布局出错时，Flutter 在 release 下默认只画一块
  // 静默灰框（RenderErrorBox，0xF0C0C0C0），用户看不到任何提示、也没法操作——
  // 2026-11-09 详情页灰框就是这么来的（音频照常播、控制条全没了）。
  // 改成带文字的深色卡片：写明出问题了、把异常第一行打出来（截图就能定位）、
  // 并提示返回重进。Directionality 自带，免得首屏还没建好就再抛错。
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final msg = details.exception.toString().replaceAll(RegExp(r'\s+'), ' ');
    final short = msg.length > 90 ? '${msg.substring(0, 90)}…' : msg;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF2A2A35),
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.orange, size: 28),
              const SizedBox(height: 8),
              const Text('这里加载出问题了，返回重进试试',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(height: 6),
              Text(short,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  };
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
