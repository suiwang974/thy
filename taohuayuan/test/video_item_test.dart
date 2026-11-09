import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/models/video_item.dart';

void main() {
  test('乱码修复：UTF-8 字节被当 latin1 解的标题修回来', () {
    // ’ = UTF-8 E2 80 99，被当 latin1 解成 â + \u0080 + \u0099；
    // … = E2 80 A6，解成 â + \u0080 + ¦。
    expect(
      VideoItem.repairMojibake('Iâ\u0080\u0099m Getting In Shape For You, My Belovedâ\u0080¦'),
      "I’m Getting In Shape For You, My Beloved…",
    );
    // 没乱码的不动。
    expect(VideoItem.repairMojibake('milf footjob 4k ultra hd'), 'milf footjob 4k ultra hd');
    expect(VideoItem.repairMojibake('测试标题'), '测试标题');
    // 只有一个 â 但拼不成合法 UTF-8 的，不硬修。
    expect(VideoItem.repairMojibake('Ângela'), 'Ângela');
  });

  test('fromJson：缓存里存的旧乱码标题读出来就修掉', () {
    final item = VideoItem.fromJson({
      'id': 'eporner-tYHgyWTFB3A',
      'title': 'Iâ\u0080\u0099m Getting In Shape',
      'author': 'Someâ\u0080\u0099s Author',
      'source': 'eporner',
    });
    expect(item.title, "I’m Getting In Shape");
    expect(item.author, "Some’s Author");
  });

  test('embedUrl：eporner 走官方 embed 页，其他源用视频页', () {
    final ep = VideoItem(id: 'eporner-tYHgyWTFB3A', title: 't', source: 'eporner',
        pageUrl: 'https://www.eporner.com/video-tYHgyWTFB3A/');
    expect(ep.embedUrl, 'https://www.eporner.com/embed/tYHgyWTFB3A/');
    final r34 = VideoItem(id: 'r34-1', title: 't', source: 'rule34videos',
        pageUrl: 'https://rule34-videos.com/video/x/');
    expect(r34.embedUrl, 'https://rule34-videos.com/video/x/');
  });
}
