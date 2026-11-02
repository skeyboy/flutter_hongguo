import 'dart:io';
import 'dart:typed_data';

import '../crypto/bytes.dart';
import 'mp4.dart';

/// A monotonic slice of progressive output: copy input verbatim, decrypt one
/// sample, emit the patched moov, or skip the original moov region.
class _Piece {
  final int inStart, inEnd;

  /// -4 in-place patch marker, -3 copy-through-complete, -2 relocated patched
  /// moov, -1 verbatim, otherwise the index into [ProgressivePlan.encryptions].
  final int encryption;

  /// How many encrypted bytes must be on disk before this piece can be
  /// emitted (0 when the piece reads only from the prefetched plan).
  final int coverage;
  const _Piece(this.inStart, this.inEnd, this.encryption, {int? coverage})
    : coverage = coverage ?? inEnd;
}

class _Span {
  final int start, end;
  final SampleEncryption? encryption;
  const _Span(this.start, this.end, this.encryption);
}

class ProgressivePlan {
  final int total, delta;
  final List<_Piece> pieces;
  final Uint8List moovPatch;
  final List<SampleEncryption> encryptions;
  final Uint8List key;

  /// Output offset where media bytes start, i.e. just past the playable
  /// metadata. A stream is worth opening once its prefix passes this point.
  final int metadataEnd;
  ProgressivePlan._(
    this.total,
    this.delta,
    this.pieces,
    this.moovPatch,
    this.encryptions,
    this.key,
    this.metadataEnd,
  );

  /// Builds a progressive recipe over [metadata]: a store exposing the file
  /// length and its metadata, which is all [Mp4Cenc.inspect] reads — top-level
  /// box headers and the moov. A store backed by a partial download plus range
  /// fetches of the header regions it lacks is therefore enough; the sample
  /// payload itself is never read here.
  ///
  /// A head-moov file is decrypted in place (identity mapping, delta 0). A
  /// tail-moov file is remapped into faststart layout: head boxes, the
  /// relocated patched moov, then the mdat header and payload in physical
  /// order, each shifted by `+moovSize`; chunk tables are rewritten with the
  /// same delta. Throws FormatException/UnsupportedError for any layout
  /// progressive playback cannot serve monotonically; callers fall back to
  /// whole-file preparation on any error.
  static ProgressivePlan build(SampleStore metadata, String keyHex) {
    final plan = Mp4Cenc.inspect(metadata);
    if (plan.encryptedSamples == 0) {
      throw const FormatException('Progressive needs encrypted samples');
    }
    final moov = plan.moov;
    final total = metadata.length;
    final mdat = plan.top.firstWhere((b) => b.type == 'mdat');
    final payload = mdat.payload;
    final relocate = moov.start >= mdat.end;
    if (relocate && moov.end != total) {
      throw const FormatException('Boxes after moov need full tail coverage');
    }
    if (!relocate && moov.end > payload) {
      throw const FormatException('moov overlaps mdat payload');
    }
    final delta = relocate ? moov.size : 0;
    // Both layouts emit the whole playable metadata — head boxes, patched
    // moov, mdat header — before the first payload byte, so the output prefix
    // just short of the remapped payload start is the point where a stream
    // becomes openable.
    final metadataEnd = payload + delta;
    // plan.metadata is the moov read at its own offset, so the patched copy is
    // already position-correct for either layout.
    final patched = Uint8List.fromList(plan.metadata);
    final tree = Mp4Cenc.applyMoovClearPatch(patched, moov);
    if (delta != 0) _rewriteChunkTables(patched, moov, tree, delta);
    final spans = <_Span>[];
    for (final track in plan.tracks) {
      for (var i = 0; i < track.sizes.length; i++) {
        if (track.sizes[i] == 0) continue;
        if (track.offsets[i] < payload ||
            track.offsets[i] + track.sizes[i] > mdat.end) {
          throw const FormatException('Sample outside mdat payload');
        }
        spans.add(
          _Span(
            track.offsets[i],
            track.offsets[i] + track.sizes[i],
            track.encryption.isNotEmpty ? track.encryption[i] : null,
          ),
        );
      }
    }
    spans.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < spans.length; i++) {
      if (spans[i].start < spans[i - 1].end) {
        throw const FormatException('Progressive requires ordered samples');
      }
    }
    final encryptions = <SampleEncryption>[];
    final pieces = <_Piece>[];
    var expectedOut = 0, inCursor = 0, emitCursor = payload;
    void advance(_Piece piece) {
      // -2/-4 (recipe-buffer patches) and -3 (completion) are gated by their
      // coverage field at pump time; they consume no stream bytes.
      final buffered = piece.encryption <= -2;
      if (!buffered && piece.inStart < inCursor) {
        throw const FormatException('Non-monotonic progressive input');
      }
      if (!buffered && piece.inEnd > inCursor) inCursor = piece.inEnd;
      expectedOut += piece.inEnd - piece.inStart;
      pieces.add(piece);
    }

    void emitGap(int end) {
      if (end > emitCursor) {
        advance(_Piece(emitCursor, end, -1));
        emitCursor = end;
      }
    }

    if (relocate) {
      // Faststart remap: head boxes, the relocated patched moov, then the
      // mdat header and payload, all streamed in physical order. Every byte
      // from the mdat header onward lands `moov.size` later in the output,
      // which is the same delta the chunk tables were rewritten with; the
      // physical moov region is never read from the growing file.
      advance(_Piece(0, mdat.start, -1));
      advance(_Piece(moov.start, moov.end, -2, coverage: 0));
      advance(_Piece(mdat.start, mdat.payload, -1));
      emitCursor = mdat.payload;
      for (final span in spans) {
        emitGap(span.start);
        if (span.encryption == null) {
          advance(_Piece(span.start, span.end, -1));
        } else {
          encryptions.add(span.encryption!);
          advance(_Piece(span.start, span.end, encryptions.length - 1));
        }
        emitCursor = span.end;
      }
      emitGap(mdat.end);
      if (mdat.end > moov.start) {
        throw const FormatException('mdat overlaps relocated moov');
      }
      advance(_Piece(mdat.end, moov.start, -1));
      advance(_Piece(total, total, -3, coverage: total + 1));
    } else {
      // head-moov identity: the file streams in physical order; once the
      // physical moov has been copied verbatim, a zero-length marker seeks
      // back and overwrites the clear bytes in place, then copies continue.
      advance(_Piece(0, moov.end, -1));
      advance(_Piece(moov.start, moov.start, -4, coverage: moov.end));
      emitCursor = moov.end;
      for (final span in spans) {
        emitGap(span.start);
        if (span.encryption == null) {
          advance(_Piece(span.start, span.end, -1));
        } else {
          encryptions.add(span.encryption!);
          advance(_Piece(span.start, span.end, encryptions.length - 1));
        }
        emitCursor = span.end;
      }
      emitGap(mdat.end);
      advance(_Piece(mdat.end, total, -1));
    }
    if (expectedOut != total) {
      throw const FormatException('Progressive layout changes file size');
    }
    return ProgressivePlan._(
      total,
      delta,
      pieces,
      patched,
      encryptions,
      unhex(keyHex),
      metadataEnd,
    );
  }
}

/// Shift every stco/co64 chunk offset inside the patched moov copy. [tree] is
/// the re-parsed moov, anchored at the file offsets [patched] was read from,
/// so box positions become buffer positions through [moov].
void _rewriteChunkTables(
  Uint8List patched,
  Mp4Box moov,
  Mp4Box tree,
  int delta,
) {
  for (final box in tree.descendants) {
    if (box.type != 'stco' && box.type != 'co64') continue;
    final wide = box.type == 'co64';
    final view = ByteData.sublistView(
      patched,
      box.payload - moov.start,
      box.end - moov.start,
    );
    final count = view.getUint32(4);
    if (8 + count * (wide ? 8 : 4) > box.size - box.header) {
      throw const FormatException('Truncated chunk table');
    }
    for (var i = 0; i < count; i++) {
      if (wide) {
        final value =
            (BigInt.from(view.getUint32(8 + i * 8)) << 32) |
            BigInt.from(view.getUint32(12 + i * 8));
        final next = value + BigInt.from(delta);
        if (next < BigInt.zero || next > BigInt.parse('9007199254740991')) {
          throw const FormatException('Chunk offset escapes support range');
        }
        view.setUint32(8 + i * 8, (next >> 32).toInt());
        view.setUint32(12 + i * 8, (next & BigInt.from(0xffffffff)).toInt());
      } else {
        final next = view.getUint32(8 + i * 4) + delta;
        if (next < 0 || next > 0xffffffff) {
          throw const FormatException('Chunk offset escapes stco range');
        }
        view.setUint32(8 + i * 4, next);
      }
    }
  }
}

/// Sequential progressive writer feeding the local stream server: consumes
/// the growing encrypted working file and appends the relocated, decrypted
/// layout to [output]. Coverage gaps stall; overlaps or a shrinking input
/// throw and the caller falls back to whole-file preparation.
class ProgressiveDecrypt {
  final ProgressivePlan plan;
  final RandomAccessFile input, output;
  int _piece = 0, _out = 0, _covered = 0, _pending = 0;
  Uint8List? _window;
  int _windowStart = 0;
  bool _done = false;

  ProgressiveDecrypt._(this.plan, this.input, this.output);

  static Future<ProgressiveDecrypt> open(
    String encryptedPath,
    String clearPath,
    ProgressivePlan plan,
  ) async {
    final input = await File(encryptedPath).open(mode: FileMode.append);
    RandomAccessFile? output;
    try {
      output = await File(clearPath).open(mode: FileMode.write);
      return ProgressiveDecrypt._(plan, input, output);
    } catch (_) {
      await input.close();
      await output?.close();
      rethrow;
    }
  }

  int get availableBytes => _out;
  bool get completed => _done;

  /// [position] is how many encrypted bytes the transfer has reported. It is
  /// only a hint: a download sink buffers, so the file itself decides what can
  /// be decrypted now, and a read past the flushed prefix would fail the whole
  /// stream for bytes that arrive a moment later.
  /// Returns the clear-output byte prefix currently playable. Pieces are
  /// emitted only once their [coverage] watermark is on disk; the -4 marker
  /// rewrites the already-copied moov region in place, so the playable
  /// prefix stays contiguous even for head-moov files.
  Future<int> pump(int position, {bool downloadComplete = false}) async {
    if (_done) return _out;
    if (position > plan.total) {
      throw const FormatException('Input exceeds planned size');
    }
    final flushed = await input.length();
    if (flushed > plan.total) {
      throw const FormatException('Input exceeds planned size');
    }
    final covered = position > flushed ? flushed : position;
    _covered = covered > _covered ? covered : _covered;
    final endOfData = downloadComplete ? plan.total : plan.total + 1;
    while (_piece < plan.pieces.length) {
      final piece = plan.pieces[_piece];
      final need = piece.inEnd == plan.total && piece.coverage > plan.total
          ? endOfData
          : piece.coverage;
      if (_covered < need) break;
      final length = piece.inEnd - piece.inStart;
      switch (piece.encryption) {
        case -4:
          await output.setPosition(piece.inStart);
          await output.writeFrom(plan.moovPatch);
          await output.setPosition(_out);
        case -2:
          if (length > 0) await output.writeFrom(plan.moovPatch);
        case -3:
          break;
        case -1:
          await output.writeFrom(await _read(piece.inStart, length));
        default:
          final bytes = await _read(piece.inStart, length);
          await output.writeFrom(
            Mp4Cenc.decryptSample(
              bytes,
              plan.encryptions[piece.encryption],
              plan.key,
            ),
          );
      }
      _out += length;
      _pending += length;
      _piece++;
      if (_pending >= 64 * 1024) {
        await output.flush();
        _pending = 0;
      }
    }
    if (_piece == plan.pieces.length) {
      await output.flush();
      _pending = 0;
      _done = true;
    }
    return _out;
  }

  Future<Uint8List> _read(int start, int length) async {
    final window = _window;
    if (window != null &&
        start >= _windowStart &&
        start + length <= _windowStart + window.length) {
      return Uint8List.sublistView(
        window,
        start - _windowStart,
        start - _windowStart + length,
      );
    }
    final bytes = Uint8List(length);
    await input.setPosition(start);
    var read = 0;
    while (read < length) {
      final n = await input.readInto(bytes, read, length);
      if (n == 0) throw const FormatException('Unexpected EOF while streaming');
      read += n;
    }
    _window = bytes;
    _windowStart = start;
    return bytes;
  }

  Future<void> close() async {
    try {
      await output.flush();
    } finally {
      await output.close();
      await input.close();
    }
  }
}
