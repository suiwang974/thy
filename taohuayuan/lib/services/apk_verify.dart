import 'dart:io';
import 'dart:typed_data';

/// 安装包完整性校验（第 57 条）。
///
/// 背景：v11 的 App 内更新下出来的包大小对（20.7MB）但内容坏了，
/// 系统安装器报「安装包已损坏」。附件本身没问题，坏在下载组装：
/// 多段同时往同一个文件里写，`FileMode.write` 打开就截断，
/// 后开的段把先开的段已写好的数据清掉；又因为预分配把文件截到满大小，
/// 「长度 == 总大小」这关永远通过，坏包就这么交给了安装器。
/// 所以只看大小不够：装之前必须验 ZIP 结构 + 每条记录的 CRC，
/// 坏了就重下，绝不把坏包交给系统安装器。
/// （GitHub Releases API 不给附件的 sha256，App 侧拿不到期望值，
/// 所以用 ZIP 自身的 CRC 校验，不对 sha256。）

/// CRC-32（IEEE），可增量喂数据。
class Crc32 {
  static final _table = List<int>.generate(256, (i) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    return c;
  });

  int _crc = 0xFFFFFFFF;

  void add(List<int> bytes) {
    for (final b in bytes) {
      _crc = _table[(_crc ^ b) & 0xFF] ^ (_crc >>> 8);
    }
  }

  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 一次性算 CRC-32。
int crc32(List<int> bytes) {
  final c = Crc32();
  c.add(bytes);
  return c.value;
}

int _u16(List<int> b, int off) => b[off] | (b[off + 1] << 8);

int _u32(List<int> b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

bool _isSig(List<int> b, int off, List<int> sig) {
  if (b.length < off + sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[off + i] != sig[i]) return false;
  }
  return true;
}

/// 从 raf 的 offset 处读满 length 字节（读不满算失败，抛错）。
Future<Uint8List> _readExact(RandomAccessFile raf, int offset, int length) async {
  await raf.setPosition(offset);
  final out = Uint8List(length);
  var got = 0;
  while (got < length) {
    final n = await raf.readInto(out, got, length - got);
    if (n == 0) throw StateError('文件提前结束（要 $length 字节，只读到 $got）');
    got += n;
  }
  return out;
}

/// 验一个文件是不是完整可用的 APK（ZIP）。
/// 返回 null = 通过；返回字符串 = 不通过的原因（人话，给 UI/日志用）。
/// 验：大小（给了期望值才验）、开头是 ZIP 本地头、EOCD 找得到、
/// 中央目录位置自洽、每条记录的本地头对得上、每条数据的 CRC 对得上
/// （stored 直接算，deflated 先解压再算；其他压缩方式不认）。
Future<String?> verifyApkFile(String path, {int? expectedSize}) async {
  final file = File(path);
  if (!await file.exists()) return '安装包不存在';
  final size = await file.length();
  if (size <= 0) return '安装包是空文件';
  if (expectedSize != null && expectedSize > 0 && size != expectedSize) {
    return '大小不对（$size / 应为 $expectedSize）';
  }
  RandomAccessFile? raf;
  try {
    raf = await file.open(mode: FileMode.read);
    // 1. 开头必须是 ZIP 本地文件头 PK\x03\x04。
    final head = await _readExact(raf, 0, 4);
    if (!_isSig(head, 0, [0x50, 0x4B, 0x03, 0x04])) {
      return '不是有效的安装包（开头不是 ZIP）';
    }
    // 2. 找 EOCD（PK\x05\x06，在文件尾 64KB+22 字节里从后往前找，
    // ZIP 注释最多 64KB，所以这个窗口够）。
    final tailLen = size < 65557 + 22 ? size : 65557 + 22;
    final tail = await _readExact(raf, size - tailLen, tailLen);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_isSig(tail, i, [0x50, 0x4B, 0x05, 0x06])) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return '安装包结构不完整（找不到 ZIP 结束标记）';
    final eocdOff = size - tailLen + eocd;
    final cdCount = _u16(tail, eocd + 10);
    final cdSize = _u32(tail, eocd + 12);
    final cdOffset = _u32(tail, eocd + 16);
    // APK 签名块在中央目录前面，中央目录必须正好顶到 EOCD。
    if (cdOffset + cdSize != eocdOff) return '安装包中央目录位置不对';
    if (cdCount == 0) return '安装包里没有文件记录';
    // 3. 逐条中央目录。
    var p = cdOffset;
    for (var n = 0; n < cdCount; n++) {
      final h = await _readExact(raf, p, 46);
      if (!_isSig(h, 0, [0x50, 0x4B, 0x01, 0x02])) {
        return '安装包中央目录损坏（第 $n 条）';
      }
      final method = _u16(h, 10);
      final crc = _u32(h, 16);
      final compSize = _u32(h, 20);
      final uncompSize = _u32(h, 24);
      final nameLen = _u16(h, 28);
      final extraLen = _u16(h, 30);
      final commentLen = _u16(h, 32);
      final localOff = _u32(h, 42);
      final lh = await _readExact(raf, localOff, 30);
      if (!_isSig(lh, 0, [0x50, 0x4B, 0x03, 0x04])) {
        return '安装包本地文件头损坏（第 $n 条）';
      }
      final lhNameLen = _u16(lh, 26);
      final lhExtraLen = _u16(lh, 28);
      final dataOff = localOff + 30 + lhNameLen + lhExtraLen;
      if (dataOff + compSize > size) return '安装包数据越界（第 $n 条）';
      if (method == 0) {
        // stored：分段算 CRC，不把整条读进内存。
        final c = Crc32();
        var remaining = compSize;
        var pos = dataOff;
        while (remaining > 0) {
          final chunk = remaining > 65536 ? 65536 : remaining;
          c.add(await _readExact(raf, pos, chunk));
          pos += chunk;
          remaining -= chunk;
        }
        if (c.value != crc) return '安装包内容校验失败（第 $n 条，CRC 对不上）';
      } else if (method == 8) {
        // deflated：ZIP 用 raw deflate（不带 zlib 头）。
        final comp = await _readExact(raf, dataOff, compSize);
        List<int> raw;
        try {
          raw = ZLibDecoder(raw: true).convert(comp);
        } catch (_) {
          return '安装包内容解压失败（第 $n 条）';
        }
        if (raw.length != uncompSize) return '安装包解压后大小不对（第 $n 条）';
        if (crc32(raw) != crc) return '安装包内容校验失败（第 $n 条，CRC 对不上）';
      } else {
        return '安装包用了不支持的压缩方式（第 $n 条）';
      }
      p += 46 + nameLen + extraLen + commentLen;
    }
    if (p != cdOffset + cdSize) return '安装包中央目录长度不对';
    return null;
  } on StateError catch (e) {
    return '安装包读取失败：${e.message}';
  } catch (e) {
    return '安装包校验失败：$e';
  } finally {
    await raf?.close();
  }
}
