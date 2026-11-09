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
}
