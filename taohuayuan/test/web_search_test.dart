import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/web_search.dart';

void main() {
  test('第 41 条：验证页特征识别', () {
    expect(WebSearchRunner.isChallengeHtml('<title>Just a moment...</title>'), isTrue);
    expect(WebSearchRunner.isChallengeHtml('<div>Attention Required! | Cloudflare</div>'), isTrue);
    expect(WebSearchRunner.isChallengeHtml('<html><body><a href="/showinfo-21-1-0.html">video</a></body></html>'), isFalse);
    expect(WebSearchRunner.isChallengeHtml(''), isFalse);
  });
}
