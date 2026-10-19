// Ported from the corresponding hongguo-web JS module; see root THIRD_PARTY_NOTICES.md.
import 'dart:convert' as encoding;
import 'dart:typed_data';
import '../crypto/bytes.dart' as crypto;
import '../ports/file_store.dart';

class ByteView {
  final Uint8List data;
  final int base;
  ByteView(List<int> data, [this.base = 0]) : data = Uint8List.fromList(data);
  int get end => base + data.length;
  void require(int p, int n) {
    if (p < base || n < 0 || p + n > end)
      throw FormatException('Truncated MP4 field at $p');
  }

  int u8(int p) {
    require(p, 1);
    return data[p - base];
  }

  int u16(int p) => (u8(p) << 8) | u8(p + 1);
  int u32(int p) {
    require(p, 4);
    return ByteData.sublistView(data).getUint32(p - base);
  }

  int u64(int p) {
    final value = (BigInt.from(u32(p)) << 32) | BigInt.from(u32(p + 4));
    if (value > BigInt.from(0x1fffffffffffff))
      throw UnsupportedError('MP4 offset exceeds portable integer range');
    return value.toInt();
  }

  String text(int p, int n) {
    require(p, n);
    return encoding.latin1.decode(data.sublist(p - base, p - base + n));
  }

  String hex(int p, int n) {
    require(p, n);
    return crypto.hex(data.sublist(p - base, p - base + n));
  }
}

class Mp4Box {
  final String type;
  final int start, headerSize, size;
  final List<Mp4Box> children;
  Mp4Box(
    this.type,
    this.start,
    this.headerSize,
    this.size, [
    this.children = const [],
  ]);
  int get end => start + size;
  int get payload => start + headerSize;
  Mp4Box? child(String type) {
    for (final c in children) {
      if (c.type == type) return c;
    }
    return null;
  }

  Mp4Box? find(String type) {
    for (final c in children) {
      if (c.type == type) return c;
      final found = c.find(type);
      if (found != null) return found;
    }
    return null;
  }
}

const _containers = {
  'moov',
  'trak',
  'mdia',
  'minf',
  'stbl',
  'edts',
  'dinf',
  'udta',
  'mvex',
  'moof',
  'traf',
  'sinf',
  'schi',
};
const _visual = {
  'encv',
  'hvc1',
  'hev1',
  'avc1',
  'av01',
  'mp4v',
  'vp08',
  'vp09',
  'dvav',
  'dva1',
};
const _audio = {'enca', 'mp4a', 'ac-3', 'ec-3', 'Opus', 'fLaC', 'samr', 'sawb'};
int _entryHeader(String t) => _visual.contains(t)
    ? 78
    : _audio.contains(t)
    ? 28
    : 0;
List<Mp4Box> parseBoxes(ByteView v, [int? offset, int? end, int depth = 0]) {
  if (depth > 32) throw FormatException('MP4 nesting exceeds 32');
  var p = offset ?? v.base;
  final stop = end ?? v.end;
  final out = <Mp4Box>[];
  v.require(p, stop - p);
  while (p < stop) {
    if (stop - p < 8) throw FormatException('Incomplete MP4 box header');
    var size = v.u32(p), header = 8;
    final type = v.text(p + 4, 4);
    if (size == 1) {
      size = v.u64(p + 8);
      header = 16;
    } else if (size == 0) {
      size = stop - p;
    }
    if (size < header || p + size > stop)
      throw FormatException('Invalid $type box extent');
    int? childStart;
    if (_containers.contains(type)) childStart = p + header;
    if (type == 'stsd') childStart = p + header + 8;
    // Sample entries contain codec-specific fixed headers before child boxes.
    if (_entryHeader(type) > 0) childStart = p + header + _entryHeader(type);
    final kids = childStart == null
        ? <Mp4Box>[]
        : parseBoxes(v, childStart, p + size, depth + 1);
    out.add(Mp4Box(type, p, header, size, kids));
    p += size;
  }
  return out;
}

class Mp4Track {
  final int id;
  final String handler;
  final List<int> sizes, offsets;
  final List<String>? ivs;
  final String? constantIv;
  final bool encrypted;
  const Mp4Track({
    required this.id,
    required this.handler,
    required this.sizes,
    required this.offsets,
    this.ivs,
    this.constantIv,
    this.encrypted = false,
  });
}

class Mp4Analysis {
  final Mp4Box moov;
  final List<Mp4Track> tracks;
  const Mp4Analysis(this.moov, this.tracks);
}

Mp4Box findMoov(RandomAccessStore store) {
  var p = 0;
  Mp4Box? moov;
  while (p < store.length) {
    if (store.length - p < 8)
      throw FormatException('Truncated top-level header');
    final v = ByteView(store.read(p, (store.length - p).clamp(8, 16)), p);
    var size = v.u32(p), header = 8;
    final type = v.text(p + 4, 4);
    if (size == 1) {
      size = v.u64(p + 8);
      header = 16;
    } else if (size == 0) {
      size = store.length - p;
    }
    if (size < header || p + size > store.length)
      throw FormatException('Invalid top-level extent');
    if (type == 'moof')
      throw UnsupportedError('Fragmented MP4 is not supported');
    if (type == 'moov') {
      if (moov != null) throw FormatException('Multiple moov boxes');
      moov = Mp4Box(type, p, header, size);
    }
    p += size;
  }
  if (moov == null) throw FormatException('Missing moov');
  if (moov.size > 64 * 1024 * 1024)
    throw UnsupportedError('moov exceeds 64 MiB budget');
  return moov;
}

Mp4Analysis analyzeMp4(ByteView v) {
  final top = parseBoxes(v);
  final moov = top.where((b) => b.type == 'moov').single;
  final tracks = <Mp4Track>[];
  for (final trak in moov.children.where((b) => b.type == 'trak')) {
    final stbl = trak.find('stbl'),
        tkhd = trak.child('tkhd'),
        hdlr = trak.find('hdlr');
    if (stbl == null) continue;
    final stsz = stbl.child('stsz'),
        stsc = stbl.child('stsc'),
        chunk = stbl.child('stco') ?? stbl.child('co64');
    if (stsz == null || stsc == null || chunk == null)
      throw UnsupportedError('Missing MP4 sample table');
    final p = stsz.payload + 4, uniform = v.u32(p), count = v.u32(p + 4);
    if (count > 2000000) throw UnsupportedError('Sample table exceeds budget');
    if (uniform == 0 && p + 8 + count * 4 > stsz.end)
      throw FormatException('Truncated stsz');
    final sizes = List.generate(
      count,
      (i) => uniform > 0 ? uniform : v.u32(p + 8 + i * 4),
    );
    final chunkCount = v.u32(chunk.payload + 4),
        width = chunk.type == 'stco' ? 4 : 8;
    if (chunk.payload + 8 + chunkCount * width > chunk.end)
      throw FormatException('Truncated chunk table');
    final chunks = List.generate(
      chunkCount,
      (i) => width == 4
          ? v.u32(chunk.payload + 8 + i * 4)
          : v.u64(chunk.payload + 8 + i * 8),
    );
    final entryCount = v.u32(stsc.payload + 4);
    if (stsc.payload + 8 + entryCount * 12 > stsc.end)
      throw FormatException('Truncated stsc');
    final offsets = <int>[];
    for (var e = 0; e < entryCount; e++) {
      final q = stsc.payload + 8 + e * 12,
          first = v.u32(q),
          perChunk = v.u32(q + 4);
      final last = e + 1 < entryCount ? v.u32(q + 12) - 1 : chunks.length;
      if (first < 1 || last > chunks.length || last < first || perChunk < 1)
        throw FormatException('Invalid stsc mapping');
      for (var c = first; c <= last; c++) {
        var off = chunks[c - 1];
        for (var s = 0; s < perChunk; s++) {
          if (offsets.length >= sizes.length)
            throw FormatException('Sample mapping overflows stsz');
          offsets.add(off);
          off += sizes[offsets.length - 1];
        }
      }
    }
    if (offsets.length != sizes.length)
      throw FormatException('Incomplete sample offsets');
    final tenc = trak.find('tenc'),
        senc = trak.find('senc'),
        schm = trak.find('schm');
    if (schm != null && v.text(schm.payload + 4, 4) != 'cenc')
      throw UnsupportedError('Only cenc AES-CTR is supported');
    String? constant;
    int ivSize = 0;
    if (tenc != null) {
      final p = tenc.payload;
      // Preserve the legacy player's compact tenc layout used by this source.
      final version = v.u8(p);
      if (tenc.size - tenc.headerSize >= 24) {
        // ISO/IEC 23001-7: fullbox + reserved/pattern + protected + IV size + KID.
        if (version > 1) throw UnsupportedError('Unsupported tenc version');
        if (version == 1 && v.u8(p + 5) != 0)
          throw UnsupportedError('Pattern encryption is not CENC CTR');
        ivSize = v.u8(p + 7);
        if (ivSize == 0 && v.u8(p + 6) == 1) {
          final n = v.u8(p + 24);
          constant = v.hex(p + 25, n);
        }
      } else {
        ivSize = v.u8(p + (version == 0 ? 4 : 9));
        if ((v.u8(p + 3) & 1) != 0)
          constant = v.hex(p + (version == 0 ? 5 : 10) + 16, ivSize);
      }
    }
    List<String>? ivs;
    if (senc != null) {
      final p = senc.payload, flags = v.u32(p) & 0xffffff, n = v.u32(p + 4);
      if ((flags & 2) != 0)
        throw UnsupportedError(
          'CENC subsample encryption requires a separate decryptor',
        );
      if (n != count) throw FormatException('senc/stsz sample count mismatch');
      if (ivSize != 8 && ivSize != 16)
        ivSize = n > 0 ? (senc.end - p - 8) ~/ n : 16;
      if ((ivSize != 8 && ivSize != 16) || p + 8 + n * ivSize != senc.end)
        throw FormatException('Invalid senc IV table');
      ivs = List.generate(n, (i) => v.hex(p + 8 + i * ivSize, ivSize));
    }
    final id = tkhd == null
        ? 0
        : v.u32(tkhd.payload + (v.u8(tkhd.payload) == 1 ? 20 : 12));
    tracks.add(
      Mp4Track(
        id: id,
        handler: hdlr == null ? '' : v.text(hdlr.payload + 8, 4),
        sizes: sizes,
        offsets: offsets,
        ivs: ivs,
        constantIv: constant,
        encrypted: tenc != null || senc != null,
      ),
    );
  }
  if (tracks.isEmpty) throw FormatException('No indexed tracks');
  return Mp4Analysis(moov, tracks);
}

Uint8List ivToCounter(String iv) {
  final raw = crypto.unhex(iv);
  if (raw.length != 8 && raw.length != 16)
    throw FormatException('IV must contain 8 or 16 bytes');
  return Uint8List(16)..setRange(0, raw.length, raw);
}

Uint8List ctrCounter(String base, int index) {
  if (index < 0) throw ArgumentError.value(index);
  final raw = crypto.unhex(base);
  if (raw.length < 8) throw FormatException('Base IV requires 8 bytes');
  var n = BigInt.zero;
  for (final b in raw.take(8)) {
    n = (n << 8) | BigInt.from(b);
  }
  n = (n + BigInt.from(index)).toUnsigned(64);
  final out = Uint8List(16);
  for (var i = 7; i >= 0; i--) {
    out[i] = (n & BigInt.from(255)).toInt();
    n >>= 8;
  }
  return out;
}

Uint8List counterFor(Mp4Track track, int index, [String? baseIv]) {
  if (track.ivs != null) return ivToCounter(track.ivs![index]);
  final base = baseIv ?? track.constantIv;
  if (base == null) throw FormatException('Missing per-sample IV and base IV');
  return ctrCounter(base, index);
}

bool avccSelfOk(List<int> data) {
  if (data.length < 5) return false;
  if (data[0] == 0 &&
      data[1] == 0 &&
      (data[2] == 1 || (data[2] == 0 && data[3] == 1)))
    return true;
  var p = 0, nals = 0;
  final v = ByteView(data);
  while (p + 5 <= data.length) {
    final n = v.u32(p);
    if (n < 1 || p + 4 + n > data.length || (data[p + 4] & 0x80) != 0)
      return false;
    p += 4 + n;
    if (++nals > 64) return false;
  }
  return nals > 0 && data.length - p <= 3;
}

void decryptTrack(
  RandomAccessStore store,
  Mp4Track track,
  List<int> key, {
  String? baseIv,
}) {
  // Validate every boundary before mutating any sample.
  for (var i = 0; i < track.sizes.length; i++) {
    if (track.sizes[i] > 64 * 1024 * 1024)
      throw UnsupportedError('Sample exceeds worker memory budget');
    if (track.offsets[i] < 0 ||
        track.offsets[i] + track.sizes[i] > store.length)
      throw FormatException('Sample exceeds file extent');
    counterFor(track, i, baseIv);
  }
  if (track.handler == 'vide') {
    final probes = {
      0,
      1,
      2,
      track.sizes.length ~/ 4,
      track.sizes.length ~/ 2,
      track.sizes.length - 1,
    };
    var checked = 0;
    for (final i in probes.where(
      (i) => i >= 0 && i < track.sizes.length && track.sizes[i] >= 8,
    )) {
      final plain = crypto.aesCtr(
        key,
        counterFor(track, i, baseIv),
        store.read(track.offsets[i], track.sizes[i]),
      );
      if (!avccSelfOk(plain))
        throw FormatException('Video key/IV verification failed');
      checked++;
    }
    if (checked == 0) throw FormatException('No video probe samples');
  }
  for (var i = 0; i < track.sizes.length; i++) {
    final off = track.offsets[i], size = track.sizes[i];
    if (size > 64 * 1024 * 1024)
      throw UnsupportedError('Sample exceeds worker memory budget');
    store.write(
      off,
      crypto.aesCtr(key, counterFor(track, i, baseIv), store.read(off, size)),
    );
  }
}

/// Rebuild only moov. Its length remains constant using free boxes, so stco/co64
/// and media data need no relocation (also handles moov at the end of a file).
Uint8List stripEncryption(ByteView v) {
  Uint8List rebuild(Mp4Box b, {String? parent}) {
    if ((parent == 'stbl' && {'senc', 'saio', 'saiz'}.contains(b.type)) ||
        (parent == 'moov' && b.type == 'pssh') ||
        b.type == 'sinf')
      return Uint8List(0);
    if (b.children.isEmpty)
      return Uint8List.fromList(
        v.data.sublist(b.start - v.base, b.end - v.base),
      );
    var type = b.type;
    if (type == 'encv' || type == 'enca') {
      final frma = b.find('frma');
      if (frma == null)
        throw UnsupportedError('Encrypted entry has no original format');
      type = v.text(frma.payload, 4);
      if (!_visual.contains(type) && !_audio.contains(type) ||
          type == 'encv' ||
          type == 'enca')
        throw UnsupportedError('Unknown original sample entry');
    }
    final prefixEnd = b.children.first.start;
    final payload = crypto.joinBytes([
      v.data.sublist(b.payload - v.base, prefixEnd - v.base),
      for (final c in b.children) rebuild(c, parent: b.type),
    ]);
    if (b.headerSize != 8)
      throw UnsupportedError(
        'Extended-size nested moov boxes cannot be rebuilt',
      );
    final result = Uint8List(8 + payload.length);
    ByteData.sublistView(result).setUint32(0, result.length);
    result.setRange(4, 8, encoding.latin1.encode(type));
    result.setRange(8, result.length, payload);
    return result;
  }

  final moov = parseBoxes(v).single;
  if (moov.type != 'moov') throw ArgumentError('Expected a moov window');
  final result = rebuild(moov);
  final delta = v.data.length - result.length;
  if (delta == 0) return result;
  if (delta < 8) throw FormatException('Insufficient padding for free box');
  final free = Uint8List(delta);
  ByteData.sublistView(free).setUint32(0, delta);
  free.setRange(4, 8, encoding.latin1.encode('free'));
  final out = crypto.joinBytes([result, free]);
  final checked = parseBoxes(ByteView(out));
  if (checked.first.find('sinf') != null || checked.first.find('senc') != null)
    throw StateError('Encryption signaling remains');
  return out;
}

/// Validate samples against mdat, and reject overlapping sample ranges before writes.
void validateMediaLayout(RandomAccessStore store, List<Mp4Track> tracks) {
  final ranges = <(int, int)>[];
  var p = 0;
  while (p < store.length) {
    final v = ByteView(store.read(p, (store.length - p).clamp(8, 16)), p);
    var size = v.u32(p), header = 8;
    if (size == 1) {
      size = v.u64(p + 8);
      header = 16;
    } else if (size == 0) {
      size = store.length - p;
    }
    if (size < header || p + size > store.length)
      throw FormatException('Invalid media box');
    if (v.text(p + 4, 4) == 'mdat') ranges.add((p + header, p + size));
    p += size;
  }
  final samples = <(int, int)>[];
  for (final track in tracks) {
    for (var i = 0; i < track.sizes.length; i++) {
      final start = track.offsets[i], end = start + track.sizes[i];
      if (!ranges.any((r) => start >= r.$1 && end <= r.$2))
        throw FormatException('Sample lies outside mdat');
      if (end > start) samples.add((start, end));
    }
  }
  samples.sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 1; i < samples.length; i++) {
    if (samples[i].$1 < samples[i - 1].$2)
      throw UnsupportedError('Overlapping media samples');
  }
}
