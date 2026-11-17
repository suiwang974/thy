// 页内翻译：直接在当前页面里把可见文字翻成中文，不经过整页代理。
//
// 之前用 translate.goog 代理整页抓取，XHamster 这类站直接返回
// "Can't translate this page"，Bing 代理也失败，还会死循环重翻。
// 这里改成：收集页面可见文本节点 -> 调免费翻译接口逐条翻 -> 按 id 写回 DOM。
// 接口是 Google 的免费翻译接口（无需 key），一次请求只翻一条；
// 同一页里相同的文本只翻一次；失败就整体抛异常，调用方不写回、不假装成功。
// 翻译失败的地址由 TranslationAttemptTracker 记下来，不再自动重翻，
// 只有用户手动点翻译按钮才重试。

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 页面翻译过程中抛出的异常。
///
/// 用来统一包装接口返回异常、网络异常、解析失败等情况，
/// 便于调用方用一个 catch 兜住所有翻译相关错误。
class PageTranslationException implements Exception {
  /// 错误描述信息。
  final String message;

  /// 创建一个翻译异常。
  const PageTranslationException(this.message);

  @override
  String toString() => 'PageTranslationException: $message';
}

/// 翻译尝试记录器（纯 Dart，无外部依赖）。
///
/// 用于记录某个页面 URL 是否已经翻译成功过、是否已经失败过，
/// 从而避免重复发起翻译请求（尤其是失败后的无意义重试）。
class TranslationAttemptTracker {
  /// 已成功处理过的 URL 集合。
  final Set<String> _done = {};

  /// 已失败过的 URL 集合。
  final Set<String> _failed = {};

  /// 判断该 URL 是否还需要尝试翻译。
  ///
  /// 只要没成功过、也没失败过就返回 true，否则返回 false。
  bool shouldAttempt(String url) {
    return !_done.contains(url) && !_failed.contains(url);
  }

  /// 标记该 URL 已成功处理。
  ///
  /// 成功后会把它从失败集合里移除，避免状态互相矛盾。
  void markDone(String url) {
    _done.add(url);
    _failed.remove(url);
  }

  /// 标记该 URL 已失败。
  void markFailed(String url) {
    _failed.add(url);
  }

  /// 清除该 URL 的全部记录，使其可以重新被尝试。
  void clear(String url) {
    _done.remove(url);
    _failed.remove(url);
  }

  /// 清空所有记录。
  void clearAll() {
    _done.clear();
    _failed.clear();
  }
}

/// 页面文本翻译工具类。
///
/// 所有成员都是静态的，不需要实例化；内部通过 Google 翻译的
/// 公开免费接口逐条翻译文本，并提供结果解析与批量翻译能力。
class PageTranslator {
  /// 目标语言：简体中文。
  static const String targetLang = 'zh-CN';

  /// 单次翻译允许的最大节点数。
  static const int maxNodes = 80;

  /// 单条文本允许的最大字符数。
  static const int maxCharsPerText = 200;

  /// 单次翻译允许的最大总字符数。
  static const int maxTotalChars = 12000;

  /// 相邻两次请求之间的间隔，避免触发限流。
  static const Duration requestGap = Duration(milliseconds: 120);

  /// 私有构造，禁止外部实例化。
  PageTranslator._();

  /// 解析翻译接口返回的 JSON 文本，拼出完整译文。
  ///
  /// 成功时返回形如：
  /// `[[["你好","Hello",null,null,10]],null,"en",null,null,null,null,[]]`
  /// 的返回体中，把所有分段里的第 0 个元素（译文片段）拼接后返回。
  ///
  /// 出现以下情况会抛出 [PageTranslationException]：
  /// 返回体是 HTML（通常意味着被限流）、不是合法 JSON、结构不符合预期。
  static String parseTranslateResponse(String body) {
    final String trimmed = body.trim();

    // 接口返回 HTML 基本说明请求被拦截或限流了。
    if (trimmed.toLowerCase().startsWith('<html')) {
      throw const PageTranslationException('接口返回了 HTML，很可能被限流');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      throw const PageTranslationException('翻译接口返回的不是合法 JSON');
    }

    if (decoded is! List) {
      throw const PageTranslationException('翻译接口返回的 JSON 顶层不是列表');
    }
    if (decoded.isEmpty) {
      throw const PageTranslationException('翻译接口返回的 JSON 列表为空');
    }

    final Object? segments = decoded[0];
    if (segments is! List) {
      throw const PageTranslationException('翻译接口返回的分段数据不是列表');
    }

    final StringBuffer buffer = StringBuffer();
    for (final Object? segment in segments) {
      if (segment is! List) {
        throw const PageTranslationException('翻译接口返回的分段项不是列表');
      }
      if (segment.isEmpty) {
        throw const PageTranslationException('翻译接口返回的分段项为空');
      }
      final Object? piece = segment[0];
      if (piece is! String) {
        throw const PageTranslationException('翻译接口返回的分段译文不是字符串');
      }
      buffer.write(piece);
    }

    return buffer.toString();
  }

  /// 解析 Bilibili 翻译接口（OpenAI 兼容 chat completions）返回的 JSON。
  ///
  /// 成功时取 choices[0].message.content，trim 后返回。
  /// 返回体异常（HTML、非 JSON、结构不对、译文为空）时抛 [PageTranslationException]。
  static String parseBilibiliResponse(String body) {
    final String trimmed = body.trim();

    if (trimmed.toLowerCase().startsWith('<html')) {
      throw const PageTranslationException('接口返回了 HTML，很可能被限流');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      throw const PageTranslationException('翻译接口返回的不是合法 JSON');
    }

    if (decoded is! Map) {
      throw const PageTranslationException('Bilibili 接口返回的 JSON 顶层不是对象');
    }
    final Object? choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const PageTranslationException('Bilibili 接口返回的 choices 为空');
    }
    final Object? first = choices[0];
    if (first is! Map) {
      throw const PageTranslationException('Bilibili 接口返回的 choice 不是对象');
    }
    final Object? message = first['message'];
    if (message is! Map) {
      throw const PageTranslationException('Bilibili 接口返回的 message 不是对象');
    }
    final Object? content = message['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const PageTranslationException('Bilibili 接口返回的译文为空');
    }
    return content.trim();
  }

  /// 解析爱词霸翻译接口返回的 JSON。
  ///
  /// 成功时取 data[0].out，trim 后返回；code 不是 1、data 为空、
  /// out 为空时抛 [PageTranslationException]。
  static String parseIcibaResponse(String body) {
    final String trimmed = body.trim();

    if (trimmed.toLowerCase().startsWith('<html')) {
      throw const PageTranslationException('接口返回了 HTML，很可能被限流');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      throw const PageTranslationException('翻译接口返回的不是合法 JSON');
    }

    if (decoded is! Map) {
      throw const PageTranslationException('爱词霸接口返回的 JSON 顶层不是对象');
    }
    if (decoded['code'] != 1) {
      throw const PageTranslationException('爱词霸接口返回了错误码');
    }
    final Object? data = decoded['data'];
    if (data is! List || data.isEmpty) {
      throw const PageTranslationException('爱词霸接口返回的 data 为空');
    }
    final Object? first = data[0];
    if (first is! Map) {
      throw const PageTranslationException('爱词霸接口返回的 data 项不是对象');
    }
    final Object? out = first['out'];
    if (out is! String || out.trim().isEmpty) {
      throw const PageTranslationException('爱词霸接口返回的译文为空');
    }
    return out.trim();
  }

  /// 解析彩云小译接口返回的 JSON。
  ///
  /// 成功时取 target[0]，trim 后返回；结构不对或译文为空时
  /// 抛 [PageTranslationException]。
  static String parseCaiyunResponse(String body) {
    final String trimmed = body.trim();

    if (trimmed.toLowerCase().startsWith('<html')) {
      throw const PageTranslationException('接口返回了 HTML，很可能被限流');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      throw const PageTranslationException('翻译接口返回的不是合法 JSON');
    }

    if (decoded is! Map) {
      throw const PageTranslationException('彩云接口返回的 JSON 顶层不是对象');
    }
    final Object? target = decoded['target'];
    if (target is! List || target.isEmpty) {
      throw const PageTranslationException('彩云接口返回的 target 为空');
    }
    final Object? first = target[0];
    if (first is! String || first.trim().isEmpty) {
      throw const PageTranslationException('彩云接口返回的译文为空');
    }
    return first.trim();
  }

  /// 解析 Yandex 翻译接口返回的 JSON。
  ///
  /// 成功时取 text[0]，trim 后返回；结构不对或译文为空时
  /// 抛 [PageTranslationException]。
  static String parseYandexResponse(String body) {
    final String trimmed = body.trim();

    if (trimmed.toLowerCase().startsWith('<html')) {
      throw const PageTranslationException('接口返回了 HTML，很可能被限流');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      throw const PageTranslationException('翻译接口返回的不是合法 JSON');
    }

    if (decoded is! Map) {
      throw const PageTranslationException('Yandex 接口返回的 JSON 顶层不是对象');
    }
    final Object? text = decoded['text'];
    if (text is! List || text.isEmpty) {
      throw const PageTranslationException('Yandex 接口返回的 text 为空');
    }
    final Object? first = text[0];
    if (first is! String || first.trim().isEmpty) {
      throw const PageTranslationException('Yandex 接口返回的译文为空');
    }
    return first.trim();
  }

  /// 翻译单条文本并返回译文。
  ///
  /// 按顺序尝试 6 个免费接口，成功一个立即返回：
  /// 1. Google（dict-chrome-ex）；2. Bilibili 翻译；3. Google（gtx）；
  /// 4. 爱词霸；5. 彩云小译；6. Yandex。
  /// 某个接口失败（网络异常、超时、状态码非 200、解析失败）就换下一个；
  /// 6 个全失败则抛出 [PageTranslationException]。
  ///
  /// 传入 [client] 时复用该客户端且不会关闭它；未传入时内部新建一个，
  /// 用完自动关闭。
  static Future<String> translateOne(String text, {http.Client? client}) async {
    final http.Client httpClient = client ?? http.Client();
    final bool ownsClient = client == null;

    try {
      final List<Future<String> Function()> attempts =
          <Future<String> Function()>[
        () => _requestOnce(httpClient, text, 'dict-chrome-ex'),
        () => _requestBilibili(httpClient, text),
        () => _requestOnce(httpClient, text, 'gtx'),
        () => _requestIciba(httpClient, text),
        () => _requestCaiyun(httpClient, text),
        () => _requestYandex(httpClient, text),
      ];
      for (final Future<String> Function() attempt in attempts) {
        try {
          return await attempt();
        } on PageTranslationException {
          // 这个接口失败，换下一个继续试。
          continue;
        }
      }
      throw const PageTranslationException('全部翻译接口都失败了');
    } finally {
      if (ownsClient) {
        httpClient.close();
      }
    }
  }

  /// 批量翻译多条文本。
  ///
  /// 先按首次出现顺序去重，再逐条调用 [translateOne]，
  /// 每条之间等待 [requestGap]，避免请求过于密集。
  /// 返回结果与去重后的输入一一对应；任意一条失败则整体抛出异常。
  /// 输入为空时直接返回空列表，不发起任何请求。
  static Future<List<String>> translateTexts(
    List<String> texts, {
    http.Client? client,
  }) async {
    if (texts.isEmpty) {
      return <String>[];
    }

    // 去重并保持首次出现的顺序。
    final List<String> uniqueTexts = <String>[];
    final Set<String> seen = <String>{};
    for (final String text in texts) {
      if (seen.add(text)) {
        uniqueTexts.add(text);
      }
    }

    final http.Client httpClient = client ?? http.Client();
    final bool ownsClient = client == null;
    final List<String> results = <String>[];

    try {
      for (int i = 0; i < uniqueTexts.length; i++) {
        if (i > 0) {
          await Future<void>.delayed(requestGap);
        }
        results.add(await translateOne(uniqueTexts[i], client: httpClient));
      }
    } finally {
      if (ownsClient) {
        httpClient.close();
      }
    }

    return results;
  }

  /// 发起一次翻译请求并解析结果（内部使用）。
  ///
  /// [clientParam] 用于切换 `client` 查询参数（`dict-chrome-ex` / `gtx`）。
  /// 任何失败都会被包装成 [PageTranslationException]。
  static Future<String> _requestOnce(
    http.Client client,
    String text,
    String clientParam,
  ) async {
    final Uri uri = Uri.parse(
      'https://translate.google.com/translate_a/single'
      '?client=$clientParam&sl=auto&tl=$targetLang&dt=t'
      '&q=${Uri.encodeQueryComponent(text)}',
    );

    http.Response response;
    try {
      response = await client.get(
        uri,
        headers: const <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
              'Chrome/120.0 Mobile Safari/537.36',
        },
      ).timeout(const Duration(seconds: 10));
    } catch (error) {
      throw PageTranslationException('请求翻译接口失败：$error');
    }

    if (response.statusCode != 200) {
      throw PageTranslationException('翻译接口返回状态码 ${response.statusCode}');
    }

    // 统一按 UTF-8 解码，避免响应头缺失导致中文乱码。
    final String body;
    try {
      body = utf8.decode(response.bodyBytes);
    } catch (error) {
      throw PageTranslationException('翻译接口响应解码失败：$error');
    }

    return parseTranslateResponse(body);
  }

  /// 发起一次 POST 翻译请求并解析结果（内部使用）。
  ///
  /// [parser] 用于解析响应体。任何失败都会被包装成 [PageTranslationException]。
  static Future<String> _postOnce(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
    String body,
    String Function(String) parser,
  ) async {
    http.Response response;
    try {
      response = await client
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      throw PageTranslationException('请求翻译接口失败：$error');
    }

    if (response.statusCode != 200) {
      throw PageTranslationException('翻译接口返回状态码 ${response.statusCode}');
    }

    final String decodedBody;
    try {
      decodedBody = utf8.decode(response.bodyBytes);
    } catch (error) {
      throw PageTranslationException('翻译接口响应解码失败：$error');
    }

    return parser(decodedBody);
  }

  /// 调 Bilibili 翻译接口（OpenAI 兼容 chat completions）翻一条（内部使用）。
  static Future<String> _requestBilibili(
    http.Client client,
    String text,
  ) {
    final Uri uri = Uri.parse(
      'https://index-translate.bilibili.com/v1/chat/completions',
    );
    final String body = jsonEncode(<String, Object>{
      'model': 'Index-Translate-35B-A3B',
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content': '你是一名专业的译者，把下面的英文原文翻译成简体中文。'
              '要求：自然流畅，避免直译腔；只输出译文，不加解释、不加引号。',
        },
        <String, String>{'role': 'user', 'content': text},
      ],
      'temperature': 0,
    });
    return _postOnce(
      client,
      uri,
      const <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer index',
      },
      body,
      parseBilibiliResponse,
    );
  }

  /// 调爱词霸翻译接口翻一条（内部使用）。
  ///
  /// 签名是 MD5（路径 + client + key + 时间戳毫秒 + 固定 salt），
  /// 格式照爱词霸网页版的请求方式。
  static Future<String> _requestIciba(http.Client client, String text) {
    final String timestamp =
        DateTime.now().millisecondsSinceEpoch.toString();
    final String signature = md5
        .convert(
          utf8.encode(
            '/dictionary/fy/batch'
            '6'
            '1000006'
            '$timestamp'
            '7ece94d9f9c202b0d2ec557dg4r9bc',
          ),
        )
        .toString();
    final Uri uri = Uri.parse(
      'https://dictionary.iciba.com/dictionary/fy/batch'
      '?client=6&key=1000006&timestamp=$timestamp&signature=$signature',
    );
    final String body = jsonEncode(<String, Object>{
      'from': 'en',
      'to': 'zh',
      'textList': <String>[text],
    });
    return _postOnce(
      client,
      uri,
      const <String, String>{
        'Content-Type': 'application/json',
        'Origin': 'https://www.iciba.com',
        'Referer': 'https://www.iciba.com/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
      body,
      parseIcibaResponse,
    );
  }

  /// 调彩云小译接口翻一条（内部使用）。
  static Future<String> _requestCaiyun(http.Client client, String text) {
    final math.Random random = math.Random();
    final String requestId = List<String>.generate(
      10,
      (_) => random.nextInt(10).toString(),
    ).join();
    final Uri uri = Uri.parse(
      'https://api.interpreter.caiyunai.com/v1/translator',
    );
    final String body = jsonEncode(<String, Object>{
      'source': <String>[text],
      'trans_type': 'en2zh',
      'request_id': requestId,
      'detect': true,
    });
    return _postOnce(
      client,
      uri,
      const <String, String>{
        'Content-Type': 'application/json',
        'x-authorization': 'token 3975l6lr5pcbvidl6jl2',
      },
      body,
      parseCaiyunResponse,
    );
  }

  /// 调 Yandex 翻译接口翻一条（内部使用）。
  ///
  /// ucid 是随机生成的 32 位十六进制串，格式照 Yandex 安卓客户端
  /// 的请求方式。
  static Future<String> _requestYandex(http.Client client, String text) {
    const String hexDigits = '0123456789abcdef';
    final math.Random random = math.Random();
    final String ucid = List<String>.generate(
      32,
      (_) => hexDigits[random.nextInt(hexDigits.length)],
    ).join();
    final Uri uri = Uri.parse(
      'https://translate.yandex.net/api/v1/tr.json/translate'
      '?ucid=$ucid&srv=android&format=text',
    );
    final String body =
        'text=${Uri.encodeQueryComponent(text)}&lang=en-zh';
    return _postOnce(
      client,
      uri,
      const <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'ru.yandex.translate/3.20.2024',
      },
      body,
      parseYandexResponse,
    );
  }

  static const String collectJs = r'''(function(){var out=[],total=0,map=new Map(),seq=0,skip={SCRIPT:1,STYLE:1,NOSCRIPT:1,TEXTAREA:1,INPUT:1,SELECT:1,OPTION:1,BUTTON:1};if(!document.body)return '[]';var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT),n;while((n=w.nextNode())){var t=n.nodeValue;if(!t)continue;t=t.trim();if(!t||t.length>200||!/[A-Za-z]/.test(t))continue;var el=n.parentElement,bad=false,p;for(p=el;p;p=p.parentElement){if(skip[p.tagName]){bad=true;break;}}if(bad)continue;if(el!==document.body&&el!==document.documentElement&&el.offsetParent===null)continue;if(el.getClientRects().length===0)continue;var cs=getComputedStyle(el);if(cs.visibility==='hidden'||cs.display==='none')continue;var idx=map.get(el);if(idx===undefined){idx=++seq;map.set(el,idx);el.setAttribute('data-pt-parent','p-'+idx);}var ci=Array.prototype.indexOf.call(el.childNodes,n);out.push({id:'pt-'+idx+'-'+ci,text:t});total+=t.length;if(out.length>=80||total>12000)break;}return JSON.stringify(out);})()''';

  static String applyJs(Map<String, String> translations) {
    final j = jsonEncode(translations);
    // 注意：这里用插值拼 j（运行时数据，里面的 $ 不会再被解析），
    // 后面的 JS 片段用相邻字符串拼接，不动里面的单引号转义。
    return 'var t=$j;for(var k in t){var a=k.split("-");'
        'var p=document.querySelector(\'[data-pt-parent="p-\'+a[1]+\'"]\');'
        'if(!p)continue;var n=p.childNodes[+a[2]];'
        'if(!n||n.nodeType!==3)continue;n.nodeValue=t[k];}';
  }
}
