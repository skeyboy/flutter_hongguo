import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'mp4.dart';

/// Lossless concatenation of already-decrypted, non-fragmented MP4 files.
///
/// Every input must share one track structure and one sample entry per track, so
/// the merged file can keep the first source's `stsd` and only re-base the sample
/// tables. Differences that live only in the tables -- a track order, a timescale,
/// a missing or differently-versioned `ctts` -- are normalised into the one table
/// set the product is written with. Anything that would change a decoded byte is
/// refused: this lane never re-encodes.

/// What a refusal is about. The panel needs the distinction because the two
/// answers differ: a format difference the viewer can undo by re-downloading one
/// quality is worth naming, and a structural one is not.
enum MergeRejectCode {
  /// The tracks cannot be paired one for one.
  tracks,

  /// Same description, different picture size -- only a re-encode can agree.
  resolution,

  /// The sample entry itself differs -- only a re-encode can agree.
  codec,

  /// Timescales cannot be reconciled into one exact common timescale.
  timescale,
}

/// The sources cannot be joined without changing their media bytes. The reason is
/// shown as it is — only the deferred re-encode lane can satisfy it.
class MergeReject implements Exception {
  final String reason;

  /// The 1-based source the verdict is about, when a comparison produced it.
  final int? position;
  final MergeRejectCode? code;
  const MergeReject(this.reason, {this.position, this.code});
  @override
  String toString() => 'MergeReject: $reason';
}

typedef MergeProgress = void Function(int done, int total);

/// One track of one source: what the merged tables need, plus where its samples
/// currently sit.
class MergeTrack {
  final String handler, codec;
  final int timescale, duration, width, height;

  /// The frame the sample entry states, for a video track; 0 for anything else.
  /// `tkhd`'s display size is a hint a muxer may leave at zero, so a size that
  /// has to be real -- an encode's, or the even-edge H.264 demands -- reads here.
  final int codedWidth, codedHeight;

  /// Bytes that must agree across sources for one `stsd` to describe them all.
  final Uint8List signature;

  /// Sample sizes and absolute source offsets, both in sample order.
  final List<int> sizes, offsets;

  /// Samples per chunk and the offset each chunk starts at, both in chunk order.
  /// Reused verbatim when a source is an earlier product of this same merge.
  final List<int> chunkCounts, chunkOffsets;
  // ignore: library_private_types_in_public_api
  final List<_Time> times;

  /// Null when the file has no `ctts`: every one of its samples is then a plain
  /// DTS-to-CTS pass-through, and the merged table says so with zero offsets
  /// rather than refusing a mix.
  // ignore: library_private_types_in_public_api
  final List<_Composition>? composition;

  /// The `ctts` version this file was written with. One merged table is written
  /// with the widest convention any part needs, so a mix of versions is carried
  /// rather than refused.
  final int cttsVersion;
  final List<int>? syncSamples;
  const MergeTrack({
    required this.handler,
    required this.codec,
    required this.timescale,
    required this.duration,
    required this.width,
    required this.height,
    this.codedWidth = 0,
    this.codedHeight = 0,
    required this.signature,
    required this.sizes,
    required this.offsets,
    required this.chunkCounts,
    required this.chunkOffsets,
    required this.times,
    required this.composition,
    required this.cttsVersion,
    required this.syncSamples,
  });

  int get samples => sizes.length;
  int get bytes => sizes.fold(0, (a, b) => a + b);
  int get durationMs => duration * 1000 ~/ timescale;
}

/// A parsed merge input.
class MergeSource {
  final SampleStore store;
  final List<MergeTrack> tracks;
  final int bytes;

  /// The first source's file-type box, reused as the merged lead. A merged file
  /// that keeps no `ftyp` is legal but reads as damaged to some demuxers.
  final Uint8List lead;

  /// The template metadata, supplying every box the merger does not rebuild.
  /// Private: it is this library's own view of the template.
  final _Moov _moov;
  MergeSource._({
    required this.store,
    required this.tracks,
    required this.bytes,
    required this.lead,
    required this._moov,
  });

  int get durationMs =>
      tracks.fold(0, (a, t) => t.durationMs > a ? t.durationMs : a);
}

/// A merge decided before any byte is written. The rebuilt `moov`, the media
/// layout and the copies still owed are all known here, so writing is one forward
/// pass that never seeks back.
class MergePlan {
  final Uint8List lead, metadata;
  // ignore: library_private_types_in_public_api
  final List<_Copy> copies;
  final int mediaBytes, mdatWidth, durationMs;

  /// Set when an existing product grows in place: the file is cut here, the new
  /// samples are appended, then the metadata follows.
  final int? appendAt, mdatStart, mdatSize;
  const MergePlan._({
    required this.lead,
    required this.metadata,
    required this.copies,
    required this.mediaBytes,
    required this.mdatWidth,
    required this.durationMs,
    required this.appendAt,
    required this.mdatStart,
    required this.mdatSize,
  });

  int get copyBytes => copies.fold(0, (a, c) => a + c.bytes);

  /// The whole file for a fresh merge; the grown size for an append.
  int get outputBytes => appendAt == null
      ? lead.length + mdatWidth + mediaBytes + metadata.length
      : appendAt! + copyBytes + metadata.length;

  /// Bytes the merge still has to read, which is what a progress bar divides by.
  int get workBytes => copyBytes;

  /// The header a fresh write emits before any sample. A resumed write finds it
  /// already in the part file and must not emit it a second time.
  int get prefixBytes => appendAt == null ? lead.length + mdatWidth : appendAt!;

  /// The largest total of whole copies that fits inside [bytes]. Copies are the
  /// smallest unit a resume can trust: restarting inside one would need the
  /// kernel to remember how far a single chunk's run had got.
  int boundary(int bytes) {
    var sum = 0;
    for (final copy in copies) {
      if (sum + copy.bytes > bytes) break;
      sum += copy.bytes;
    }
    return sum;
  }
}

class Mp4Merger {
  static const _ignorable = {
    'free',
    'skip',
    'uuid',
    'pssh',
    'senc',
    'saio',
    'saiz',
    'sgpd',
    'sbgp',
    'srtz',
    'sfrk',
    'schi',
    'sinf',
    'frma',
    'schm',
    'tenc',
  };

  /// Presentation hints that may differ between episodes without changing one
  /// decoded byte, so they are neither compared nor carried over.
  static const _cosmetic = {
    'pasp',
    'clap',
    'colr',
    'clli',
    'btrt',
    'panc',
    'std3',
    'prol',
    'ccst',
    'mexf',
    'mebk',
    'nclx',
  };

  /// Reads one candidate. [Mp4Cenc.inspect] owns the structural checks this lane
  /// builds on: one `moov`, samples inside `mdat`, no overlap, no fragmentation.
  static MergeSource read(SampleStore store) {
    late final Mp4Plan parsed;
    try {
      parsed = Mp4Cenc.inspect(store);
    } on FormatException catch (e) {
      throw MergeReject('源文件无法解析：${e.message}');
    } on UnsupportedError catch (e) {
      throw MergeReject('源文件形态不支持合并：${e.message}');
    }
    final moov = parsed.moov;
    if (parsed.encryptedSamples > 0) {
      // Copying bytes verbatim would publish ciphertext as clear media.
      throw const MergeReject('源文件仍是加密的，请先完成解密');
    }
    final v = _R(parsed.metadata, moov.start);
    final traks = moov.children.where((b) => b.type == 'trak').toList();
    if (traks.isEmpty) throw const MergeReject('源文件没有可合并的轨道');
    final tracks = <MergeTrack>[];
    final templateTraks = <Mp4Box>[];
    var used = <Mp4Track>{};
    for (final trak in traks) {
      final stbl = trak.find('stbl'), hdlr = trak.find('hdlr');
      if (stbl == null || hdlr == null) continue;
      final handler = v.text(hdlr.payload + 8, 4);
      final stsz = stbl.child('stsz');
      if (stsz == null || v.u32(stsz.payload + 8) == 0) continue;
      final samples = parsed.tracks.firstWhere(
        (t) => t.handler == handler && !used.contains(t),
        orElse: () => throw const MergeReject('轨道与样本表对不上'),
      );
      used.add(samples);
      templateTraks.add(trak);
      tracks.add(_track(v, trak, stbl, samples));
    }
    if (tracks.length != parsed.tracks.length) {
      throw const MergeReject('存在无法解析的轨道');
    }
    if (!tracks.any((t) => t.handler == 'vide')) {
      throw const MergeReject('源文件没有视频轨');
    }
    final lead = <int>[];
    for (final box in parsed.top) {
      if (box.type == 'moov' || box.type == 'mdat') break;
      if (box.type != 'ftyp' && box.type != 'styp') continue;
      lead.addAll(store.read(box.start, box.size));
    }
    return MergeSource._(
      store: store,
      tracks: tracks,
      bytes: store.length,
      lead: Uint8List.fromList(
        lead.isEmpty ? _boxBytes('ftyp', _isom()) : lead,
      ),
      moov: _Moov.parse(v, moov, parsed.top, templateTraks),
    );
  }

  static MergeTrack _track(_R v, Mp4Box trak, Mp4Box stbl, Mp4Track samples) {
    final hdlr = trak.find('hdlr')!;
    final mdhd = trak.find('mdhd'), tkhd = trak.find('tkhd');
    if (mdhd == null || tkhd == null) {
      throw const MergeReject('轨道缺少时长信息');
    }
    final entry = stbl.child('stsd')!.children.single;
    final stts = stbl.child('stts');
    if (stts == null) throw const MergeReject('轨道缺少时间表');
    final times = <_Time>[];
    var covered = 0;
    for (var i = 0; i < v.u32(stts.payload + 4); i++) {
      final at = stts.payload + 8 + i * 8;
      final count = v.u32(at), delta = v.u32(at + 4);
      if (count == 0 || delta == 0) throw const MergeReject('时间表无效');
      covered += count;
      times.add(_Time(count, delta));
    }
    if (covered != samples.sizes.length) {
      throw const MergeReject('时间表与样本数不符');
    }
    final ctts = stbl.child('ctts'), composition = <_Composition>[];
    if (ctts != null) {
      var seen = 0;
      for (var i = 0; i < v.u32(ctts.payload + 4); i++) {
        final at = ctts.payload + 8 + i * 8;
        final count = v.u32(at);
        seen += count;
        composition.add(_Composition(count, v.i32(at + 4)));
      }
      if (seen != samples.sizes.length) {
        throw const MergeReject('显示顺序表与样本数不符');
      }
    }
    final stss = stbl.child('stss'), sync = <int>[];
    if (stss != null) {
      for (var i = 0; i < v.u32(stss.payload + 4); i++) {
        sync.add(v.u32(stss.payload + 8 + i * 4));
      }
    }
    final chunkCounts = _chunkCounts(v, stbl, samples.sizes.length);
    final co = (stbl.child('stco') ?? stbl.child('co64'))!;
    final wide = co.type == 'co64';
    final chunkOffsets = [
      for (var i = 0; i < chunkCounts.length; i++)
        wide ? v.u64(co.payload + 8 + i * 8) : v.u32(co.payload + 8 + i * 4),
    ];
    final dim = v.u8(tkhd.payload) == 1 ? 88 : 76;
    final handler = v.text(hdlr.payload + 8, 4);
    // ISO 14496-12 puts the coded frame at the 24th byte of a video sample
    // entry's fixed fields; an audio entry has other numbers there, so only a
    // `vide` track is read.
    final coded = handler == 'vide' && entry.size - entry.header >= 28
        ? [v.u16(entry.payload + 24), v.u16(entry.payload + 26)]
        : const [0, 0];
    return MergeTrack(
      handler: handler,
      codec: samples.codec,
      timescale: _mdhdTimescale(v, mdhd),
      duration: _mdhdDuration(v, mdhd),
      width: v.u16(tkhd.payload + dim),
      height: v.u16(tkhd.payload + dim + 2),
      codedWidth: coded[0],
      codedHeight: coded[1],
      signature: _signature(v, entry),
      sizes: samples.sizes,
      offsets: samples.offsets,
      chunkCounts: chunkCounts,
      chunkOffsets: chunkOffsets,
      times: times,
      composition: ctts == null ? null : composition,
      cttsVersion: ctts == null ? 0 : v.u8(ctts.payload),
      syncSamples: stss == null ? null : sync,
    );
  }

  /// The sample entry stripped of its presentation hints: sources matching here
  /// really are decodable from one shared description.
  static Uint8List _signature(_R v, Mp4Box entry) {
    final out = <int>[];
    final fixed = entry.children.isEmpty
        ? entry.size - entry.header
        : entry.children.first.start - entry.payload;
    out.addAll(v.slice(entry.payload, fixed));
    for (final child in entry.children) {
      if (_cosmetic.contains(child.type) || _ignorable.contains(child.type)) {
        continue;
      }
      out.addAll(v.slice(child.start, child.size));
    }
    return Uint8List.fromList(out);
  }

  static List<int> _chunkCounts(_R v, Mp4Box stbl, int sampleCount) {
    final stsc = stbl.child('stsc');
    final co = stbl.child('stco') ?? stbl.child('co64');
    if (stsc == null || co == null) throw const MergeReject('缺少分块表');
    final entries = v.u32(stsc.payload + 4), chunks = v.u32(co.payload + 4);
    if (chunks == 0 || chunks > sampleCount) throw const MergeReject('分块表无效');
    final per = List<int>.filled(chunks, 0);
    for (var i = 0; i < entries; i++) {
      final at = stsc.payload + 8 + i * 12;
      final first = v.u32(at), count = v.u32(at + 4);
      if (first < 1 || first > chunks || count < 1) {
        throw const MergeReject('分块表无效');
      }
      final next = i + 1 < entries
          ? v.u32(stsc.payload + 8 + (i + 1) * 12)
          : chunks + 1;
      for (var c = first; c < next; c++) {
        per[c - 1] = count;
      }
    }
    if (per.fold(0, (a, b) => a + b) != sampleCount) {
      throw const MergeReject('分块表与样本数不符');
    }
    return per;
  }

  /// Merges [sources] in order into a file written from scratch.
  static MergePlan plan(List<MergeSource> sources) {
    if (sources.length < 2) throw const MergeReject('至少选择两集');
    final base = sources.first;
    final pairings = [_identity(base)];
    for (var i = 1; i < sources.length; i++) {
      pairings.add(_compare(base, sources[i], i + 1));
    }
    final media = _mediaOf(sources);
    // The header width follows the mdat box alone: widening it later would move
    // the media, so the layout must agree with `_mdatHeaderBytes` exactly.
    final width = media + 8 > 0xffffffff ? 16 : 8;
    final chunks = {
      for (var t = 0; t < base.tracks.length; t++) t: <_OutChunk>[],
    };
    final copies = <_Copy>[];
    var position = base.lead.length + width;
    for (var si = 0; si < sources.length; si++) {
      final source = sources[si];
      for (var t = 0; t < base.tracks.length; t++) {
        final at = pairings[si][t];
        final track = source.tracks[at];
        var first = 0;
        for (final count in track.chunkCounts) {
          chunks[t]!.add(_OutChunk(offset: position, samples: count));
          copies.add(
            _Copy(
              source: source,
              track: at,
              firstSample: first,
              sampleCount: count,
            ),
          );
          var bytes = 0;
          for (var i = first; i < first + count; i++) {
            bytes += track.sizes[i];
          }
          position += bytes;
          first += count;
        }
      }
    }
    return _assemble(
      sources,
      pairings,
      chunks,
      copies,
      mediaBytes: media,
      mdatWidth: width,
    );
  }

  static List<int> _identity(MergeSource base) => [
    for (var t = 0; t < base.tracks.length; t++) t,
  ];

  /// Grows an earlier product by appending [added] behind the media it already
  /// holds. Its own chunk offsets are reused untouched, which is what keeps a
  /// late episode from rewriting the whole series.
  ///
  /// Throws [MergeReject] when the product cannot grow in place — metadata before
  /// the data, more than one `mdat`, or a box that would outgrow 32 bits. The
  /// caller then falls back to [plan], which rewrites everything.
  static MergePlan appendPlan(MergeSource existing, List<MergeSource> added) {
    if (added.isEmpty) throw const MergeReject('没有要追加的分集');
    final pairings = [_identity(existing)];
    for (var i = 0; i < added.length; i++) {
      pairings.add(_compare(existing, added[i], i + 2));
    }
    final mdat = existing._moov.top.where((b) => b.type == 'mdat').toList();
    if (mdat.length != 1) {
      throw const MergeReject('已有产物的数据不连续，请整体重新合成');
    }
    final box = mdat.single;
    if (box.end > existing._moov.box.start) {
      throw const MergeReject('已有产物的元数据在数据之前，请整体重新合成');
    }
    if (box.header != 8) {
      throw const MergeReject('已有产物已使用扩展数据头，请整体重新合成');
    }
    final chunks = {
      for (var t = 0; t < existing.tracks.length; t++) t: <_OutChunk>[],
    };
    for (var t = 0; t < existing.tracks.length; t++) {
      final track = existing.tracks[t];
      for (var c = 0; c < track.chunkOffsets.length; c++) {
        chunks[t]!.add(
          _OutChunk(
            offset: track.chunkOffsets[c],
            samples: track.chunkCounts[c],
          ),
        );
      }
    }
    final copies = <_Copy>[];
    var position = box.end;
    for (var si = 0; si < added.length; si++) {
      final source = added[si];
      for (var t = 0; t < existing.tracks.length; t++) {
        final at = pairings[si + 1][t];
        final track = source.tracks[at];
        var first = 0;
        for (final count in track.chunkCounts) {
          chunks[t]!.add(_OutChunk(offset: position, samples: count));
          copies.add(
            _Copy(
              source: source,
              track: at,
              firstSample: first,
              sampleCount: count,
            ),
          );
          var bytes = 0;
          for (var i = first; i < first + count; i++) {
            bytes += track.sizes[i];
          }
          position += bytes;
          first += count;
        }
      }
    }
    final plan = _assemble(
      [existing, ...added],
      pairings,
      chunks,
      copies,
      mediaBytes: position - box.payload,
      mdatWidth: 8,
      appendAt: box.end,
      mdatStart: box.start,
      mdatSize: box.size + (position - box.end),
    );
    if (plan.mdatSize! > 0xffffffff) {
      throw const MergeReject('追加后的数据长度超出 32 位，请整体重新合成');
    }
    return plan;
  }

  /// The verdict this writer would reach for these sources, without keeping the
  /// plan. A precheck asks it so it can promise only what a merge really does:
  /// one implementation, no rule that can drift between the panel and the write.
  /// Returns null when merging exactly these files is accepted.
  static String? rejectOf(List<MergeSource> sources) {
    try {
      plan(sources);
      return null;
    } on MergeReject catch (e) {
      return e.reason;
    }
  }

  /// The same question for an append of an earlier product. Returns null when
  /// the product grows in place, and the reason when it cannot -- including the
  /// reasons that only show once the grown size is known.
  static String? growRejectOf(MergeSource existing, List<MergeSource> added) {
    try {
      appendPlan(existing, added);
      return null;
    } on MergeReject catch (e) {
      return e.reason;
    }
  }

  /// Why [other] cannot join a product built on [base], or null when it can. The
  /// verdict is structured, so a caller can say what the viewer would have to do
  /// about it -- a different picture size is a re-download, a different sample
  /// entry is a re-encode.
  static MergeReject? rejectAgainst(
    MergeSource base,
    MergeSource other, {
    int position = 2,
  }) {
    try {
      _compare(base, other, position);
      return null;
    } on MergeReject catch (e) {
      return e;
    }
  }

  /// Everything one product can hold in common: the parts of a source's shape that
  /// no table rebuild can reconcile.
  ///
  /// Two sources with the same key are candidates for one file, and the key is
  /// built from exactly what [_compare] inspects, so a candidate list never hides
  /// a difference the writer would object to. [rejectOf] is still what turns a
  /// candidate into a promise: a pathological timescale pair can be refused by
  /// the rebuild even with identical keys.
  static String compatibilityKeyOf(MergeSource source) {
    final parts = [
      for (final t in source.tracks)
        '${t.handler}|${t.width}x${t.height}|${t.codec}|${_fnv(t.signature)}',
    ]..sort();
    return parts.join(';');
  }

  /// A short digest of one sample entry. Only compared within one precheck, so it
  /// needs no cross-run stability -- and a collision still lands on the writer's
  /// own verdict rather than a wrong promise.
  static String _fnv(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash = ((hash ^ b) * 0x01000193) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  /// The rule the writer and the precheck share. Answers with how [other]'s
  /// tracks line up with the output tracks, so a plan and a promise cannot drift.
  ///
  /// Only what a decoded byte depends on has to agree. Track order, timescale and
  /// the shape of `ctts` live entirely in the sample tables, and the rebuild
  /// normalises them, so they are not compared here.
  static List<int> _compare(MergeSource base, MergeSource other, int position) {
    if (other.tracks.length != base.tracks.length) {
      throw MergeReject(
        '第 $position 集的轨道数量与第 1 集不同，暂时无法无损合并',
        position: position,
        code: MergeRejectCode.tracks,
      );
    }
    final pairing = _pairing(base, other, position);
    for (var t = 0; t < base.tracks.length; t++) {
      final a = base.tracks[t], b = other.tracks[pairing[t]];
      final what = a.handler == 'vide' ? '视频' : '音频';
      if (a.width != b.width || a.height != b.height) {
        throw MergeReject(
          '第 $position 集的$what分辨率与第 1 集不同，暂时无法无损合并',
          position: position,
          code: MergeRejectCode.resolution,
        );
      }
      if (!_sameBytes(a.signature, b.signature)) {
        throw MergeReject(
          '第 $position 集的$what编码参数与第 1 集不同，暂时无法无损合并',
          position: position,
          code: MergeRejectCode.codec,
        );
      }
      if (a.timescale < 1 || b.timescale < 1) {
        throw MergeReject(
          '第 $position 集的$what时间基无效，暂时无法无损合并',
          position: position,
          code: MergeRejectCode.timescale,
        );
      }
    }
    return pairing;
  }

  /// Tracks pair by what they are, not by where they sit: two episodes whose
  /// audio and video merely swapped places are still the same format.
  static List<int> _pairing(MergeSource base, MergeSource other, int position) {
    final taken = List<bool>.filled(other.tracks.length, false);
    final pairing = <int>[];
    for (final a in base.tracks) {
      var at = -1;
      for (var i = 0; i < other.tracks.length; i++) {
        if (!taken[i] && other.tracks[i].handler == a.handler) {
          at = i;
          break;
        }
      }
      if (at < 0) {
        throw MergeReject(
          '第 $position 集的轨道构成与第 1 集不同，暂时无法无损合并',
          position: position,
          code: MergeRejectCode.tracks,
        );
      }
      taken[at] = true;
      pairing.add(at);
    }
    return pairing;
  }

  static int _mediaOf(List<MergeSource> sources) =>
      sources.fold(0, (a, s) => a + s.tracks.fold(0, (b, t) => b + t.bytes));

  static MergePlan _assemble(
    List<MergeSource> sources,
    List<List<int>> pairings,
    Map<int, List<_OutChunk>> chunks,
    List<_Copy> copies, {
    required int mediaBytes,
    required int mdatWidth,
    int? appendAt,
    int? mdatStart,
    int? mdatSize,
  }) {
    final merged = [
      for (var t = 0; t < sources.first.tracks.length; t++)
        _MergedTrack.build(
          template: sources.first.tracks[t],
          parts: [
            for (var i = 0; i < sources.length; i++)
              sources[i].tracks[pairings[i][t]],
          ],
          chunks: chunks[t]!,
        ),
    ];
    return MergePlan._(
      lead: sources.first.lead,
      metadata: _moovBytes(sources.first._moov, merged),
      copies: copies,
      mediaBytes: mediaBytes,
      mdatWidth: mdatWidth,
      durationMs: sources.fold(0, (a, s) => a + s.durationMs),
      appendAt: appendAt,
      mdatStart: mdatStart,
      mdatSize: mdatSize,
    );
  }

  /// Writes a fresh merge as `ftyp + mdat + moov`. Metadata goes last so a later
  /// append grows the file without moving a single media byte.
  ///
  /// [resumed] is the sample bytes a part file already holds when a killed
  /// worker restarts the same plan; [MergePlan.boundary] rounds it to a copy
  /// boundary. The sink must already hold the header plus exactly that many
  /// bytes, and a file sink must be positioned there — this lane only writes
  /// forward.
  static void write(
    MergePlan plan,
    MergeSink sink, {
    MergeProgress? onProgress,
    int resumed = 0,
  }) {
    if (plan.appendAt != null) throw ArgumentError('这是追加计划');
    final done = plan.boundary(resumed);
    if (done == 0) {
      sink.write(plan.lead);
      sink.write(_mdatHeaderBytes(plan.mediaBytes));
    }
    _copyAll(plan, sink, onProgress, resumed: done);
    sink.write(plan.metadata);
  }

  /// Grows an existing product in place: cut its tail metadata, add the new
  /// samples inside the extended `mdat`, rewrite that size, then append the
  /// rebuilt metadata. The caller journals the bytes cut here so an interrupted
  /// append can be restored — the merged media up to [MergePlan.appendAt] is
  /// never rewritten.
  ///
  /// [resumed] lets a killed append continue instead of cutting and copying the
  /// whole tail again; the file is always re-cut to the trusted boundary first,
  /// so bytes left past an interrupted write cannot survive into the product.
  static void append(
    MergePlan plan,
    RandomAccessFile file, {
    MergeProgress? onProgress,
    int resumed = 0,
  }) {
    final cut = plan.appendAt;
    if (cut == null) throw ArgumentError('这不是追加计划');
    final done = plan.boundary(resumed);
    file.truncateSync(cut + done);
    file.setPositionSync(cut + done);
    _copyAll(plan, _FileAppend(file), onProgress, resumed: done);
    final dataEnd = cut + plan.copyBytes;
    final size = Uint8List(4);
    _putU32(size, 0, plan.mdatSize!);
    file.setPositionSync(plan.mdatStart!);
    file.writeFromSync(size, 0, 4);
    file.setPositionSync(dataEnd);
    file.writeFromSync(plan.metadata, 0, plan.metadata.length);
    file.flushSync();
  }

  static void _copyAll(
    MergePlan plan,
    MergeSink sink,
    MergeProgress? onProgress, {
    int resumed = 0,
  }) {
    var done = resumed;
    var skip = resumed;
    final total = plan.copyBytes;
    for (final copy in plan.copies) {
      if (copy.bytes <= skip) {
        skip -= copy.bytes;
        continue;
      }
      _copySamples(copy, sink, (read) {
        done += read;
        onProgress?.call(done, total);
      });
    }
    if (onProgress != null) onProgress(total, total);
  }

  /// One chunk's samples, read in runs so a chunk costs one access instead of
  /// hundreds.
  static void _copySamples(
    _Copy copy,
    MergeSink sink,
    void Function(int) onBytes,
  ) {
    const maxRun = 2 * 1024 * 1024;
    final track = copy.source.tracks[copy.track];
    final stop = copy.firstSample + copy.sampleCount;
    var at = copy.firstSample;
    while (at < stop) {
      var run = track.sizes[at], end = at + 1;
      while (end < stop &&
          run + track.sizes[end] <= maxRun &&
          track.offsets[end] == track.offsets[end - 1] + track.sizes[end - 1]) {
        run += track.sizes[end];
        end++;
      }
      final bytes = copy.source.store.read(track.offsets[at], run);
      if (bytes.length != run) throw const MergeReject('源文件在合成期间被改动');
      sink.write(bytes);
      onBytes(run);
      at = end;
    }
  }

  /// The `mdat` header: 32-bit unless the box cannot fit, because widening it
  /// would move the media and invalidate every offset written around it.
  static Uint8List _mdatHeaderBytes(int payload) {
    if (payload + 8 > 0xffffffff) {
      final out = Uint8List(16);
      _putU32(out, 0, 1);
      out.setRange(4, 8, convert.latin1.encode('mdat'));
      _putU64(out, 8, payload + 16);
      return out;
    }
    final out = Uint8List(8);
    _putU32(out, 0, payload + 8);
    out.setRange(4, 8, convert.latin1.encode('mdat'));
    return out;
  }
}

/// Forward-only output. The worker isolate implements this over a
/// `RandomAccessFile` part; tests use the in-memory form.
abstract interface class MergeSink {
  void write(Uint8List bytes);
}

class MemoryMergeSink implements MergeSink {
  final _out = _Grower();
  @override
  void write(Uint8List bytes) => _out.add(bytes);
  Uint8List takeBytes() => _out.take();
}

class FileMergeSink implements MergeSink {
  final RandomAccessFile file;
  FileMergeSink(this.file);
  @override
  void write(Uint8List bytes) => file.writeFromSync(bytes, 0, bytes.length);
}

class _FileAppend implements MergeSink {
  final RandomAccessFile file;
  _FileAppend(this.file);
  @override
  void write(Uint8List bytes) => file.writeFromSync(bytes, 0, bytes.length);
}

class _Time {
  final int count, delta;
  const _Time(this.count, this.delta);
}

class _Composition {
  final int count, offset;
  const _Composition(this.count, this.offset);
}

class _OutChunk {
  final int offset, samples;
  const _OutChunk({required this.offset, required this.samples});
}

/// A chunk of one source's track, addressed by sample range.
class _Copy {
  final MergeSource source;
  final int track, firstSample, sampleCount;
  const _Copy({
    required this.source,
    required this.track,
    required this.firstSample,
    required this.sampleCount,
  });
  int get bytes {
    final t = source.tracks[track];
    var sum = 0;
    for (var i = firstSample; i < firstSample + sampleCount; i++) {
      sum += t.sizes[i];
    }
    return sum;
  }
}

/// An output track and everything the merged tables take from it.
///
/// Each part counts time in its own timescale, so the rebuild settles on one
/// common timescale and re-dates every duration, delta and composition offset
/// into it. The settle is exact, not rounded: the common timescale is the least
/// multiple of every part's, so a re-dated tick count is the same length of time.
class _MergedTrack {
  final MergeTrack template;
  final List<MergeTrack> parts;
  final List<_OutChunk> chunks;

  /// The timescale the merged `mdhd`, `stts` and `ctts` are written with.
  final int timescale;

  /// One factor per part: [timescale] divided by that part's own timescale.
  final List<int> scales;

  _MergedTrack._({
    required this.template,
    required this.parts,
    required this.chunks,
    required this.timescale,
    required this.scales,
  });

  static _MergedTrack build({
    required MergeTrack template,
    required List<MergeTrack> parts,
    required List<_OutChunk> chunks,
  }) {
    var common = 1;
    for (final p in parts) {
      common = _lcm(common, p.timescale);
    }
    final scales = [for (final p in parts) common ~/ p.timescale];
    for (var i = 0; i < parts.length; i++) {
      final scale = scales[i];
      // A delta only has to fit the field it is written to, so a wild timescale
      // pair is refused here rather than truncated into a wrong timeline.
      for (final e in parts[i].times) {
        if (e.delta * scale > 0xffffffff) throw _tooWideTimescale();
      }
      for (final c in parts[i].composition ?? const <_Composition>[]) {
        if (c.offset.abs() * scale > 0x7fffffff) throw _tooWideTimescale();
      }
    }
    return _MergedTrack._(
      template: template,
      parts: parts,
      chunks: chunks,
      timescale: common,
      scales: scales,
    );
  }

  int get samples => parts.fold(0, (a, p) => a + p.samples);

  /// The merged length in [timescale] ticks: every part re-dated before it is
  /// summed, which is what a raw tick sum could only claim when the timescales
  /// already agreed.
  int get duration {
    var sum = 0;
    for (var i = 0; i < parts.length; i++) {
      sum += parts[i].duration * scales[i];
    }
    return sum;
  }

  bool get hasComposition => parts.any((p) => p.composition != null);

  /// One `stts` entry per part entry, re-dated into [timescale].
  List<_Time> get runs => [
    for (var i = 0; i < parts.length; i++)
      for (final e in parts[i].times) _Time(e.count, e.delta * scales[i]),
  ];

  /// Composition offsets in [timescale]. A part whose file has no `ctts` says
  /// every sample is a pass-through, and that is exactly a run of zero offsets.
  List<_Composition> get compositions => [
    for (var i = 0; i < parts.length; i++)
      for (final c
          in parts[i].composition ?? [_Composition(parts[i].samples, 0)])
        _Composition(c.count, c.offset * scales[i]),
  ];

  /// The widest convention any part needs: v1 carries signed offsets, so a single
  /// negative one -- or a source already written that way -- lifts the whole
  /// table, and every v0 offset still reads the same.
  int get cttsVersion {
    if (!hasComposition) return 0;
    if (compositions.any((c) => c.offset < 0)) return 1;
    return parts.any((p) => p.cttsVersion == 1) ? 1 : 0;
  }
}

/// The smallest timescale both can be re-dated into exactly, or a refusal when
/// the two have nothing in common that still fits the field.
int _lcm(int a, int b) {
  if (a < 1 || b < 1) {
    throw const MergeReject(
      '所选各集的时间基无效，无法归一为同一时间轴',
      code: MergeRejectCode.timescale,
    );
  }
  final g = _gcd(a, b);
  if (a ~/ g > 0xffffffff ~/ b) throw _tooWideTimescale();
  return a ~/ g * b;
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

MergeReject _tooWideTimescale() => const MergeReject(
  '所选各集的时间基差异过大，无法归一为同一时间轴，请分成多次合成',
  code: MergeRejectCode.timescale,
);

/// The template `moov`: boxes to copy, and the fixed fields of the ones rebuilt.
class _Moov {
  final Mp4Box box;
  final List<Mp4Box> top;
  final int timescale;
  final Uint8List mvhd;
  final List<_MoovTrak> traks;
  final List<Uint8List> extras;
  const _Moov({
    required this.box,
    required this.top,
    required this.timescale,
    required this.mvhd,
    required this.traks,
    required this.extras,
  });

  /// [traks] are the source's tracks that the merge actually carries, in order:
  /// the rebuilt `moov` must line up with them one for one, so a track the
  /// reader skipped cannot shift every template slot by one.
  static _Moov parse(_R v, Mp4Box moov, List<Mp4Box> top, List<Mp4Box> traks) {
    final mvhd = moov.child('mvhd');
    if (mvhd == null) throw const MergeReject('缺少影片信息');
    return _Moov(
      box: moov,
      top: top,
      timescale: v.u32(mvhd.payload + (v.u8(mvhd.payload) == 1 ? 20 : 12)),
      mvhd: v.slice(mvhd.payload, mvhd.size - mvhd.header),
      traks: [for (final trak in traks) _MoovTrak.parse(v, trak)],
      extras: [
        for (final b in moov.children)
          if (b.type != 'mvhd' &&
              b.type != 'trak' &&
              !Mp4Merger._ignorable.contains(b.type))
            v.slice(b.start, b.size),
      ],
    );
  }
}

class _MoovTrak {
  final int trackId;
  final Uint8List tkhd, mdhd, hdlr, minfHead, stsd;

  /// The whole `edts` box, or null when the track has no edit list.
  final Uint8List? edts;
  const _MoovTrak({
    required this.trackId,
    required this.tkhd,
    required this.mdhd,
    required this.edts,
    required this.hdlr,
    required this.minfHead,
    required this.stsd,
  });

  static _MoovTrak parse(_R v, Mp4Box trak) {
    final tkhd = trak.find('tkhd'), mdia = trak.child('mdia');
    if (tkhd == null || mdia == null) throw const MergeReject('轨道缺少头部');
    final mdhd = mdia.child('mdhd'), hdlr = mdia.child('hdlr');
    final minf = mdia.child('minf'), stbl = minf?.child('stbl');
    if (mdhd == null || hdlr == null || stbl == null) {
      throw const MergeReject('轨道结构不完整');
    }
    final stsd = stbl.child('stsd');
    if (stsd == null || stsd.children.length != 1) {
      throw const MergeReject('轨道需要单一样本描述');
    }
    final edts = trak.child('edts');
    return _MoovTrak(
      trackId: v.u32(tkhd.payload + (v.u8(tkhd.payload) == 1 ? 20 : 12)),
      tkhd: v.slice(tkhd.payload, tkhd.size - tkhd.header),
      mdhd: v.slice(mdhd.payload, mdhd.size - mdhd.header),
      // An edit list describing one episode would misdescribe the series, so
      // only the single-segment form survives, re-dated by the merge.
      edts: edts == null ? null : v.slice(edts.start, edts.size),
      hdlr: v.slice(hdlr.start, hdlr.size),
      minfHead: Uint8List.fromList([
        for (final b in minf!.children)
          if (b.type != 'stbl' && !Mp4Merger._ignorable.contains(b.type))
            ...v.slice(b.start, b.size),
      ]),
      stsd: v.slice(stsd.start, stsd.size),
    );
  }
}

Uint8List _moovBytes(_Moov base, List<_MergedTrack> merged) {
  var movieDuration = 0;
  final durations = <int>[];
  for (final m in merged) {
    // The track counts time in the timescale the merge settled on, the movie in
    // its own.
    final inMovie = m.duration * base.timescale ~/ m.timescale;
    durations.add(inMovie);
    if (inMovie > movieDuration) movieDuration = inMovie;
  }
  final body = <int>[..._boxBytes('mvhd', _mvhd(base.mvhd, movieDuration))];
  for (var t = 0; t < merged.length; t++) {
    final m = merged[t], template = base.traks[t];
    body.addAll(
      _boxBytes(
        'trak',
        Uint8List.fromList([
          ..._boxBytes('tkhd', _tkhd(template.tkhd, durations[t])),
          if (template.edts != null)
            ..._edts(
              template.edts!,
              m.duration,
              m.timescale ~/ m.template.timescale,
            ),
          ..._boxBytes(
            'mdia',
            Uint8List.fromList([
              ..._boxBytes(
                'mdhd',
                _mdhd(template.mdhd, m.duration, m.timescale),
              ),
              ...template.hdlr,
              ..._boxBytes(
                'minf',
                Uint8List.fromList([
                  ...template.minfHead,
                  ..._stbl(template.stsd, m),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
  for (final extra in base.extras) {
    body.addAll(extra);
  }
  return _boxBytes('moov', Uint8List.fromList(body));
}

Uint8List _mvhd(Uint8List template, int duration) {
  final version = template[0];
  final out = Uint8List.fromList(template);
  if (version == 1) {
    _putU64(out, 24, duration);
    return out;
  }
  if (duration > 0xffffffff) return _mvhdWide(template, duration);
  _putU32(out, 16, duration);
  return out;
}

/// QuickTime's `mvhd` v1 carries 64-bit times; the fields after duration keep
/// their v0 widths, so the payload grows by exactly twelve bytes.
Uint8List _mvhdWide(Uint8List template, int duration) {
  final out = Uint8List(template.length + 12);
  _copyVersion(out, template);
  _putU64(out, 4, _readU32(template, 4));
  _putU64(out, 12, _readU32(template, 8));
  out.setRange(20, 24, template.sublist(12, 16));
  _putU64(out, 24, duration);
  out.setRange(32, out.length, template.sublist(20, template.length));
  return out;
}

Uint8List _tkhd(Uint8List template, int duration) {
  final version = template[0];
  final out = Uint8List.fromList(template);
  if (version == 1) {
    _putU64(out, 28, duration);
    return out;
  }
  if (duration > 0xffffffff) return _tkhdWide(template, duration);
  _putU32(out, 20, duration);
  return out;
}

Uint8List _tkhdWide(Uint8List template, int duration) {
  final out = Uint8List(template.length + 12);
  _copyVersion(out, template);
  _putU64(out, 4, _readU32(template, 4));
  _putU64(out, 12, _readU32(template, 8));
  out.setRange(20, 28, template.sublist(12, 20));
  _putU64(out, 28, duration);
  out.setRange(36, out.length, template.sublist(24, template.length));
  return out;
}

/// A v1 rebuild keeps the template's flags; only the version byte changes.
void _copyVersion(Uint8List out, Uint8List template) {
  out[0] = 1;
  out.setRange(1, 4, template.sublist(1, 4));
}

/// The template's `mdhd` with the merged length and the timescale the merge
/// settled on -- the two have to move together, or every table below it counts a
/// different length of time.
Uint8List _mdhd(Uint8List template, int duration, int timescale) {
  final version = template[0];
  final out = Uint8List.fromList(template);
  if (version == 1) {
    _putU32(out, 20, timescale);
    _putU64(out, 24, duration);
    return out;
  }
  if (duration > 0xffffffff) {
    // v1 spends twelve more bytes on 64-bit times; pad and language keep their
    // place at the end of the box.
    final wide = Uint8List(36);
    _copyVersion(wide, template);
    _putU64(wide, 4, _readU32(template, 4));
    _putU64(wide, 12, _readU32(template, 8));
    wide.setRange(20, 24, template.sublist(12, 16));
    _putU32(wide, 20, timescale);
    _putU64(wide, 24, duration);
    wide.setRange(32, 36, template.sublist(20, 24));
    return wide;
  }
  _putU32(out, 12, timescale);
  _putU32(out, 16, duration);
  return out;
}

/// The template's single-segment edit list, re-dated to the merged duration. The
/// media time is in the media's own timescale, so it moves by the same factor the
/// tables were re-dated by; it keeps its value, which is where an encoder's
/// priming offset lives.
List<int> _edts(Uint8List edts, int duration, int scale) {
  final boxes = _childrenOf(edts);
  final out = <int>[];
  for (final b in boxes) {
    if (b.type != 'elst') {
      out.addAll(_sliceOf(edts, b));
      continue;
    }
    final payload = b.size - b.header;
    final rebuilt = Uint8List(payload);
    rebuilt.setRange(0, payload, edts.sublist(b.payload, b.end));
    final version = rebuilt[0];
    final count = _readU32(rebuilt, 4);
    if (count != 1) {
      // Anything more elaborate than one segment is not ours to reinterpret.
      return const [];
    }
    if (version == 1) {
      _putU64(rebuilt, 8, duration);
      _putU64(rebuilt, 16, _readI64(rebuilt, 16) * scale);
    } else {
      _putU32(rebuilt, 8, duration);
      _putU32(rebuilt, 12, _readI32(rebuilt, 12) * scale);
    }
    out.addAll(_boxBytes('elst', rebuilt));
  }
  return _boxBytes('edts', Uint8List.fromList(out));
}

/// `elst` media times are signed, and the field is read back to be re-dated.
int _readI32(Uint8List b, int at) =>
    ByteData.sublistView(b).getInt32(at, Endian.big);

int _readI64(Uint8List b, int at) =>
    ByteData.sublistView(b).getInt64(at, Endian.big);

List<int> _stbl(Uint8List stsd, _MergedTrack m) {
  final out = <int>[...stsd];
  out.addAll(_boxBytes('stts', _stts(m)));
  out.addAll(_boxBytes('stsc', _stsc([for (final c in m.chunks) c.samples])));
  out.addAll(_boxBytes('stsz', _stsz(m)));
  out.addAll(
    _boxBytes(
      m.chunks.any((c) => c.offset > 0xffffffff) ? 'co64' : 'stco',
      _chunkOffsets(m),
    ),
  );
  final sync = _stss(m);
  if (sync != null) out.addAll(_boxBytes('stss', sync));
  final composition = _ctts(m);
  if (composition != null) out.addAll(_boxBytes('ctts', composition));
  return _boxBytes('stbl', Uint8List.fromList(out));
}

Uint8List _stts(_MergedTrack m) {
  final entries = <_Time>[];
  for (final e in m.runs) {
    if (entries.isNotEmpty && entries.last.delta == e.delta) {
      entries[entries.length - 1] = _Time(
        entries.last.count + e.count,
        e.delta,
      );
    } else {
      entries.add(e);
    }
  }
  final body = Uint8List(8 + entries.length * 8);
  _putU32(body, 4, entries.length);
  for (var i = 0; i < entries.length; i++) {
    _putU32(body, 8 + i * 8, entries[i].count);
    _putU32(body, 8 + i * 8 + 4, entries[i].delta);
  }
  return body;
}

/// Consecutive chunks with the same sample count share one `stsc` entry, which is
/// what an encoder emits too.
Uint8List _stsc(List<int> chunkCounts) {
  final runs = <_Time>[];
  var at = 0;
  while (at < chunkCounts.length) {
    var run = 1;
    while (at + run < chunkCounts.length &&
        chunkCounts[at + run] == chunkCounts[at]) {
      run++;
    }
    runs.add(_Time(at + 1, chunkCounts[at]));
    at += run;
  }
  final body = Uint8List(8 + runs.length * 12);
  _putU32(body, 4, runs.length);
  for (var i = 0; i < runs.length; i++) {
    _putU32(body, 8 + i * 12, runs[i].count);
    _putU32(body, 8 + i * 12 + 4, runs[i].delta);
    _putU32(body, 8 + i * 12 + 8, 1);
  }
  return body;
}

Uint8List _stsz(_MergedTrack m) {
  final sizes = <int>[];
  for (final part in m.parts) {
    sizes.addAll(part.sizes);
  }
  var uniform = sizes.isEmpty ? 0 : sizes.first;
  for (final s in sizes) {
    if (s != uniform) {
      uniform = 0;
      break;
    }
  }
  if (uniform != 0) {
    final head = Uint8List(12);
    _putU32(head, 4, uniform);
    _putU32(head, 8, sizes.length);
    return head;
  }
  final body = Uint8List(12 + sizes.length * 4);
  _putU32(body, 8, sizes.length);
  for (var i = 0; i < sizes.length; i++) {
    _putU32(body, 12 + i * 4, sizes[i]);
  }
  return body;
}

Uint8List _chunkOffsets(_MergedTrack m) {
  final wide = m.chunks.any((c) => c.offset > 0xffffffff);
  final step = wide ? 8 : 4;
  final body = Uint8List(8 + m.chunks.length * step);
  _putU32(body, 4, m.chunks.length);
  for (var i = 0; i < m.chunks.length; i++) {
    if (wide) {
      _putU64(body, 8 + i * 8, m.chunks[i].offset);
    } else {
      _putU32(body, 8 + i * 4, m.chunks[i].offset);
    }
  }
  return body;
}

/// Null when every merged sample is a sync sample: a file without `stss` already
/// says exactly that, and saying it twice only bloats the metadata.
Uint8List? _stss(_MergedTrack m) {
  final sync = <int>[];
  var first = 0;
  for (final part in m.parts) {
    final list = part.syncSamples;
    if (list == null) {
      for (var i = 1; i <= part.samples; i++) {
        sync.add(first + i);
      }
    } else {
      for (final s in list) {
        sync.add(first + s);
      }
    }
    first += part.samples;
  }
  for (var i = 0; i < sync.length; i++) {
    if (sync[i] != i + 1) {
      final body = Uint8List(8 + sync.length * 4);
      _putU32(body, 4, sync.length);
      for (var j = 0; j < sync.length; j++) {
        _putU32(body, 8 + j * 4, sync[j]);
      }
      return body;
    }
  }
  return null;
}

/// The composition offsets, already re-dated into the merged timescale. A part
/// whose own file has no `ctts` contributes one run of zeros, which is what its
/// missing table asserts.
Uint8List? _ctts(_MergedTrack m) {
  if (!m.hasComposition) return null;
  final entries = m.compositions;
  final head = Uint8List(8);
  head[0] = m.cttsVersion;
  _putU32(head, 4, entries.length);
  final body = Uint8List(entries.length * 8);
  for (var i = 0; i < entries.length; i++) {
    _putU32(body, i * 8, entries[i].count);
    _putU32(body, i * 8 + 4, entries[i].offset);
  }
  return Uint8List.fromList([...head, ...body]);
}

List<int> _isom() {
  final out = Uint8List(24);
  out.setRange(0, 4, convert.latin1.encode('isom'));
  _putU32(out, 4, 0x200);
  out.setRange(8, 12, convert.latin1.encode('isom'));
  out.setRange(12, 16, convert.latin1.encode('iso2'));
  out.setRange(16, 20, convert.latin1.encode('avc1'));
  out.setRange(20, 24, convert.latin1.encode('mp41'));
  return out;
}

int _mdhdTimescale(_R v, Mp4Box mdhd) =>
    v.u32(mdhd.payload + (v.u8(mdhd.payload) == 1 ? 20 : 12));

int _mdhdDuration(_R v, Mp4Box mdhd) {
  if (v.u8(mdhd.payload) == 1) {
    final high = v.u32(mdhd.payload + 24);
    if (high != 0) throw const MergeReject('轨道时长超出可合并范围');
    return v.u32(mdhd.payload + 28);
  }
  return v.u32(mdhd.payload + 16);
}

Uint8List _boxBytes(String type, List<int> payload) {
  final out = Uint8List(8 + payload.length);
  _putU32(out, 0, out.length);
  out.setRange(4, 8, convert.latin1.encode(type));
  out.setRange(8, out.length, payload);
  return out;
}

/// `Uint8List` compares by identity, and this package has no collection library
/// to borrow an element-wise equality from.
bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The immediate children of a box payload, for the boxes rebuilt by hand.
List<Mp4Box> _childrenOf(Uint8List bytes) {
  final v = _R(bytes, 0);
  final out = <Mp4Box>[];
  var p = 8;
  while (p + 8 <= bytes.length) {
    var size = v.u32(p), header = 8;
    final type = v.text(p + 4, 4);
    if (size == 1) {
      size = v.u64(p + 8);
      header = 16;
    }
    if (size == 0) size = bytes.length - p;
    if (size < header || p + size > bytes.length) break;
    out.add(Mp4Box(type, p, size, header, const []));
    p += size;
  }
  return out;
}

List<int> _sliceOf(Uint8List bytes, Mp4Box box) =>
    bytes.sublist(box.start, box.start + box.size);

int _readU32(Uint8List b, int at) {
  return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}

void _putU32(Uint8List b, int at, int value) {
  final v = value & 0xffffffff;
  b[at] = v >> 24 & 0xff;
  b[at + 1] = v >> 16 & 0xff;
  b[at + 2] = v >> 8 & 0xff;
  b[at + 3] = v & 0xff;
}

void _putU64(Uint8List b, int at, int value) {
  _putU32(b, at, value >> 32);
  _putU32(b, at + 4, value);
}

/// A buffer that grows in blocks, so a whole merged file never sits in memory
/// twice while it is assembled.
class _Grower {
  final _parts = <Uint8List>[];
  int length = 0;
  void add(Uint8List bytes) {
    _parts.add(bytes);
    length += bytes.length;
  }

  Uint8List take() {
    final out = Uint8List(length);
    var at = 0;
    for (final p in _parts) {
      out.setRange(at, at + p.length, p);
      at += p.length;
    }
    _parts.clear();
    length = 0;
    return out;
  }
}

/// Big-endian reads over a byte range anchored at an absolute file position — the
/// same view the private reader in `mp4.dart` uses, for the tables it does not
/// parse.
class _R {
  final Uint8List b;
  final int base;
  _R(this.b, this.base);

  void _need(int at, int size) {
    if (at < base || size < 0 || at + size > base + b.length) {
      throw const MergeReject('源文件的元数据不完整');
    }
  }

  int u8(int p) {
    _need(p, 1);
    return b[p - base];
  }

  int u16(int p) {
    _need(p, 2);
    return ByteData.sublistView(b).getUint16(p - base);
  }

  int u32(int p) {
    _need(p, 4);
    return ByteData.sublistView(b).getUint32(p - base);
  }

  int i32(int p) {
    _need(p, 4);
    return ByteData.sublistView(b).getInt32(p - base);
  }

  int u64(int p) {
    _need(p, 8);
    return ByteData.sublistView(b).getUint64(p - base);
  }

  Uint8List slice(int p, int length) {
    _need(p, length);
    return Uint8List.fromList(b.sublist(p - base, p - base + length));
  }

  String text(int p, int length) => convert.latin1.decode(slice(p, length));
}
