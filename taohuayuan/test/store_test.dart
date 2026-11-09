import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/store.dart';

void main() {
  test('看完比例 + 观看位置都记下来，续播用', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    final item = VideoItem(id: 'v1', title: 'test', source: 'eporner', durationSec: 600);
    await store.recordWatch(item, 390);
    expect(store.watchRatio('v1'), closeTo(0.65, 0.001));
    expect(store.watchPosition('v1'), 390);
    // 没看过的返回 0。
    expect(store.watchRatio('nope'), 0.0);
    expect(store.watchPosition('nope'), 0);
    // 不知道总时长的记不下来。
    final noDur = VideoItem(id: 'v2', title: 'test2', source: 'eporner', durationSec: 0);
    await store.recordWatch(noDur, 100);
    expect(store.watchRatio('v2'), 0.0);
    expect(store.watchPosition('v2'), 0);
  });

  test('搜过的词和不喜欢的标签进画像', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    await store.recordSearchTerm('足');
    await store.recordSearchTerm('footjob');
    expect(store.searchTerms, ['footjob', '足']);
    final item = VideoItem(id: 'v1', title: 't', source: 'eporner', keywords: ['femdom']);
    await store.dislikeItem(item);
    expect(store.dislikedTags, contains('femdom'));
  });

  test('降权是切换：点一下亮、再点取消，状态持久保存', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    final a = VideoItem(
        id: 'a', title: 't', source: 'eporner', keywords: ['femdom', 'asian'], author: 'X');
    final b = VideoItem(
        id: 'b', title: 't2', source: 'eporner', keywords: ['femdom'], author: 'Y');
    expect(store.isDisliked(a), isFalse);
    expect(await store.toggleDislike(a), isTrue);
    expect(store.isDisliked(a), isTrue);
    expect(store.dislikedTags, contains('femdom'));
    expect(store.dislikedTags, contains('author:x'));
    // 另一条共用 femdom 标签也降权。
    await store.toggleDislike(b);
    // 取消 a 的降权：femdom 还在（b 贡献的），author:x 没了。
    expect(await store.toggleDislike(a), isFalse);
    expect(store.isDisliked(a), isFalse);
    expect(store.dislikedTags, contains('femdom'));
    expect(store.dislikedTags, isNot(contains('author:x')));
    // 取消 b：femdom 也没了。
    await store.toggleDislike(b);
    expect(store.dislikedTags, isEmpty);
  });

  test('短视频默认静音（第 15 条）：没存过就是 true，改了持久保存', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    expect(store.shortsMuted, isTrue);
    await store.setShortsMuted(false);
    expect(store.shortsMuted, isFalse);
    // 重新加载还记得。
    final store2 = await Store.load();
    expect(store2.shortsMuted, isFalse);
    await store2.setShortsMuted(true);
    expect(store.shortsMuted, isTrue);
  });

  test('短视频轮换计数 + 各标签位置（第 46/48 条）：默认 0，存了重启还记得', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    expect(store.shortsRotation, 0);
    expect(store.shortsPosition('rec'), 0);
    expect(store.shortsPosition('newest'), 0);
    expect(store.shortsPosition('hottest'), 0);
    await store.setShortsRotation(3);
    await store.setShortsPosition('rec', 120);
    await store.setShortsPosition('newest', 5);
    await store.setShortsPosition('hottest', 77);
    // 重新加载还记得，各标签互不干扰。
    final store2 = await Store.load();
    expect(store2.shortsRotation, 3);
    expect(store2.shortsPosition('rec'), 120);
    expect(store2.shortsPosition('newest'), 5);
    expect(store2.shortsPosition('hottest'), 77);
  });

  test('第 60 条：喜欢的标签手动加/删，搜过的词单条删', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    await store.addLikedTag(' Cosplay ');
    await store.addLikedTag('cosplay'); // 重复加不重复存
    await store.addLikedTag('3d');
    expect(store.likedTags, {'cosplay', '3d'});
    await store.removeLikedTag('cosplay');
    expect(store.likedTags, {'3d'});
    // 搜过的词单条删，别的留着。
    await store.recordSearchTerm('足');
    await store.recordSearchTerm('3d');
    await store.removeSearchTerm('足');
    expect(store.searchTerms, ['3d']);
  });

  test('第 60 条：不喜欢的标签手动加/删；降权条目贡献的删了不再回来', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    // 手动加的。
    await store.dislikeTag('femdom');
    expect(store.dislikedTags, contains('femdom'));
    await store.removeDislikedTag('femdom');
    expect(store.dislikedTags, isNot(contains('femdom')));
    // 条目降权贡献的：删掉后，之后再降权别的条目（重算并集）也不复活；
    // 但之后又降权一条带这标签的新片，它会合理地回来——那是新贡献，不是复活。
    final a = VideoItem(
        id: 'a', title: 't', source: 'eporner', keywords: ['femdom']);
    final b = VideoItem(
        id: 'b', title: 't2', source: 'eporner', keywords: ['femdom']);
    final c = VideoItem(
        id: 'c', title: 't3', source: 'eporner', keywords: ['asian']);
    await store.toggleDislike(a);
    expect(store.dislikedTags, contains('femdom'));
    await store.removeDislikedTag('femdom');
    expect(store.dislikedTags, isNot(contains('femdom')));
    await store.toggleDislike(c); // 触发重算并集
    expect(store.dislikedTags, contains('asian'));
    expect(store.dislikedTags, isNot(contains('femdom')));
    await store.toggleDislike(b); // 新降权的条目带 femdom，合理回来
    expect(store.dislikedTags, contains('femdom'));
    // 清除口味数据：手动标签和降权条目一起清。
    await store.addLikedTag('cosplay');
    await store.clearTaste();
    expect(store.likedTags, isEmpty);
    expect(store.dislikedTags, isEmpty);
    expect(store.dislikedItemIds, isEmpty);
  });
}
