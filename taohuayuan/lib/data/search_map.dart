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
