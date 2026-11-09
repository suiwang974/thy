import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置浏览器的广告拦截（第 26 条）。
///
/// 规则来源：用户 1DM 备份里的 27 个规则源（22 个启用、5 个未启用，
/// URL、名字、启用状态原样抄进来，见 [kFilterSources]）。种子规则
/// `assets/adblock-seed.json` 是 2026-11-09 从实拉的 EasyList、
/// AdGuard Base、1DM filters、Peter Lowe's 四个文件解析出来的
/// （68,888 个拦截域名 + 1,452 个高频域名 + 26 个播放器白名单域名 +
/// 1,632 条隐藏选择器），首次启动离线可用；联网后按源 URL 拉全量更新。
///
/// webview_flutter（4.14.1）的 Dart 层 WebViewClient
/// 只暴露 onPageStarted/onPageFinished/onReceivedHttpError/requestLoading/
/// urlLoading/onLoadResource 等回调，**没有 shouldInterceptRequest 的 Dart
/// 回调**（生成的 pigeon 代码里只有一个参数类，没有可接的回调口）。
/// 所以做不到 1DM 那种「每个子资源请求在发出前就拦掉」的原生拦截。
/// 能做的三层（不冒充原生拦截）：
/// ① Dart 层 NavigationDelegate 拦顶层跳转——弹窗/跳转到广告域名直接不让跳
/// （这些站最烦人的广告形式），用全量 hosts 判定；
/// ② JS 注入——fetch/XHR 发往广告域名的直接 abort、window.open 弹窗拦截、
/// 按 ## 选择器藏广告元素 + MutationObserver 跟踪后加载的广告，
/// JS 里只带 hotHosts（1,452 个多源交集域名，小，快）；
/// ③ App 自己的 HTTP 请求（搜索、解析）本来就不走 WebView、不带广告。
/// 首屏 HTML 里内嵌的广告子资源（图片/脚本）在 JS 注入前可能已经发出去了，
/// 拦不干净；想做到 1DM 同款要换 flutter_inappwebview（它暴露
/// shouldInterceptRequest）或写原生代码——那是下一步的大改，不在这次做。
///
/// 判定口径（跟 EasyList 的 $third-party 一个意思）：
/// - 第一方（当前页自己的域名及子域名）永远不拦——种子里甚至有
/// `||xvideos.com^$third-party` 这类规则，解析时已把 $third-party
/// 当成普通规则收进来，不加第一方豁免会把站本身拦掉；
/// - 白名单（1DM filters 的 @@ 播放器放行，如 jwplayer、challenges.cloudflare.com）
/// 优先于拦截；
/// - 其余按「域名及父域名后缀」匹配（`||ads.example.com^` 拦掉它全部子域名）。
class AdblockService {
AdblockService._();
static final AdblockService instance = AdblockService._();

static const _prefsLastUpdated = 'taohuayuan_adblock_updated';
static const _prefsEnabled = 'taohuayuan_adblock_enabled_sources';
static const _prefsDisabled = 'taohuayuan_adblock_disabled_sources';
static const _hostsFile = 'adblock-hosts.txt';
static const _autoUpdateInterval = Duration(days: 7);

/// 本 App 的 10 个源站域名：站内 cosmetic 规则只留这些站的；
/// 更新时解析也只收这些站的站内规则。
static const appHosts = {
'eporner.com',
'rule34video.com',
'xvideos.com',
'xhamster.com',
'pornhub.com',
'spankbang.com',
'niacg.com',
'lianzu11.com',
'hanime1.me',
'hanimeone.me',
};

/// 1DM 备份里的规则源（2026-11-09 备份原文：名字、URL、启用状态）。
/// 启用状态默认跟备份一致；用户可以在「我的」里开关。
static const kFilterSources = [
('1DM filters', 'https://www.apps2sd.info/idm/filters.txt', true),
('EasyList', 'https://easylist.to/easylist/easylist.txt', true),
('uBlock filters',
'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt', true),
('AdGuard Base filter',
'https://filters.adtidy.org/extension/ublock/filters/2_without_easylist.txt', true),
('EasyPrivacy', 'https://easylist.to/easylist/easyprivacy.txt', true),
("Peter Lowe's Ad and tracking server list",
'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext', true),
('AakList (Anti-Adblock Killer)',
'https://raw.githubusercontent.com/reek/anti-adblock-killer/master/anti-adblock-killer-filters.txt', true),
('Adblock Warning Removal List',
'https://easylist-downloads.adblockplus.org/antiadblockfilters.txt', true),
('uBlock filters – Unbreak',
'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt', true),
('AdGuard Mobile Ads filter',
'https://filters.adtidy.org/extension/ublock/filters/11.txt', true),
('uBlock filters – Resource abuse',
'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/resource-abuse.txt', true),
('AdGuard Annoyances',
'https://filters.adtidy.org/extension/ublock/filters/14.txt', true),
("Fanboy's Annoyance List", 'https://secure.fanboy.co.nz/fanboy-annoyance.txt', true),
('uBlock filters – Annoyances',
'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances.txt', true),
("Fanboy's Indian filter", 'https://secure.fanboy.co.nz/fanboy-indian.txt', true),
('AdGuard Turkish filter', 'https://filters.adtidy.org/windows/filters/13.txt?id=13', true),
('ABPindo Indonesian filter',
'https://raw.githubusercontent.com/ABPindo/indonesianadblockrules/master/subscriptions/abpindo.txt', true),
('AdGuard Russian filter', 'https://filters.adtidy.org/windows/filters/1.txt?id=1', true),
('AdGuard Spanish/Portuguese filter',
'https://filters.adtidy.org/extension/ublock/filters/9.txt', true),
('EasyList German filter', 'https://easylist-downloads.adblockplus.org/easylistgermany.txt', true),
('OISD Abp Full', 'https://abp.oisd.nl', true),
('FFAdblock (Anti-Adblock Killer)',
'https://raw.githubusercontent.com/bogachenko/fuckfuckadblock/master/fuckfuckadblock.txt', true),
('uBlock filters – Badware risks',
'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt', false),
('uBlock filters – Privacy',
'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt', false),
('Online Malicious URL Blocklist',
'https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-online.txt', false),
('Easylist Cookie List', 'https://secure.fanboy.co.nz/fanboy-cookiemonster.txt', false),
('1Hosts (Lite)', 'https://badmojr.github.io/1Hosts/Lite/hosts.txt', false),
];

Set<String> _hosts = {};
Set<String> _hotHosts = {};
Set<String> _allowHosts = {};
List<String> _cosmetic = [];
bool _ready = false;
int _seedHostCount = 0;
DateTime? _lastUpdated;
// 每个源上次更新的结果（源名 -> 状态文案），「我的」里显示。
final Map<String, String> sourceStatus = {};

bool get isReady => _ready;
int get blockedHostCount => _hosts.length;
int get hotHostCount => _hotHosts.length;
int get seedHostCount => _seedHostCount;
DateTime? get lastUpdated => _lastUpdated;

  /// 供单元测试用：直接装入解析好的规则，不走 asset/文件/网络。
  @visibleForTesting
  void loadFromParsed({
    required Set<String> hosts,
    required Set<String> hotHosts,
    required Set<String> allowHosts,
    required List<String> cosmetic,
  }) {
    _hosts = hosts;
    _hotHosts = hotHosts;
    _allowHosts = allowHosts;
    _cosmetic = cosmetic;
    _seedHostCount = hosts.length;
    _ready = true;
  }

/// 启动时调一次：先读种子（离线可用），再读本地已更新过的全量文件；
/// 超过 7 天没更新就后台拉一次（不阻塞启动，失败不报错）。
Future<void> init() async {
await _loadSeed();
await _loadCachedUpdate();
_ready = true;
final prefs = await SharedPreferences.getInstance();
final ms = prefs.getInt(_prefsLastUpdated)?? 0;
_lastUpdated = ms > 0? DateTime.fromMillisecondsSinceEpoch(ms): null;
if (_lastUpdated == null ||
DateTime.now().difference(_lastUpdated!) > _autoUpdateInterval) {
unawaited(updateRules().then((_) {}).catchError((_) {}));
}
}

Future<void> _loadSeed() async {
try {
final raw = await rootBundle.loadString('assets/adblock-seed.json');
final data = jsonDecode(raw) as Map<String, dynamic>;
_hosts = ((data['hosts'] as List?)?? []).map((e) => e.toString()).toSet();
_hotHosts = ((data['hotHosts'] as List?)?? []).map((e) => e.toString()).toSet();
_allowHosts =
((data['allowHosts'] as List?)?? []).map((e) => e.toString()).toSet();
_cosmetic = ((data['cosmetic'] as List?)?? []).map((e) => e.toString()).toList();
_seedHostCount = _hosts.length;
} catch (_) {
_hosts = {};
_hotHosts = {};
_allowHosts = {};
_cosmetic = [];
}
}

Future<File> _hostsCacheFile() async {
final dir = await getApplicationDocumentsDirectory();
return File('${dir.path}/$_hostsFile');
}

Future<void> _loadCachedUpdate() async {
try {
final f = await _hostsCacheFile();
if (!await f.exists()) return;
final lines = await f.readAsLines();
if (lines.isEmpty) return;
_hosts = {..._hosts,...lines.map((e) => e.trim()).where((e) => e.isNotEmpty)};
} catch (_) {}
}

/// 某个源开没开（默认跟 1DM 备份一致）。
Future<bool> isSourceEnabled(String name) async {
final prefs = await SharedPreferences.getInstance();
final disabled = prefs.getStringList(_prefsDisabled)?? [];
if (disabled.contains(name)) return false;
final enabled = prefs.getStringList(_prefsEnabled)?? [];
if (enabled.contains(name)) return true;
final found = kFilterSources.where((s) => s.$1 == name).toList();
return found.isEmpty? true: found.first.$3;
}

Future<void> setSourceEnabled(String name, bool enabled) async {
final prefs = await SharedPreferences.getInstance();
final disabled = (prefs.getStringList(_prefsDisabled)?? []).toSet();
final enabledList = (prefs.getStringList(_prefsEnabled)?? []).toSet();
if (enabled) {
disabled.remove(name);
enabledList.add(name);
} else {
enabledList.remove(name);
disabled.add(name);
}
await prefs.setStringList(_prefsDisabled, disabled.toList());
await prefs.setStringList(_prefsEnabled, enabledList.toList());
}

/// 是否拦这个域名（第一方豁免：host 是 firstPartyHost 本身或其子域名就不拦）。
/// allowHosts（播放器白名单）优先于拦截。
bool isBlockedHost(String host, {String? firstPartyHost}) {
final h = host.toLowerCase().trim();
if (h.isEmpty) return false;
if (firstPartyHost!= null && firstPartyHost.isNotEmpty) {
final fp = firstPartyHost.toLowerCase();
if (h == fp || h.endsWith('.$fp')) return false;
}
if (_matchesSuffix(h, _allowHosts)) return false;
return _matchesSuffix(h, _hosts);
}

/// 是否拦这个 URL（第一方豁免同上；解析不出 host 的不拦）。
bool isBlockedUrl(String url, {String? firstPartyHost}) {
final host = Uri.tryParse(url)?.host?? '';
if (host.isEmpty) return false;
return isBlockedHost(host, firstPartyHost: firstPartyHost);
}

static bool _matchesSuffix(String host, Set<String> set) {
var h = host;
while (true) {
if (set.contains(h)) return true;
final dot = h.indexOf('.');
if (dot < 0) return false;
h = h.substring(dot + 1);
}
}

/// 注入到 WebView 的 JS（每次页面加载后跑一次）：
/// - 按 ## 选择器藏广告元素（MutationObserver 跟踪后加载的）；
/// - fetch/XHR 发往 hotHosts 里的域名直接 abort（同步判定，不等网络）；
/// - window.open 到广告域名的直接拦掉（弹窗广告）。
/// 注意：JS 里只带 hotHosts（多源交集的小集合），全量 hosts 只在 Dart 层
/// 拦顶层跳转用；首屏 HTML 里内嵌的广告子资源在注入前可能已经发出去了，
/// 这是 webview_flutter 做不到原生拦截的上限（见类注释）。
String get injectionJs {
final hot = _hotHosts.map((h) => "'$h'").join(',');
final css = _cosmetic
.map((s) => s.replaceAll("'", "\\'"))
.map((s) => "$s{display:none!important}")
.join('\n');
return '''
(function(){
try {
var blocked = new Set([$hot]);
function hostOf(u){ try { return new URL(u, location.href).hostname.toLowerCase();} catch(e){ return '';}}
function isBlocked(u){
var h = hostOf(u);
if(!h) return false;
if(h === location.hostname || h.endsWith('.' + location.hostname)) return false;
while(h){ if(blocked.has(h)) return true; var i = h.indexOf('.'); if(i < 0) break; h = h.slice(i+1);}
return false;
}
var ofetch = window.fetch;
window.fetch = function(u, o){ try { if(isBlocked(u instanceof Request? u.url: u)) return Promise.reject(new Error('blocked by adblock'));} catch(e){} return ofetch.apply(this, arguments);};
var oxhr = XMLHttpRequest.prototype.open;
XMLHttpRequest.prototype.open = function(m, u){ if(isBlocked(u)){ this.__adBlocked = true;} return oxhr.apply(this, arguments);};
var osend = XMLHttpRequest.prototype.send;
XMLHttpRequest.prototype.send = function(){ if(this.__adBlocked){ try { this.abort();} catch(e){} return;} return osend.apply(this, arguments);};
var oopen = window.open;
window.open = function(u){ try { if(u && isBlocked(u)) return null;} catch(e){} return oopen.apply(this, arguments);};
var st = document.createElement('style');
st.textContent = `$css`;
(document.head || document.documentElement).appendChild(st);
if(window.MutationObserver){
var hide = function(){
try {
document.querySelectorAll('iframe[src]').forEach(function(f){
if(isBlocked(f.src)) f.remove();
});
} catch(e){}
};
new MutationObserver(hide).observe(document.documentElement, {childList:true, subtree:true});
hide();
}
} catch(e){}
})();
''';
}

/// 拉取全部启用的源并更新（手动点「更新规则」或启动时过期自动拉）。
/// 逐源记状态（成功多少条 / 失败原因），失败的源不影响其他源；
/// 返回 (成功源数, 失败源数, 新增拦截域名数)。
Future<({int ok, int failed, int added})> updateRules() async {
var ok = 0;
var failed = 0;
final merged = <String>{..._hosts};
final extraCosmetic = <String>[];
final before = merged.length;
for (final (name, url, _) in kFilterSources) {
if (!await isSourceEnabled(name)) continue;
try {
final res = await http
.get(Uri.parse(url), headers: {'User-Agent': 'TaohuayuanAdblock/1.0'})
.timeout(const Duration(seconds: 20));
if (res.statusCode!= 200) {
sourceStatus[name] = '失败：HTTP ${res.statusCode}';
failed++;
continue;
}
final parsed = await compute(_parseFilterText, res.body);
merged.addAll(parsed.hosts);
_allowHosts.addAll(parsed.allow);
for (final c in parsed.cosmetic) {
if (extraCosmetic.length < 500 &&!extraCosmetic.contains(c)) {
extraCosmetic.add(c);
}
}
sourceStatus[name] = '已更新：${parsed.hosts.length} 条域名';
ok++;
} catch (e) {
sourceStatus[name] = '失败：${e.toString().split('\n').first}';
failed++;
}
}
if (ok > 0) {
_hosts = merged;
if (extraCosmetic.isNotEmpty) _cosmetic = [..._cosmetic,...extraCosmetic];
try {
final f = await _hostsCacheFile();
final sorted = merged.toList()..sort();
await f.writeAsString(sorted.join('\n'));
} catch (_) {}
_lastUpdated = DateTime.now();
final prefs = await SharedPreferences.getInstance();
await prefs.setInt(_prefsLastUpdated, _lastUpdated!.millisecondsSinceEpoch);
}
return (ok: ok, failed: failed, added: merged.length - before);
}
}

/// 供单元测试直接验 + compute 后台解析用：一段规则文本 -> 域名/白名单/隐藏选择器。
/// 口径跟种子生成脚本（/tmp/adblock-lists/gen_seed.py）一致：
/// - `||域名^`（不含 domain= 限定的）与 hosts 行（127.0.0.1/0.0.0.0 域名）进拦截；
/// - `@@||域名` 进白名单（只收域名部分）；
/// - `##选择器`（通用 + 本 App 10 个源站的站内规则）进隐藏选择器；
/// - `##+js` 脚本注入、`#$#` 等高级语法不支持（WebView 注入跑不了 uBO 脚本）；
/// - 通配符、带路径/参数的规则不要（域名拦截器吃不了）。
({Set<String> hosts, Set<String> allow, List<String> cosmetic}) parseFilterText(
String text) {
final hosts = <String>{};
final allow = <String>{};
final cosmetic = <String>[];
bool hostOk(String h) {
h = h.trim().toLowerCase();
if (h.isEmpty || h.contains('*') || h.contains('/') || h.contains('?')) {
return false;
}
if (h.startsWith('.') || h.endsWith('.') || h.contains('..')) return false;
if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(h)) return false;
return h.contains('.');
}

for (final raw in text.split('\n')) {
final line = raw.trim();
if (line.isEmpty || line.startsWith('!') || line.startsWith('[')) continue;
if (line.contains('##')) {
final idx = line.indexOf('##');
final left = line.substring(0, idx);
final sel = line.substring(idx + 2).trim();
if (sel.isEmpty || sel.contains('+js') || sel.startsWith('#')) continue;
if (sel.length > 120 || sel.contains('{')) continue;
if (left.isEmpty) {
if (cosmetic.length < 1500) cosmetic.add(sel);
} else {
for (final d in left.split(RegExp(r'[,\s]+'))) {
final dom = d.trim().toLowerCase().replaceAll(RegExp(r'^~+'), '');
if (AdblockService.appHosts.contains(dom) ||
AdblockService.appHosts.any((a) => dom.endsWith('.$a'))) {
if (cosmetic.length < 2000) cosmetic.add(sel);
break;
}
}
}
continue;
}
if (line.startsWith('@@')) {
final m = RegExp(r'@@\|\|([^/^$*]+)').firstMatch(line);
if (m!= null && hostOk(m.group(1)!)) allow.add(m.group(1)!.toLowerCase());
continue;
}
if (line.startsWith('||')) {
var rest = line.substring(2);
if (rest.contains('\$')) {
final parts = rest.split('\$');
rest = parts.first;
if (parts.skip(1).join('\$').contains('domain=')) continue;
}
final host = RegExp(r'^[^/^]+').firstMatch(rest)?.group(0)?? '';
if (hostOk(host)) hosts.add(host.toLowerCase());
continue;
}
final m = RegExp(r'^(?:127\.0\.0\.1|0\.0\.0\.0)\s+(\S+)').firstMatch(line);
if (m!= null && hostOk(m.group(1)!)) hosts.add(m.group(1)!.toLowerCase());
}
return (hosts: hosts, allow: allow, cosmetic: cosmetic);
}

/// compute 用的顶层函数（不能是方法）。
({Set<String> hosts, Set<String> allow, List<String> cosmetic}) _parseFilterText(
String text) =>
parseFilterText(text);
