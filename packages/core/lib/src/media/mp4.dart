import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

/// Random-access port: native files and in-memory fixtures use the same parser.
abstract interface class SampleStore {
  int get length;
  Uint8List read(int offset, int length);
  void write(int offset, Uint8List bytes);
}

class MemorySampleStore implements SampleStore {
  final Uint8List bytes;
  MemorySampleStore(this.bytes);
  @override
  int get length => bytes.length;
  @override
  Uint8List read(int offset, int length) =>
      Uint8List.fromList(bytes.sublist(offset, offset + length));
  @override
  void write(int offset, Uint8List value) =>
      bytes.setRange(offset, offset + value.length, value);
}

class Mp4Box {
  final String type;
  final int start, size, header;
  final List<Mp4Box> children;
  const Mp4Box(this.type, this.start, this.size, this.header, this.children);
  int get payload => start + header;
  int get end => start + size;
  Mp4Box? child(String type) =>
      children.where((b) => b.type == type).firstOrNull;
  Iterable<Mp4Box> get descendants sync* {
    for (final child in children) {
      yield child;
      yield* child.descendants;
    }
  }

  Mp4Box? find(String type) =>
      descendants.where((b) => b.type == type).firstOrNull;
}

class _View {
  final Uint8List bytes;
  final int base;
  _View(this.bytes, this.base);
  void need(int at, int size) {
    if (at < base || size < 0 || at + size > base + bytes.length) {
      throw const FormatException('Truncated MP4 metadata');
    }
  }

  int u8(int p) {
    need(p, 1);
    return bytes[p - base];
  }

  int u16(int p) {
    need(p, 2);
    return ByteData.sublistView(bytes).getUint16(p - base);
  }

  int u32(int p) {
    need(p, 4);
    return ByteData.sublistView(bytes).getUint32(p - base);
  }

  int u64(int p) {
    need(p, 8);
    final value = (BigInt.from(u32(p)) << 32) | BigInt.from(u32(p + 4));
    if (value > BigInt.parse('9007199254740991')) {
      throw const FormatException('MP4 offset exceeds supported range');
    }
    return value.toInt();
  }

  Uint8List slice(int p, int length) {
    need(p, length);
    return Uint8List.fromList(bytes.sublist(p - base, p - base + length));
  }

  String text(int p, int size) => convert.latin1.decode(slice(p, size));
}

const _containers = {
  'moov',
  'trak',
  'mdia',
  'minf',
  'stbl',
  'edts',
  'dinf',
  'sinf',
  'schi',
  'mvex',
};
List<Mp4Box> _boxes(_View view, int start, int end, [int depth = 0]) {
  if (depth > 24) throw const FormatException('MP4 box nesting too deep');
  final out = <Mp4Box>[];
  var p = start;
  while (p < end) {
    if (end - p < 8) throw const FormatException('Truncated MP4 box header');
    var size = view.u32(p), header = 8;
    final type = view.text(p + 4, 4);
    if (size == 1) {
      size = view.u64(p + 8);
      header = 16;
    }
    if (size == 0) size = end - p;
    if (size < header || size > end - p) {
      throw const FormatException('Invalid MP4 box length');
    }
    var childStart = -1;
    if (_containers.contains(type)) childStart = p + header;
    if (type == 'stsd') {
      view.need(p + header, 8);
      childStart = p + header + 8;
    }
    if (['encv', 'avc1', 'avc3', 'hvc1', 'hev1'].contains(type)) {
      childStart = p + header + 78;
    }
    if (['enca', 'mp4a'].contains(type)) {
      final version = view.u16(p + header + 8);
      childStart =
          p +
          header +
          (version == 1
              ? 44
              : version == 2
              ? 64
              : 28);
    }
    if (childStart > p + size) {
      throw const FormatException('Truncated sample entry');
    }
    final children = childStart >= 0
        ? _boxes(view, childStart, p + size, depth + 1)
        : <Mp4Box>[];
    out.add(Mp4Box(type, p, size, header, children));
    p += size;
  }
  return out;
}

class Subsample {
  final int clear, encrypted;
  const Subsample(this.clear, this.encrypted);
}

class SampleEncryption {
  final Uint8List iv;
  final List<Subsample> subsamples;
  const SampleEncryption(this.iv, this.subsamples);
}

class Mp4Track {
  final String handler, codec;
  final int nalLength;
  final List<int> offsets, sizes;
  final List<SampleEncryption> encryption;
  const Mp4Track(
    this.handler,
    this.codec,
    this.nalLength,
    this.offsets,
    this.sizes,
    this.encryption,
  );
  bool get encrypted => encryption.isNotEmpty;
}

class Mp4Plan {
  final Mp4Box moov;
  final List<Mp4Box> top;
  final Uint8List metadata;
  final List<Mp4Track> tracks;
  const Mp4Plan(this.moov, this.top, this.metadata, this.tracks);
  int get encryptedSamples => tracks.fold(0, (n, t) => n + t.encryption.length);
}

/// Non-fragmented CENC AES-CTR. CBCS/pattern encryption is rejected explicitly.
class Mp4Cenc {
  static Mp4Plan inspect(
    SampleStore store, {
    int maxMoovBytes = 64 * 1024 * 1024,
  }) {
    final top = <Mp4Box>[];
    var p = 0;
    Mp4Box? moov;
    while (p < store.length) {
      if (store.length - p < 8) {
        throw const FormatException('Truncated MP4 file');
      }
      final h = _View(
        store.read(p, store.length - p < 16 ? store.length - p : 16),
        p,
      );
      var size = h.u32(p), header = 8;
      final type = h.text(p + 4, 4);
      if (size == 1) {
        size = h.u64(p + 8);
        header = 16;
      }
      if (size == 0) size = store.length - p;
      if (size < header || size > store.length - p) {
        throw const FormatException('Invalid top-level box');
      }
      final box = Mp4Box(type, p, size, header, []);
      top.add(box);
      if (type == 'moof') {
        throw UnsupportedError('Fragmented MP4 is not supported');
      }
      if (type == 'moov') {
        if (moov != null) throw const FormatException('Multiple moov boxes');
        moov = box;
      }
      p += size;
    }
    if (moov == null || !top.any((b) => b.type == 'mdat')) {
      throw const FormatException('MP4 needs moov and mdat');
    }
    if (moov.size > maxMoovBytes) {
      throw const FormatException('MP4 metadata exceeds memory budget');
    }
    final metadata = store.read(moov.start, moov.size);
    final v = _View(metadata, moov.start);
    final parsed = _boxes(v, moov.start, moov.end).single;
    if (parsed.find('mvex') != null) {
      throw UnsupportedError('Fragmented MP4 initialization is not supported');
    }
    final tracks = <Mp4Track>[];
    for (final trak in parsed.children.where((b) => b.type == 'trak')) {
      final stbl = trak.find('stbl'), hdlr = trak.find('hdlr');
      if (stbl == null || hdlr == null) continue;
      final handler = v.text(hdlr.payload + 8, 4);
      final stsd = stbl.child('stsd');
      if (stsd == null || stsd.children.length != 1) {
        throw UnsupportedError('Expected one sample description per track');
      }
      final entry = stsd.children.single;
      final sinf = entry.child('sinf');
      final frma = sinf?.child('frma');
      final codec = frma == null ? entry.type : v.text(frma.payload, 4);
      final avcc = entry.child('avcC'), hvcc = entry.child('hvcC');
      final nalLength = avcc != null
          ? (v.u8(avcc.payload + 4) & 3) + 1
          : hvcc != null && hvcc.size >= 30
          ? (v.u8(hvcc.payload + 21) & 3) + 1
          : 4;
      final sizes = _sizes(v, stbl);
      if (sizes.isEmpty) continue;
      final offsets = _offsets(v, stbl, sizes);
      for (var i = 0; i < sizes.length; i++) {
        if (sizes[i] > 32 * 1024 * 1024) {
          throw const FormatException('Sample exceeds memory budget');
        }
        if (!top
            .where((b) => b.type == 'mdat')
            .any(
              (b) => offsets[i] >= b.payload && offsets[i] + sizes[i] <= b.end,
            )) {
          throw const FormatException('Sample lies outside mdat');
        }
      }
      var encryption = <SampleEncryption>[];
      if (entry.type == 'encv' || entry.type == 'enca') {
        if (sinf == null || frma == null) {
          throw const FormatException('Encrypted entry has no original codec');
        }
        final schm = sinf.child('schm'), tenc = sinf.find('tenc');
        if (schm == null || v.text(schm.payload + 4, 4) != 'cenc') {
          throw UnsupportedError('Only CENC AES-CTR is supported');
        }
        if (tenc == null) throw const FormatException('Missing tenc');
        final ivSize = _ivSize(v, tenc);
        final senc = stbl.child('senc') ?? trak.find('senc');
        if (senc == null) {
          throw UnsupportedError(
            'External auxiliary IV tables are not supported',
          );
        }
        encryption = _encryption(v, senc, sizes, ivSize);
      }
      tracks.add(
        Mp4Track(handler, codec, nalLength, offsets, sizes, encryption),
      );
    }
    if (tracks.isEmpty) {
      throw const FormatException('No supported MP4 sample tables');
    }
    final spans = <({int start, int end})>[];
    for (final track in tracks) {
      if (spans.length + track.sizes.length > 2000000) {
        throw const FormatException('Excessive total sample count');
      }
      for (var i = 0; i < track.sizes.length; i++) {
        if (track.sizes[i] > 0) {
          spans.add((
            start: track.offsets[i],
            end: track.offsets[i] + track.sizes[i],
          ));
        }
      }
    }
    spans.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < spans.length; i++) {
      if (spans[i].start < spans[i - 1].end) {
        throw const FormatException('Overlapping MP4 samples');
      }
    }
    return Mp4Plan(parsed, top, metadata, tracks);
  }

  static List<int> _sizes(_View v, Mp4Box stbl) {
    final box = stbl.child('stsz');
    if (box == null) {
      throw UnsupportedError('Compact sample-size tables are not supported');
    }
    final p = box.payload, uniform = v.u32(p + 4), count = v.u32(p + 8);
    if (count > 2000000) throw const FormatException('Excessive sample count');
    if (uniform == 0 && 12 + count * 4 > box.size - box.header) {
      throw const FormatException('Truncated stsz');
    }
    return List.generate(
      count,
      (i) => uniform == 0 ? v.u32(p + 12 + i * 4) : uniform,
    );
  }

  static List<int> _offsets(_View v, Mp4Box stbl, List<int> sizes) {
    final sc = stbl.child('stsc'),
        co = stbl.child('stco') ?? stbl.child('co64');
    if (sc == null || co == null) {
      throw const FormatException('Missing sample/chunk tables');
    }
    final count = v.u32(sc.payload + 4),
        chunks = v.u32(co.payload + 4),
        wide = co.type == 'co64';
    if (count == 0 ||
        count > sizes.length ||
        chunks > sizes.length ||
        8 + count * 12 > sc.size - sc.header ||
        8 + chunks * (wide ? 8 : 4) > co.size - co.header) {
      throw const FormatException('Invalid chunk table');
    }
    final mappings = <({int first, int samples})>[];
    for (var i = 0; i < count; i++) {
      final at = sc.payload + 8 + i * 12,
          first = v.u32(at),
          samples = v.u32(at + 4),
          description = v.u32(at + 8);
      if (first < 1 ||
          samples < 1 ||
          description != 1 ||
          (i == 0 && first != 1) ||
          (i > 0 && first <= mappings.last.first) ||
          first > chunks) {
        throw const FormatException('Invalid stsc entry');
      }
      mappings.add((first: first, samples: samples));
    }
    final offsets = <int>[];
    var map = 0;
    for (var chunk = 1; chunk <= chunks; chunk++) {
      if (map + 1 < mappings.length && chunk >= mappings[map + 1].first) map++;
      final at = co.payload + 8 + (chunk - 1) * (wide ? 8 : 4);
      var offset = wide ? v.u64(at) : v.u32(at);
      for (var i = 0; i < mappings[map].samples; i++) {
        if (offsets.length >= sizes.length) {
          throw const FormatException('Chunk has excess samples');
        }
        offsets.add(offset);
        offset += sizes[offsets.length - 1];
      }
    }
    if (offsets.length != sizes.length) {
      throw const FormatException('Incomplete sample offsets');
    }
    return offsets;
  }

  static int _ivSize(_View v, Mp4Box tenc) {
    final p = tenc.payload;
    // Original Hongguo fixture has a compact, nonstandard tenc v0 layout.
    if (tenc.size - tenc.header == 21) {
      final size = v.u8(p + 4);
      if (size == 8 || size == 16) return size;
    }
    v.need(p, 23);
    final version = v.u8(p);
    if (version > 1) throw UnsupportedError('Unsupported tenc version');
    if (version == 1 && v.u8(p + 4) != 0) {
      throw UnsupportedError('Pattern encryption is not supported');
    }
    final legacyReserved = tenc.size - tenc.header == 24;
    final size = v.u8(p + (legacyReserved ? 7 : 6)),
        protected = v.u8(p + (legacyReserved ? 6 : 5));
    if (protected != 1 || !([8, 16].contains(size))) {
      throw UnsupportedError('Unsupported constant/default IV');
    }
    return size;
  }

  static List<SampleEncryption> _encryption(
    _View v,
    Mp4Box senc,
    List<int> sizes,
    int ivSize,
  ) {
    final p = senc.payload, flags = v.u32(p) & 0xffffff;
    if ((flags & ~2) != 0) throw UnsupportedError('Unsupported senc flags');
    final count = v.u32(p + 4), hasSubsamples = (flags & 2) != 0;
    if (count != sizes.length) {
      throw const FormatException('senc/sample count mismatch');
    }
    var at = p + 8;
    final out = <SampleEncryption>[];
    for (var i = 0; i < count; i++) {
      if (at + ivSize > senc.end) {
        throw const FormatException('Truncated sample IV');
      }
      final iv = Uint8List(16)..setRange(0, ivSize, v.slice(at, ivSize));
      at += ivSize;
      final subs = <Subsample>[];
      if (hasSubsamples) {
        if (at + 2 > senc.end) {
          throw const FormatException('Truncated subsample count');
        }
        final n = v.u16(at);
        at += 2;
        if (at + n * 6 > senc.end) {
          throw const FormatException('Truncated subsamples');
        }
        var total = 0;
        for (var j = 0; j < n; j++) {
          final clear = v.u16(at), enc = v.u32(at + 2);
          at += 6;
          total += clear + enc;
          subs.add(Subsample(clear, enc));
        }
        if (n > 0 && total != sizes[i]) {
          throw const FormatException('Subsample sizes do not cover sample');
        }
      }
      out.add(SampleEncryption(iv, subs));
    }
    if (at != senc.end) {
      throw const FormatException('Unexpected senc trailing data');
    }
    return out;
  }

  static Uint8List decryptSample(
    Uint8List input,
    SampleEncryption spec,
    Uint8List key,
  ) {
    if (key.length != 16) {
      throw ArgumentError('Content key must contain 16 bytes');
    }
    final cipher = pc.SICStreamCipher(pc.AESEngine())
      ..init(false, pc.ParametersWithIV(pc.KeyParameter(key), spec.iv));
    if (spec.subsamples.isEmpty) return cipher.process(input);
    final out = Uint8List.fromList(input);
    var at = 0;
    for (final sub in spec.subsamples) {
      at += sub.clear;
      if (sub.encrypted > 0) {
        out.setRange(
          at,
          at + sub.encrypted,
          cipher.process(Uint8List.sublistView(input, at, at + sub.encrypted)),
        );
      }
      at += sub.encrypted;
    }
    return out;
  }

  static bool validNalSample(Uint8List plain, int lengthSize, String codec) {
    if (plain.isEmpty || lengthSize < 1 || lengthSize > 4) return false;
    var at = 0, count = 0;
    while (at < plain.length) {
      if (at + lengthSize > plain.length) return false;
      var length = 0;
      for (var i = 0; i < lengthSize; i++) {
        length = (length << 8) | plain[at + i];
      }
      at += lengthSize;
      if (length < 1 || at + length > plain.length) return false;
      final hevc = ['hvc1', 'hev1'].contains(codec);
      if (hevc) {
        if (length < 2 || (plain[at] & 0x80) != 0 || (plain[at + 1] & 7) == 0) {
          return false;
        }
      } else {
        final type = plain[at] & 31;
        if ((plain[at] & 0x80) != 0 || type == 0 || type > 23) return false;
      }
      at += length;
      count++;
    }
    return at == plain.length && count > 0;
  }

  /// Validate before modifying any ciphertext, then process every encrypted track.
  static int decrypt(SampleStore store, Mp4Plan plan, Uint8List key) {
    final video = plan.tracks
        .where((t) => t.handler == 'vide' && t.encrypted)
        .firstOrNull;
    if (video == null && plan.encryptedSamples > 0) {
      throw UnsupportedError('Cannot verify key without encrypted video');
    }
    if (video != null) {
      final first = decryptSample(
        store.read(video.offsets.first, video.sizes.first),
        video.encryption.first,
        key,
      );
      if (!validNalSample(first, video.nalLength, video.codec)) {
        throw const FormatException('Content key/IV does not match video');
      }
    }
    var count = 0;
    for (final track in plan.tracks.where((t) => t.encrypted)) {
      for (var i = 0; i < track.sizes.length; i++) {
        final plain = decryptSample(
          store.read(track.offsets[i], track.sizes[i]),
          track.encryption[i],
          key,
        );
        store.write(track.offsets[i], plain);
        count++;
      }
    }
    if (count > 0) clearEncryptionMetadata(store, plan);
    return count;
  }

  /// Replace encryption boxes with same-size `free` boxes. Chunk offsets stay
  /// valid, even with tail moov/co64. No media copying or ffmpeg is needed.
  static void clearEncryptionMetadata(SampleStore store, Mp4Plan plan) {
    final view = _View(plan.metadata, plan.moov.start);
    final patched = Uint8List.fromList(plan.metadata);
    void type(int at, String value) => patched.setRange(
      at - plan.moov.start,
      at - plan.moov.start + 4,
      convert.latin1.encode(value),
    );
    for (final b in plan.moov.descendants) {
      if (b.type == 'encv' || b.type == 'enca') {
        final frma = b.child('sinf')?.child('frma');
        if (frma == null) {
          throw const FormatException('Missing original sample entry type');
        }
        type(b.start + 4, view.text(frma.payload, 4));
      }
      if (['sinf', 'senc', 'saiz', 'saio', 'pssh'].contains(b.type)) {
        type(b.start + 4, 'free');
      }
    }
    store.write(plan.moov.start, patched);
    for (final b in plan.top.where((b) => b.type == 'pssh')) {
      store.write(
        b.start + 4,
        Uint8List.fromList(convert.latin1.encode('free')),
      );
    }
  }
}
