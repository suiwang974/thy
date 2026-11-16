import 'dart:async';

import 'package:flutter/material.dart';

import '../data/sources.dart';
import '../search/global_search.dart';
import '../search/search_history.dart';
import '../services/store.dart';
import '../source/source_registry.dart';
import 'web_source_browser.dart';
import 'widgets.dart';

/// 浏览器栏（2026-11-09 用户定，第 19 条；时间表栏去掉换成它）：
/// 全部 10 个源都列在这里，点哪个就用内置浏览器打开哪个源站；
/// 内置浏览器按第 18 条的规矩来（上面那个退出按钮才退出，
/// 系统返回键走 WebView 历史回退）。
/// Hanime1 / HanimeOne 是同一站的两个镜像域名，内容一样，只当成一个站显示
/// （第 20 条）：点开先走能进的 hanimeone.me，打不开自动切 hanime1.me。
class BrowserSourcesScreen extends StatelessWidget {
  final Store store;
  const BrowserSourcesScreen({super.key, required this.store});

  void _open(BuildContext context, String title, String url, String sourceId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WebSourceBrowser(
        title: title,
        url: url,
        sourceId: sourceId,
        store: store,
      ),
    ));
  }

  /// 实现 5：全局搜索入口——不挑源也能搜。输词走搜索引擎、输网址直接打开，
  /// 打开的是同一个内置浏览器（地址栏、嗅探、下载都在里面）。
  void _search(BuildContext context, String input) {
    final resolved = GlobalSearch.resolve(
      input,
      engine: store.preferredSearchEngine,
      isKnownHost: (host) => SourceRegistry.bindingForHost(host) != null,
    );
    if (resolved == null) return;
    // 记入搜索历史（异步，不堵导航）。
    unawaited(
      SearchHistory.load().then((h) => h.add(input.trim(), resolved.url)),
    );
    final host = Uri.tryParse(resolved.url)?.host ?? '';
    final binding = SourceRegistry.bindingForHost(host);
    _open(
      context,
      resolved.isSearch
          ? '搜索：${resolved.query}'
          : (binding?.displayName ?? '浏览器'),
      resolved.url,
      binding?.id ?? 'web',
    );
  }

  @override
  Widget build(BuildContext context) {
    final sources = allSources();
    final hanime = sources.where((s) => s.id == 'hanime1' || s.id == 'hanimeone').toList();
    final others = sources.where((s) => s.id != 'hanime1' && s.id != 'hanimeone').toList();
    return Scaffold(
      // 第 61 条：透明，让 main.dart 的 AppBackground 透出来；卡片自带深色底。
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('浏览器', style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        children: [
          // 实现 5：全局搜索框——输搜索词走搜索引擎，输网址直接打开。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: '搜索或输入网址',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon:
                    const Icon(Icons.search, color: Colors.white54),
                filled: true,
                fillColor: const Color(0xFF2A2A35),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              textInputAction: TextInputAction.go,
              onSubmitted: (value) => _search(context, value),
            ),
          ),
          const SectionTitle('全部源站', subtitle: '点哪个就用内置浏览器打开哪个源站'),
          // Hanime：两个镜像域名是同一站，内容一样，只显示一行；
          // 先走能进的 hanimeone.me，打不开自动切 hanime1.me。
          if (hanime.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.public, color: Colors.pinkAccent),
              title: const Text('Hanime（成人动漫）', style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                '同一站的两个镜像：hanimeone.me（能进）· hanime1.me（常被验证拦住，打不开自动切）',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.white54),
              onTap: () => _open(
                context,
                'Hanime（成人动漫）',
                'https://${HanimeSource.preferredHost}/',
                'hanimeone',
              ),
            ),
          ...others.map((s) => ListTile(
                leading: Icon(
                  s.webViewOnly ? Icons.verified_user : Icons.public,
                  color: s.webViewOnly ? Colors.amber : Colors.pinkAccent,
                ),
                title: Text(s.name, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  s.webViewOnly ? '要过验证，在内置浏览器里打开' : '网络源 · 在内置浏览器里打开',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                onTap: () => _open(context, s.name, s.webHomeUrl, s.id),
              )),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Text(
              '内置浏览器跟真浏览器一样：上面那个退出按钮才退出，系统返回键先回上一页，'
              '到第一页再按才退出。站内页面有广告的站会写清楚。',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
