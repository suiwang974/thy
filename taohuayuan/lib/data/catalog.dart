import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/video_item.dart';

/// 在线片库目录：62 条（第 01/02/03/04/05/07 批），存在 assets/catalog.json。
/// 注意：这只是目录 + 直链，用户手机上并没有下载这 62 个视频，
/// 界面里一律叫“片库”，绝不出现“本地片库”。
class Catalog {
  static List<VideoItem>? _items;

  static Future<List<VideoItem>> load() async {
    if (_items != null) return _items!;
    final raw = await rootBundle.loadString('assets/catalog.json');
    final list = jsonDecode(raw) as List;
    _items = list.map((e) => VideoItem.fromCatalog(e as Map<String, dynamic>)).toList();
    return _items!;
  }

  /// 目录内搜索：标题 / 作者 / 批次 / 关键词，全部按词 AND 匹配。
  /// 中文关键词（足/足交/足控）就写在每条的 keywords 里，所以搜“足”能直接命中。
  static List<VideoItem> search(List<VideoItem> items, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return items;
    final tokens = q.split(RegExp(r'\s+'));
    return items.where((v) {
      final hay = [v.title, v.author, v.batch, v.source, ...v.keywords].join(' ').toLowerCase();
      return tokens.every(hay.contains);
    }).toList();
  }

  /// 按作者分组（3D 按作者；真人按演员——目录里作者字段就是分组键）。
  static Map<String, List<VideoItem>> groupByAuthor(List<VideoItem> items) {
    final map = <String, List<VideoItem>>{};
    for (final v in items) {
      final key = v.author.isEmpty ? '未署名' : v.author;
      (map[key] ??= []).add(v);
    }
    return map;
  }
}
