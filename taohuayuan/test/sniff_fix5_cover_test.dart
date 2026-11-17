import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:taohuayuan/models/video_item.dart';
import 'package:taohuayuan/services/downloader.dart';
import 'package:taohuayuan/ui/widgets.dart';

/// 第 5 轮真机反馈修复的测试：封面本地化（2026-11-17）。
/// 海报存本地用假的图片下载函数注入（不真联网）；应用文档目录用
/// path_provider 的方法通道 mock 指向系统临时目录。
void main() {
  const png1x1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  late Directory docs;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docs = await Directory.systemTemp.createTemp('cover-docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docs.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await docs.delete(recursive: true);
  });

  http.Response fakeImage(int status, {String contentType = 'image/png'}) {
    return http.Response.bytes(base64Decode(png1x1), status,
        headers: {'content-type': contentType});
  }

  group('savePosterLocally：海报图存成本地文件', () {
    test('200 + image：写盘成功，返回本地路径，字节一致', () async {
      final path = await DownloadManager.savePosterLocally(
        taskId: 'sniff-123',
        posterUrl: 'https://ei.phncdn.com/videos/202303/10/427144391/poster.jpg',
        referer: 'https://cn.pornhub.com/',
        fetchImage: (_, _) async => fakeImage(200),
      );
      expect(path, isNotNull);
      expect(path, startsWith(docs.path));
      expect(path, endsWith('.jpg'));
      final file = File(path!);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), base64Decode(png1x1));
    });

    test('data: 占位图、404、非图片一律返回 null', () async {
      expect(
          await DownloadManager.savePosterLocally(
            taskId: 't1',
            posterUrl: 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
            fetchImage: (_, _) async => fakeImage(200),
          ),
          isNull);
      expect(
          await DownloadManager.savePosterLocally(
            taskId: 't2',
            posterUrl: 'https://example.com/missing.jpg',
            fetchImage: (_, _) async => fakeImage(404),
          ),
          isNull);
      expect(
          await DownloadManager.savePosterLocally(
            taskId: 't3',
            posterUrl: 'https://example.com/page.html',
            fetchImage: (_, _) async =>
                fakeImage(200, contentType: 'text/html'),
          ),
          isNull);
      expect(
          await DownloadManager.savePosterLocally(
            taskId: 't4',
            posterUrl: '',
            fetchImage: (_, _) async => fakeImage(200),
          ),
          isNull);
    });

    test('请求头里带 Referer（假下载函数收到什么就记什么）', () async {
      Map<String, String>? seen;
      await DownloadManager.savePosterLocally(
        taskId: 't5',
        posterUrl: 'https://example.com/p.jpg',
        referer: 'https://www.xvideos.com/video/1',
        fetchImage: (uri, headers) async {
          seen = headers;
          return fakeImage(200);
        },
      );
      expect(seen?['Referer'], 'https://www.xvideos.com/video/1');
      expect(seen?['User-Agent'], contains('Chrome'));
    });
  });

  group('PosterThumb：本地文件分支', () {
    test('posterKind：分支判定是纯函数（不解码图片）', () {
      expect(PosterThumb.posterKind('assets/covers/a.jpg'), 'asset');
      expect(PosterThumb.posterKind('https://ei.phncdn.com/x.jpg'), 'http');
      expect(PosterThumb.posterKind('/data/user/0/app/posters/t1.jpg'), 'file');
      expect(PosterThumb.posterKind(''), 'none');
      expect(PosterThumb.posterKind('data:image/gif;base64,AAAA'), 'none');
    });

    testWidgets('本地文件不存在：回占位图标，不崩', (tester) async {
      const item = VideoItem(
        id: 'v1',
        title: '视频标题',
        source: 'web',
        poster: '/tmp/does-not-exist-taohuayuan-cover.jpg',
        durationSec: 30,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PosterThumb(item: item, height: 54)),
        ),
      );
      // 文件不存在的错误是 dart:io 真异步回调（假时钟看不到它），
      // 先在 runAsync 里等真实时间让错误送达，再 pump 一帧渲染占位。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    });
  });

  group('DownloadTask.poster：本地路径持久化 round-trip', () {
    test('poster 是本地路径 + 已转 mp4：toJson/fromJson 一圈回来还在', () {
      final t = DownloadTask(
        id: 't1',
        title: '视频',
        source: 'xvideos',
        poster: '${docs.path}/posters/sniff-123.jpg',
        durationSec: 710,
        kind: DownloadKind.hls,
      );
      t.remuxedToMp4 = true;
      final back = DownloadTask.fromJson(t.toJson());
      expect(back.poster, '${docs.path}/posters/sniff-123.jpg');
      expect(back.remuxedToMp4, isTrue);
      // poster 字段可变：下载完成后抽帧能把它指到本地缩略图。
      back.poster = '${docs.path}/posters/thumb.jpg';
      expect(back.poster, endsWith('thumb.jpg'));
    });
  });
}
