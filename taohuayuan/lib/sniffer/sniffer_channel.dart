import 'package:flutter/services.dart';

import '../transfer/download_candidate.dart';

/// 原生捕获层的 Dart 桥（MethodChannel，与 MainActivity 的
/// "taohuayuan/sniffer" 通道对应；沿用已有 downloads/update 通道的写法）。
/// start/navigate 都可带 adapters（路名列表，见 NativeSnifferBridge；
/// 空列表表示默认六路全开）；navigate 在同一个无头会话里换地址，
/// 先清掉上一页的记录与候选再打开新地址。
class SnifferChannel {
  static const MethodChannel _channel = MethodChannel('taohuayuan/sniffer');

  /// 启动捕获并加载 URL（document-start 脚本在导航前已注册）。
  /// 会话已在跑时，原生侧当 navigate 处理（不清 WebView，只清记录）。
  Future<void> start(String url, {List<String> adapters = const []}) async {
    await _channel.invokeMethod(
      'start',
      {'url': url, 'adapters': adapters},
    );
  }

  /// 同一会话换地址：清掉上一页的记录与候选，换一套生效的路，再打开新地址。
  /// 会话没在跑时，原生侧按 start 走（新建会话）。
  Future<void> navigate(String url, {List<String> adapters = const []}) async {
    await _channel.invokeMethod(
      'navigate',
      {'url': url, 'adapters': adapters},
    );
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  /// 取当前候选列表（按 confidence 降序，原生侧已排好）。
  /// headers 是原生侧记到的真实请求头；expiresAt 是毫秒时间戳（可空）。
  Future<List<DownloadCandidate>> getCandidates() async {
    final list =
        await _channel.invokeListMethod<Map<Object?, Object?>>('getCandidates');
    if (list == null) return [];
    return list.map((m) {
      final headers = <String, String>{};
      final rawHeaders = m['headers'];
      if (rawHeaders is Map) {
        for (final e in rawHeaders.entries) {
          final k = e.key?.toString() ?? '';
          final v = e.value?.toString() ?? '';
          if (k.isNotEmpty) headers[k] = v;
        }
      }
      final expiresMs = m['expiresAt'];
      return DownloadCandidate(
        url: m['url'] as String? ?? '',
        headers: headers,
        referer: m['referer'] as String?,
        mime: m['mime'] as String?,
        confidence: (m['confidence'] as num?)?.toDouble() ?? 0.5,
        source: m['source'] as String? ?? 'network',
        expiresAt: expiresMs is num
            ? DateTime.fromMillisecondsSinceEpoch(expiresMs.toInt())
            : null,
      );
    }).where((c) => c.url.isNotEmpty).toList();
  }

  Future<void> dispose() async {
    await _channel.invokeMethod('dispose');
  }
}
