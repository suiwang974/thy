import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/sniffer/sniffer_channel.dart';

/// SnifferChannel（Dart 桥）测试：方法名、参数、候选解析。
/// 通道用 mock，不真调原生。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('taohuayuan/sniffer');
  final calls = <MethodCall>[];
  var candidatesReply = <Map<String, Object?>>[];

  setUp(() {
    calls.clear();
    candidatesReply = <Map<String, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
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

  test('start 传 url 与 adapters', () async {
    final ch = SnifferChannel();
    await ch.start(
      'https://xhamster.com/videos/1',
      adapters: ['NETWORK', 'BLOB_MSE'],
    );
    expect(calls.length, 1);
    expect(calls.first.method, 'start');
    final args = calls.first.arguments as Map;
    expect(args['url'], 'https://xhamster.com/videos/1');
    expect(args['adapters'], ['NETWORK', 'BLOB_MSE']);
  });

  test('start 不传 adapters 时传空列表（原生侧默认六路全开）', () async {
    final ch = SnifferChannel();
    await ch.start('https://xhamster.com/videos/1');
    expect(calls.length, 1);
    expect((calls.first.arguments as Map)['adapters'], <String>[]);
  });

  test('navigate 传 url 与 adapters', () async {
    final ch = SnifferChannel();
    await ch.navigate(
      'https://xhamster.com/videos/2',
      adapters: ['PAGE_SCRIPT'],
    );
    expect(calls.length, 1);
    expect(calls.first.method, 'navigate');
    expect((calls.first.arguments as Map)['url'], 'https://xhamster.com/videos/2');
    expect((calls.first.arguments as Map)['adapters'], ['PAGE_SCRIPT']);
  });

  test('stop / dispose 调对方法', () async {
    final ch = SnifferChannel();
    await ch.stop();
    await ch.dispose();
    expect(calls.map((c) => c.method), ['stop', 'dispose']);
  });

  test('getCandidates 解析 headers 与 expiresAt、过滤空地址', () async {
    candidatesReply = [
      {
        'url': 'https://cdn.example/a.m3u8',
        'referer': 'https://xhamster.com/videos/1',
        'mime': 'application/vnd.apple.mpegurl',
        'confidence': 0.9,
        'source': 'NETWORK',
        'headers': {'User-Agent': 'Mozilla/5.0', 'Origin': 'https://xhamster.com'},
        'expiresAt': 1794000000000,
      },
      {
        'url': '',
        'confidence': 0.5,
        'source': 'NETWORK',
      },
      {
        'url': 'https://cdn.example/b.mp4',
      },
    ];
    final ch = SnifferChannel();
    final out = await ch.getCandidates();
    // 空地址那条被过滤
    expect(out.length, 2);
    final first = out.first;
    expect(first.url, 'https://cdn.example/a.m3u8');
    expect(first.referer, 'https://xhamster.com/videos/1');
    expect(first.mime, 'application/vnd.apple.mpegurl');
    expect(first.confidence, 0.9);
    expect(first.source, 'NETWORK');
    expect(first.headers['User-Agent'], 'Mozilla/5.0');
    expect(first.headers['Origin'], 'https://xhamster.com');
    expect(
      first.expiresAt,
      DateTime.fromMillisecondsSinceEpoch(1794000000000),
    );
    // 缺字段时走默认值
    final second = out[1];
    expect(second.confidence, 0.5);
    expect(second.source, 'network');
    expect(second.headers, isEmpty);
    expect(second.expiresAt, isNull);
  });

  test('getCandidates 返回 null 时给空列表', () async {
    candidatesReply = <Map<String, Object?>>[];
    final ch = SnifferChannel();
    final out = await ch.getCandidates();
    expect(out, isEmpty);
  });
}
