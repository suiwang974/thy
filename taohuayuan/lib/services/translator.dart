/// 内置浏览器翻译（第 35 条）：默认把页面翻成中文给用户看。
///
/// 用 Google 的 translate.goog 代理（VM 探针 2026-11-09：translate.goog 200
/// 可达，代理页含 google.translate.TranslateService JS；翻译是客户端 JS
/// 在 WebView 里跑的，curl 拿不到中文是正常的——VM 下只能验代理页能加载，
/// JS 翻译本身要靠手机 WebView 实跑）。
/// 映射：https://www.pornhub.com/view_video.php?viewkey=x
///   -> https://www-pornhub-com.translate.goog/view_video.php?viewkey=x
///      &_x_tr_sl=auto&_x_tr_tl=zh-CN&_x_tr_hl=zh-CN&_x_tr_pto=wapp
/// （host 的点换成横线 + .translate.goog 后缀）。
/// 不翻译的：localhost/IP 地址、已经是 translate.goog 的页、非 http(s)。
/// 加载失败自动回落原文（WebSourceBrowser 里做）。
/// 上限如实说：用户手机在中国，Google 能否通取决于他的 VPN（他本来就在
/// 手机上看这些被墙的站，说明有可用代理路径）；若不通，App 自动回落原文，
/// 不假装可用。
class Translator {
  static const targetLang = 'zh-CN';

  /// 这条地址能不能翻（http(s) 域名站才翻）。
  static bool isTranslatableUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    if (u.scheme != 'http' && u.scheme != 'https') return false;
    final host = u.host;
    if (host.isEmpty) return false;
    if (host == 'localhost' || host == '127.0.0.1') return false;
    if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) return false; // IP 不翻
    if (isTranslatedUrl(url)) return false;
    if (isBingTranslatedUrl(url)) return false; // 第 39 条：Bing 翻译页也是翻译页，别再拿 Google 翻它
    return true;
  }

  /// 已经是 translate.goog 的翻译页。
  static bool isTranslatedUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.endsWith('.translate.goog');
  }

  /// 原文地址 -> 翻译代理地址。
  static String toTranslatedUrl(String url, {String target = targetLang}) {
    final u = Uri.tryParse(url);
    if (u == null || !isTranslatableUrl(url)) return url;
    final host = '${u.host.replaceAll('.', '-')}.translate.goog';
    final query = <String, String>{
      ...u.queryParameters,
      '_x_tr_sl': 'auto',
      '_x_tr_tl': target,
      '_x_tr_hl': target,
      '_x_tr_pto': 'wapp',
    };
    return u.replace(host: host, queryParameters: query).toString();
  }

  /// Bing 翻译代理（第 39 条：Google translate.goog 在用户手机网络下不通时
  /// 的备选；Bing 国内一般能直接打开。VM 下探不到——沙盒网络连不上
  /// microsofttranslator.com，手机实跑为准）。
  static String toBingTranslatedUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null || !isTranslatableUrl(url)) return url;
    return 'https://www.microsofttranslator.com/bv.aspx?ref=SERP&br=ro&mkt=zh-CN&dl=zh&lp=EN_ZH-CHS&a=${Uri.encodeComponent(url)}';
  }

  /// 已经是 Bing 翻译页。
  static bool isBingTranslatedUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'www.microsofttranslator.com';
  }

  /// 翻译失败页的特征（第 39 条的根因）：Google 的 "Can't translate this page"
  /// 是 HTTP 200 正常页，不触发 onWebResourceError，所以只靠报错回落永远等不到，
  /// 用户直接看到英文错误页。必须加载完看内容判断，不通就换 Bing、再不行回原文。
  static bool isTranslationFailurePage(String title, String bodyText) {
    final t = '$title $bodyText'.toLowerCase();
    return t.contains("can't translate this page") ||
        t.contains('cannot translate this page') ||
        t.contains('translation failed') ||
        t.contains('无法翻译此页');
  }

  /// 翻译页地址 -> 原文地址（翻不回去就返回原串）。
  static String originalUrlFromTranslated(String url) {
    final u = Uri.tryParse(url);
    if (u == null || !isTranslatedUrl(url)) return url;
    final host = u.host.replaceAll('.translate.goog', '').replaceAll('-', '.');
    final query = Map<String, String>.from(u.queryParameters)
      ..removeWhere((k, _) => k.startsWith('_x_tr_'));
    return u.replace(host: host, queryParameters: query.isEmpty ? null : query).toString();
  }
}
