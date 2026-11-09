import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:taohuayuan/services/app_update.dart';

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
    final okBody = jsonEncode({
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
    });
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

  test('第 50 条：同版 APK 已下完直接复用，不重复下载（不走网络）', () async {
    final dir = await Directory.systemTemp.createTemp('app_update_test_');
    try {
      final info = AppUpdateInfo(
        remoteCode: 11,
        tag: 'taohuayuan-v11',
        name: '桃花源 v11',
        downloadUrl: 'https://example.com/a.apk',
        sizeBytes: 100,
        notes: '',
      );
      final target = File('${dir.path}/taohuayuan-v11.apk');
      await target.writeAsBytes(List.filled(100, 0));
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
}
