import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/ui/shorts_screen.dart';

void main() {
  test('短视频流不过 30 分钟的长片（第 16 条），时长未知的不丢', () {
    VideoItem item(int sec) =>
        VideoItem(id: 'v$sec', title: 't', source: 'eporner', durationSec: sec);
    expect(isShortForShorts(item(0)), isTrue); // 时长未知，保留
    expect(isShortForShorts(item(60)), isTrue);
    expect(isShortForShorts(item(1800)), isTrue); // 正好半小时，留
    expect(isShortForShorts(item(1801)), isFalse);
    expect(isShortForShorts(item(3600)), isFalse);
  });

  VideoItem item(String id, {int publishedAtMs = 0, int views = 0}) => VideoItem(
        id: id,
        title: 't',
        source: 'eporner',
        publishedAtMs: publishedAtMs,
        views: views,
      );

  test('第 48 条：最新按发布时间倒序，没有发布时间的放后面', () {
    final items = [
      item('a'), // 没发布时间
      item('b', publishedAtMs: 100),
      item('c', publishedAtMs: 300),
      item('d', publishedAtMs: 200),
    ];
    final sorted = sortShortsByNewest(items);
    expect(sorted.map((v) => v.id).toList(), ['c', 'd', 'b', 'a']);
  });

  test('第 48 条：最热门按播放量倒序，没有播放量的放后面', () {
    final items = [
      item('a', views: 50),
      item('b'), // 没播放量
      item('c', views: 900),
      item('d', views: 100),
    ];
    final sorted = sortShortsByHottest(items);
    expect(sorted.map((v) => v.id).toList(), ['c', 'd', 'a', 'b']);
  });

  test('第 49 条 vs 第 46 条：已在短视频栏再点才刷新，从别的栏切过来不刷新', () {
    // 已在短视频栏（index 1）再点短视频栏 → 刷新，换一批新的。
    expect(
        shouldRefreshShortsOnTabTap(
            tappedIndex: 1, currentIndex: 1, shortsIndex: 1),
        isTrue);
    // 从推荐（0）切到短视频（1）→ 只导航，不刷新——46 条的续播位置要看得到。
    expect(
        shouldRefreshShortsOnTabTap(
            tappedIndex: 1, currentIndex: 0, shortsIndex: 1),
        isFalse);
    // 从浏览器（2）切到短视频（1）→ 同样不刷新。
    expect(
        shouldRefreshShortsOnTabTap(
            tappedIndex: 1, currentIndex: 2, shortsIndex: 1),
        isFalse);
    // 点别的栏 → 当然不刷新短视频。
    expect(
        shouldRefreshShortsOnTabTap(
            tappedIndex: 0, currentIndex: 1, shortsIndex: 1),
        isFalse);
    expect(
        shouldRefreshShortsOnTabTap(
            tappedIndex: 2, currentIndex: 2, shortsIndex: 1),
        isFalse);
  });
}
