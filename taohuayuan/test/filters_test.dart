import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/search_service.dart';

VideoItem item({
  required String id,
  String title = '',
  List<String> keywords = const [],
  int durationSec = 0,
  String resolution = '',
  int views = 0,
  int publishedAtMs = 0,
}) =>
    VideoItem(
      id: id,
      title: title,
      source: 'eporner',
      keywords: keywords,
      durationSec: durationSec,
      resolution: resolution,
      views: views,
      publishedAtMs: publishedAtMs,
    );

void main() {
  test('分类过滤：足控命中标题/标签，3D 不命中足控', () {
    const f = SearchFilters(category: '足控');
    expect(f.matches(item(id: 'a', title: 'footjob girl', keywords: ['footjob'])), isTrue);
    expect(f.matches(item(id: 'b', title: '3d animation', keywords: ['3d'])), isFalse);
    expect(f.matches(item(id: 'c', title: '恋足视频', keywords: [])), isTrue); // 中文标题命中
  });

  test('时长过滤：时长未知的不过滤掉', () {
    const f = SearchFilters(minDurationSec: 300, maxDurationSec: 1200);
    expect(f.matches(item(id: 'a', durationSec: 600)), isTrue);
    expect(f.matches(item(id: 'b', durationSec: 100)), isFalse);
    expect(f.matches(item(id: 'c', durationSec: 0)), isTrue); // 未知时长不丢
  });

  test('画质过滤：1080p+ 只拦已知非高清的，未知的不丢', () {
    const f = SearchFilters(hdOnly: true);
    expect(f.matches(item(id: 'a', resolution: '1080p')), isTrue);
    expect(f.matches(item(id: 'b', resolution: '720p')), isFalse);
    expect(f.matches(item(id: 'c', resolution: '')), isTrue);
  });

  test('排序：最新按发布时间倒序，最多看按播放量倒序，最长按时长倒序', () {
    final items = [
      item(id: 'old', publishedAtMs: 1000, views: 5, durationSec: 60),
      item(id: 'new', publishedAtMs: 3000, views: 1, durationSec: 600),
      item(id: 'mid', publishedAtMs: 2000, views: 9, durationSec: 120),
    ];
    expect(
        const SearchFilters(sort: SortOrder.newest).apply(items).map((v) => v.id).toList(),
        ['new', 'mid', 'old']);
    expect(
        const SearchFilters(sort: SortOrder.mostViewed).apply(items).map((v) => v.id).toList(),
        ['mid', 'old', 'new']);
    expect(
        const SearchFilters(sort: SortOrder.longest).apply(items).map((v) => v.id).toList(),
        ['new', 'mid', 'old']);
  });

  test('相关排序不重排，保持源站原顺序', () {
    final items = [item(id: 'a'), item(id: 'b'), item(id: 'c')];
    expect(
        const SearchFilters(sort: SortOrder.relevance).apply(items).map((v) => v.id).toList(),
        ['a', 'b', 'c']);
  });
}
