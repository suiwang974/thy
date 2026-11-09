import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/ui/shorts_screen.dart';
import 'package:taohuayuan/ui/shorts_search_screen.dart';

void main() {
  test('第 55 条：播放量格式化（抖音搜索结果页那样子：75.1万）', () {
    expect(formatShortsViews(0), ''); // 源站没给，不编
    expect(formatShortsViews(-5), '');
    expect(formatShortsViews(999), '999');
    expect(formatShortsViews(9999), '9999');
    expect(formatShortsViews(10000), '1.0万');
    expect(formatShortsViews(751000), '75.1万');
    expect(formatShortsViews(266000), '26.6万');
    expect(formatShortsViews(1836000), '183.6万');
    expect(formatShortsViews(123456789), '1.2亿');
  });

  VideoItem item(String id, {int durationSec = 60}) =>
      VideoItem(id: id, title: 't', source: 'eporner', durationSec: durationSec);

  test('第 55 条：搜索流只留能竖滑的（30 分钟内/时长未知），按网格顺序、去重', () {
    final items = [
      item('a', durationSec: 60),
      item('b', durationSec: 3600), // 长片，不进
      item('c', durationSec: 0), // 时长未知，留
      item('a', durationSec: 60), // 重复，去掉
      item('d', durationSec: 1800), // 正好半小时，留
    ];
    expect(shortsSearchStream(items).map((v) => v.id).toList(), ['a', 'c', 'd']);
  });

  test('第 55 条：点中的那条在搜索流里的位置；点长片返回 -1', () {
    final items = [
      item('a', durationSec: 60),
      item('b', durationSec: 3600),
      item('c', durationSec: 120),
      item('d', durationSec: 30),
    ];
    expect(shortsSearchStartIndex(items, 0), 0);
    expect(shortsSearchStartIndex(items, 2), 1); // 前面长片不占位置
    expect(shortsSearchStartIndex(items, 3), 2);
    expect(shortsSearchStartIndex(items, 1), -1); // 长片，进详情页
    expect(shortsSearchStartIndex(items, 99), -1);
    expect(shortsSearchStartIndex(items, -1), -1);
  });

  test('第 55 条：搜索流里一条长片都没有', () {
    final items = List.generate(20, (i) => item('v$i', durationSec: i.isEven ? 60 : 3600));
    final stream = shortsSearchStream(items);
    expect(stream.length, 10);
    expect(stream.every((v) => v.durationSec <= 1800), isTrue);
  });
}
