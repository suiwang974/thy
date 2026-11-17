import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/source/source_registry.dart';

/// 规则 JSON（assets/rules/*.json）与 Dart 绑定层（SourceRegistry）的一致性：
/// 两边是同一份绑定数据的两种形态，改一边忘另一边就报错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('10 份规则 JSON 都能读到、都解析成功', () async {
    for (final b in SourceRegistry.bindings) {
      final raw = await rootBundle.loadString('assets/rules/${b.id}.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      expect(data['id'], b.id, reason: b.id);
    }
  });

  test('规则 JSON 的 hosts/searchMode/mirrors/适配器与绑定层一致', () async {
    for (final b in SourceRegistry.bindings) {
      final raw = await rootBundle.loadString('assets/rules/${b.id}.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      expect(List<String>.from(data['hosts'] as List), b.hosts,
          reason: '${b.id} hosts');
      expect(data['searchMode'], b.searchMode.name, reason: '${b.id} searchMode');
      expect(List<String>.from(data['mirrors'] as List), b.mirrors,
          reason: '${b.id} mirrors');
      expect((data['adapterPath'] as List).length, 6, reason: '${b.id} 六路');
      expect((data['adapterPath'] as List).first, 'network',
          reason: '${b.id} 首路 network');
      expect(data['rollbackKey'], b.rollbackKey, reason: '${b.id} rollbackKey');
      expect(data['entryUrl'], b.entryUrl, reason: '${b.id} entryUrl');
    }
  });
}
