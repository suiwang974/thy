import '../data/search_map.dart';
import '../models/video_item.dart';
import 'store.dart';

/// 推荐算法（用户 2026-11-08 定）。
/// - 口味画像只存本地：点赞、看完比例、关注作者、搜过的词；
/// - 打分 = 标签重合 + 作者加权 + 新鲜度 + 来源偏好；同一作者太多降权；
/// - 80% 按口味推、20% 试新标签；不喜欢就降权；
/// - 冷启动默认足控 / 3D / 亚洲；
/// - 每条推荐写明理由。
/// - 已看完（看完比例 >= 90%）的不再推。

/// 英文标签 -> 中文理由词。
const Map<String, String> kTagLabels = {
  'foot': '足控',
  'footjob': '足交',
  'feet': '足控',
  'femdom': '调教',
  '3d': '3D',
  'asian': '亚洲',
  'japanese': '日本',
  'cosplay': '角色扮演',
  'blowjob': '口交',
};

/// 冷启动默认口味标签。
const Set<String> kColdStartTags = {'foot', 'footjob', '3d', 'asian'};

class TasteProfile {
  final Set<String> tags; // 喜欢的标签（小写英文词）
  final Set<String> authors; // 关注的作者
  final Map<String, int> sourceLikes; // 每个源被点赞的次数
  final Set<String> dislikedTags; // 点过“不喜欢”的标签
  final Set<String> watchedIds; // 已看完的视频 id
  final Set<String> seenIds; // 看过一半以上的视频 id（没看完也降权，别反复置顶）

  const TasteProfile({
    this.tags = const {},
    this.authors = const {},
    this.sourceLikes = const {},
    this.dislikedTags = const {},
    this.watchedIds = const {},
    this.seenIds = const {},
  });

  /// 从本地 Store 拼出画像；什么都没有时用冷启动默认口味。
  factory TasteProfile.fromStore(Store store) {
    final tags = <String>{};
    for (final item in store.likedItems()) {
      tags.addAll(item.keywords.map((k) => k.toLowerCase()));
    }
    for (final term in store.searchTerms) {
      // 原词（中文标题能命中）+ 映射后的英文词（英文标题/标签能命中）都进画像。
      tags.add(term.toLowerCase());
      final mapped = mapSearchQuery(term).toLowerCase();
      if (mapped.isNotEmpty) tags.add(mapped);
    }
    final sourceLikes = <String, int>{};
    for (final item in store.likedItems()) {
      sourceLikes[item.source] = (sourceLikes[item.source] ?? 0) + 1;
    }
    final watchedIds = <String>{};
    final seenIds = <String>{};
    for (final item in store.historyItems()) {
      final ratio = store.watchRatio(item.id);
      if (ratio >= 0.9) watchedIds.add(item.id);
      if (ratio > 0) seenIds.add(item.id);
    }
    if (tags.isEmpty) tags.addAll(kColdStartTags);
    return TasteProfile(
      tags: tags,
      authors: store.followedAuthors,
      sourceLikes: sourceLikes,
      dislikedTags: store.dislikedTags,
      watchedIds: watchedIds,
      seenIds: seenIds,
    );
  }
}

class ScoredItem {
  final VideoItem item;
  final double score;
  final String reason;
  const ScoredItem(this.item, this.score, this.reason);
}

/// 给一批在线结果打分、排序、混入 20% 试新，返回带理由的推荐列表。
List<ScoredItem> rankRecommendations(
  List<VideoItem> items,
  TasteProfile profile0, {
  int explorationPercent = 20,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  // 画像里一个标签都没有（刚装好、或刚清过口味数据）= 冷启动默认口味。
  final profile = profile0.tags.isEmpty
      ? TasteProfile(
          tags: kColdStartTags,
          authors: profile0.authors,
          sourceLikes: profile0.sourceLikes,
          dislikedTags: profile0.dislikedTags,
          watchedIds: profile0.watchedIds,
          seenIds: profile0.seenIds,
        )
      : profile0;
  // 去重：同一条（同 id）只留第一次出现，别在推荐流里反复出现。
  final seenIds = <String>{};
  final unique = items.where((v) => seenIds.add(v.id)).toList();
  final scored = <ScoredItem>[];
  for (final item in unique) {
    if (profile.watchedIds.contains(item.id)) continue; // 已看完的不再推
    final hay = '${item.title.toLowerCase()} ${item.keywords.join(' ').toLowerCase()}';
    var score = 0.0;
    var reason = '热门推荐';
    var reasonScore = 0.0;

    // 标签重合：每命中一个口味标签 +3，上限 +6。
    // 理由取最长命中的标签（“footjob”优先于“foot”，和搜索映射的长词优先一个道理）。
    var tagHits = 0;
    String? hitTag;
    for (final tag in profile.tags) {
      if (tag.isEmpty) continue;
      if (hay.contains(tag)) {
        tagHits++;
        if (hitTag == null || tag.length > hitTag.length) hitTag = tag;
      }
    }
    if (tagHits > 0) {
      final add = (tagHits * 3).clamp(0, 6).toDouble();
      score += add;
      if (add > reasonScore) {
        reasonScore = add;
        reason = '因为你喜欢${kTagLabels[hitTag] ?? hitTag}';
      }
    }
    // 关注的作者 +8（作者加权最高，压过标签重合）。
    if (item.author.isNotEmpty && profile.authors.contains(item.author)) {
      score += 8;
      if (8 > reasonScore) {
        reasonScore = 8;
        reason = '你关注了 ${item.author}';
      }
    }
    // 来源偏好：常点赞的源 +2。
    if ((profile.sourceLikes[item.source] ?? 0) > 0) {
      score += 2;
      if (2 > reasonScore) {
        reasonScore = 2;
        reason = '来自你常看的 ${item.source}';
      }
    }
    // 新鲜度：7 天内 +2，30 天内 +1（只看发布时间已知的）。
    if (item.publishedAtMs > 0) {
      final days = (now - item.publishedAtMs) / 86400000;
      if (days <= 7) {
        score += 2;
      } else if (days <= 30) {
        score += 1;
      }
      if (days <= 7 && reasonScore < 2) reason = '新鲜热门';
    }
    // 不喜欢的标签：命中一个 -10。
    for (final tag in profile.dislikedTags) {
      if (tag.isNotEmpty && hay.contains(tag)) score -= 10;
    }
    // 看过但没看完的：降权 -4，别反复置顶（已看完的上面已经直接去掉了）。
    if (profile.seenIds.contains(item.id)) score -= 4;
    scored.add(ScoredItem(item, score, reason));
  }

  scored.sort((a, b) => b.score.compareTo(a.score));

  // 同一作者太多降权：同一作者最多 2 条排在前面，超出的挪到队尾（保持原顺序）。
  final authorCount = <String, int>{};
  final head = <ScoredItem>[];
  final tail = <ScoredItem>[];
  for (final s in scored) {
    final a = s.item.author;
    if (a.isEmpty) {
      head.add(s);
      continue;
    }
    final n = (authorCount[a] ?? 0) + 1;
    authorCount[a] = n;
    if (n <= 2) {
      head.add(s);
    } else {
      tail.add(ScoredItem(s.item, s.score, s.reason));
    }
  }
  final ranked = [...head, ...tail];

  // 80% 按口味推 + 20% 试新标签：从“和口味完全不沾边”的条目里挑新鲜/多人看的，
  // 插到推荐流里，每条写明“试试新口味”。
  // “不沾边” = 标签没命中、作者没关注、来源也不是常看的源（关注的作者不算试新）。
  if (ranked.isEmpty) return ranked;
  final exploreCount = (ranked.length * explorationPercent / 100).round().clamp(1, ranked.length);
  final novel = ranked.where((s) {
    final hay = '${s.item.title.toLowerCase()} ${s.item.keywords.join(' ').toLowerCase()}';
    final tagHit = profile.tags.any((t) => t.isNotEmpty && hay.contains(t));
    final authorHit = s.item.author.isNotEmpty && profile.authors.contains(s.item.author);
    final sourceHit = (profile.sourceLikes[s.item.source] ?? 0) > 0;
    // 看过的也不当“试新”推，别把看过的又顶上来。
    return !tagHit && !authorHit && !sourceHit && !profile.seenIds.contains(s.item.id);
  }).toList();
  if (novel.isEmpty) return ranked;
  novel.sort((a, b) {
    final byViews = b.item.views.compareTo(a.item.views);
    if (byViews != 0) return byViews;
    return b.item.publishedAtMs.compareTo(a.item.publishedAtMs);
  });
  final explore = novel.take(exploreCount).toList();
  final exploreIds = explore.map((s) => s.item.id).toSet();
  final taste = ranked.where((s) => !exploreIds.contains(s.item.id)).toList();
  final out = <ScoredItem>[];
  final step = taste.isEmpty ? 1 : (taste.length / explore.length).ceil();
  var ei = 0;
  for (var i = 0; i < taste.length; i++) {
    out.add(taste[i]);
    if (ei < explore.length && (i + 1) % step == 0) {
      final e = explore[ei++];
      final tag = _novelTag(e.item, profile);
      out.add(ScoredItem(e.item, e.score, '试试新口味：${kTagLabels[tag] ?? tag}'));
    }
  }
  while (ei < explore.length) {
    final e = explore[ei++];
    final tag = _novelTag(e.item, profile);
    out.add(ScoredItem(e.item, e.score, '试试新口味：${kTagLabels[tag] ?? tag}'));
  }
  return out;
}

/// 从一条“试新”条目里挑一个它有、画像里没有的标签词来当理由。
String _novelTag(VideoItem item, TasteProfile profile) {
  for (final k in item.keywords) {
    final t = k.toLowerCase();
    if (t.isNotEmpty && !profile.tags.contains(t)) return t;
  }
  final words = item.title.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
  for (final w in words) {
    if (w.length > 2 && !profile.tags.contains(w)) return w;
  }
  return '新标签';
}
