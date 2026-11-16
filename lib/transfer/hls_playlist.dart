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
