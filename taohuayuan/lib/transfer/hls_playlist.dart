/// HLS 播放列表解析器（纯 Dart，无 Flutter 依赖）。
/// master 列表：变体选择；media 列表：分片、密钥、BYTERANGE、MAP、直播判定。
/// KEY 的 URI 在解析时按 playlist 的 base 拼成绝对地址；IV 按 0x 十六进制解析。
class HlsVariant {
  final int bandwidth;
  final String resolution;
  final String codecs;
  final String url;
  const HlsVariant({
    required this.bandwidth,
    required this.resolution,
    required this.codecs,
    required this.url,
  });
}

class HlsKey {
  final String method;
  final String uri;
  final List<int>? iv;
  const HlsKey({required this.method, required this.uri, this.iv});
}

class HlsSegment {
  final String url;
  final double duration;
  final HlsKey? key;
  final int? byteRangeLength;
  final int? byteRangeOffset;
  final int sequence;
  const HlsSegment({
    required this.url,
    required this.duration,
    this.key,
    this.byteRangeLength,
    this.byteRangeOffset,
    required this.sequence,
  });
}

class HlsMediaPlaylist {
  final List<HlsSegment> segments;
  final String? mapUri;
  final bool isLive;
  final int mediaSequence;
  double get totalDuration =>
      segments.fold(0.0, (sum, e) => sum + e.duration);
  const HlsMediaPlaylist({
    required this.segments,
    this.mapUri,
    required this.isLive,
    required this.mediaSequence,
  });
}

class HlsPlaylist {
  static bool isMaster(String text) => text.contains('#EXT-X-STREAM-INF');

  static List<HlsVariant> parseMaster(String text, String base) {
    final result = <HlsVariant>[];
    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final bandwidth =
          int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '') ?? 0;
      final resolution =
          RegExp(r'RESOLUTION=([^,\s]+)').firstMatch(line)?.group(1) ?? '';
      final codecs =
          RegExp(r'CODECS="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      var j = i + 1;
      while (j < lines.length &&
          (lines[j].trim().isEmpty || lines[j].trim().startsWith('#'))) {
        j++;
      }
      if (j < lines.length) {
        result.add(HlsVariant(
          bandwidth: bandwidth,
          resolution: resolution,
          codecs: codecs,
          url: Uri.parse(base).resolve(lines[j].trim()).toString(),
        ));
        i = j;
      }
    }
    return result;
  }

  static HlsMediaPlaylist parseMedia(String text, String base) {
    final segments = <HlsSegment>[];
    String? mapUri;
    var isLive = true;
    var mediaSequence = 0;
    HlsKey? currentKey;
    double? duration;
    int? pendingRangeLength;
    int? pendingRangeOffset;
    var nextOffset = 0;
    var sequence = 0;
    var sequenceSet = false;

    String? attrValue(String line, String name) {
      final quoted =
          RegExp('$name="([^"]*)"').firstMatch(line)?.group(1);
      if (quoted != null) return quoted;
      return RegExp('$name=([^,\\s]+)').firstMatch(line)?.group(1);
    }

    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-ENDLIST')) {
        isLive = false;
      } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) {
        mediaSequence =
            int.tryParse(line.substring(line.indexOf(':') + 1).trim()) ?? 0;
        if (!sequenceSet) {
          sequence = mediaSequence;
          sequenceSet = true;
        }
      } else if (line.startsWith('#EXT-X-MAP')) {
        final uri = attrValue(line, 'URI');
        if (uri != null) mapUri = Uri.parse(base).resolve(uri).toString();
      } else if (line.startsWith('#EXT-X-KEY')) {
        final method = attrValue(line, 'METHOD') ?? '';
        final uri = attrValue(line, 'URI');
        final ivRaw = attrValue(line, 'IV');
        currentKey = HlsKey(
          method: method,
          uri: uri == null ? '' : Uri.parse(base).resolve(uri).toString(),
          iv: ivRaw == null ? null : parseIv(ivRaw),
        );
      } else if (line.startsWith('#EXT-X-BYTERANGE')) {
        final value = line.substring(line.indexOf(':') + 1).trim();
        final parts = value.split('@');
        pendingRangeLength = int.tryParse(parts[0]);
        if (parts.length > 1) {
          pendingRangeOffset = int.tryParse(parts[1]);
        } else {
          pendingRangeOffset = nextOffset;
        }
      } else if (line.startsWith('#EXTINF')) {
        final afterColon = line.substring(line.indexOf(':') + 1);
        duration = double.tryParse(afterColon.split(',').first.trim());
      } else if (!line.startsWith('#')) {
        final length = pendingRangeLength;
        final offset = pendingRangeOffset;
        if (length != null && offset != null) {
          nextOffset = offset + length;
        }
        segments.add(HlsSegment(
          url: Uri.parse(base).resolve(line).toString(),
          duration: duration ?? 0.0,
          key: currentKey,
          byteRangeLength: length,
          byteRangeOffset: offset,
          sequence: sequence,
        ));
        sequence++;
        duration = null;
        pendingRangeLength = null;
        pendingRangeOffset = null;
      }
    }
    return HlsMediaPlaylist(
      segments: segments,
      mapUri: mapUri,
      isLive: isLive,
      mediaSequence: mediaSequence,
    );
  }

  static HlsVariant? pickVariant(List<HlsVariant> variants) {
    if (variants.isEmpty) return null;
    var best = variants.first;
    for (final v in variants) {
      if (v.bandwidth > best.bandwidth) best = v;
    }
    return best;
  }

  /// 累加所有 `#EXTINF:` 行秒数并统计分片数，返回 (总秒四舍五入, 分片数)。
  /// 空正文返回 (0, 0)。
  static (int, int) parseMediaDurations(String body) {
    var total = 0.0;
    var count = 0;
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('#EXTINF:')) continue;
      final value = line.substring('#EXTINF:'.length).split(',').first.trim();
      final seconds = double.tryParse(value);
      count++;
      if (seconds != null && seconds > 0) total += seconds;
    }
    return (total.round(), count);
  }

  /// 从 URL 小写路径里找分辨率提示，返回标准 16:9 展示宽高，找不到返回 null。
  /// 宽度是按 16:9 推算的，仅用于展示和排序。
  static String? resolutionFromUrlHint(String url) {
    final lower = url.toLowerCase();
    String path;
    try {
      final uri = Uri.parse(lower);
      path = uri.path.isEmpty ? lower : uri.path;
    } catch (_) {
      path = lower;
    }
    const hints = <String, String>{
      '2160': '3840x2160',
      '1440': '2560x1440',
      '1080': '1920x1080',
      '720': '1280x720',
      '480': '854x480',
      '360': '640x360',
      '240': '426x240',
      '4k': '3840x2160',
      '2k': '2560x1440',
    };
    for (final entry in hints.entries) {
      final pattern =
          RegExp('(?<![0-9])${RegExp.escape(entry.key)}(?![0-9])');
      if (pattern.hasMatch(path)) return entry.value;
    }
    return null;
  }

  /// master 解析成最终的变体信息（Dart 侧嗅探与原生侧富化共用同一份逻辑）。
  /// 兜底顺序：master RESOLUTION → 嵌套 master 再解析一层 → 变体 URL 提示。
  /// fetch 只负责拉取（调用方决定怎么拉、带什么请求头）；任何一步失败都
  /// 不抛错，返回带 metaNote 的结果。
  static Future<HlsResolvedMeta> resolveVariantMeta({
    required String masterBody,
    required String masterUrl,
    required Future<String> Function(String url) fetch,
  }) async {
    // 不是 master：当媒体播放列表直接算时长。
    if (!isMaster(masterBody)) {
      final (dur, count) = parseMediaDurations(masterBody);
      return HlsResolvedMeta(
        durationSec: dur > 0 ? dur : null,
        segmentCount: count,
        metaNote: dur > 0 ? '播放列表无分辨率信息' : null,
      );
    }
    final variants = parseMaster(masterBody, masterUrl);
    final picked = pickVariant(variants);
    if (picked == null) {
      return const HlsResolvedMeta(metaNote: '播放列表无分辨率信息');
    }
    var resolution = picked.resolution.isEmpty ? null : picked.resolution;
    var bandwidth = picked.bandwidth > 0 ? picked.bandwidth : null;
    String? mediaBody;
    // 选中变体没有 RESOLUTION：先拉变体地址，看是不是嵌套 master。
    if (resolution == null) {
      try {
        final body = await fetch(picked.url);
        if (isMaster(body)) {
          final nested = pickVariant(parseMaster(body, picked.url));
          if (nested != null) {
            if (nested.resolution.isNotEmpty) {
              resolution = nested.resolution;
            }
            if (nested.bandwidth > 0) bandwidth = nested.bandwidth;
            // 嵌套 master 的选中变体才是媒体播放列表，再拉一次。
            try {
              mediaBody = await fetch(nested.url);
            } catch (_) {
              return HlsResolvedMeta(
                resolution: resolution,
                bandwidth: bandwidth,
                metaNote: '播放列表拉取失败',
              );
            }
          }
        } else {
          mediaBody = body;
          resolution ??= resolutionFromUrlHint(picked.url);
        }
      } catch (_) {
        return HlsResolvedMeta(
          resolution: resolution,
          bandwidth: bandwidth,
          metaNote: '播放列表拉取失败',
        );
      }
    }
    // 拉最终的媒体播放列表正文（上面已取到的复用，不重复拉）。
    mediaBody ??= await _fetchMediaBody(picked.url, fetch);
    if (mediaBody == null) {
      return HlsResolvedMeta(
        resolution: resolution,
        bandwidth: bandwidth,
        metaNote: '播放列表拉取失败',
      );
    }
    final (dur, count) = parseMediaDurations(mediaBody);
    return HlsResolvedMeta(
      resolution: resolution,
      bandwidth: bandwidth,
      durationSec: dur > 0 ? dur : null,
      segmentCount: count,
      metaNote: resolution == null && dur > 0 ? '播放列表无分辨率信息' : null,
    );
  }

  /// 拉媒体播放列表正文；失败返回 null（不抛错）。
  static Future<String?> _fetchMediaBody(
    String url,
    Future<String> Function(String url) fetch,
  ) async {
    try {
      return await fetch(url);
    } catch (_) {
      return null;
    }
  }

  /// 解析 IV=0x... 十六进制串；不合法返回 null。
  static List<int>? parseIv(String raw) {
    var hex = raw.trim();
    if (hex.toLowerCase().startsWith('0x')) hex = hex.substring(2);
    if (hex.isEmpty || hex.length.isOdd) return null;
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}

/// 一次 master 解析的结果：分辨率/码率/时长/分片数，失败时 metaNote 写原因。
class HlsResolvedMeta {
  final String? resolution; // 如 '1920x1080'
  final int? bandwidth; // bps
  final int? durationSec;
  final int segmentCount;
  final String? metaNote; // 失败原因显示文案，成功为 null
  const HlsResolvedMeta({
    this.resolution,
    this.bandwidth,
    this.durationSec,
    this.segmentCount = 0,
    this.metaNote,
  });
}
