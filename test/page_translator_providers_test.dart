import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:taohuayuan/services/page_translator.dart';

void main() {
  group('parseBilibiliResponse', () {
    test('成功返回 choices 里 message 的 content', () {
      expect(
        PageTranslator.parseBilibiliResponse(
          '{"id":"x","choices":[{"message":{"role":"assistant","content":"你好"}}]}',
        ),
        '你好',
      );
    });

    test('content 带空白时 trim 后返回', () {
      expect(
        PageTranslator.parseBilibiliResponse(
          '{"choices":[{"message":{"content":"  你好  "}}]}',
        ),
        '你好',
      );
    });

    test('choices 为空抛异常', () {
      expect(
        () => PageTranslator.parseBilibiliResponse('{"choices":[]}'),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('content 为空抛异常', () {
      expect(
        () => PageTranslator.parseBilibiliResponse(
          '{"choices":[{"message":{"content":"  "}}]}',
        ),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('非 JSON 抛异常', () {
      expect(
        () => PageTranslator.parseBilibiliResponse('not json'),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('错误体抛异常', () {
      expect(
        () => PageTranslator.parseBilibiliResponse(
          '{"error":{"message":"bad key","type":"invalid"}}',
        ),
        throwsA(isA<PageTranslationException>()),
      );
    });
  });

  group('parseIcibaResponse', () {
    test('成功返回 data 里 out', () {
      expect(
        PageTranslator.parseIcibaResponse(
          '{"code":1,"data":[{"out":"你好","from":"en","to":"zh"}]}',
        ),
        '你好',
      );
    });

    test('code 不是 1 抛异常', () {
      expect(
        () => PageTranslator.parseIcibaResponse(
          '{"code":0,"data":[{"out":"你好"}]}',
        ),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('data 为空抛异常', () {
      expect(
        () => PageTranslator.parseIcibaResponse('{"code":1,"data":[]}'),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('out 为空抛异常', () {
      expect(
        () => PageTranslator.parseIcibaResponse(
          '{"code":1,"data":[{"out":""}]}',
        ),
        throwsA(isA<PageTranslationException>()),
      );
    });
  });

  group('parseCaiyunResponse', () {
    test('成功返回 target 第一项', () {
      expect(
        PageTranslator.parseCaiyunResponse('{"target":["你好"]}'),
        '你好',
      );
    });

    test('target 缺失抛异常', () {
      expect(
        () => PageTranslator.parseCaiyunResponse('{}'),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('target 为空抛异常', () {
      expect(
        () => PageTranslator.parseCaiyunResponse('{"target":[]}'),
        throwsA(isA<PageTranslationException>()),
      );
    });
  });

  group('parseYandexResponse', () {
    test('成功返回 text 第一项', () {
      expect(
        PageTranslator.parseYandexResponse('{"code":200,"text":["你好"]}'),
        '你好',
      );
    });

    test('text 缺失抛异常', () {
      expect(
        () => PageTranslator.parseYandexResponse('{"code":200}'),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('text 为空抛异常', () {
      expect(
        () => PageTranslator.parseYandexResponse('{"code":200,"text":[]}'),
        throwsA(isA<PageTranslationException>()),
      );
    });
  });

  group('translateOne 兜底链', () {
    test('Google 与 Bilibili 失败后走 gtx 成功', () async {
      var calls = 0;
      final mock = MockClient((http.Request request) async {
        calls++;
        if (request.url.queryParameters['client'] == 'gtx') {
          return http.Response(
            '[[["你好","Hello",null,null,10]],null,"en",null,null,null,null,[]]',
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('error', 500);
      });

      final result = await PageTranslator.translateOne('Hello', client: mock);

      expect(result, '你好');
      expect(calls, 3);
    });

    test('Google 全失败后走 Bilibili 成功', () async {
      final mock = MockClient((http.Request request) async {
        if (request.url.host == 'index-translate.bilibili.com') {
          return http.Response(
            '{"choices":[{"message":{"role":"assistant","content":"你好"}}]}',
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('error', 500);
      });

      final result = await PageTranslator.translateOne('Hello', client: mock);

      expect(result, '你好');
    });

    test('前面都失败后走爱词霸成功', () async {
      final mock = MockClient((http.Request request) async {
        if (request.url.host == 'dictionary.iciba.com') {
          return http.Response(
            '{"code":1,"data":[{"out":"你好"}]}',
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('error', 500);
      });

      final result = await PageTranslator.translateOne('Hello', client: mock);

      expect(result, '你好');
    });

    test('前面都失败后走彩云成功', () async {
      final mock = MockClient((http.Request request) async {
        if (request.url.host == 'api.interpreter.caiyunai.com') {
          return http.Response(
            '{"target":["你好"]}',
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('error', 500);
      });

      final result = await PageTranslator.translateOne('Hello', client: mock);

      expect(result, '你好');
    });

    test('前面都失败后走 Yandex 成功', () async {
      final mock = MockClient((http.Request request) async {
        if (request.url.host == 'translate.yandex.net') {
          return http.Response(
            '{"code":200,"text":["你好"]}',
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('error', 500);
      });

      final result = await PageTranslator.translateOne('Hello', client: mock);

      expect(result, '你好');
    });

    test('6 个接口全失败抛异常', () async {
      final mock = MockClient((http.Request request) async {
        return http.Response('error', 500);
      });

      expect(
        () => PageTranslator.translateOne('Hello', client: mock),
        throwsA(isA<PageTranslationException>()),
      );
    });
  });
}
