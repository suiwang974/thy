import 'dart:io';
import 'dart:typed_data';

import 'package:taohuayuan/services/apk_verify.dart';

/// 手造最小 ZIP 夹具（stored + deflated 各一条），供 apk_verify 测试用。
/// 不依赖 archive 包，免得测试多一个依赖。
Uint8List buildTestZip({
  required String storedName,
  required Uint8List storedData,
  required String deflatedName,
  required Uint8List deflatedData,
}) {
  final out = BytesBuilder();
  void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) => out.add(
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  final entries = <_Entry>[];
  void addLocal(String name, Uint8List raw, int method, List<int> comp) {
    final nameBytes = name.codeUnits;
    final offset = out.length;
    out.add([0x50, 0x4B, 0x03, 0x04]);
    u16(20);
    u16(0);
    u16(method);
    u16(0);
    u16(0);
    u32(crc32(raw));
    u32(comp.length);
    u32(raw.length);
    u16(nameBytes.length);
    u16(0);
    out.add(nameBytes);
    out.add(comp);
    entries.add(_Entry(
        name: name,
        method: method,
        crc: crc32(raw),
        compSize: comp.length,
        uncompSize: raw.length,
        localOffset: offset));
  }

  addLocal(storedName, storedData, 0, storedData);
  final comp = ZLibCodec(raw: true).encode(deflatedData);
  addLocal(deflatedName, deflatedData, 8, comp);

  final cdOffset = out.length;
  for (final e in entries) {
    final nameBytes = e.name.codeUnits;
    out.add([0x50, 0x4B, 0x01, 0x02]);
    u16(20);
    u16(20);
    u16(0);
    u16(e.method);
    u16(0);
    u16(0);
    u32(e.crc);
    u32(e.compSize);
    u32(e.uncompSize);
    u16(nameBytes.length);
    u16(0);
    u16(0);
    u16(0);
    u16(0);
    u32(0);
    u32(e.localOffset);
    out.add(nameBytes);
  }
  final cdSize = out.length - cdOffset;
  out.add([0x50, 0x4B, 0x05, 0x06]);
  u16(0);
  u16(0);
  u16(entries.length);
  u16(entries.length);
  u32(cdSize);
  u32(cdOffset);
  u16(0);
  return out.toBytes();
}

class _Entry {
  final String name;
  final int method;
  final int crc;
  final int compSize;
  final int uncompSize;
  final int localOffset;
  _Entry({
    required this.name,
    required this.method,
    required this.crc,
    required this.compSize,
    required this.uncompSize,
    required this.localOffset,
  });
}
