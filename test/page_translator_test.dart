import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:taohuayuan/services/page_translator.dart';

const String successResponseBody =
    '[[["你好","Hello",null,null,10]],null,"en",null,null,null,null,[]]';

void main() {
  group('parseTranslateResponse 成功', () {
    test('单个分段返回对应译文', () {
      expect(
        PageTranslator.parseTranslateResponse(
          '[[["你好","Hello",null,null,10]],null,"en",null,null,null,null,[]]',
        ),
        '你好',
      );
    });

    test('多个分段拼接成完整译文', () {
      expect(
        PageTranslator.parseTranslateResponse(
          '[[["早上","Good ",null,null,10],["好","morning",null,null,10]],null,"en",null,null,null,null,[]]',
        ),
        '早上好',
      );
    });

    test('空字符串译文返回空字符串', () {
      expect(
        PageTranslator.parseTranslateResponse(
          '[[["","",null,null,10]],null,"en",null,null,null,null,[]]',
        ),
        '',
      );
    });
  });

  group('parseTranslateResponse 失败', () {
    test('HTML 错误页面抛异常', () {
      expect(
        () => PageTranslator.parseTranslateResponse(
          '<html><head><title>Sorry...</title></head></html>',
        ),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('非 JSON 文本抛异常', () {
      expect(
        () => PageTranslator.parseTranslateResponse('not json'),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('空数组抛异常', () {
      expect(
        () => PageTranslator.parseTranslateResponse('[]'),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('空对象抛异常', () {
      expect(
        () => PageTranslator.parseTranslateResponse('{}'),
        throwsA(isA<PageTranslationException>()),
      );
    });

    test('分段元素不是字符串抛异常', () {
      expect(
        () => PageTranslator.parseTranslateResponse('[[[null,"x"]]]'),
        throwsA(isA<PageTranslationException>()),
      );
    });
  });

  group('translateOne 网络请求', () {
    test('一次请求成功返回译文', () async {
      final mock = MockClient((http.Request request) async {
        return http.Response(successResponseBody, 200, headers: const {'content-type': 'application/json; charset=utf-8'});
      });

      final result = await PageTranslator.translateOne('Hello', client: mock);

      expect(result, '你好');
    });
  });
}
