// 会话级回滚策略单测。
import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/source/source_registry.dart';
import 'package:taohuayuan/source/source_session_policy.dart';

void main() {
  setUp(SourceRegistry.resetAll);
  tearDown(SourceRegistry.resetAll);

  group('sniffEnabledFor', () {
    test('未知站默认能嗅探', () {
      expect(sniffEnabledFor(null), isTrue);
    });

    test('绑定的源默认能嗅探', () {
      expect(
        sniffEnabledFor(SourceRegistry.bindingFor('xhamster')),
        isTrue,
      );
    });

    test('整源下线后不能嗅探，恢复后又能', () {
      SourceRegistry.disable('xhamster');
      expect(
        sniffEnabledFor(SourceRegistry.bindingFor('xhamster')),
        isFalse,
      );
      SourceRegistry.enable('xhamster');
      expect(
        sniffEnabledFor(SourceRegistry.bindingFor('xhamster')),
        isTrue,
      );
    });

    test('只关一路适配器不影响整源嗅探', () {
      SourceRegistry.disableAdapter('xhamster', AdapterKind.blobMse);
      expect(
        sniffEnabledFor(SourceRegistry.bindingFor('xhamster')),
        isTrue,
      );
    });
  });

  group('activeAdaptersFor', () {
    test('未知站默认全开六路', () {
      expect(activeAdaptersFor(null), AdapterKind.values);
    });

    test('绑定的源默认全开六路', () {
      expect(
        activeAdaptersFor(SourceRegistry.bindingFor('xhamster')),
        AdapterKind.values,
      );
    });

    test('关掉的一路不在启用列表里，其余都在', () {
      SourceRegistry.disableAdapter('xhamster', AdapterKind.blobMse);
      final active = activeAdaptersFor(
        SourceRegistry.bindingFor('xhamster'),
      );
      expect(active, isNot(contains(AdapterKind.blobMse)));
      expect(active.length, AdapterKind.values.length - 1);
      expect(active.first, AdapterKind.network);
    });

    test('整源下线不影响适配器列表（下线由 sniffEnabledFor 管）', () {
      SourceRegistry.disable('xhamster');
      expect(
        activeAdaptersFor(SourceRegistry.bindingFor('xhamster')),
        AdapterKind.values,
      );
    });
  });
}
