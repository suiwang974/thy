/// 下载候选：捕获层产出、传输层消费的最小数据模型。
/// 字段与 D3 契约一致（url / headers / referer / cookies / mime /
/// confidence / source / expiresAt）。
class DownloadCandidate {
  final String url;
  final Map<String, String> headers;
  final String? referer;
  final List<String> cookies;
  final String? mime;
  final double confidence;
  final String source;
  final DateTime? expiresAt;

  const DownloadCandidate({
    required this.url,
    this.headers = const {},
    this.referer,
    this.cookies = const [],
    this.mime,
    this.confidence = 0.5,
    this.source = 'network',
    this.expiresAt,
  });

  /// 合并后的请求头：先放 headers，再用 referer 覆盖 Referer 键
  /// （referer 非空时），再加 Cookie 键（cookies 非空时用 '; ' 连接）。
  Map<String, String> effectiveHeaders() {
    final out = Map<String, String>.from(headers);
    if (referer != null && referer!.isNotEmpty) {
      out['Referer'] = referer!;
    }
    if (cookies.isNotEmpty) {
      out['Cookie'] = cookies.join('; ');
    }
    return out;
  }
}
