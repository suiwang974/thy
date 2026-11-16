import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/source/source_registry.dart';

void main() {
  setUp(() {
    SourceRegistry.resetAll();
  });

  test('10 个源都在', () {
    final ids = SourceRegistry.bindings.map((b) => b.id).toSet();
    expect(ids, {
      'xhamster',
      'eporner',
      'rule34videos',
      'xvideos',
      'pornhub',
      'spankbang',
      'hanime1',
      'hanimeone',
      'niacg',
      'lianzu11',
    });
  });

  test('按域名找绑定：精确与子域名都命中，未知返回 null', () {
    expect(SourceRegistry.bindingForHost('xhamster.com')?.id, 'xhamster');
    expect(SourceRegistry.bindingForHost('www.xhamster.com')?.id, 'xhamster');
    expect(SourceRegistry.bindingForHost('m.xhamster.com')?.id, 'xhamster');
    expect(SourceRegistry.bindingForHost('example.com'), isNull);
  });

  test('niacg/lianzu11/hanime1/hanimeone 是 sniffOnly', () {
    for (final id in ['niacg', 'lianzu11', 'hanime1', 'hanimeone']) {
      expect(SourceRegistry.bindingFor(id)?.searchMode, SearchMode.sniffOnly,
          reason: id);
    }
    expect(SourceRegistry.bindingFor('eporner')?.searchMode, SearchMode.http);
    expect(SourceRegistry.bindingFor('xhamster')?.searchMode, SearchMode.both);
  });

  test('hanime1 与 hanimeone 互为镜像', () {
    expect(SourceRegistry.bindingFor('hanime1')?.mirrors, ['hanimeone.me']);
    expect(SourceRegistry.bindingFor('hanimeone')?.mirrors, ['hanime1.me']);
  });

  test('xhamster 适配器顺序以 network 开头，六路全开', () {
    final b = SourceRegistry.bindingFor('xhamster')!;
    expect(b.adapterPath.first, AdapterKind.network);
    expect(b.adapterPath.length, 6);
    expect(b.activeAdapters.length, 6);
  });

  test('disable 整源下线，enable 恢复', () {
    SourceRegistry.disable('xhamster');
    expect(SourceRegistry.bindingFor('xhamster')?.enabled, isFalse);
    expect(SourceRegistry.bindingFor('eporner')?.enabled, isTrue);
    SourceRegistry.enable('xhamster');
    expect(SourceRegistry.bindingFor('xhamster')?.enabled, isTrue);
  });

  test('disableAdapter 只关一路，其余不受影响', () {
    SourceRegistry.disableAdapter('xhamster', AdapterKind.blobMse);
    final b = SourceRegistry.bindingFor('xhamster')!;
    expect(b.enabled, isTrue);
    expect(b.activeAdapters.contains(AdapterKind.blobMse), isFalse);
    expect(b.activeAdapters.length, 5);
    SourceRegistry.enableAdapter('xhamster', AdapterKind.blobMse);
    expect(
        SourceRegistry.bindingFor('xhamster')!.activeAdapters.length, 6);
  });

  test('未知 id 的 disable/disableAdapter 不抛错、不影响其他源', () {
    SourceRegistry.disable('no-such-source');
    SourceRegistry.disableAdapter('no-such-source', AdapterKind.network);
    expect(SourceRegistry.bindingFor('xhamster')?.enabled, isTrue);
  });
}
