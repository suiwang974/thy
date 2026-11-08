/// 中文搜索词 -> 英文搜索词映射。搜中文时先映射再发给各源。
/// 长词优先：匹配时按 key 长度从长到短替换，避免“足交”被“足”先截走。
const Map<String, String> kSearchMap = {
  '足交': 'footjob',
  '足控': 'footjob',
  '调教': 'femdom',
  '足': 'foot',
  '八重神子': 'yae miko',
  '甘雨': 'ganyu',
  '索拉卡': 'soraka',
  '娑娜': 'sona',
  '猎空': 'tracer',
  '白皇后': 'emma frost',
  '阿卡丽': 'akali',
  '流萤': 'firefly',
  '芙宁娜': 'furina',
  '艾莲': 'ellen joe',
  '长离': 'changli',
  '夜兰': 'yelan',
  '胡桃': 'hutao',
  '原神': 'genshin',
  '崩坏': 'honkai',
  '绝区零': 'zenless zone zero',
  '鸣潮': 'wuthering waves',
  '星穹铁道': 'honkai star rail',
};

/// 把用户输入的中文词映射成英文搜索词。
/// 规则：先按长词整体替换；没有命中映射的词原样保留（英文词、名字直接搜）。
String mapSearchQuery(String raw) {
  var q = raw.trim();
  if (q.isEmpty) return q;
  // 长词优先，避免短词先替换掉长词的一部分。
  final keys = kSearchMap.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final k in keys) {
    if (q.contains(k)) q = q.replaceAll(k, kSearchMap[k]!);
  }
  return q.trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// 分类过滤：中文分类名 -> 匹配用的英文标签词（小写）。
/// 匹配时看标题和 keywords 里有没有这些词；标题里有中文分类名本身也算命中。
const Map<String, List<String>> kCategories = {
  // 中文同义词也放进来：标题是中文的站（niacg、lianzu11）靠它们命中。
  // “足”会连“足球”也命中，在这个 App 的语境里可以接受（标题含“足”基本都是足内容）。
  '足控': ['foot', 'footjob', 'feet', 'soles', '足'],
  '调教': ['femdom', 'domination', 'bdsm', '调教'],
  '3D': ['3d', '3-d', 'cgi', 'hentai 3d'],
  '亚洲': ['asian', 'japanese', 'chinese', 'korean', 'jav', '亚洲', '日本'],
  '角色扮演': ['cosplay', 'roleplay', '角色扮演'],
  '口交': ['blowjob', 'oral', '口交'],
};

