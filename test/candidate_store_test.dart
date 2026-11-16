import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/sniffer/candidate_store.dart';
import 'package:taohuayuan/transfer/download_candidate.dart';

void main() {
  group('CandidateStore', () {
    test('同 URL 只留 confidence 最高者', () {
      final store = CandidateStore();
      store.addAll([
        const DownloadCandidate(url: 'https://cdn.example.com/a.m3u8', confidence: 0.6),
        const DownloadCandidate(url: 'https://cdn.example.com/a.m3u8', confidence: 0.9),
      ]);
      expect(store.length, 1);
      expect(store.sorted.first.confidence, 0.9);
    });

    test('fragment 不同算同一条（去 fragment 后同 id）', () {
      final store = CandidateStore();
      store.addAll([
        const DownloadCandidate(url: 'https://cdn.example.com/a.m3u8#x', confidence: 0.7),
        const DownloadCandidate(url: 'https://cdn.example.com/a.m3u8#y', confidence: 0.8),
      ]);
      expect(store.length, 1);
    });

    test('多源命中升权 0.05，上限 1.0', () {
      final store = CandidateStore();
      store.addAll([
        const DownloadCandidate(
            url: 'https://cdn.example.com/a.m3u8', confidence: 0.9, source: 'network'),
        const DownloadCandidate(
            url: 'https://cdn.example.com/a.m3u8', confidence: 0.9, source: 'page_script'),
      ]);
      expect(store.sorted.first.confidence, closeTo(0.95, 0.001));
    });

    test('排序按 confidence 降序', () {
      final store = CandidateStore();
      store.addAll([
        const DownloadCandidate(url: 'https://cdn.example.com/low.m3u8', confidence: 0.4),
        const DownloadCandidate(url: 'https://cdn.example.com/high.m3u8', confidence: 0.95),
        const DownloadCandidate(url: 'https://cdn.example.com/mid.m3u8', confidence: 0.7),
      ]);
      final urls = store.sorted.map((c) => c.url).toList();
      expect(urls, [
        'https://cdn.example.com/high.m3u8',
        'https://cdn.example.com/mid.m3u8',
        'https://cdn.example.com/low.m3u8',
      ]);
    });

    test('超上限只留前 N 条', () {
      final store = CandidateStore(maxCandidates: 2);
      store.addAll([
        const DownloadCandidate(url: 'https://cdn.example.com/a', confidence: 0.5),
        const DownloadCandidate(url: 'https://cdn.example.com/b', confidence: 0.9),
        const DownloadCandidate(url: 'https://cdn.example.com/c', confidence: 0.7),
      ]);
      expect(store.length, 2);
      expect(store.sorted.map((c) => c.url),
          ['https://cdn.example.com/b', 'https://cdn.example.com/c']);
    });

    test('clear 清空', () {
      final store = CandidateStore();
      store.addAll([
        const DownloadCandidate(url: 'https://cdn.example.com/a'),
      ]);
      store.clear();
      expect(store.isEmpty, isTrue);
    });
  });

  group('DownloadCandidate.effectiveHeaders', () {
    test('referer 覆盖 Referer 键，cookies 拼成 Cookie 键', () {
      const c = DownloadCandidate(
        url: 'https://cdn.example.com/a.m3u8',
        headers: {'User-Agent': 'UA/1.0', 'Referer': 'https://old.example.com/'},
        referer: 'https://www.example.com/watch/1',
        cookies: ['a=1', 'b=2'],
      );
      final h = c.effectiveHeaders();
      expect(h['User-Agent'], 'UA/1.0');
      expect(h['Referer'], 'https://www.example.com/watch/1');
      expect(h['Cookie'], 'a=1; b=2');
    });

    test('无 referer/cookies 时原样返回', () {
      const c = DownloadCandidate(
        url: 'https://cdn.example.com/a.m3u8',
        headers: {'User-Agent': 'UA/1.0'},
      );
      final h = c.effectiveHeaders();
      expect(h, {'User-Agent': 'UA/1.0'});
      expect(h.containsKey('Referer'), isFalse);
      expect(h.containsKey('Cookie'), isFalse);
    });
  });
}
