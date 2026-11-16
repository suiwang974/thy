import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/transfer/hls_playlist.dart';

void main() {
  group('HlsPlaylist.isMaster', () {
    test('master 文本 true，media 文本 false', () {
      expect(
          HlsPlaylist.isMaster(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nlow.m3u8\n'),
          isTrue);
      expect(
          HlsPlaylist.isMaster(
              '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXT-X-ENDLIST\n'),
          isFalse);
    });
  });

  group('HlsPlaylist.parseMaster', () {
    test('两变体：带宽/分辨率/CODECS 都取到，相对 URL 按 base 拼', () {
      const text = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360,CODECS="avc1.64001e,mp4a.40.2"\n'
          'low.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"\n'
          'high.m3u8\n';
      final variants =
          HlsPlaylist.parseMaster(text, 'https://cdn.example.com/v/');
      expect(variants.length, 2);
      expect(variants[0].bandwidth, 500000);
      expect(variants[0].resolution, '640x360');
      expect(variants[0].codecs, 'avc1.64001e,mp4a.40.2');
      expect(variants[0].url, 'https://cdn.example.com/v/low.m3u8');
      expect(variants[1].bandwidth, 2000000);
      expect(variants[1].url, 'https://cdn.example.com/v/high.m3u8');
    });

    test('空行与注释行跳过，不产生多余变体', () {
      const text = '#EXTM3U\n\n#EXT-X-VERSION:3\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000\n'
          'mid.m3u8\n\n';
      final variants =
          HlsPlaylist.parseMaster(text, 'https://cdn.example.com/');
      expect(variants.length, 1);
      expect(variants[0].url, 'https://cdn.example.com/mid.m3u8');
    });
  });

  group('HlsPlaylist.parseMedia', () {
    test('AES-128 KEY 带 IV，两个分片都带该 key，iv 字节正确', () {
      const text = '#EXTM3U\n#EXT-X-VERSION:3\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="/key.bin",IV=0x000102030405060708090a0b0c0d0e0f\n'
          '#EXTINF:10.0,\nseg0.ts\n'
          '#EXTINF:10.0,\nseg1.ts\n'
          '#EXT-X-ENDLIST\n';
      final pl =
          HlsPlaylist.parseMedia(text, 'https://cdn.example.com/v/');
      expect(pl.segments.length, 2);
      expect(pl.segments[0].key, isNotNull);
      expect(pl.segments[0].key!.method, 'AES-128');
      expect(pl.segments[0].key!.uri, 'https://cdn.example.com/key.bin');
      expect(pl.segments[0].key!.iv,
          [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
      expect(pl.segments[1].key!.uri, 'https://cdn.example.com/key.bin');
      expect(pl.segments[0].url, 'https://cdn.example.com/v/seg0.ts');
      expect(pl.isLive, isFalse);
    });

    test('无 KEY 时 key 为 null；METHOD=NONE 的 KEY 也解析', () {
      const text = '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=NONE\n'
          '#EXTINF:10.0,\nseg0.ts\n'
          '#EXTINF:10.0,\nseg1.ts\n';
      final pl = HlsPlaylist.parseMedia(text, 'https://cdn.example.com/');
      expect(pl.segments[0].key, isNotNull);
      expect(pl.segments[0].key!.method, 'NONE');

      const plain = '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n#EXT-X-ENDLIST\n';
      final pl2 = HlsPlaylist.parseMedia(plain, 'https://cdn.example.com/');
      expect(pl2.segments[0].key, isNull);
      expect(pl2.isLive, isFalse);
    });

    test('BYTERANGE：n@o 与缺省 offset（续接上一分片末尾）', () {
      const text = '#EXTM3U\n'
          '#EXT-X-BYTERANGE:1000@0\n'
          '#EXTINF:10.0,\nfile.ts\n'
          '#EXT-X-BYTERANGE:500\n'
          '#EXTINF:10.0,\nfile.ts\n'
          '#EXT-X-BYTERANGE:200@5000\n'
          '#EXTINF:10.0,\nfile.ts\n'
          '#EXT-X-ENDLIST\n';
      final pl = HlsPlaylist.parseMedia(text, 'https://cdn.example.com/');
      expect(pl.segments.length, 3);
      expect(pl.segments[0].byteRangeLength, 1000);
      expect(pl.segments[0].byteRangeOffset, 0);
      expect(pl.segments[1].byteRangeLength, 500);
      expect(pl.segments[1].byteRangeOffset, 1000);
      expect(pl.segments[2].byteRangeLength, 200);
      expect(pl.segments[2].byteRangeOffset, 5000);
    });

    test('EXT-X-MAP、直播判定、mediaSequence 起始', () {
      const text = '#EXTM3U\n#EXT-X-VERSION:6\n'
          '#EXT-X-MEDIA-SEQUENCE:42\n'
          '#EXT-X-MAP:URI="init.mp4"\n'
          '#EXTINF:10.0,\nseg42.m4s\n'
          '#EXTINF:10.0,\nseg43.m4s\n';
      final pl = HlsPlaylist.parseMedia(text, 'https://cdn.example.com/v/');
      expect(pl.mapUri, 'https://cdn.example.com/v/init.mp4');
      expect(pl.isLive, isTrue);
      expect(pl.mediaSequence, 42);
      expect(pl.segments[0].sequence, 42);
      expect(pl.segments[1].sequence, 43);
      expect(pl.totalDuration, 20.0);
    });
  });

  group('HlsPlaylist.pickVariant', () {
    test('返回 bandwidth 最大的；空表返回 null', () {
      const vs = [
        HlsVariant(bandwidth: 500000, resolution: '640x360', codecs: '', url: 'a'),
        HlsVariant(bandwidth: 2000000, resolution: '1280x720', codecs: '', url: 'b'),
        HlsVariant(bandwidth: 800000, resolution: '854x480', codecs: '', url: 'c'),
      ];
      expect(HlsPlaylist.pickVariant(vs)?.url, 'b');
      expect(HlsPlaylist.pickVariant(const []), isNull);
    });
  });
}
