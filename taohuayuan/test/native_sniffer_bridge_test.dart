import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/sniffer/native_sniffer_bridge.dart';
import 'package:taohuayuan/source/source_registry.dart';
import 'package:taohuayuan/transfer/download_candidate.dart';

/// 集成测试：NativeSnifferBridge（通道用 mock，不真调原生）。
/// 覆盖：路名映射、候选转展示条目、起会话/导航/停/销毁、
/// 轮询进仓库、请求头、未知站默认全开。

const _testBinding = SourceBinding(
  id: 'test',
  displayName: 'Test',
  hosts: ['test.example'],
  adapterPath: [
    AdapterKind.network,
    AdapterKind.pageScript,
    AdapterKind.blobMse,
  ],
  searchMode: SearchMode.both,
  entryUrl: 'https://test.example/',
  flags: {
    AdapterKind.network: true,
    AdapterKind.pageScript: true,
    AdapterKind.blobMse: true,
  },
  rollbackKey: 'test-v1',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('taohuayuan/sniffer');
  final calls = <MethodCall>[];
  var candidatesReply = <Map<String, Object?>>[];
  var throwOn = <String>{};

  setUp(() {
    calls.clear();
    candidatesReply = <Map<String, Object?>>[];
    throwOn = <String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (throwOn.contains(call.method)) {
        throw PlatformException(code: 'MOCK_FAIL', message: 'mock fail');
      }
      if (call.method == 'getCandidates') {
        return candidatesReply;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('adapterChannelNames', () {
    test('六路全开按给定顺序转', () {
      expect(
        NativeSnifferBridge.adapterChannelNames(AdapterKind.values),
        ['NETWORK', 'SERVICE_WORKER', 'PAGE_SCRIPT', 'VIDEO_LISTENER', 'RULE', 'BLOB_MSE'],
      );
    });

    test('只开其中几路', () {
      expect(
        NativeSnifferBridge.adapterChannelNames(
            [AdapterKind.blobMse, AdapterKind.network]),
        ['BLOB_MSE', 'NETWORK'],
      );
    });
  });

  group('candidateToSniffed', () {
    test('按后缀认 m3u8/mp4/webm/ts', () {
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(url: 'https://x.com/a.m3u8'),
        )?.kind,
        'm3u8',
      );
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(url: 'https://x.com/a.mp4?token=1'),
        )?.kind,
        'mp4',
      );
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(url: 'https://x.com/a.webm'),
        )?.kind,
        'webm',
      );
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(url: 'https://x.com/seg-001.ts'),
        )?.kind,
        'ts',
      );
    });

    test('没后缀时按 mime 认', () {
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(
            url: 'https://x.com/play/123',
            mime: 'application/vnd.apple.mpegurl',
          ),
        )?.kind,
        'm3u8',
      );
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(
            url: 'https://x.com/play/123',
            mime: 'video/mp4',
          ),
        )?.kind,
        'mp4',
      );
    });

    test('认不出来或空地址返回 null', () {
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(url: 'https://x.com/cover.jpg'),
        ),
        isNull,
      );
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(url: 'https://x.com/play/123'),
        ),
        isNull,
      );
      expect(
        NativeSnifferBridge.candidateToSniffed(
          const DownloadCandidate(url: ''),
        ),
        isNull,
      );
    });
  });

  group('startSession / navigateTo / stopSession', () {
    test('整源下线时不起会话、不调通道', () async {
      final bridge = NativeSnifferBridge();
      final ok = await bridge.startSession(
        'https://test.example/v/1',
        _testBinding.copyWith(enabled: false),
      );
      expect(ok, isFalse);
      expect(bridge.isRunning, isFalse);
      expect(calls, isEmpty);
    });

    test('未知站（binding 为 null）默认全开、能起会话', () async {
      final bridge = NativeSnifferBridge();
      final ok = await bridge.startSession('https://any.example/v/1', null);
      expect(ok, isTrue);
      expect(bridge.isRunning, isTrue);
      expect(calls.length, 1);
      expect(calls.first.method, 'start');
      expect(
        (calls.first.arguments as Map)['adapters'],
        ['NETWORK', 'SERVICE_WORKER', 'PAGE_SCRIPT', 'VIDEO_LISTENER', 'RULE', 'BLOB_MSE'],
      );
    });

    test('起会话按绑定的路传 adapters', () async {
      final bridge = NativeSnifferBridge();
      final ok = await bridge.startSession(
        'https://test.example/v/1',
        _testBinding,
      );
      expect(ok, isTrue);
      expect(calls.length, 1);
      expect(calls.first.method, 'start');
      expect((calls.first.arguments as Map)['url'], 'https://test.example/v/1');
      expect(
        (calls.first.arguments as Map)['adapters'],
        ['NETWORK', 'PAGE_SCRIPT', 'BLOB_MSE'],
      );
    });

    test('通道抛错时返回 false、不向上传播', () async {
      throwOn = {'start'};
      final bridge = NativeSnifferBridge();
      final ok = await bridge.startSession(
        'https://test.example/v/1',
        _testBinding,
      );
      expect(ok, isFalse);
      expect(bridge.isRunning, isFalse);
    });

    test('没在跑时 navigateTo 按 start 走', () async {
      final bridge = NativeSnifferBridge();
      final ok = await bridge.navigateTo(
        'https://test.example/v/2',
        _testBinding,
      );
      expect(ok, isTrue);
      expect(calls.length, 1);
      expect(calls.first.method, 'start');
    });

    test('在跑时 navigateTo 调 navigate 并清掉上一页候选', () async {
      final bridge = NativeSnifferBridge();
      await bridge.startSession('https://test.example/v/1', _testBinding);
      candidatesReply = [
        {
          'url': 'https://cdn.example/a.m3u8',
          'confidence': 0.9,
          'source': 'NETWORK',
        },
      ];
      await bridge.pollCandidates();
      expect(bridge.store.length, 1);

      calls.clear();
      final ok = await bridge.navigateTo(
        'https://test.example/v/2',
        _testBinding,
      );
      expect(ok, isTrue);
      expect(calls.length, 1);
      expect(calls.first.method, 'navigate');
      expect((calls.first.arguments as Map)['url'], 'https://test.example/v/2');
      expect(bridge.store.isEmpty, isTrue);
    });

    test('导航到下线源时停会话', () async {
      final bridge = NativeSnifferBridge();
      await bridge.startSession('https://test.example/v/1', _testBinding);
      expect(bridge.isRunning, isTrue);
      calls.clear();
      final ok = await bridge.navigateTo(
        'https://test.example/v/2',
        _testBinding.copyWith(enabled: false),
      );
      expect(ok, isFalse);
      expect(bridge.isRunning, isFalse);
      expect(calls.any((c) => c.method == 'stop'), isTrue);
    });

    test('stopSession 停掉并清仓库；dispose 调通道 dispose', () async {
      final bridge = NativeSnifferBridge();
      await bridge.startSession('https://test.example/v/1', _testBinding);
      candidatesReply = [
        {
          'url': 'https://cdn.example/a.m3u8',
          'confidence': 0.9,
          'source': 'NETWORK',
        },
      ];
      await bridge.pollCandidates();
      expect(bridge.store.length, 1);
      await bridge.stopSession();
      expect(bridge.isRunning, isFalse);
      expect(bridge.store.isEmpty, isTrue);
      expect(calls.any((c) => c.method == 'stop'), isTrue);

      await bridge.startSession('https://test.example/v/1', _testBinding);
      await bridge.dispose();
      expect(bridge.isRunning, isFalse);
      expect(calls.any((c) => c.method == 'dispose'), isTrue);
    });
  });

  group('pollCandidates / headersFor / sniffedMedia', () {
    test('没在跑时轮询返回空列表、不调通道', () async {
      final bridge = NativeSnifferBridge();
      final out = await bridge.pollCandidates();
      expect(out, isEmpty);
      expect(calls, isEmpty);
    });

    test('轮询进仓库、按 confidence 降序、去重', () async {
      final bridge = NativeSnifferBridge();
      await bridge.startSession('https://test.example/v/1', _testBinding);
      candidatesReply = [
        {
          'url': 'https://cdn.example/low.mp4',
          'confidence': 0.6,
          'source': 'NETWORK',
        },
        {
          'url': 'https://cdn.example/high.m3u8',
          'confidence': 0.95,
          'source': 'PAGE_SCRIPT',
        },
        {
          'url': 'https://cdn.example/low.mp4',
          'confidence': 0.6,
          'source': 'NETWORK',
        },
      ];
      final out = await bridge.pollCandidates();
      expect(out.length, 2);
      expect(out.first.url, 'https://cdn.example/high.m3u8');
      expect(bridge.sniffedMedia.map((m) => m.kind), ['m3u8', 'mp4']);
    });

    test('headersFor 返回真实请求头（referer 覆盖 + Cookie）', () async {
      final bridge = NativeSnifferBridge();
      await bridge.startSession('https://test.example/v/1', _testBinding);
      candidatesReply = [
        {
          'url': 'https://cdn.example/a.m3u8',
          'referer': 'https://test.example/v/1',
          'headers': {
            'User-Agent': 'Mozilla/5.0',
            'Referer': 'https://old.example/',
          },
          'confidence': 0.9,
          'source': 'NETWORK',
        },
      ];
      await bridge.pollCandidates();
      final headers = bridge.headersFor('https://cdn.example/a.m3u8');
      expect(headers, isNotNull);
      expect(headers!['User-Agent'], 'Mozilla/5.0');
      // referer 字段优先于 headers 里的同名项
      expect(headers['Referer'], 'https://test.example/v/1');
      // 地址带 # 后缀也能对上
      expect(
        bridge.headersFor('https://cdn.example/a.m3u8#frag'),
        isNotNull,
      );
      // 查不到返回 null
      expect(bridge.headersFor('https://cdn.example/other.mp4'), isNull);
    });

    test('sniffedMedia 跳过认不出来的候选', () async {
      final bridge = NativeSnifferBridge();
      await bridge.startSession('https://test.example/v/1', _testBinding);
      candidatesReply = [
        {
          'url': 'https://cdn.example/a.m3u8',
          'confidence': 0.9,
          'source': 'NETWORK',
        },
        {
          'url': 'https://cdn.example/cover.jpg',
          'confidence': 0.8,
          'source': 'NETWORK',
        },
      ];
      await bridge.pollCandidates();
      expect(bridge.sniffedMedia.length, 1);
      expect(bridge.sniffedMedia.first.url, 'https://cdn.example/a.m3u8');
    });
  });
}
