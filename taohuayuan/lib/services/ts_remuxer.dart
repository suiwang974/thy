import 'dart:io';
import 'dart:typed_data';

/// MPEG-TS -> MP4 重封装（不转码，只换容器）：把 HLS 下下来的 .ts 分片
/// 拼成的文件转成 .mp4，让系统相册/其他播放器也能直接播。
///
/// 背景（第 34 条 1DM 对照）：1DM 下载时有“将 ts 文件转换为 mp4（视频）
/// 和 aac（音频）”的选项。App 里没有 ffmpeg，只能自己写一个纯 Dart 的
/// TS 解包 + MP4 打包器，只支持最常见的组合：H.264 视频 + AAC 音频
/// （r34、xhamster 的 HLS 都是这个组合，2026-11-09 VM 用 ffprobe
/// 实测确认：r34 分片 h264 1280x720 + aac 48kHz 立体声）。
///
/// 做法：
/// - TS 解包：PAT -> PMT -> 视频 PID（0x1B）/音频 PID（0x0F），PES 重组，
///   视频按 AUD/切片边界拼成 Access Unit（一个 AU = 一帧），音频按 ADTS
///   帧切分（每帧 1024 个采样）；
/// - 时间戳：视频用 PES 的 DTS/PTS（90kHz），stts 取 DTS 差分，
///   ctts 取 PTS-DTS（B 帧重排）；多分片拼成的文件在分片边界处 PTS
///   会回跳（每段从头开始），检测到回跳就加偏移量续上，保证单调递增；
/// - MP4 打包：ftyp + mdat（先全部视频采样、再全部音频采样，各自一段连续
///   chunk，stco 只要一个入口）+ moov（avcC 从 SPS/PPS 来，esds 从 ADTS
///   头来）。moov 在 mdat 后面（不是 faststart，本地文件无所谓）；
/// - 限制（写明，不假装）：只认 H.264 + AAC；其他编码（H.265、MP3、AC-3
///   等）直接抛错，调用方保留 .ts；加密 HLS 本来就下不下来，不到这一步；
///   文件超过 4GB 抛错（32 位 chunk 偏移）。
/// 验证：test/ts_remuxer_test.dart 用 r34 真分片（test/fixtures/）跑，
/// 再在 VM 里 ffprobe 验输出（时长、流、能播）。
class TsRemuxer {
  /// input .ts（已拼好的分片文件）-> output .mp4。
  /// 成功返回 (输出路径, 总时长毫秒, 视频帧数, 音频帧数)；
  /// 失败抛 StateError（调用方保留 .ts，别把下载标成失败）。
  static Future<({String outputPath, int durationMs, int videoSamples, int audioSamples})> remuxFile(
      String inputPath, String outputPath) async {
    final input = File(inputPath);
    if (!await input.exists()) throw StateError('找不到 .ts 文件');
    final tmpDir = await Directory.systemTemp.createTemp('ts_remux_');
    try {
      final videoTmp = File('${tmpDir.path}/v.bin');
      final audioTmp = File('${tmpDir.path}/a.bin');
      final demux = _TsDemuxer();
      await demux.demuxFile(input, videoTmp, audioTmp);
      if (demux.videoSamples.isEmpty) throw StateError('TS 里没有 H.264 视频帧');
      if (demux.sps == null || demux.pps == null) {
        throw StateError('TS 里没有 SPS/PPS，没法写 mp4');
      }
      final out = await _Mp4Writer.write(
        outputPath,
        videoTmp,
        audioTmp,
        demux.videoSamples,
        demux.audioSampleSizes,
        demux.sps!,
        demux.pps!,
        demux.audioConfig,
      );
      return (
        outputPath: out.outputPath,
        durationMs: out.durationMs,
        videoSamples: demux.videoSamples.length,
        audioSamples: demux.audioSampleCount,
      );
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// 一个视频采样（Access Unit = 一帧）的元数据。
/// 时间戳是 90kHz 单位、已做归一化（第一帧 DTS = 0）+ 断点续接。
class _VideoSample {
  final int offset; // 在视频临时文件里的偏移
  final int size;
  final int dts; // 90kHz，已归一化
  final int ctsOffset; // pts - dts（>= 0，B 帧重排）
  final bool keyframe;
  _VideoSample(this.offset, this.size, this.dts, this.ctsOffset, this.keyframe);
}

/// TS 解包器：读 .ts 文件，把视频/音频采样分别写进两个临时文件，
/// 只留元数据在内存里（大文件也不爆内存）。
class _TsDemuxer {
  int? _pmtPid;
  int? _videoPid;
  int? _audioPid;
  Uint8List? sps;
  Uint8List? pps;
  // 音频配置（从第一个 ADTS 帧来）：(objectType, sampleRate, channels)。
  ({int objectType, int sampleRate, int channels})? audioConfig;
  final List<_VideoSample> videoSamples = [];
  int audioSampleCount = 0;
  // 音频每帧大小（写 stsz 用；ADTS 帧长短不一，不能只记总数）。
  final List<int> audioSampleSizes = [];

  // PES 重组状态（每路 PID 一份）。
  final Map<int, _PesBuffer> _pes = {};
  // 当前正在拼的视频 AU（NAL 列表 + 它所属 PES 的时间戳）。
  final List<Uint8List> _auNals = [];
  int _auDts = 0;
  int _auPts = 0;
  bool _auHasSlice = false;
  bool _auKeyframe = false;
  int _pesSeq = 0; // PES 序号（切 AU 时判断是不是新的 PES）
  int _auPesSeq = -1; // 当前 AU 起始的 PES 序号
  int? _firstDts; // 第一帧 DTS（归一化用）
  // 时间戳断点续接（多分片拼成的文件在分片边界 PTS 回跳）。
  int _maxDts = -1;
  int _timeOffset = 0;
  int _lastDelta = 3000; // 30fps 一帧 3000 tick（90kHz）
  int _videoBytes = 0;

  Future<void> demuxFile(File input, File videoTmp, File audioTmp) async {
    final vSink = videoTmp.openWrite();
    final aSink = audioTmp.openWrite();
    try {
      final bytes = await input.readAsBytes();
      var i = 0;
      while (i + 188 <= bytes.length) {
        // 找同步字节（正常文件每 188 字节一个 0x47；丢包时逐字节找下一个）。
        if (bytes[i] != 0x47) {
          i++;
          continue;
        }
        _parsePacket(bytes, i, vSink, aSink);
        i += 188;
      }
      // 文件尾的 AU 也要落盘。
      _flushAu(vSink);
    } finally {
      await vSink.close();
      await aSink.close();
    }
  }

  void _parsePacket(Uint8List bytes, int off, IOSink vSink, IOSink aSink) {
    final pid = ((bytes[off + 1] & 0x1f) << 8) | bytes[off + 2];
    final pusi = (bytes[off + 1] >> 6) & 1;
    final afc = (bytes[off + 3] >> 4) & 3;
    if (afc == 0 || afc == 2) return; // 无 payload
    var p = off + 4;
    if (afc == 3) {
      final afl = bytes[p];
      p += 1 + afl;
      if (p >= off + 188) return;
    }
    if (pid == 0) {
      // PAT：找 PMT PID。
      if (pusi == 0 || _pmtPid != null) return;
      final ptr = bytes[p];
      final sec = p + 1 + ptr;
      if (sec + 12 > off + 188) return;
      final sectionLength = ((bytes[sec + 1] & 0x0f) << 8) | bytes[sec + 2];
      var o = sec + 8;
      final end = sec + 3 + sectionLength - 4;
      while (o + 4 <= end && o + 4 <= off + 188) {
        final program = (bytes[o] << 8) | bytes[o + 1];
        final ppid = ((bytes[o + 2] & 0x1f) << 8) | bytes[o + 3];
        if (program != 0) _pmtPid = ppid;
        o += 4;
      }
      return;
    }
    if (pid == _pmtPid) {
      // PMT：找视频/音频 PID。
      if (pusi == 0 || (_videoPid != null && _audioPid != null)) return;
      final ptr = bytes[p];
      final sec = p + 1 + ptr;
      if (sec + 12 > off + 188) return;
      final sectionLength = ((bytes[sec + 1] & 0x0f) << 8) | bytes[sec + 2];
      final programInfoLength = ((bytes[sec + 10] & 0x0f) << 8) | bytes[sec + 11];
      var o = sec + 12 + programInfoLength;
      final end = sec + 3 + sectionLength - 4;
      while (o + 5 <= end && o + 5 <= off + 188) {
        final type = bytes[o];
        final epid = ((bytes[o + 1] & 0x1f) << 8) | bytes[o + 2];
        final esInfoLength = ((bytes[o + 3] & 0x0f) << 8) | bytes[o + 4];
        if (type == 0x1b) _videoPid = epid;
        if (type == 0x0f) _audioPid = epid;
        o += 5 + esInfoLength;
      }
      return;
    }
    if (pid == _videoPid || pid == _audioPid) {
      final buf = _pes.putIfAbsent(pid, () => _PesBuffer());
      if (pusi == 1) {
        // 新 PES 开始：上一个先处理掉（视频 PES 长度常为 0，不能等长度收满）。
        _handlePes(pid, buf, vSink, aSink);
        buf.reset();
        buf.data.add(bytes.sublist(p, off + 188));
      } else {
        buf.data.add(bytes.sublist(p, off + 188));
      }
    }
  }

  void _handlePes(int pid, _PesBuffer buf, IOSink vSink, IOSink aSink) {
    final d = buf.data.toBytes();
    if (d.length < 9) return;
    if (d[0] != 0 || d[1] != 0 || d[2] != 1) return;
    final flags = d[7];
    final hlen = d[8];
    var pts = -1;
    var dts = -1;
    if ((flags & 0x80) != 0 && d.length >= 14) {
      pts = _parsePts(d, 9);
      if ((flags & 0x40) != 0 && d.length >= 19) dts = _parsePts(d, 14);
    }
    if (dts < 0) dts = pts;
    if (pts < 0 || dts < 0) return;
    final payloadStart = 9 + hlen;
    if (payloadStart >= d.length) return;
    final payload = Uint8List.sublistView(d, payloadStart);
    if (pid == _videoPid) {
      _handleVideoPes(payload, dts, pts, vSink);
    } else {
      _handleAudioPes(payload, aSink);
    }
  }

  int _parsePts(Uint8List d, int o) {
    return (((d[o] >> 1) & 7) << 30) |
        (d[o + 1] << 22) |
        (((d[o + 2] >> 1) & 0x7f) << 15) |
        (d[o + 3] << 7) |
        ((d[o + 4] >> 1) & 0x7f);
  }

  void _handleVideoPes(Uint8List payload, int dtsRaw, int ptsRaw, IOSink vSink) {
    _pesSeq++;
    // 断点续接：DTS 往回跳超过 1 秒，说明到了下一个分片（时间戳从头开始），
    // 加偏移量续上，保证输出时间戳单调递增。
    var dts = dtsRaw + _timeOffset;
    var pts = ptsRaw + _timeOffset;
    if (_maxDts >= 0 && dts < _maxDts - 90000) {
      _timeOffset += (_maxDts - dts) + _lastDelta;
      dts = dtsRaw + _timeOffset;
      pts = ptsRaw + _timeOffset;
    }
    if (dts > _maxDts) {
      if (_maxDts >= 0 && dts > _maxDts) _lastDelta = dts - _maxDts;
      _maxDts = dts;
    }
    // 按 NAL 切分：AUD（type 9）开新 AU；已有切片时再遇到切片也开新 AU
    // （但只在“新的 PES”里才这么切——一帧被拆成两个 PES 时，后一个 PES
    // 的切片是同一帧的延续，不能切；有 AUD 的流走 AUD 分支，本来就是准的）。
    var i = 0;
    while (i + 3 < payload.length) {
      final scLen = _startCodeLen(payload, i);
      if (scLen == 0) {
        i++;
        continue;
      }
      final nalStart = i + scLen;
      if (nalStart >= payload.length) break;
      // 找下一个 start code，确定本 NAL 的范围。
      var j = nalStart + 1;
      var next = -1;
      while (j + 3 < payload.length) {
        final l = _startCodeLen(payload, j);
        if (l > 0) {
          next = j;
          break;
        }
        j++;
      }
      final nalEnd = next < 0 ? payload.length : next;
      final nalType = payload[nalStart] & 0x1f;
      final nal = Uint8List.sublistView(payload, nalStart, nalEnd);
      if (nalType == 9) {
        // AUD：开新 AU（上一个先落盘）。
        _flushAu(vSink);
        _auDts = dts;
        _auPts = pts;
        _auPesSeq = _pesSeq;
      } else if ((nalType == 1 || nalType == 5) && _auHasSlice && _pesSeq != _auPesSeq) {
        // 新切片、旧 AU 已有切片、且是新的 PES：旧 AU 落盘，新 AU 从这个切片开始。
        _flushAu(vSink);
        _auDts = dts;
        _auPts = pts;
        _auPesSeq = _pesSeq;
      }
      if (nalType == 7 && sps == null) sps = Uint8List.fromList(nal);
      if (nalType == 8 && pps == null) pps = Uint8List.fromList(nal);
      if (nalType == 1 || nalType == 5) _auHasSlice = true;
      if (nalType == 5) _auKeyframe = true;
      _auNals.add(Uint8List.fromList(nal));
      i = nalEnd;
    }
  }

  /// start code 长度：00 00 01 -> 3，00 00 00 01 -> 4，否则 0。
  int _startCodeLen(Uint8List d, int i) {
    if (i + 2 < d.length && d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) return 3;
    if (i + 3 < d.length && d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1) return 4;
    return 0;
  }

  /// 当前 AU 落盘：NAL 前面改写成 4 字节大端长度（MP4 的格式），
  /// 不再是 TS 的 start code。DTS 归一化：第一帧 DTS = 0。
  void _flushAu(IOSink vSink) {
    if (_auNals.isEmpty) return;
    final out = BytesBuilder();
    for (final n in _auNals) {
      final len = ByteData(4)..setUint32(0, n.length);
      out.add(len.buffer.asUint8List());
      out.add(n);
    }
    final bytes = out.toBytes();
    vSink.add(bytes);
    _firstDts ??= _auDts;
    videoSamples.add(_VideoSample(
      _videoBytes,
      bytes.length,
      _auDts - _firstDts!,
      (_auPts - _auDts).clamp(0, 1 << 30),
      _auKeyframe,
    ));
    _videoBytes += bytes.length;
    _auNals.clear();
    _auHasSlice = false;
    _auKeyframe = false;
  }

  void _handleAudioPes(Uint8List payload, IOSink aSink) {
    // ADTS 帧：每帧一个采样（1024 采样点）。帧头 7 字节（有 CRC 时 9 字节）。
    var i = 0;
    while (i + 7 <= payload.length) {
      if (payload[i] != 0xff || (payload[i + 1] & 0xf0) != 0xf0) {
        i++;
        continue;
      }
      final protectionAbsent = payload[i + 1] & 1;
      final profile = (payload[i + 2] >> 6) & 3;
      final sfi = (payload[i + 2] >> 2) & 0x0f;
      final channels = ((payload[i + 2] & 1) << 2) | ((payload[i + 3] >> 6) & 3);
      final frameLen = ((payload[i + 3] & 3) << 11) | (payload[i + 4] << 3) | ((payload[i + 5] >> 5) & 7);
      if (frameLen < 7 || i + frameLen > payload.length) break;
      const sampleRates = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350,
      ];
      if (sfi < sampleRates.length && audioConfig == null) {
        audioConfig = (
          objectType: profile + 1,
          sampleRate: sampleRates[sfi],
          channels: channels,
        );
      }
      // ADTS 头（含 CRC）不要：MP4 里只要裸 AAC 帧数据。
      final headerLen = protectionAbsent == 1 ? 7 : 9;
      final frame = Uint8List.sublistView(payload, i + headerLen, i + frameLen);
      aSink.add(frame);
      audioSampleSizes.add(frame.length);
      audioSampleCount++;
      i += frameLen;
    }
  }
}

/// PES 重组缓冲（一个 PID 一份，跨多个 TS 包攒）。
class _PesBuffer {
  final BytesBuilder data = BytesBuilder();
  void reset() => data.clear();
}

/// ---- SPS 解析（取宽高，供 tkhd/avc1 用）----

class _BitReader {
  final Uint8List data;
  int _bytePos;
  int _bitPos = 0; // 0..7，当前字节里已读的位数
  _BitReader(this.data, this._bytePos);

  int readBit() {
    if (_bytePos >= data.length) throw StateError('SPS 读越界');
    final b = (data[_bytePos] >> (7 - _bitPos)) & 1;
    _bitPos++;
    if (_bitPos == 8) {
      _bitPos = 0;
      _bytePos++;
    }
    return b;
  }

  int readBits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | readBit();
    }
    return v;
  }

  int readUe() {
    var zeros = 0;
    while (readBit() == 0) {
      zeros++;
      if (zeros > 31) throw StateError('SPS 无效');
    }
    if (zeros == 0) return 0;
    return (1 << zeros) - 1 + readBits(zeros);
  }

  int readSe() {
    final ue = readUe();
    return ue.isOdd ? (ue + 1) ~/ 2 : -(ue ~/ 2);
  }
}

/// SPS -> (宽, 高)。解析失败抛 StateError。
({int width, int height}) _parseSps(Uint8List sps) {
  // NAL 头 1 字节（0x67）后面是 rbsp；先去掉 emulation prevention 字节。
  final rbsp = <int>[];
  for (var i = 1; i < sps.length; i++) {
    if (i + 2 < sps.length && sps[i] == 0 && sps[i + 1] == 0 && sps[i + 2] == 3) {
      rbsp.add(0);
      rbsp.add(0);
      i += 2;
    } else {
      rbsp.add(sps[i]);
    }
  }
  final r = _BitReader(Uint8List.fromList(rbsp), 0);
  final profile = r.readBits(8);
  r.readBits(8); // constraint flags
  r.readBits(8); // level
  r.readUe(); // sps id
  var chromaFormat = 1;
  if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile)) {
    chromaFormat = r.readUe();
    if (chromaFormat == 3) r.readBit();
    r.readUe(); // bit_depth_luma_minus8
    r.readUe(); // bit_depth_chroma_minus8
    r.readBit(); // qpprime_y_zero_transform_bypass
    if (r.readBit() == 1) {
      // seq_scaling_matrix_present：跳过各 scaling list。
      final n = chromaFormat != 3 ? 8 : 12;
      for (var i = 0; i < n; i++) {
        if (r.readBit() == 1) {
          final size = i < 6 ? 16 : 64;
          var lastScale = 8;
          var nextScale = 8;
          for (var j = 0; j < size; j++) {
            if (nextScale != 0) {
              final delta = r.readSe();
              nextScale = (lastScale + delta + 256) % 256;
            }
            lastScale = nextScale == 0 ? lastScale : nextScale;
          }
        }
      }
    }
  }
  r.readUe(); // log2_max_frame_num_minus4
  final pocType = r.readUe();
  if (pocType == 0) {
    r.readUe();
  } else if (pocType == 1) {
    r.readBit();
    r.readSe();
    r.readSe();
    final n = r.readUe();
    for (var i = 0; i < n; i++) {
      r.readSe();
    }
  }
  r.readUe(); // max_num_ref_frames
  r.readBit(); // gaps
  final wMbs = r.readUe();
  final hMap = r.readUe();
  final frameMbsOnly = r.readBit();
  if (frameMbsOnly == 0) r.readBit(); // mb_adaptive_frame_field
  r.readBit(); // direct_8x8_inference
  var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
  if (r.readBit() == 1) {
    cropLeft = r.readUe();
    cropRight = r.readUe();
    cropTop = r.readUe();
    cropBottom = r.readUe();
  }
  // 裁剪单位（4:2:0 最常见：x=2，y=2；逐行时 y 再乘 1，隔行乘 2）。
  var unitX = 1, unitY = 1;
  if (chromaFormat == 1) {
    unitX = 2;
    unitY = 2 * (2 - frameMbsOnly);
  } else if (chromaFormat == 2) {
    unitX = 2;
    unitY = 1 * (2 - frameMbsOnly);
  } else if (chromaFormat == 0) {
    unitX = 1;
    unitY = 2 - frameMbsOnly;
  }
  final width = (wMbs + 1) * 16 - (cropLeft + cropRight) * unitX;
  final height = (2 - frameMbsOnly) * (hMap + 1) * 16 - (cropTop + cropBottom) * unitY;
  if (width <= 0 || height <= 0) throw StateError('SPS 宽高无效');
  return (width: width, height: height);
}

/// ---- MP4 打包 ----

Uint8List _box(String type, Uint8List payload) {
  final b = BytesBuilder();
  final len = ByteData(4)..setUint32(0, payload.length + 8);
  b.add(len.buffer.asUint8List());
  b.add(type.codeUnits);
  b.add(payload);
  return b.toBytes();
}

Uint8List _fullBox(String type, int version, int flags, Uint8List payload) {
  final b = BytesBuilder();
  b.add([version, (flags >> 16) & 0xff, (flags >> 8) & 0xff, flags & 0xff]);
  b.add(payload);
  return _box(type, b.toBytes());
}

void _putU32(BytesBuilder b, int v) {
  final d = ByteData(4)..setUint32(0, v & 0xffffffff);
  b.add(d.buffer.asUint8List());
}

void _putU16(BytesBuilder b, int v) {
  final d = ByteData(2)..setUint16(0, v & 0xffff);
  b.add(d.buffer.asUint8List());
}

void _putU64(BytesBuilder b, int v) {
  final d = ByteData(8)..setUint64(0, v);
  b.add(d.buffer.asUint8List());
}

/// dinf：dref 是 FullBox（版本/标志 + entry_count=1），里面一个 url  box
///（flags=1 表示媒体在当前文件里）。之前写漏了 dref 自己的头，
///ffmpeg 会把 url box 的尺寸当成 entry_count 读出天文数字而拒读。
Uint8List _dinf() {
  final drefPayload = BytesBuilder();
  _putU32(drefPayload, 1); // entry_count
  drefPayload.add(_fullBox('url ', 0, 1, Uint8List(0)));
  return _box('dinf', _fullBox('dref', 0, 0, drefPayload.toBytes()));
}
List<int> _descrLen(int len) {
  var v = len;
  final stack = <int>[];
  stack.add(v & 0x7f);
  v >>= 7;
  while (v > 0) {
    stack.add(0x80 | (v & 0x7f));
    v >>= 7;
  }
  return stack.reversed.toList();
}

class _Mp4Writer {
  static Future<({String outputPath, int durationMs})> write(
    String outputPath,
    File videoTmp,
    File audioTmp,
    List<_VideoSample> videoSamples,
    List<int> audioSampleSizes,
    Uint8List sps,
    Uint8List pps,
    ({int objectType, int sampleRate, int channels})? audioConfig,
  ) async {
    final videoBytes = videoSamples.fold(0, (s, e) => s + e.size);
    final audioBytes = audioConfig == null ? 0 : audioSampleSizes.fold(0, (s, e) => s + e);
    final mdatSize = 8 + videoBytes + audioBytes;
    if (mdatSize >= 0xffffffff) throw StateError('文件超过 4GB，没法写 mp4');
    final dims = _parseSps(sps);
    // 视频时长（毫秒）：最后 DTS + 最后一帧时长。
    final lastDelta = _lastVideoDelta(videoSamples);
    final videoDurationMs = ((videoSamples.last.dts + lastDelta) * 1000) ~/ 90000;
    final audioDurationMs = audioConfig == null
        ? 0
        : (audioSampleSizes.length * 1024 * 1000) ~/ audioConfig.sampleRate;
    final durationMs = videoDurationMs > audioDurationMs ? videoDurationMs : audioDurationMs;

    final out = await File(outputPath).open(mode: FileMode.write);
    try {
      // ftyp
      final ftyp = _box('ftyp', Uint8List.fromList([
        ...'isom'.codeUnits, 0, 0, 2, 0,
        ...'isom'.codeUnits, ...'iso2'.codeUnits, ...'avc1'.codeUnits, ...'mp41'.codeUnits,
      ]));
      await out.writeFrom(ftyp);
      final videoChunkOffset = ftyp.length + 8;
      final audioChunkOffset = videoChunkOffset + videoBytes;
      // mdat 头 + 视频采样 + 音频采样（各一段连续 chunk）。
      final mdatHeader = ByteData(8)
        ..setUint32(0, mdatSize)
        ..setUint32(4, 0x6d646174); // 'mdat'
      await out.writeFrom(mdatHeader.buffer.asUint8List());
      await _copyFile(videoTmp, out);
      if (audioBytes > 0) await _copyFile(audioTmp, out);
      // moov
      final moov = _buildMoov(
        videoSamples, lastDelta, audioSampleSizes, audioConfig,
        sps, pps, dims, videoChunkOffset, audioChunkOffset, durationMs,
      );
      await out.writeFrom(moov);
    } finally {
      await out.close();
    }
    return (outputPath: outputPath, durationMs: durationMs);
  }

  static Future<void> _copyFile(File src, RandomAccessFile dst) async {
    final raf = await src.open();
    try {
      const chunk = 1 << 20;
      while (true) {
        final b = await raf.read(chunk);
        if (b.isEmpty) break;
        await dst.writeFrom(b);
      }
    } finally {
      await raf.close();
    }
  }

  static int _lastVideoDelta(List<_VideoSample> samples) {
    if (samples.length < 2) return 3000;
    for (var i = samples.length - 1; i >= 1; i--) {
      final d = samples[i].dts - samples[i - 1].dts;
      if (d > 0) return d;
    }
    return 3000;
  }

  /// stts：把连续相等的时长合并成 (count, delta) 条目。
  static List<(int, int)> _groupRuns(List<int> values) {
    final out = <(int, int)>[];
    for (final v in values) {
      if (out.isNotEmpty && out.last.$2 == v) {
        out[out.length - 1] = (out.last.$1 + 1, v);
      } else {
        out.add((1, v));
      }
    }
    return out;
  }

  static Uint8List _buildMoov(
    List<_VideoSample> videoSamples,
    int lastDelta,
    List<int> audioSampleSizes,
    ({int objectType, int sampleRate, int channels})? audioConfig,
    Uint8List sps,
    Uint8List pps,
    ({int width, int height}) dims,
    int videoChunkOffset,
    int audioChunkOffset,
    int durationMs,
  ) {
    // ---- 视频 stts/ctts/stss ----
    final deltas = <int>[];
    for (var i = 0; i < videoSamples.length - 1; i++) {
      final d = videoSamples[i + 1].dts - videoSamples[i].dts;
      deltas.add(d > 0 ? d : lastDelta);
    }
    if (videoSamples.isNotEmpty) deltas.add(lastDelta);
    final sttsRuns = _groupRuns(deltas);
    final cttsRuns = _groupRuns(videoSamples.map((s) => s.ctsOffset).toList());
    final hasCtts = cttsRuns.length != 1 || cttsRuns.first.$2 != 0;
    final keyframes = <int>[];
    for (var i = 0; i < videoSamples.length; i++) {
      if (videoSamples[i].keyframe) keyframes.add(i + 1);
    }
    final videoDuration = videoSamples.last.dts + lastDelta; // 90kHz

    final mvhdPayload = BytesBuilder();
    _putU32(mvhdPayload, 0); // creation
    _putU32(mvhdPayload, 0); // modification
    _putU32(mvhdPayload, 1000); // timescale
    _putU32(mvhdPayload, durationMs); // duration (ms)
    _putU32(mvhdPayload, 0x00010000); // rate 1.0
    _putU16(mvhdPayload, 0x0100); // volume 1.0
    _putU16(mvhdPayload, 0);
    _putU32(mvhdPayload, 0);
    _putU32(mvhdPayload, 0);
    // unity matrix
    for (final v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]) {
      _putU32(mvhdPayload, v);
    }
    for (var i = 0; i < 6; i++) {
      _putU32(mvhdPayload, 0);
    }
    _putU32(mvhdPayload, 3); // next track id
    final mvhd = _fullBox('mvhd', 0, 0, mvhdPayload.toBytes());

    final videoTrak = _buildVideoTrak(
      videoSamples, sttsRuns, hasCtts ? cttsRuns : null, keyframes,
      sps, pps, dims, videoChunkOffset, videoDuration, durationMs,
    );
    final traks = <Uint8List>[videoTrak];
    if (audioConfig != null && audioSampleSizes.isNotEmpty) {
      traks.add(_buildAudioTrak(
        audioSampleSizes, audioConfig, audioChunkOffset, durationMs,
      ));
    }
    final moovPayload = BytesBuilder();
    moovPayload.add(mvhd);
    for (final t in traks) {
      moovPayload.add(t);
    }
    return _box('moov', moovPayload.toBytes());
  }

  static Uint8List _buildVideoTrak(
    List<_VideoSample> samples,
    List<(int, int)> sttsRuns,
    List<(int, int)>? cttsRuns,
    List<int> keyframes,
    Uint8List sps,
    Uint8List pps,
    ({int width, int height}) dims,
    int chunkOffset,
    int trackDuration,
    int movieDurationMs,
  ) {
    final tkhdPayload = BytesBuilder();
    _putU32(tkhdPayload, 0);
    _putU32(tkhdPayload, 0);
    _putU32(tkhdPayload, 1); // track id
    _putU32(tkhdPayload, 0);
    _putU32(tkhdPayload, movieDurationMs); // duration (movie timescale 1000)
    _putU64(tkhdPayload, 0);
    _putU16(tkhdPayload, 0);
    _putU16(tkhdPayload, 0);
    _putU16(tkhdPayload, 0);
    _putU16(tkhdPayload, 0);
    for (final v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]) {
      _putU32(tkhdPayload, v);
    }
    _putU32(tkhdPayload, dims.width << 16);
    _putU32(tkhdPayload, dims.height << 16);
    final tkhd = _fullBox('tkhd', 0, 0x07, tkhdPayload.toBytes());

    final mdhdPayload = BytesBuilder();
    _putU32(mdhdPayload, 0);
    _putU32(mdhdPayload, 0);
    _putU32(mdhdPayload, 90000);
    _putU32(mdhdPayload, trackDuration);
    _putU16(mdhdPayload, 0x55c4); // 'und'
    _putU16(mdhdPayload, 0);
    final mdhd = _fullBox('mdhd', 0, 0, mdhdPayload.toBytes());

    final hdlrPayload = BytesBuilder();
    _putU32(hdlrPayload, 0);
    hdlrPayload.add('vide'.codeUnits);
    _putU32(hdlrPayload, 0);
    _putU32(hdlrPayload, 0);
    _putU32(hdlrPayload, 0);
    hdlrPayload.add('VideoHandler'.codeUnits);
    hdlrPayload.add([0]);
    final hdlr = _fullBox('hdlr', 0, 0, hdlrPayload.toBytes());

    final vmhdPayload = BytesBuilder();
    _putU16(vmhdPayload, 0);
    _putU16(vmhdPayload, 0);
    _putU16(vmhdPayload, 0);
    _putU16(vmhdPayload, 0);
    final vmhd = _fullBox('vmhd', 0, 1, vmhdPayload.toBytes());

    final dinf = _dinf();

    // avcC
    final avcc = BytesBuilder();
    avcc.add([1, sps[1], sps[2], sps[3], 0xff]);
    avcc.add([0xe1]);
    _putU16(avcc, sps.length);
    avcc.add(sps);
    avcc.add([1]);
    _putU16(avcc, pps.length);
    avcc.add(pps);
    final avcCBox = _box('avcC', avcc.toBytes());

    final avc1Payload = BytesBuilder();
    avc1Payload.add(List.filled(6, 0));
    _putU16(avc1Payload, 1); // data_reference_index
    avc1Payload.add(List.filled(16, 0));
    _putU16(avc1Payload, dims.width);
    _putU16(avc1Payload, dims.height);
    _putU32(avc1Payload, 0x00480000);
    _putU32(avc1Payload, 0x00480000);
    _putU32(avc1Payload, 0);
    _putU16(avc1Payload, 1); // frame count
    avc1Payload.add(List.filled(32, 0)); // compressor name
    _putU16(avc1Payload, 0x0018); // depth
    _putU16(avc1Payload, 0xffff);
    avc1Payload.add(avcCBox);
    final stsd = _fullBox('stsd', 0, 0, (() {
      final b = BytesBuilder();
      _putU32(b, 1);
      b.add(_box('avc1', avc1Payload.toBytes()));
      return b.toBytes();
    })());

    final sttsPayload = BytesBuilder();
    _putU32(sttsPayload, sttsRuns.length);
    for (final r in sttsRuns) {
      _putU32(sttsPayload, r.$1);
      _putU32(sttsPayload, r.$2);
    }
    final stts = _fullBox('stts', 0, 0, sttsPayload.toBytes());

    Uint8List? stss;
    if (keyframes.isNotEmpty) {
      final b = BytesBuilder();
      _putU32(b, keyframes.length);
      for (final k in keyframes) {
        _putU32(b, k);
      }
      stss = _fullBox('stss', 0, 0, b.toBytes());
    }

    Uint8List? ctts;
    if (cttsRuns != null) {
      final b = BytesBuilder();
      _putU32(b, cttsRuns.length);
      for (final r in cttsRuns) {
        _putU32(b, r.$1);
        _putU32(b, r.$2);
      }
      ctts = _fullBox('ctts', 0, 0, b.toBytes());
    }

    final stszPayload = BytesBuilder();
    _putU32(stszPayload, 0);
    _putU32(stszPayload, samples.length);
    for (final s in samples) {
      _putU32(stszPayload, s.size);
    }
    final stsz = _fullBox('stsz', 0, 0, stszPayload.toBytes());

    final stscPayload = BytesBuilder();
    _putU32(stscPayload, 1);
    _putU32(stscPayload, 1);
    _putU32(stscPayload, samples.length);
    _putU32(stscPayload, 1);
    final stsc = _fullBox('stsc', 0, 0, stscPayload.toBytes());

    final stcoPayload = BytesBuilder();
    _putU32(stcoPayload, 1);
    _putU32(stcoPayload, chunkOffset);
    final stco = _fullBox('stco', 0, 0, stcoPayload.toBytes());

    final stblPayload = BytesBuilder();
    stblPayload.add(stsd);
    stblPayload.add(stts);
    if (ctts != null) stblPayload.add(ctts);
    if (stss != null) stblPayload.add(stss);
    stblPayload.add(stsz);
    stblPayload.add(stsc);
    stblPayload.add(stco);
    final stbl = _box('stbl', stblPayload.toBytes());

    final minfPayload = BytesBuilder();
    minfPayload.add(vmhd);
    minfPayload.add(dinf);
    minfPayload.add(stbl);
    final minf = _box('minf', minfPayload.toBytes());

    final mdiaPayload = BytesBuilder();
    mdiaPayload.add(mdhd);
    mdiaPayload.add(hdlr);
    mdiaPayload.add(minf);
    final mdia = _box('mdia', mdiaPayload.toBytes());

    final trakPayload = BytesBuilder();
    trakPayload.add(tkhd);
    trakPayload.add(mdia);
    return _box('trak', trakPayload.toBytes());
  }

  static Uint8List _buildAudioTrak(
    List<int> sampleSizes,
    ({int objectType, int sampleRate, int channels}) cfg,
    int chunkOffset,
    int movieDurationMs,
  ) {
    final sampleCount = sampleSizes.length;
    final trackDuration = sampleCount * 1024;
    final tkhdPayload = BytesBuilder();
    _putU32(tkhdPayload, 0);
    _putU32(tkhdPayload, 0);
    _putU32(tkhdPayload, 2); // track id
    _putU32(tkhdPayload, 0);
    _putU32(tkhdPayload, movieDurationMs);
    _putU64(tkhdPayload, 0);
    _putU16(tkhdPayload, 0);
    _putU16(tkhdPayload, 0);
    _putU16(tkhdPayload, 0);
    _putU16(tkhdPayload, 0);
    for (final v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]) {
      _putU32(tkhdPayload, v);
    }
    _putU32(tkhdPayload, 0);
    _putU32(tkhdPayload, 0);
    final tkhd = _fullBox('tkhd', 0, 0x07, tkhdPayload.toBytes());

    final mdhdPayload = BytesBuilder();
    _putU32(mdhdPayload, 0);
    _putU32(mdhdPayload, 0);
    _putU32(mdhdPayload, cfg.sampleRate);
    _putU32(mdhdPayload, trackDuration);
    _putU16(mdhdPayload, 0x55c4);
    _putU16(mdhdPayload, 0);
    final mdhd = _fullBox('mdhd', 0, 0, mdhdPayload.toBytes());

    final hdlrPayload = BytesBuilder();
    _putU32(hdlrPayload, 0);
    hdlrPayload.add('soun'.codeUnits);
    _putU32(hdlrPayload, 0);
    _putU32(hdlrPayload, 0);
    _putU32(hdlrPayload, 0);
    hdlrPayload.add('SoundHandler'.codeUnits);
    hdlrPayload.add([0]);
    final hdlr = _fullBox('hdlr', 0, 0, hdlrPayload.toBytes());

    final smhdPayload = BytesBuilder();
    _putU16(smhdPayload, 0);
    _putU16(smhdPayload, 0);
    final smhd = _fullBox('smhd', 0, 0, smhdPayload.toBytes());

    final dinf = _dinf();

    // AudioSpecificConfig：objectType(5) + samplingIndex(4) + channels(4) + 3 位 0。
    const sampleRateIndex = {
      96000: 0, 88200: 1, 64000: 2, 48000: 3, 44100: 4, 32000: 5,
      24000: 6, 22050: 7, 16000: 8, 12000: 9, 11025: 10, 8000: 11, 7350: 12,
    };
    final sfi = sampleRateIndex[cfg.sampleRate] ?? 3;
    final asc = [
      ((cfg.objectType << 3) | (sfi >> 1)) & 0xff,
      (((sfi & 1) << 7) | (cfg.channels << 3)) & 0xff,
    ];
    final esdsPayload = BytesBuilder();
    _putU32(esdsPayload, 0); // version/flags
    // ES_Descriptor (0x03)
    final decSpecific = <int>[0x05, ..._descrLen(asc.length), ...asc];
    final decConfig = <int>[
      0x04, ..._descrLen(13 + decSpecific.length),
      0x40, // objectTypeIndication: AAC
      0x15, // streamType audio + upstream 0 + reserved 1
      0, 0, 0, // bufferSizeDB
      0, 0, 0, 0, // maxBitrate
      0, 0, 0, 0, // avgBitrate
      ...decSpecific,
    ];
    final esDesc = <int>[
      0x03, ..._descrLen(3 + decConfig.length + 2),
      0, 1, // ES_ID
      0, // flags
      ...decConfig,
      0x06, 1, 0x02, // SLConfigDescriptor
    ];
    esdsPayload.add(esDesc);
    final esds = _fullBox('esds', 0, 0, esdsPayload.toBytes());

    final mp4aPayload = BytesBuilder();
    mp4aPayload.add(List.filled(6, 0));
    _putU16(mp4aPayload, 1);
    mp4aPayload.add(List.filled(8, 0));
    _putU16(mp4aPayload, cfg.channels);
    _putU16(mp4aPayload, 16);
    _putU16(mp4aPayload, 0);
    _putU16(mp4aPayload, 0);
    _putU32(mp4aPayload, cfg.sampleRate << 16);
    mp4aPayload.add(esds);
    final stsd = _fullBox('stsd', 0, 0, (() {
      final b = BytesBuilder();
      _putU32(b, 1);
      b.add(_box('mp4a', mp4aPayload.toBytes()));
      return b.toBytes();
    })());

    final sttsPayload = BytesBuilder();
    _putU32(sttsPayload, 1);
    _putU32(sttsPayload, sampleCount);
    _putU32(sttsPayload, 1024);
    final stts = _fullBox('stts', 0, 0, sttsPayload.toBytes());

    final stszPayload = BytesBuilder();
    _putU32(stszPayload, 0);
    _putU32(stszPayload, sampleCount);
    for (final s in sampleSizes) {
      _putU32(stszPayload, s);
    }
    final stsz = _fullBox('stsz', 0, 0, stszPayload.toBytes());

    final stscPayload = BytesBuilder();
    _putU32(stscPayload, 1);
    _putU32(stscPayload, 1);
    _putU32(stscPayload, sampleCount);
    _putU32(stscPayload, 1);
    final stsc = _fullBox('stsc', 0, 0, stscPayload.toBytes());

    final stcoPayload = BytesBuilder();
    _putU32(stcoPayload, 1);
    _putU32(stcoPayload, chunkOffset);
    final stco = _fullBox('stco', 0, 0, stcoPayload.toBytes());

    final stblPayload = BytesBuilder();
    stblPayload.add(stsd);
    stblPayload.add(stts);
    stblPayload.add(stsz);
    stblPayload.add(stsc);
    stblPayload.add(stco);
    final stbl = _box('stbl', stblPayload.toBytes());

    final minfPayload = BytesBuilder();
    minfPayload.add(smhd);
    minfPayload.add(dinf);
    minfPayload.add(stbl);
    final minf = _box('minf', minfPayload.toBytes());

    final mdiaPayload = BytesBuilder();
    mdiaPayload.add(mdhd);
    mdiaPayload.add(hdlr);
    mdiaPayload.add(minf);
    final mdia = _box('mdia', mdiaPayload.toBytes());

    final trakPayload = BytesBuilder();
    trakPayload.add(tkhd);
    trakPayload.add(mdia);
    return _box('trak', trakPayload.toBytes());
  }
}
