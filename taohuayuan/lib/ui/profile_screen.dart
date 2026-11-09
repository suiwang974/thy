import 'package:flutter/material.dart';

import '../data/sources.dart';
import '../models/video_item.dart';
import '../services/adblock_service.dart';
import '../services/downloader.dart';
import '../services/search_service.dart';
import '../services/store.dart';
import 'app_update_ui.dart';
import 'downloads_screen.dart';
import 'player_screen.dart';
import 'web_source_browser.dart';
import 'widgets.dart';

/// 我的页：源开关、关注的作者、关注作者的新片、我喜欢的、口味画像、观看记录、关于。
/// （2026-11-09 用户定，第 19/21 条：时间表栏、追番栏都去掉并进这里；
///  底部最后剩四栏：推荐 / 短视频 / 浏览器 / 我的。）
/// 功能多了，分区要清楚：每区一张卡片 + 标题 + 说明，不是一长串堆在一起。
/// 关注作者的新片是联网实时搜的，折叠起来、点开才加载，不拖慢「我的」打开速度。
class ProfileScreen extends StatefulWidget {
  final Store store;
  final void Function(String author) onAuthorTap;
  const ProfileScreen({super.key, required this.store, required this.onAuthorTap});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<VideoItem> _followVideos = [];
  bool _followLoading = false;
  bool _followLoaded = false;
  // 关注作者的新片是按哪一份关注名单搜出来的；名单变了旧结果作废（第 59 条顺手修）。
  String _followLoadedFor = '';
  // 广告拦截更新状态（第 26 条）：点「更新规则」时的进度 + 结果。
  bool _adblockUpdating = false;
  String? _adblockResult;

  void _open(VideoItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item, store: widget.store),
    )).then((_) {
          // 第 59 条：喜欢和观看记录在 build() 里现读，不用在这里缓存；
          // 从播放页回来只触发一次重建即可。
          if (mounted) setState(() {});
        });
  }

  /// 关注作者的新片：各源实时搜作者名（最多同时搜 5 位作者，单个源 8 秒超时跳过）。
  /// 只在用户点开这一区时才加载一次。
  Future<void> _loadFollowVideos() async {
    if (_followLoaded || _followLoading) return;
    setState(() => _followLoading = true);
    final follows = widget.store.followedAuthors.toList()..sort();
    final svc = SearchService(disabledSources: widget.store.disabledSources);
    final found = <VideoItem>[];
    await Future.wait(follows.take(5).map((author) async {
      final results = await svc.searchAll(author);
      final needle = author.toLowerCase();
      for (final r in results) {
        for (final v in r.items) {
          if (v.author.toLowerCase().contains(needle) ||
              v.title.toLowerCase().contains(needle)) {
            found.add(v);
          }
        }
      }
    }));
    if (!mounted) return;
    final seen = <String>{};
    setState(() {
      _followVideos = found.where((v) => seen.add(v.id)).take(30).toList();
      _followLoading = false;
      _followLoaded = true;
      _followLoadedFor = follows.join('|');
    });
  }

  String _fmtPos(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _fmtDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// 一区一张卡片：标题 + 说明 + 内容，分区一眼看清。
  Widget _sectionCard({required String title, required String subtitle, required Widget child}) {
    return Card(
      color: const Color(0xFF1C1C22),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  /// 一组口味标签（第 60 条）：标题 + 一排可 × 删除的芯片；空了给一句提示。
  /// 删了立刻存本地（调 store 的方法），setState 后重建——推荐下次算分就生效。
  Widget _tasteGroup({
    required String label,
    required String emptyHint,
    required List<String> tags,
    required Color chipColor,
    required Future<void> Function(String tag) onDeleted,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          tags.isEmpty
              ? Text(emptyHint,
                  style: const TextStyle(color: Colors.white38, fontSize: 12))
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: tags
                      .map((t) => InputChip(
                            label: Text(t),
                            backgroundColor: const Color(0xFF2A2A35),
                            labelStyle: TextStyle(color: chipColor),
                            deleteIcon: const Icon(Icons.close,
                                size: 16, color: Colors.white54),
                            onDeleted: () async {
                              await onDeleted(t);
                              if (mounted) setState(() {});
                            },
                          ))
                      .toList(),
                ),
        ],
      ),
    );
  }

  /// 第 60 条：手动加一个标签——选“喜欢”进推荐画像，选“不喜欢”进降权。
  Future<void> _showAddTagDialog() async {
    final controller = TextEditingController();
    var liked = true;
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C22),
          title: const Text('添加标签', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: '比如 footjob、3d、cosplay',
                  hintStyle: TextStyle(color: Colors.white38),
                ),
                onSubmitted: (_) => Navigator.of(ctx).pop(true),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('喜欢'),
                    selected: liked,
                    onSelected: (_) => setDialogState(() => liked = true),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('不喜欢'),
                    selected: !liked,
                    onSelected: (_) => setDialogState(() => liked = false),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('喜欢的进推荐，不喜欢的降权；都只存手机本地。',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (added != true) return;
    final tag = controller.text.trim();
    if (tag.isEmpty) return;
    if (liked) {
      await widget.store.addLikedTag(tag);
    } else {
      await widget.store.dislikeTag(tag);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sources = allSources();
    final follows = widget.store.followedAuthors.toList()..sort();
    // 第 59 条：喜欢和观看记录每次 build 都现读——底部四栏是 IndexedStack，
    // 切栏不销毁页面，initState 只跑一次会一直显示 App 启动时的旧快照。
    final liked = widget.store.likedItems();
    final history = widget.store.historyItems();
    return Scaffold(
      // 第 61 条：透明，让 main.dart 的 AppBackground 透出来；卡片自带深色底。
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('我的', style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          // 下载管理（第 27 条定死：「我的」里加下载管理，可以看到下载了什么，
          // 也能直接点开看）。点卡片进管理页；正在下的在这里也能看到进度。
          _sectionCard(
            title: '下载管理',
            subtitle: '文件存在系统 Downloads/桃花源/ 里',
            child: ListenableBuilder(
              listenable: DownloadManager.instance,
              builder: (_, _) {
                final m = DownloadManager.instance;
                final active = m.activeTasks;
                final done = m.doneTasks;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '正在下 ${active.length} 个 · 已下完 ${done.length} 个',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    if (active.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ...active.take(3).map((t) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontSize: 13)),
                                const SizedBox(height: 3),
                                LinearProgressIndicator(
                                  value: t.progress > 0 ? t.progress : null,
                                  minHeight: 3,
                                  backgroundColor: Colors.white24,
                                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.pinkAccent),
                                ),
                                const SizedBox(height: 2),
                                Text('${t.statusText} ${(t.progress * 100).round()}% · ${t.sizeText}',
                                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              ],
                            ),
                          )),
                    ],
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => DownloadsScreen(
                            manager: DownloadManager.instance,
                            store: widget.store,
                          ),
                        )),
                        child: const Text('打开下载管理'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          // 广告拦截（第 26 条）：规则来自用户 1DM 备份里的 27 个源（22 个启用）。
          // 更新按源 URL 现拉；上次更新时间与每源状态写清楚，失败的源不藏着。
          // 上限如实说：webview_flutter 没有 shouldInterceptRequest，
          // 弹窗/跳转能拦，页面内嵌的广告子资源拦不干净。
          _sectionCard(
            title: '广告拦截',
            subtitle: '内置浏览器的拦截规则，来自你的 1DM 备份',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AdblockService.instance.isReady
                      ? '已加载 ${AdblockService.instance.blockedHostCount} 个拦截域名'
                          '（种子 ${AdblockService.instance.seedHostCount} 个）'
                          '${AdblockService.instance.lastUpdated == null ? ' · 还没更新过' : ' · 上次更新 ${_fmtDate(AdblockService.instance.lastUpdated!)}'}'
                      : '规则还没加载好，稍等再看',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 4),
                const Text(
                  '能拦：弹窗、跳转到广告站的链接、页面里的广告位；拦不干净：首屏 HTML 里内嵌的广告图片/脚本（系统限制，见反馈说明）。',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                if (_adblockResult != null) ...[
                  const SizedBox(height: 4),
                  Text(_adblockResult!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _adblockUpdating
                        ? null
                        : () async {
                            setState(() {
                              _adblockUpdating = true;
                              _adblockResult = null;
                            });
                            final r = await AdblockService.instance.updateRules();
                            if (!mounted) return;
                            setState(() {
                              _adblockUpdating = false;
                              _adblockResult = r.ok > 0
                                  ? '更新完成：${r.ok} 个源成功、${r.failed} 个源失败，新增 ${r.added} 个拦截域名。'
                                      '${r.failed > 0 ? '失败的源稍后再试。' : ''}'
                                  : '更新失败：${r.failed} 个源都没拉回来，检查网络再试。';
                            });
                          },
                    child: Text(_adblockUpdating ? '正在更新规则…' : '更新规则'),
                  ),
                ),
              ],
            ),
          ),
          _sectionCard(
            title: '浏览器与下载',
            subtitle: '翻译默认开；下载的 ts 分段默认转 mp4',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('浏览器默认翻译成中文',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('内置浏览器打开页面就翻成中文；AppBar 的翻译按钮可随时切回原文',
                      style: TextStyle(color: Colors.white54)),
                  value: widget.store.translateEnabled,
                  activeThumbColor: Colors.pinkAccent,
                  onChanged: (v) async {
                    await widget.store.setTranslateEnabled(v);
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('下载的 ts 转成 mp4',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('HLS 的 .ts 分段下完重封装成 mp4；转不了就保留 .ts',
                      style: TextStyle(color: Colors.white54)),
                  value: widget.store.tsToMp4,
                  activeThumbColor: Colors.pinkAccent,
                  onChanged: (v) async {
                    await widget.store.setTsToMp4(v);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          _sectionCard(
            title: '启用的源',
            subtitle: '默认全部启用；关掉后搜索不再查它',
            child: Column(
              children: sources.map((s) {
                final enabled = !widget.store.disabledSources.contains(s.id);
                final isHanime = s.id == 'hanime1' || s.id == 'hanimeone';
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(s.name, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    isHanime
                        ? '成人动漫 · 与另一镜像是同一站，hanimeone.me 能进，hanime1.me 常被验证拦住'
                        : s.webViewOnly
                            ? '要过验证，在内置浏览器里打开'
                            : '网络源 · 实时搜索',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  // 成人动漫源点右侧图标进内置浏览器（首页）。
                  secondary: s.webViewOnly
                      ? IconButton(
                          icon: const Icon(Icons.open_in_browser, color: Colors.pinkAccent),
                          tooltip: '在内置浏览器里打开',
                          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => WebSourceBrowser(
                              title: s.name,
                              url: s.webHomeUrl,
                              sourceId: s.id,
                              store: widget.store,
                            ),
                          )),
                        )
                      : null,
                  value: enabled,
                  activeThumbColor: Colors.pinkAccent,
                  onChanged: (v) async {
                    await widget.store.setSourceEnabled(s.id, v);
                    setState(() {});
                  },
                );
              }).toList(),
            ),
          ),
          _sectionCard(
            title: '关注的作者',
            subtitle: '点名字只看他的片；点 ✕ 取消关注',
            child: follows.isEmpty
                ? const Text('还没关注作者，在视频卡片上点作者名就能关注',
                    style: TextStyle(color: Colors.white54))
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: follows.map((a) => InputChip(
                      label: Text('👤 $a'),
                      backgroundColor: const Color(0xFF2A2A35),
                      labelStyle: const TextStyle(color: Colors.amber),
                      onPressed: () => widget.onAuthorTap(a),
                      deleteIcon: const Icon(Icons.close, size: 16, color: Colors.white54),
                      onDeleted: () async {
                        await widget.store.toggleFollow(a);
                        setState(() => _followLoaded = false);
                      },
                    )).toList(),
                  ),
          ),
          // 关注作者的新片：联网搜的，折叠起来点开才加载。
          Card(
            color: const Color(0xFF1C1C22),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ExpansionTile(
              title: const Text('关注作者的新片', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              subtitle: const Text('各源实时搜出来的；点开才加载', style: TextStyle(color: Colors.white54, fontSize: 12)),
              onExpansionChanged: (expanded) {
                if (expanded) {
                  // 关注名单变了（别处关注/取关），旧的搜结果作废，重搜。
                  final key =
                      (widget.store.followedAuthors.toList()..sort()).join('|');
                  if (_followLoaded && _followLoadedFor != key) {
                    setState(() {
                      _followLoaded = false;
                      _followVideos = [];
                    });
                  }
                  _loadFollowVideos();
                }
              },
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _followLoading
                      ? const Center(child: CircularProgressIndicator(color: Colors.pinkAccent))
                      : _followVideos.isEmpty
                          ? const Text('还没搜到关注作者的新片（关注作者后点开这里再看）',
                              style: TextStyle(color: Colors.white54))
                          : GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                              ),
                              itemCount: _followVideos.length,
                              itemBuilder: (_, i) => VideoCard(item: _followVideos[i], onTap: () => _open(_followVideos[i])),
                            ),
                ),
              ],
            ),
          ),
          _sectionCard(
            title: '我喜欢的',
            subtitle: '在播放页点右上角的 ♥ 就会出现在这里',
            child: liked.isEmpty
                ? const Text('还没点过喜欢', style: TextStyle(color: Colors.white54))
                : GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 14, childAspectRatio: 16 / 13,
                    ),
                    itemCount: liked.length,
                    itemBuilder: (_, i) => VideoCard(item: liked[i], onTap: () => _open(liked[i])),
                  ),
          ),
          _sectionCard(
            title: '我的口味',
            subtitle: '只存手机本地，不上传；推荐就按这些算；点 × 删掉一个标签',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '喜欢 ${liked.length} 条 · 关注 ${follows.length} 位作者 · 搜过 ${widget.store.searchTerms.length} 个词',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 12),
                _tasteGroup(
                  label: '喜欢的标签',
                  emptyHint: '还没有；点 ♥ 的视频关键词会自动进画像，也可以在下面手动加',
                  tags: widget.store.effectiveLikedTags.toList()..sort(),
                  chipColor: Colors.pinkAccent,
                  onDeleted: (t) => widget.store.removeLikedTagFromProfile(t),
                ),
                _tasteGroup(
                  label: '不喜欢的标签',
                  emptyHint: '没有；点“不喜欢”的视频标签会出现在这里',
                  tags: widget.store.dislikedTags.toList()..sort(),
                  chipColor: Colors.white70,
                  onDeleted: (t) => widget.store.removeDislikedTag(t),
                ),
                _tasteGroup(
                  label: '搜过的词',
                  emptyHint: '还没搜过',
                  tags: widget.store.searchTerms,
                  chipColor: Colors.white70,
                  onDeleted: (t) => widget.store.removeSearchTerm(t),
                ),
                OutlinedButton(
                  onPressed: _showAddTagDialog,
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.pinkAccent),
                  child: const Text('＋ 添加标签'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    await widget.store.clearTaste();
                    setState(() {});
                  },
                  child: const Text('清除口味数据（回到冷启动：足控 / 3D / 亚洲）'),
                ),
              ],
            ),
          ),
          _sectionCard(
            title: '观看记录',
            subtitle: '点开能接着看（续播）',
            child: history.isEmpty
                ? const Text('还没看过片', style: TextStyle(color: Colors.white54))
                : Column(
                    children: history.take(20).map((v) {
                      final ratio = widget.store.watchRatio(v.id);
                      final pos = widget.store.watchPosition(v.id);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
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
                    }).toList(),
                  ),
          ),
          // 版本更新（第 50 条）：不用删了重装，App 里直接查新版、下载、安装。
          AppUpdateCard(store: widget.store),
          _sectionCard(
            title: '关于',
            subtitle: '桃花源 2.9.0 · 从零重写版',
            child: const Text('10 个在线源实时搜索，视频均在线播；下载的视频存在系统 Downloads/桃花源/ 里。',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
