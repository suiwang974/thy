import '../data/sources.dart';

/// 搜索页逐源状态文案的口径（第 45 条）。
///
/// 之前的问题：onResult 里状态写的是 `'${r.items.length} 条'`，源返回 0 条时
/// 就写成 "0 条"；汇总和空结果判断都只看状态里含不含“条”，"0 条"也被当成
/// “有结果”——用户截图就是这么来的：“共 3 个源：3 个有结果”，下面一条
/// 不显示，空结果页还赖“被筛选条件滤掉了”。其实三个源返回的都是 0 条，
/// 默认筛选（全部）根本滤不掉任何东西（时长/画质未知的本来就不过滤）。
///
/// 口径从这里统一：
/// - "12 条"、"3 条（后台补回）" = 真有条目；
/// - "0 条" 不算有结果——状态里就别写 "0 条"，直接写“没结果”。
bool statusHasResults(String status) =>
    RegExp(r'^[1-9]\d* 条').hasMatch(status);

/// 源返回后的状态文案：有错报错；没条目就是“没结果”。
String statusTextForResult(SourceResult r) {
  if (r.error != null) return '${r.error}，后台再试…';
  if (r.items.isEmpty) return '没结果';
  return '${r.items.length} 条';
}
