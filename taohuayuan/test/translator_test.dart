import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/translator.dart';

void main() {
  test('第 39 条：Bing 翻译地址（Google 备选）', () {
    final url = Translator.toBingTranslatedUrl('https://hanimeone.me/search?query=foot');
    expect(url, startsWith('https://www.microsofttranslator.com/bv.aspx?'));
    expect(url, contains(Uri.encodeComponent('https://hanimeone.me/search?query=foot')));
  });

  test('第 39 条：翻译失败页靠内容判断（HTTP 200 的英文错误页）', () {
    expect(Translator.isTranslationFailurePage("Can't translate this page", ''), isTrue);
    expect(Translator.isTranslationFailurePage('HanimeOne', "Can't translate this page"), isTrue);
    expect(Translator.isTranslationFailurePage('Google Translate', 'Some video title here'), isFalse);
    expect(Translator.isTranslationFailurePage('HanimeOne', 'video list here'), isFalse);
  });

  test('第 39 条：Bing 翻译页不再被当成可翻译页（别拿 Google 再翻它）', () {
    expect(Translator.isTranslatableUrl('https://www.microsofttranslator.com/bv.aspx?a=x'), isFalse);
    expect(Translator.isTranslatableUrl('https://hanimeone.me/'), isTrue);
  });
}
