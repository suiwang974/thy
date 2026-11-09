import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/shorts_preload.dart';
import 'package:taohuayuan/services/stream_resolver.dart';
import 'package:video_player/video_player.dart';

VideoItem item(String id) => VideoItem(id: id, title: 't', source: 'eporner');

/// 假建造：只建播放器、不 initialize（单元测试里没有平台实现，
/// initialize 会调平台通道；建播放器本身不调平台，dispose 也不调——
/// video_player 2.14.1 的 dispose 在没 initialize 时直接跳过平台释放）。
/// 每个测试结束时把到手的播放器 dispose 掉。
ShortControllerBuilder fakeBuilder(Map<String, int> calls) {
  return (VideoItem item) async {
    calls[item.id] = (calls[item.id] ?? 0) + 1;
    return PreloadedShort(
      VideoPlayerController.networkUrl(
          Uri.parse('https://example.com/${item.id}.mp4')),
      const ResolvedStream('https://example.com/x.mp4'),
    );
  };
}

void main() {
  test('第 66 条：预加载只探当前往后 1、2 条，越界的不要', () {
    expect(preloadIndices(0, 10), [1, 2]);
    expect(preloadIndices(8, 10), [9]);
    expect(preloadIndices(9, 10), isEmpty);
    expect(preloadIndices(0, 1), isEmpty);
    expect(preloadIndices(0, 0), isEmpty);
    expect(preloadIndices(0, 10, ahead: 1), [1]);
  });

  test('第 66 条：预加载窗口是当前 ±2 段，滑远了就释放', () {
    expect(keepPreloaded(1, 1), isTrue);
    expect(keepPreloaded(3, 1), isTrue);
    expect(keepPreloaded(4, 1), isFalse);
    expect(keepPreloaded(0, 2), isTrue);
    expect(keepPreloaded(5, 2), isFalse);
  });

  test('第 66 条：take 没现成的就现建一个', () async {
    final calls = <String, int>{};
    final preloader = ShortsPreloader(builder: fakeBuilder(calls));
    final got = await preloader.take(item('a'));
    expect(got, isNotNull);
    expect(calls['a'], 1);
    expect(preloader.readyCount, 0); // 接手的不进缓存
    await got!.controller.dispose();
    preloader.dispose();
  });

  test('第 66 条：预加载和页面共用同一个 Future，不重复建', () async {
    final calls = <String, int>{};
    final preloader = ShortsPreloader(builder: fakeBuilder(calls));
    final items = [item('a'), item('b'), item('c'), item('d')];
    preloader.precache(items, 0); // 只建 b、c
    expect(calls.keys.toSet(), {'b', 'c'});
    // 页面来拿 b：等的是预加载那个 Future，建造只算一次。
    final got = await preloader.take(item('b'));
    expect(got, isNotNull);
    expect(calls['b'], 1);
    await got!.controller.dispose();
    // c 还在缓存里等接手。
    expect(preloader.readyCount, 1);
    final gotC = await preloader.take(item('c'));
    expect(gotC, isNotNull);
    expect(calls['c'], 1);
    await gotC!.controller.dispose();
    preloader.dispose();
  });

  test('第 66 条：接手过的下次再拿要重新建，不拿旧的冒充', () async {
    final calls = <String, int>{};
    final preloader = ShortsPreloader(builder: fakeBuilder(calls));
    final first = await preloader.take(item('a'));
    await first!.controller.dispose();
    final second = await preloader.take(item('a'));
    expect(calls['a'], 2);
    expect(second, isNotNull);
    expect(identical(first.controller, second!.controller), isFalse);
    await second.controller.dispose();
    preloader.dispose();
  });

  test('第 66 条：窗口滑远了，现成的释放掉，再拿重新建', () async {
    final calls = <String, int>{};
    final preloader = ShortsPreloader(builder: fakeBuilder(calls));
    final items = [item('a'), item('b'), item('c'), item('d'), item('e'), item('f'), item('g')];
    preloader.precache(items, 0); // 建 b、c
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(preloader.readyCount, 2);
    preloader.precache(items, 4); // 窗口移到 f、g，b、c 释放
    expect(preloader.readyCount, 0);
    expect(calls.keys.toSet(), {'b', 'c', 'f', 'g'});
    final again = await preloader.take(item('b'));
    expect(calls['b'], 2); // b 被释放过，再拿重新建
    await again!.controller.dispose();
    preloader.dispose();
  });

  test('第 66 条：建失败（返回 null）的不缓存，下次再拿重新建', () async {
    var calls = 0;
    final preloader = ShortsPreloader(builder: (_) async {
      calls++;
      return null;
    });
    expect(await preloader.take(item('a')), isNull);
    expect(await preloader.take(item('a')), isNull);
    expect(calls, 2);
    preloader.dispose();
  });

  test('第 66 条：reset 废掉现成的，drop 废掉指定的一条', () async {
    final calls = <String, int>{};
    final preloader = ShortsPreloader(builder: fakeBuilder(calls));
    final items = [item('a'), item('b'), item('c')];
    preloader.precache(items, 0);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(preloader.readyCount, 2);
    preloader.drop('b');
    expect(preloader.readyCount, 1);
    final b = await preloader.take(item('b'));
    expect(calls['b'], 2);
    await b!.controller.dispose();
    preloader.reset();
    expect(preloader.readyCount, 0);
    final c = await preloader.take(item('c'));
    expect(calls['c'], 2);
    await c!.controller.dispose();
    preloader.dispose();
  });
}
