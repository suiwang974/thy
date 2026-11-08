import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/image_fallbacks.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';

/// 短视频：一页一支片，上下滑动刷片。
///
/// 数据源是片库源（`extensionManager.getAllProviders()` 里 `packageName`
/// 含 `superlibrary.local` 的那个），直接调它的 `getHome()`，把各分组
/// （第 01 批、第 02 批……）拍平成一个列表。片库是在线片库目录（标题/作者/时长/直链），点开走直链在线播；
/// 目录数据嵌在包里、瞬间返回，前面不加任何网络探测。
///
/// 点一下进现有详情页（和搜索结果点击同一条链路：`DetailsRoute`，详情页
/// 里再走 `playback_launcher` 调 `loadStreams` 播放），这里不自造播放链路。
class ShortsScreen extends ConsumerStatefulWidget {
  const ShortsScreen({super.key});

  @override
  ConsumerState<ShortsScreen> createState() => _ShortsScreenState();
}

/// 一支短视频 + 它在 `getHome()` 里所属的分组名（批次）。
class _ShortItem {
  const _ShortItem({required this.item, required this.batch});
  final MultimediaItem item;
  final String batch;
}

class _ShortsScreenState extends ConsumerState<ShortsScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  /// 已找到的 local-library 源；换源才重新拉数据。
  SkyStreamProvider? _provider;
  Future<List<_ShortItem>>? _future;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<List<_ShortItem>> _load(SkyStreamProvider provider) async {
    final groups = await provider.getHome();
    final items = <_ShortItem>[];
    for (final entry in groups.entries) {
      for (final item in entry.value) {
        items.add(_ShortItem(item: item, batch: entry.key));
      }
    }
    return items;
  }

  /// local-library 的 `toItem` 把作者写进 description 开头
  ///（`作者 · 批次 · 分辨率`）；没作者时开头就是批次本身。
  static String _authorOf(MultimediaItem item) {
    final description = item.description;
    if (description == null || description.isEmpty) return '';
    final first = description.split(' · ').first.trim();
    if (first.isEmpty || first.startsWith('第')) return '';
    return first;
  }

  /// local-library 的 `duration` 是整分钟（`Math.round(durationSec / 60)`）。
  static String _durationText(MultimediaItem item) {
    final minutes = item.duration;
    if (minutes == null || minutes <= 0) return '';
    return '约 $minutes 分钟';
  }

  @override
  Widget build(BuildContext context) {
    // 插件同步是异步的：先 watch 列表，源一出现就拉数据；同步未完成又
    // 没源时显示加载中，而不是直接判空。
    final providers = ref.watch(extensionManagerProvider);
    final syncComplete = ref.watch(pluginSyncCompleteProvider);
    final local = providers.firstWhereOrNull(
      (p) => p.packageName.contains('superlibrary.local'),
    );

    if (local == null) {
      if (!syncComplete) {
        return const Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppLoadingIndicator(),
                SizedBox(height: 16),
                Text('正在加载片库…'),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.video_library_outlined,
                  size: 64,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
                ),
                const SizedBox(height: 16),
                const Text('未找到片库', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text(
                  '请检查片库插件是否已安装并启用',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (local != _provider) {
      _provider = local;
      _future = _load(local);
      _currentPage = 0;
    }

    return Scaffold(
      body: FutureBuilder<List<_ShortItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppLoadingIndicator(),
                  SizedBox(height: 16),
                  Text('正在加载短视频…'),
                ],
              ),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    const Text('加载失败', style: TextStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    Text(
                      snapshot.error.toString(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _future = _load(local);
                        });
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            );
          }
          final items = snapshot.data ?? const <_ShortItem>[];
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.play_circle_outline,
                      size: 64,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
                    ),
                    const SizedBox(height: 16),
                    const Text('暂无短视频', style: TextStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    Text(
                      '片库里还没有视频',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: items.length,
                onPageChanged: (index) {
                  setState(() => _currentPage = index);
                },
                itemBuilder: (context, index) {
                  final short = items[index];
                  return _ShortPage(
                    short: short,
                    onTap: () {
                      DetailsRoute(
                        $extra: DetailsRouteExtra(item: short.item),
                      ).push<void>(context);
                    },
                  );
                },
              ),
              Positioned(
                right: 16,
                top: MediaQuery.paddingOf(context).top + 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_currentPage + 1} / ${items.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 一页短视频：有封面（网络图或包内缩略图）就全屏显示封面，否则显示文字卡
///（标题 + 作者 + 时长 + 批次），底部叠加标题 / 作者 / 时长。
class _ShortPage extends StatelessWidget {
  const _ShortPage({required this.short, required this.onTap});
  final _ShortItem short;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = short.item;
    final theme = Theme.of(context);
    final author = _ShortsScreenState._authorOf(item);
    final durationText = _ShortsScreenState._durationText(item);
    final meta = [
      if (author.isNotEmpty) author,
      short.batch,
      if (durationText.isNotEmpty) durationText,
    ].join(' · ');

    // 片库的 poster 是 `assets/thumbs/…` 这样的包内路径
    //（已在 pubspec 的 assets 里声明），或 http(s) 网络地址；只有这
    // 两种才当封面显示，其余（空串等）一律按插件自己的规矩显示文字卡。
    final posterUrl = AppImageFallbacks.poster(item.posterUrl);
    final isNetworkPoster =
        posterUrl != null && posterUrl.startsWith('http');
    final isAssetPoster =
        posterUrl != null && posterUrl.startsWith('assets/');

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (isNetworkPoster)
            CachedNetworkImage(
              // isNetworkPoster 为真时 posterUrl 一定非空且以 http 开头。
              imageUrl: posterUrl,
              fit: BoxFit.cover,
              placeholder: (context, url) => ShimmerPlaceholder(),
              errorWidget: (_, _, _) =>
                  _ShortTextCard(item: item, batch: short.batch),
            )
          else if (isAssetPoster)
            Image.asset(
              posterUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  _ShortTextCard(item: item, batch: short.batch),
            )
          else
            _ShortTextCard(item: item, batch: short.batch),
          // 底部信息条：标题 / 作者 / 时长（封面加载失败时文字卡里已有
          // 一份，这里是刷片时一眼能看到的那份）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(
                        Icons.play_circle_filled,
                        color: Colors.white70,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '点一下查看详情',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 无可用封面时的文字卡：标题 + 作者 + 时长 + 批次，不用渐变占位图。
class _ShortTextCard extends StatelessWidget {
  const _ShortTextCard({required this.item, required this.batch});
  final MultimediaItem item;
  final String batch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = _ShortsScreenState._authorOf(item);
    final durationText = _ShortsScreenState._durationText(item);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.play_circle_outline,
            size: 72,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 24),
          Text(
            item.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          if (author.isNotEmpty)
            Text(
              author,
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          if (durationText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(durationText, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 8),
          Text(
            batch,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
