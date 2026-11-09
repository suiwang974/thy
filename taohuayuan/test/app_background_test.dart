import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taohuayuan/services/store.dart';
import 'package:taohuayuan/ui/app_background.dart';
import 'package:taohuayuan/ui/browser_sources_screen.dart';
import 'package:taohuayuan/ui/profile_screen.dart';

void main() {
  testWidgets('第 61 条：背景图 + 暗色遮罩都画出来', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AppBackground(child: Text('内容')),
    ));
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, AppBackground.asset);
    expect(image.fit, BoxFit.cover);
    // 遮罩：黑色半透明容器，盖在图上、内容下。
    final dim = tester.widget<Container>(find.byWidgetPredicate((w) =>
        w is Container &&
        w.color == Colors.black.withValues(alpha: AppBackground.dimOpacity)));
    expect(dim, isNotNull);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('第 61 条：浏览器栏与“我的”页 Scaffold 透明，背景透得出来',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();

    await tester.pumpWidget(MaterialApp(
      home: BrowserSourcesScreen(store: store),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.transparent);

    await tester.pumpWidget(MaterialApp(
      home: ProfileScreen(store: store, onAuthorTap: (_) {}),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.transparent);
  });
}
