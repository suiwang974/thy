import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:taohuayuan/main.dart';
import 'package:taohuayuan/services/store.dart';

/// 启动验证：App 能起来、底部五栏出现。
/// 只断言 HomeShell 的底部栏（立刻渲染），不依赖首页的网络加载
/// （homeFeed 可能慢/失败），所以不用 pumpAndSettle。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('桃花源启动：底部五栏出现', (tester) async {
    final store = await Store.load();
    await tester.pumpWidget(TaohuayuanApp(store: store));

    // 等底部栏出现，最多等 30 秒（不要求首页网络加载完成）。
    var found = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('我的').evaluate().isNotEmpty) {
        found = true;
        break;
      }
    }
    expect(found, isTrue, reason: '底部栏未出现，App 未正常启动');

    expect(find.text('推荐'), findsWidgets);
    expect(find.text('短视频'), findsWidgets);
    expect(find.text('搜索'), findsWidgets);
    expect(find.text('追番'), findsWidgets);
    expect(find.text('我的'), findsWidgets);
  });
}
