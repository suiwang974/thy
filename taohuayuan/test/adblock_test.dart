import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/adblock_service.dart';

void main() {
  group('parseFilterText', () {
    const sample = '''
! comment
||ads.example.com^
||tracker.example.org^
||sub.ads.example.com^
@@||cdn.jwplayer.com^
||wildcard*.example.net^\$script
||with-domain.example.com^\$domain=other.com
##.ad-banner
xvideos.com##.site-ad
example.com##.other-ad
127.0.0.1 hosts.example.io
0.0.0.0 bad.example.co
''';
    test('网络规则 / 白名单 / 选择器 / hosts 行解析', () {
      final p = parseFilterText(sample);
      expect(p.hosts.contains('ads.example.com'), isTrue);
      expect(p.hosts.contains('tracker.example.org'), isTrue);
      expect(p.hosts.contains('sub.ads.example.com'), isTrue);
      // 通配符、带 domain= 限定的规则不要（种子生成脚本同一口径）
      expect(p.hosts.any((h) => h.contains('*')), isFalse);
      expect(p.hosts.contains('with-domain.example.com'), isFalse);
      // 白名单
      expect(p.allow.contains('cdn.jwplayer.com'), isTrue);
      // 选择器：通用规则收，站内规则只收 App 10 个源站的（别的站的不要，
      // 种子生成脚本同一口径）
      expect(p.cosmetic.contains('.ad-banner'), isTrue);
      expect(p.cosmetic.contains('.site-ad'), isTrue);
      expect(p.cosmetic.contains('.other-ad'), isFalse);
      // hosts 行
      expect(p.hosts.contains('hosts.example.io'), isTrue);
      expect(p.hosts.contains('bad.example.co'), isTrue);
    });
  });

  group('isBlockedHost / isBlockedUrl', () {
    late AdblockService svc;
    setUp(() {
      svc = AdblockService.instance;
      svc.loadFromParsed(
        hosts: {'ads.example.com', 'tracker.example.org', 'xvideos.com'},
        hotHosts: {'ads.example.com'},
        allowHosts: {'cdn.jwplayer.com'},
        cosmetic: ['.ad-banner'],
      );
    });

    test('命中域名与子域名', () {
      expect(svc.isBlockedHost('ads.example.com'), isTrue);
      expect(svc.isBlockedHost('sub.ads.example.com'), isTrue);
      expect(svc.isBlockedHost('notads.example.com'), isFalse);
      expect(svc.isBlockedHost('tracker.example.org'), isTrue);
    });

    test('白名单优先于拦截', () {
      expect(svc.isBlockedHost('cdn.jwplayer.com'), isFalse);
    });

    test('第一方豁免：站本身不拦', () {
      // xvideos.com 在 hosts 里（来自 ||xvideos.com^\$third-party 这类规则），
      // 但它是第一方时不拦；第三方广告域名照拦。
      expect(
        svc.isBlockedUrl('https://xvideos.com/video123',
            firstPartyHost: 'xvideos.com'),
        isFalse,
      );
      expect(
        svc.isBlockedUrl('https://ads.example.com/x.js',
            firstPartyHost: 'xvideos.com'),
        isTrue,
      );
    });
  });

  group('AdblockService.kFilterSources（用户 1DM 备份原样）', () {
    test('27 个源，22 个默认启用', () {
      expect(AdblockService.kFilterSources.length, 27);
      expect(AdblockService.kFilterSources.where((s) => s.$3).length, 22);
      final names = AdblockService.kFilterSources.map((s) => s.$1).toSet();
      expect(names.contains('EasyList'), isTrue);
      expect(names.contains('AdGuard Base filter'), isTrue);
      expect(names.contains('1DM filters'), isTrue);
      expect(
          names.contains("Peter Lowe's Ad and tracking server list"), isTrue);
      // 5 个未启用的源原样保留（备份里就是关着的）
      expect(names.contains('uBlock filters – Badware risks'), isTrue);
      expect(
        AdblockService.kFilterSources
            .firstWhere((s) => s.$1 == 'uBlock filters – Badware risks')
            .$3,
        isFalse,
      );
    });
  });

  test('injectionJs 包含 fetch/XHR 覆盖与选择器隐藏', () {
    final js = AdblockService.instance.injectionJs;
    expect(js.contains('window.fetch'), isTrue);
    expect(js.contains('XMLHttpRequest'), isTrue);
    expect(js.contains('MutationObserver'), isTrue);
    expect(js.contains('window.open'), isTrue);
  });
}
