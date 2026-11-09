import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/store.dart';
import 'package:taohuayuan/ui/profile_screen.dart';

void main() {
  testWidgets('第 59 条：切走再切回“我的”，刚点的喜欢要出现、取消要消失',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    final item = VideoItem(
        id: 'v-like-1', title: '喜欢的测试片', source: 'eporner', durationSec: 300);

    var index = 0;
    late StateSetter setTab;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        setTab = setState;
        return Scaffold(
          body: IndexedStack(index: index, children: [
            const Center(child: Text('推荐页')),
            ProfileScreen(store: store, onAuthorTap: (_) {}),
          ]),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: index,
            onTap: (i) => setState(() => index = i),
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.home), label: '推荐'),
              BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
            ],
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();

    // 在“推荐页”时点喜欢（模拟播放页点 ♥：数据已存上）。
    await store.toggleLike(item);
    expect(store.likedItems().length, 1);

    // 切到“我的”：旧快照会显示“还没点过喜欢”。ListView 是懒加载，
    // 先滑到“我喜欢的”那一区再断言。
    setTab(() => index = 1);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('我喜欢的'), 600);
    await tester.pumpAndSettle();
    // 标题在卡片里出现（卡片标题 + 详情行可能各有一份，至少出现即算显示）。
    expect(find.text('喜欢的测试片'), findsWidgets);
    expect(find.text('还没点过喜欢'), findsNothing);

    // 再取消喜欢，切走切回后应消失。
    await store.toggleLike(item);
    setTab(() => index = 0);
    await tester.pumpAndSettle();
    setTab(() => index = 1);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('我喜欢的'), 600);
    await tester.pumpAndSettle();
    expect(find.text('喜欢的测试片'), findsNothing);
    expect(find.text('还没点过喜欢'), findsOneWidget);
  });

  testWidgets('第 60 条：口味标签列出来，喜欢/不喜欢/搜过的词都在',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    await store.recordSearchTerm('足');
    await store.addLikedTag('cosplay');
    await store.dislikeTag('femdom');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ProfileScreen(store: store, onAuthorTap: (_) {})),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('我的口味'), 600);
    await tester.pumpAndSettle();

    expect(find.text('cosplay'), findsOneWidget);
    expect(find.text('femdom'), findsOneWidget);
    expect(find.text('足'), findsOneWidget);
    // 不再是只有统计句 + 全清按钮。
    expect(find.text('＋ 添加标签'), findsOneWidget);
  });

  testWidgets('第 60 条：点 × 删掉一个不喜欢的标签，立刻消失',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.load();
    await store.dislikeTag('femdom');
    await store.dislikeTag('asian');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ProfileScreen(store: store, onAuthorTap: (_) {})),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('我的口味'), 600);
    await tester.pumpAndSettle();
    expect(find.text('femdom'), findsOneWidget);

    // 点 femdom 芯片上的 ×（InputChip 的 deleteIcon）。
    final chip = find.ancestor(
        of: find.text('femdom'), matching: find.byType(InputChip));
    expect(chip, findsOneWidget);
    await tester.tap(find.descendant(
        of: chip, matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();

    expect(find.text('femdom'), findsNothing);
    expect(find.text('asian'), findsOneWidget);
    expect(store.dislikedTags.contains('femdom'), isFalse);
  });
}
