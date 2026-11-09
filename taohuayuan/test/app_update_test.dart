import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:taohuayuan/services/app_update.dart';

import 'zip_fixture.dart';

void main() {
  test('第 50 条：tag 里解析发布号，只有 taohuayuan-v<数字> 才认', () {
    expect(AppUpdateService.parseReleaseCode('taohuayuan-v10'), 10);
    expect(AppUpdateService.parseReleaseCode('taohuayuan-v11'), 11);
    expect(AppUpdateService.parseReleaseCode('taohuayuan-v2.9.0'), isNull);
    expect(AppUpdateService.parseReleaseCode('v2.9.0'), isNull);
    expect(AppUpdateService.parseReleaseCode('taohuayuan-v'), isNull);
    expect(AppUpdateService.parseReleaseCode(''), isNull);
    expect(AppUpdateService.parseReleaseCode(' taohuayuan-v12 '), 12);
  });

  test('第 50 条：releases/latest 的 JSON 里挑 APK 附件', () {
    final json = {
      'tag_name': 'taohuayuan-v11',
      'name': '桃花源 v11（重写版）',
      'body': '修了搜索计数',
      'published_at': '2026-11-09T08:00:00Z',
      'assets': [
        {
          'name': 'taohuayuan-android-arm64-v2.9.0.apk',
          'size': 21553447,
          'browser_download_url':
              'https://github.com/suiwang974/thy/releases/download/taohuayuan-v11/taohuayuan-android-arm64-v2.9.0.apk',
        },
        {
          'name': 'checksums.txt',
          'size': 100,
          'browser_download_url': 'https://example.com/checksums.txt',
        },
      ],
    };
    final info = AppUpdateService.parseLatestRelease(json);
    expect(info, isNotNull);
    expect(info!.remoteCode, 11);
    expect(info.tag, 'taohuayuan-v11');
    expect(info.downloadUrl, contains('taohuayuan-v11'));
    expect(info.sizeBytes, 21553447);
    expect(info.notes, '修了搜索计数');
  });

  test('第 50 条：没有 APK 附件、老固定 tag，都不认作新版', () {
    expect(
      AppUpdateService.parseLatestRelease({
        'tag_name': 'taohuayuan-v11',
        'assets': [
          {'name': 'source.zip', 'browser_download_url': 'https://example.com/x.zip'}
        ],
      }),
      isNull,
    );
    expect(
      AppUpdateService.parseLatestRelease({
        'tag_name': 'taohuayuan-v2.9.0',
        'assets': [
          {
            'name': 'taohuayuan-android-arm64-v2.9.0.apk',
            'size': 21553447,
            'browser_download_url': 'https://example.com/a.apk',
          }
        ],
      }),
      isNull,
    );
    expect(AppUpdateService.parseLatestRelease({}), isNull);
  });

  test('第 50 条：只有远端发布号比本机大才算有新版', () {
    AppUpdateInfo info(int code) => AppUpdateInfo(
          remoteCode: code,
          tag: 'taohuayuan-v$code',
          name: '桃花源 v$code',
          downloadUrl: 'https://example.com/a.apk',
          sizeBytes: 100,
          notes: '',
        );
    expect(AppUpdateService.isNewer(info(11), 10), isTrue);
    expect(AppUpdateService.isNewer(info(10), 10), isFalse);
    expect(AppUpdateService.isNewer(info(9), 10), isFalse);
  });

  test('第 50 条：大小格式化不编数字', () {
    expect(AppUpdateService.formatSize(21553447), '20.6 MB');
    expect(AppUpdateService.formatSize(1536), '1.5 KB');
    expect(AppUpdateService.formatSize(512), '512 B');
    expect(AppUpdateService.formatSize(0), '未知大小');
    expect(AppUpdateService.formatSize(-1), '未知大小');
  });

  test('第 50 条：分段数跟视频下载同一套数', () {
    expect(AppUpdateService.computeParts(5 * 1024 * 1024), 1); // 8MB 以下不分段
    expect(AppUpdateService.computeParts(21 * 1024 * 1024), 8); // 21MB：10 段封顶 8
    expect(AppUpdateService.computeParts(8 * 1024 * 1024), 4);
  });

  test('第 50 条：checkLatest——200 正常、404/500/坏 JSON 都返回 null（检查失败，不是“没新版”）',
      () async {
    final okBody = jsonEncode([
      {
        'tag_name': 'taohuayuan-v11',
        'name': '桃花源 v11',
        'body': 'notes',
        'published_at': '2026-11-09T08:00:00Z',
        'assets': [
          {
            'name': 'taohuayuan-android-arm64-v2.9.0.apk',
            'size': 21553447,
            'browser_download_url': 'https://example.com/a.apk',
          }
        ],
      }
    ]);
    Future<http.Client> clientFor(http.Response res) async =>
        MockClient((_) async => res);

    // Response 默认按 Latin-1 编 body，中文会炸：用 bytes + utf-8 头。
    var c = await clientFor(http.Response.bytes(
      utf8.encode(okBody),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ));
    var info = await AppUpdateService.instance.checkLatest(client: c);
    expect(info?.remoteCode, 11);

    c = await clientFor(http.Response('Not Found', 404));
    expect(await AppUpdateService.instance.checkLatest(client: c), isNull);

    c = await clientFor(http.Response('error', 500));
    expect(await AppUpdateService.instance.checkLatest(client: c), isNull);

    c = await clientFor(http.Response('not json', 200));
    expect(await AppUpdateService.instance.checkLatest(client: c), isNull);
  });

  test('第 50 条：checkLatest——列表里 latest 是旧 tag 时，仍取发布号最大的那个（2026-11-09 实测回归）',
      () async {
    // 实测：v10 release 的 created_at（11-08）比旧固定 tag 的 release（11-09）
    // 还早，releases/latest 指向旧 tag；列表里两个都在，取最大的 v10。
    final body = jsonEncode([
      {
        'tag_name': 'taohuayuan-v2.9.0',
        'name': '桃花源 v2.9.0（重写版）',
        'body': 'old',
        'published_at': '2026-11-08T14:57:50Z',
        'assets': [
          {
            'name': 'taohuayuan-android-arm64-v2.9.0.apk',
            'size': 21685103,
            'browser_download_url': 'https://example.com/old.apk',
          }
        ],
      },
      {
        'tag_name': 'taohuayuan-v10',
        'name': '桃花源 v10（重写版）',
        'body': 'new',
        'published_at': '2026-11-09T08:29:51Z',
        'assets': [
          {
            'name': 'taohuayuan-android-arm64-v2.9.0.apk',
            'size': 21685103,
            'browser_download_url': 'https://example.com/v10.apk',
          }
        ],
      },
      {
        'tag_name': 'v2.9.0',
        'name': 'v2.9.0',
        'body': 'shell',
        'published_at': '2026-11-08T05:04:14Z',
        'assets': [],
      },
    ]);
    final c = MockClient((_) async => http.Response.bytes(
          utf8.encode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
    final info = await AppUpdateService.instance.checkLatest(client: c);
    expect(info?.remoteCode, 10);
    expect(info?.downloadUrl, 'https://example.com/v10.apk');
  });

  test('第 50 条：同版 APK 已下完且验过 ZIP 直接复用，不重复下载（不走网络）', () async {
    final dir = await Directory.systemTemp.createTemp('app_update_test_');
    try {
      // 第 57 条：复用前先验 ZIP——100 字节 0 文件不再是“已下完”，
      // 必须是真 ZIP 才复用。
      final zip = buildTestZip(
        storedName: 'a.txt',
        storedData: Uint8List.fromList('ok'.codeUnits),
        deflatedName: 'b.txt',
        deflatedData: Uint8List.fromList(List<int>.generate(200, (i) => i)),
      );
      final info = AppUpdateInfo(
        remoteCode: 11,
        tag: 'taohuayuan-v11',
        name: '桃花源 v11',
        downloadUrl: 'https://example.com/a.apk',
        sizeBytes: zip.length,
        notes: '',
      );
      final target = File('${dir.path}/taohuayuan-v11.apk');
      await target.writeAsBytes(zip);
      final path = await AppUpdateService.instance.downloadApk(
        info,
        downloadDir: dir,
        isCancelled: () => false,
      );
      expect(path, target.path);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('第 57 条：缓存里大小对但内容坏的包不复用——downloadApk 会重下，'
      '下不到就报错，不许把坏包当好包返回', () async {
    final dir = await Directory.systemTemp.createTemp('app_update_test_');
    try {
      final zip = buildTestZip(
        storedName: 'a.txt',
        storedData: Uint8List.fromList('ok'.codeUnits),
        deflatedName: 'b.txt',
        deflatedData: Uint8List.fromList(List<int>.generate(200, (i) => i)),
      );
      final info = AppUpdateInfo(
        remoteCode: 11,
        tag: 'taohuayuan-v11',
        name: '桃花源 v11',
        // 指向不存在的地址：坏缓存必须触发重下，重下失败要报错，
        // 绝不能悄悄返回坏包。
        downloadUrl: 'https://127.0.0.1:1/a.apk',
        sizeBytes: zip.length,
        notes: '',
      );
      final target = File('${dir.path}/taohuayuan-v11.apk');
      final bad = Uint8List.fromList(zip);
      bad.fillRange(35, 41, 0); // 大小对、CRC 对不上（v11 真机坏包的样子）
      await target.writeAsBytes(bad);
      await expectLater(
        () => AppUpdateService.instance.downloadApk(
          info,
          downloadDir: dir,
          isCancelled: () => false,
        ),
        throwsA(anything),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
