import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/data/sources.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/search_status.dart';

void main() {
  test('第 45 条：只有真有条目的状态才算“有结果”，"0 条" 不算', () {
    expect(statusHasResults('12 条'), isTrue);
    expect(statusHasResults('3 条（后台补回）'), isTrue);
    expect(statusHasResults('0 条'), isFalse);
    expect(statusHasResults('没结果'), isFalse);
    expect(statusHasResults('还在搜…'), isFalse);
    expect(statusHasResults('超时（15秒），后台再试…'), isFalse);
  });

  test('第 45 条：源返回后的状态文案——0 条写“没结果”，不写“0 条”', () {
    VideoItem v(String id) => VideoItem(id: id, title: 't', source: 'niacg');
    SourceResult r({List<VideoItem> items = const [], String? error}) =>
        SourceResult(sourceId: 'niacg', sourceName: 'Niacg', items: items, error: error);
    expect(statusTextForResult(r(items: [])), '没结果');
    expect(statusTextForResult(r(items: [v('1'), v('2'), v('3')])), '3 条');
    expect(statusTextForResult(r(error: '超时（15秒）')), '超时（15秒），后台再试…');
  });
}
