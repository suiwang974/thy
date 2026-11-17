// ignore_for_file: unnecessary_string_escapes
// 上面这行是故意的：mediaDefinitions fixture 是真页原文，里面全是 JSON
// 转义的 \/，lint 会逐条报不必要的转义，但删掉反斜杠 fixture 就不是真页了。
import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/sniffer.dart';

/// 第 5 轮补充：Pornhub 预览/广告短片过滤（2026-11-17）。
/// 用户实证：下成功的 Pornhub 4.8MB 是 pre_videos 预览片（21 秒，带广告字），
/// 不是正片。嗅探器把预览当正片收了。
void main() {
  const preVideos =
      'https://evtubescms.phncdn.com/pre_videos/003/003/832/3003832/mp4_720p.mp4';
  const normalMp4 = 'https://cdn.example.com/videos/12345/720p.mp4';

  group('isPreviewUrl / isExcludedUrl：路径段匹配，不错杀正片', () {
    test('pre_videos 路径段：预览，过滤', () {
      expect(Sniffer.isPreviewUrl(preVideos), isTrue);
      expect(Sniffer.isExcludedUrl(preVideos), isTrue);
    });

    test('preview/trailer 文件名：预览，过滤', () {
      expect(
          Sniffer.isPreviewUrl('https://cdn.example.com/x/preview_720p.mp4'),
          isTrue);
      expect(
          Sniffer.isPreviewUrl('https://cdn.example.com/x/preview.mp4'),
          isTrue);
      expect(
          Sniffer.isPreviewUrl('https://cdn.example.com/x/trailer_720p.mp4'),
          isTrue);
      expect(
          Sniffer.isPreviewUrl('https://cdn.example.com/x/trailer.mp4'),
          isTrue);
      expect(
          Sniffer.isPreviewUrl('https://cdn.example.com/x/video_preview.mp4'),
          isTrue);
    });

    test('路径段恰好叫 preview 的正片页：不排除', () {
      // /videos/preview/ 只是路由段，文件本身是正片 12345.mp4。
      expect(
          Sniffer.isPreviewUrl(
              'https://example.com/videos/preview/12345.mp4'),
          isFalse);
      expect(
          Sniffer.isExcludedUrl(
              'https://example.com/videos/preview/12345.mp4'),
          isFalse);
    });

    test('正常视频地址：不排除；旧的 thumb/广告域名规则还在', () {
      expect(Sniffer.isPreviewUrl(normalMp4), isFalse);
      expect(Sniffer.isExcludedUrl(normalMp4), isFalse);
      expect(
          Sniffer.isExcludedUrl(
              'https://cdn.example.com/thumbs/123.jpg'),
          isTrue);
      expect(
          Sniffer.isExcludedUrl(
              'https://doubleclick.net/ads/x.mp4'),
          isTrue);
    });
  });

  group('groupAndEnrich：预览候选到不了分组', () {
    test('pre_videos + 正片同在：只剩正片', () async {
      final items = await Sniffer.groupAndEnrich(
        candidates: [preVideos, normalMp4],
        pageUrl: 'https://example.com/v/1',
        fetchText: (_) async => throw StateError('no fetch'),
        probeHead: (_) async => null,
      );
      expect(items.length, 1);
      expect(items.first.url, normalMp4);
    });

    test('只有 pre_videos：分组结果为空（不过滤后偷偷放回来）', () async {
      final items = await Sniffer.groupAndEnrich(
        candidates: [preVideos],
        pageUrl: 'https://example.com/v/1',
        fetchText: (_) async => throw StateError('no fetch'),
        probeHead: (_) async => null,
      );
      expect(items, isEmpty);
    });
  });

  group('unescapeHtmlUrls：JSON 转义地址还原', () {
    test(r'\/ 与 \u002F 都还原成 /', () {
      const escaped =
          r'"videoUrl":"https:\/\/hv-h.phncdn.com\/hls\/videos\/x\/master.m3u8"';
      final clean = Sniffer.unescapeHtmlUrls(escaped);
      expect(clean, contains('https://hv-h.phncdn.com/hls/videos/x/master.m3u8'));
      expect(clean, isNot(contains(r'\/')));
      expect(
          Sniffer.unescapeHtmlUrls(r'https:\u002F\u002Fcdn.example.com\u002Fa.mp4'),
          'https://cdn.example.com/a.mp4');
    });
  });

  group('pornhubMainCandidates：mediaDefinitions 提出正片 HLS', () {
    // fixture 是真页原文：2026-11-17 从 cn.pornhub.com 真视频页
    // （viewkey=640bb26f797aa，200，1,624,004 字节）上抠下来的
    // mediaDefinitions 数组原文（5 条：1080/720/480/240 四档 HLS +
    // 1 条 get_media 接口地址），一字未改。
    const html = '''"mediaDefinitions":[{"group":1,"height":1080,"width":1920,"defaultQuality":false,"format":"hls","videoUrl":"https:\/\/hv-h.phncdn.com\/hls\/videos\/202303\/10\/427144391\/1080P_4000K_427144391.mp4\/master.m3u8?h=EMe1f7zAPhc2DuEzOKhTi0CeHN4%3D&e=1794899558&f=1","quality":"1080","segmentFormats":{"audio":"ts_aac","video":"mpeg2_ts"}},{"group":1,"height":240,"width":426,"defaultQuality":false,"format":"hls","videoUrl":"https:\/\/hv-h.phncdn.com\/hls\/videos\/202303\/10\/427144391\/240P_1000K_427144391.mp4\/master.m3u8?h=InWBIVm5H%2BNLTi8RbVuIWEUNQ9I%3D&e=1794899558&f=1","quality":"240","segmentFormats":{"audio":"ts_aac","video":"mpeg2_ts"}},{"group":1,"height":480,"width":854,"defaultQuality":false,"format":"hls","videoUrl":"https:\/\/hv-h.phncdn.com\/hls\/videos\/202303\/10\/427144391\/480P_2000K_427144391.mp4\/master.m3u8?h=H%2BiuvVmcXbxHrT3wm1jdNBKpNFQ%3D&e=1794899558&f=1","quality":"480","segmentFormats":{"audio":"ts_aac","video":"mpeg2_ts"}},{"group":1,"height":720,"width":1280,"defaultQuality":true,"format":"hls","videoUrl":"https:\/\/hv-h.phncdn.com\/hls\/videos\/202303\/10\/427144391\/720P_4000K_427144391.mp4\/master.m3u8?h=qVVEJVWs1ZDKa03KyfnCVB%2FJkNI%3D&e=1794899558&f=1","quality":"720","segmentFormats":{"audio":"ts_aac","video":"mpeg2_ts"}},{"group":1,"height":2160,"width":3840,"defaultQuality":false,"format":"mp4","videoUrl":"https:\/\/cn.pornhub.com\/video\/get_media?s=eyJrIjoiNDIxNTc1MTQ0MzUzOTljZmJkY2MyOWJjOTg2ZWQyMWEwMWJhNGM0NDUzM2NjOTY5ZjI2ZTU3NmYxYzY2YzQwMyIsInQiOjE3OTQ4OTU5NTh9&v=640bb26f797aa&e=0&t=p","quality":[],"remote":true}],"other":1''';
    test('4 档 HLS master 都提出来，get_media 接口地址不要', () {
      final urls = Sniffer.pornhubMainCandidates(html);
      expect(urls.length, 4);
      for (final u in urls) {
        expect(u, contains('hv-h.phncdn.com'));
        expect(u, contains('.m3u8')); // 带 ?h=...&e=... 签名查询串，不以 .m3u8 结尾
        expect(u, isNot(contains(r'\/')));
      }
      expect(urls.any((u) => u.contains('1080P')), isTrue);
      expect(urls.any((u) => u.contains('720P')), isTrue);
      expect(urls.any((u) => u.contains('get_media')), isFalse);
    });

    test('没有 mediaDefinitions：返回空，不抛错', () {
      expect(Sniffer.pornhubMainCandidates('<html>no video here</html>'),
          isEmpty);
    });
  });

  group('SniffDiagnosis：过滤后零候选要诚实', () {
    test('只剩预览时诊断写明“只有预览短片，没找到正片”', () {
      const d = SniffDiagnosis(previewFilteredCount: 2);
      expect(d.text, contains('只嗅到预览短片'));
      expect(d.text, contains('没找到正片'));
      expect(d.text, contains('2'));
    });

    test('没过滤预览时诊断还是老文案', () {
      const d = SniffDiagnosis();
      expect(d.text, isNot(contains('预览短片')));
    });
  });
}
