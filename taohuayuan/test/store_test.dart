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
}
