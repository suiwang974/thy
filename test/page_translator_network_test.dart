import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:taohuayuan/services/page_translator.dart';

const String successResponseBody =
    '[[["你好","Hello",null,null,10]],null,"en",null,null,null,null,[]]';

void main() {
  group('translateOne 重试与失败', () {
    test('前面 5 个失败后走 gtx 成功', () async {
      var calls = 0;
      final mock = MockClient((http.Request request) async {
        calls++;
        if (request.url.queryParameters['client'] == 'gtx') {
          return http.Response(successResponseBody, 200, headers: const {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response('error', 500);
      });

      final result = await PageTranslator.translateOne('Hello', client: mock);

      expect(result, '你好');
      expect(calls, 6);
    });

    test('全部失败抛异常', () async {
      final mock = MockClient((http.Request request) async {
        return http.Response('error', 500);
      });

      expect(
        () => PageTranslator.translateOne('Hello', client: mock),
        throwsA(isA<PageTranslationException>()),
      );
    });
  });

  group('translateTexts 批量', () {
    test('去重后逐条翻，重复文本只翻一次', () async {
      var calls = 0;
      final mock = MockClient((http.Request request) async {
        calls++;
        if (request.url.host == 'index-translate.bilibili.com') {
          return http.Response(
            '{"choices":[{"message":{"role":"assistant","content":"你好"}}]}',
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(successResponseBody, 200, headers: const {'content-type': 'application/json; charset=utf-8'});
      });

      final result = await PageTranslator.translateTexts(
        ['Hello', 'Hi', 'Hello'],
        client: mock,
      );

      expect(result.length, 2);
      expect(calls, 2);
    });

    test('空输入直接返回空列表，不发请求', () async {
      var calls = 0;
      final mock = MockClient((http.Request request) async {
        calls++;
        return http.Response(successResponseBody, 200, headers: const {'content-type': 'application/json; charset=utf-8'});
      });

      final result = await PageTranslator.translateTexts([], client: mock);

      expect(result, isEmpty);
      expect(calls, 0);
    });

    test('中途失败整体抛异常，不返回半截结果', () async {
      final mock = MockClient((http.Request request) async {
        if (request.url.queryParameters['q'] == 'Hi') {
          return http.Response('error', 500);
        }
        return http.Response(successResponseBody, 200, headers: const {'content-type': 'application/json; charset=utf-8'});
      });

      expect(
        () => PageTranslator.translateTexts(['Hello', 'Hi'], client: mock),
        throwsA(isA<PageTranslationException>()),
      );
    });
  });

  group('TranslationAttemptTracker', () {
    test('成功、失败、清除的状态流转', () {
      final tracker = TranslationAttemptTracker();
      const url = 'https://xhamster.com/';

      expect(tracker.shouldAttempt(url), isTrue);

      tracker.markDone(url);
      expect(tracker.shouldAttempt(url), isFalse);

      tracker.clear(url);
      expect(tracker.shouldAttempt(url), isTrue);

      tracker.markFailed(url);
      expect(tracker.shouldAttempt(url), isFalse);

      tracker.markDone(url);
      expect(tracker.shouldAttempt(url), isFalse);

      tracker.clear(url);
      tracker.markFailed(url);
      tracker.clearAll();
      expect(tracker.shouldAttempt(url), isTrue);
    });
  });

  group('collectJs 与 applyJs', () {
    test('collectJs 包含定位标记与 JSON 返回', () {
      expect(PageTranslator.collectJs, contains('data-pt-parent'));
      expect(PageTranslator.collectJs, contains('JSON.stringify'));
    });

    test('applyJs 生成的脚本包含译文映射与定位', () {
      final js = PageTranslator.applyJs({'pt-1-0': '你好'});

      expect(js, contains('"pt-1-0"'));
      expect(js, contains('你好'));
      expect(js, contains('data-pt-parent'));
    });
  });
}
