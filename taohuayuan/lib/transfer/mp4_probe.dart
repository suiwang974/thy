import 'dart:io';

/// MP4 moov 探测：Range 只取文件头一段，解析 mvhd/tkhd 拿时长和宽高。
/// 失败返回 null，不抛错。
/// 做法抄猫抓 cat-catch `js/m3u8.js` 的 fixFileDuration（解析 moov 里的
/// mvhd/tkhd/mdhd）；实现是原创 Dart，没搬它的代码。
class Mp4Probe {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 纯函数：解析一段 MP4 字节（必须含完整 moov，否则返回 null）。
  static ({int? durationSec, String? resolution})? parseBytes(
      List<int> data) {
    final moov = _findBox(data, 0, data.length, 'moov');
    if (moov == null) return null;
    final (moovStart, moovEnd) = moov;
    int? durationSec;
    String? resolution;
    final mvhd = _findBox(data, moovStart, moovEnd, 'mvhd');
    if (mvhd != null) {
      durationSec = _parseMvhd(data, mvhd.$1, mvhd.$2);
    }
    // 第一个有宽高的 trak 就是视频轨。
    var pos = moovStart;
    while (pos + 8 <= moovEnd) {
      final trak = _findBox(data, pos, moovEnd, 'trak');
      if (trak == null) break;
      final tkhd = _findBox(data, trak.$1, trak.$2, 'tkhd');
      if (tkhd != null) {
        resolution = _parseTkhd(data, tkhd.$1, tkhd.$2);
        if (resolution != null) break;
      }
      pos = trak.$2;
    }
    if (durationSec == null && resolution == null) return null;
    return (durationSec: durationSec, resolution: resolution);
  }

  /// 联网：Range 取前 64KB 再解析。headers 原样传给请求。
  /// 超时 8 秒；任何失败返回 null。
  static Future<({int? durationSec, String? resolution})?> probe(
      String url, Map<String, String> headers) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', _ua);
      headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.set('Range', 'bytes=0-65535');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 206 && res.statusCode != 200) return null;
      final bytes = await res
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
          .timeout(const Duration(seconds: 8));
      return parseBytes(bytes);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 在 [start, end) 里顺序找第一个 type 为 [type] 的 box，
  /// 返回 (内容起点, 内容终点)；找不到返回 null。
  /// Box 头：[size:uint32BE][type:4 字节]；size==1 时后跟 64 位 largesize；
  /// size==0 表示到父级末尾。
  static (int, int)? _findBox(
      List<int> data, int start, int end, String type) {
    var p = start;
    while (p + 8 <= end && p + 8 <= data.length) {
      final size32 = _u32(data, p);
      if (size32 == null) return null;
      final t = String.fromCharCodes(data.sublist(p + 4, p + 8));
      var headerLen = 8;
      var total = size32;
      if (size32 == 1) {
        final large = _u64(data, p + 8);
        if (large == null || large < 16) return null;
        total = large;
        headerLen = 16;
      } else if (size32 == 0) {
        total = end - p;
      }
      if (total < headerLen) return null;
      final contentStart = p + headerLen;
      final contentEnd = p + total;
      if (t == type) return (contentStart, contentEnd);
      if (contentEnd <= p) return null;
      p = contentEnd;
    }
    return null;
  }

  /// mvhd 内容：version==0 时 timescale 在 +12、duration 在 +16（各 uint32）；
  /// version==1 时 timescale 在 +20（uint32）、duration 在 +24（uint64）。
  static int? _parseMvhd(List<int> data, int start, int end) {
    if (start >= end || start >= data.length) return null;
    final version = data[start];
    int? timescale;
    int? duration;
    if (version == 0) {
      timescale = _u32(data, start + 12);
      duration = _u32(data, start + 16);
    } else if (version == 1) {
      timescale = _u32(data, start + 20);
      duration = _u64(data, start + 24);
    } else {
      return null;
    }
    if (timescale == null || timescale <= 0) return null;
    if (duration == null || duration <= 0) return null;
    final sec = (duration / timescale).round();
    return sec > 0 ? sec : null;
  }

  /// tkhd 内容：version==0 时宽在 +76、高在 +80；version==1 时宽在 +88、
  /// 高在 +92（各 uint32，16.16 定点，取高 16 位）。
  static String? _parseTkhd(List<int> data, int start, int end) {
    if (start >= end || start >= data.length) return null;
    final version = data[start];
    int? w;
    int? h;
    if (version == 0) {
      w = _u32(data, start + 76);
      h = _u32(data, start + 80);
    } else if (version == 1) {
      w = _u32(data, start + 88);
      h = _u32(data, start + 92);
    } else {
      return null;
    }
    if (w == null || h == null) return null;
    final width = w >> 16;
    final height = h >> 16;
    if (width <= 0 || height <= 0) return null;
    return '${width}x$height';
  }

  static int? _u32(List<int> data, int offset) {
    if (offset < 0 || offset + 4 > data.length) return null;
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }

  static int? _u64(List<int> data, int offset) {
    if (offset < 0 || offset + 8 > data.length) return null;
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | data[offset + i];
    }
    return v;
  }
}
