import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/ui/download_button.dart';
import 'package:taohuayuan/ui/widgets.dart';

/// 实测 VideoCard 里下载按钮渲染出来的尺寸与位置（2026-11-09 真机截图：
/// 按钮看着是封面中间一个大圆圈；代码写的是左下角 18px 小图标——
/// 实测是 IconButton 默认最小点按目标 48×48，constraints 压不小。
/// 第 30 条修法：tapTargetSize shrinkWrap + 16px + 移到封面右下角，
/// 时长 chip 让位到左下角。本测试断言修好后的尺寸与位置）。
void main() {
  testWidgets('VideoCard download button size and position', (tester) async {
    const item = VideoItem(
      id: 'xvideos-1',
      title: 'test video',
      source: 'xvideos',
      poster: '',
      durationSec: 600,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: VideoCard(item: item, onTap: _noop),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final buttonBox =
        tester.getRect(find.byType(DownloadButton));
    final posterBox = tester.getRect(find.byType(PosterThumb));
    final iconBox = tester.getRect(find.byIcon(Icons.download));
    // ignore: avoid_print
    print('BUTTON rect=$buttonBox poster=$posterBox icon=$iconBox');
    // ignore: avoid_print
    print('BUTTON w=${buttonBox.width} h=${buttonBox.height} '
        'posterW=${posterBox.width} posterH=${posterBox.height} '
        'ratioW=${buttonBox.width / posterBox.width} '
        'right=${posterBox.right - buttonBox.right} '
        'bottom=${posterBox.bottom - buttonBox.bottom} '
        'centerY=${(buttonBox.center.dy - posterBox.top) / posterBox.height}');
    // 断言：按钮必须是右下角小图标（宽 <= 28px，贴在右下角，不挡画面）。
    expect(buttonBox.width, lessThanOrEqualTo(28));
    expect(buttonBox.height, lessThanOrEqualTo(28));
    expect(posterBox.right - buttonBox.right, lessThan(10));
    expect(posterBox.bottom - buttonBox.bottom, lessThan(10));
    // 时长 chip 让位到左下角（不在右下角跟按钮打架）。
    // Text 本身的左缘 = 容器 left:6 + 内边距 6 = 12。
    final chip = tester.getRect(find.text('10:00'));
    expect(chip.left - posterBox.left, lessThan(16));
    expect(posterBox.bottom - chip.bottom, lessThan(10));
  });
}

void _noop() {}
