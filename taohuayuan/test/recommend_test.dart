import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/recommend.dart';
import 'package:taohuayuan/services/store.dart';

VideoItem item({
  required String id,
  String title = '',
  String author = '',
  String source = 'eporner',
  List<String> keywords = const [],
  int views = 0,
  int publishedAtMs = 0,
}) =>
    VideoItem(
      id: id,
      title: title,
      author: author,
      source: source,
      keywords: keywords,
      views: views,
      publishedAtMs: publishedAtMs,
    );

void main() {
  test('冷启动：默认口味足控/3D/亚洲，命中的排前面且有理由', () {
    const profile = TasteProfile(); // 空画像 = 冷启动默认
    final ranked = rankRecommendations([
      item(id: 'a', title: 'random video', keywords: ['music']),
      item(id: 'b', title: 'footjob asian girl', keywords: ['footjob', 'asian']),
      item(id: 'c', title: '3d animation', keywords: ['3d']),
    ], profile);
    expect(ranked.first.item.id, 'b');
    expect(ranked.first.reason, contains('足交'));
    expect(ranked.map((s) => s.item.id), contains('c'));
  });

  test('关注的作者加权最高，理由写明作者名', () {
    const profile = TasteProfile(authors: {'Sugardust'});
    final ranked = rankRecommendations([
      item(id: 'a', title: 'footjob video', keywords: ['footjob']),
      item(id: 'b', title: 'Sugardust new', author: 'Sugardust'),
    ], profile);
    expect(ranked.first.item.id, 'b');
    expect(ranked.first.reason, contains('Sugardust'));
  });

  test('同一作者太多降权：前 2 条之后挪到队尾', () {
    const profile = TasteProfile(authors: {'A'});
    final ranked = rankRecommendations([
      item(id: 'a1', title: 'A one', author: 'A'),
      item(id: 'a2', title: 'A two', author: 'A'),
      item(id: 'a3', title: 'A three', author: 'A'),
      item(id: 'b1', title: 'footjob', keywords: ['footjob']),
    ], profile);
    final ids = ranked.map((s) => s.item.id).toList();
    expect(ids.indexOf('a3'), greaterThan(ids.indexOf('b1')));
  });

  test('不喜欢的标签降权：含 dislike 标签的沉底', () {
    const profile = TasteProfile(dislikedTags: {'femdom'});
    final ranked = rankRecommendations([
      item(id: 'a', title: 'femdom video', keywords: ['femdom']),
      item(id: 'b', title: 'footjob video', keywords: ['footjob']),
    ], profile);
    expect(ranked.first.item.id, 'b');
    expect(ranked.last.item.id, 'a');
  });

  test('已看完的不再推', () {
    const profile = TasteProfile(watchedIds: {'done'});
    final ranked = rankRecommendations([
      item(id: 'done', title: 'footjob', keywords: ['footjob']),
      item(id: 'new', title: 'footjob 2', keywords: ['footjob']),
    ], profile);
    expect(ranked.map((s) => s.item.id), ['new']);
  });

  test('80/20 试新：20% 是和口味完全不重合的条目，理由写明试新', () {
    const profile = TasteProfile(tags: {'footjob'});
    final items = <VideoItem>[
      for (var i = 0; i < 8; i++) item(id: 't$i', title: 'footjob $i', keywords: ['footjob']),
      item(id: 'n1', title: 'cosplay dance', keywords: ['cosplay'], views: 9999),
      item(id: 'n2', title: 'cooking show', keywords: ['cooking'], views: 8888),
    ];
    final ranked = rankRecommendations(items, profile);
    final explore = ranked.where((s) => s.reason.startsWith('试试新口味')).toList();
    expect(explore.length, 2);
    expect(explore.map((s) => s.item.id), containsAll(['n1', 'n2']));
  });

  test('每条都有理由，不为空', () {
    const profile = TasteProfile();
    final ranked = rankRecommendations([
      item(id: 'a', title: 'zzz'),
    ], profile);
    expect(ranked.length, 1);
    expect(ranked.first.reason.isNotEmpty, isTrue);
  });

  test('去重：同一条（同 id）只留一次，不反复出现', () {
    const profile = TasteProfile();
    final ranked = rankRecommendations([
      item(id: 'a', title: 'footjob one', keywords: ['footjob']),
      item(id: 'a', title: 'footjob one', keywords: ['footjob']),
      item(id: 'b', title: '3d one', keywords: ['3d']),
    ], profile);
    expect(ranked.length, 2);
    expect(ranked.map((s) => s.item.id).toSet(), {'a', 'b'});
  });

  test('看过但没看完的降权：同分时排在没看过的后面', () {
    const profile = TasteProfile(seenIds: {'a'});
    final ranked = rankRecommendations([
      item(id: 'a', title: 'footjob one', keywords: ['footjob']),
      item(id: 'b', title: 'footjob two', keywords: ['footjob']),
    ], profile);
    expect(ranked.first.item.id, 'b');
    expect(ranked.last.item.id, 'a');
  });

  test('看过的不当“试新”推', () {
    const profile = TasteProfile(seenIds: {'n1'});
    final ranked = rankRecommendations([
      item(id: 't0', title: 'footjob 0', keywords: ['footjob']),
      item(id: 'n1', title: 'cosplay dance', keywords: ['cosplay'], views: 9999),
      item(id: 'n2', title: 'cooking show', keywords: ['cooking'], views: 8888),
    ], profile);
    final explore = ranked.where((s) => s.reason.startsWith('试试新口味')).toList();
    expect(explore.map((s) => s.item.id), isNot(contains('n1')));
  });

  test('第 60 条：手动加的喜欢标签进画像，立刻影响推荐排序', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    await store.addLikedTag('cosplay');
    final profile = TasteProfile.fromStore(store);
    expect(profile.tags, contains('cosplay'));
    final ranked = rankRecommendations([
      item(id: 'a', title: 'cosplay dance', keywords: ['cosplay']),
      item(id: 'b', title: 'cooking show', keywords: ['cooking']),
    ], profile);
    expect(ranked.first.item.id, 'a');
    // 删掉就不影响了。
    await store.removeLikedTag('cosplay');
    expect(TasteProfile.fromStore(store).tags, isNot(contains('cosplay')));
  });

}
