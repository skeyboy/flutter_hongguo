import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

Uint8List bytes(String name) =>
    File('test/fixtures/media/$name').readAsBytesSync();

final realKey =
    jsonDecode(File('test/fixtures/media/real.json').readAsStringSync())['key']
        as String;

/// An episode as the merge lane receives it: already decrypted in place.
MemorySampleStore decrypted() {
  final store = MemorySampleStore(Uint8List.fromList(bytes('real.cenc.mp4')));
  Mp4Cenc.decrypt(store, Mp4Cenc.inspect(store), unhex(realKey));
  return store;
}

MergeSource sourceOf(Uint8List value) =>
    Mp4Merger.read(MemorySampleStore(value));

/// Every sample of every track, addressed by its absolute file offset.
List<List<Uint8List>> sampleBytes(SampleStore store, List<Mp4Track> tracks) => [
  for (final track in tracks)
    [
      for (var i = 0; i < track.sizes.length; i++)
        store.read(track.offsets[i], track.sizes[i]),
    ],
];

List<List<Uint8List>> sourceSamples(Uint8List file) => sampleBytes(
  MemorySampleStore(file),
  Mp4Cenc.inspect(MemorySampleStore(file)).tracks,
);

Matcher refusedBy(String reason) =>
    isA<MergeReject>().having((e) => e.reason, 'reason', contains(reason));

/// A size-preserving edit of one box field, so a source differs from its twin in
/// exactly the way the merge precheck has to notice. Boxes are big-endian, and a
/// timescale written the other way is a different number than the one the test
/// names -- which matters as soon as the merge has to compute with it.
Uint8List edit(
  Uint8List source,
  String type,
  int index,
  int Function(int version) field,
  int value, {
  int width = 4,
}) {
  final out = Uint8List.fromList(source);
  final box = Mp4Cenc.inspect(MemorySampleStore(out)).moov.descendants
      .where((b) => b.type == type)
      .toList()[index];
  final view = ByteData.sublistView(out);
  final at = box.payload + field(out[box.payload]);
  if (width == 2) {
    view.setUint16(at, value, Endian.big);
  } else {
    view.setUint32(at, value, Endian.big);
  }
  return out;
}

Uint8List bumpLast(Uint8List source, String type) {
  final out = Uint8List.fromList(source);
  final box = Mp4Cenc.inspect(MemorySampleStore(out)).moov.descendants
      .firstWhere((b) => b.type == type);
  out[box.end - 1] = out[box.end - 1] + 1;
  return out;
}

/// One table the file no longer claims to have, with every offset left exactly
/// where it was: a box renamed to `free` keeps its size and is skipped by the
/// readers, which is how a source without `ctts` is stood up.
Uint8List hideBox(Uint8List source, String type) {
  final out = Uint8List.fromList(source);
  final box = Mp4Cenc.inspect(MemorySampleStore(out)).moov.descendants
      .firstWhere((b) => b.type == type);
  out.setRange(box.start + 4, box.start + 8, latin1.encode('free'));
  return out;
}

Uint8List setVersion(Uint8List source, String type, int value) {
  final out = Uint8List.fromList(source);
  final box = Mp4Cenc.inspect(MemorySampleStore(out)).moov.descendants
      .firstWhere((b) => b.type == type);
  out[box.payload] = value;
  return out;
}

/// One track renamed to a different kind: the same number of tracks, and the one
/// pairing genuinely cannot answer.
Uint8List setHandler(Uint8List source, int index, String handler) {
  final out = Uint8List.fromList(source);
  final hdlr = Mp4Cenc.inspect(MemorySampleStore(out)).moov.descendants
      .where((b) => b.type == 'hdlr')
      .toList()[index];
  out.setRange(hdlr.payload + 8, hdlr.payload + 12, latin1.encode(handler));
  return out;
}

/// Reverses the two `trak` boxes inside `moov`, which keeps the metadata the same
/// length and so leaves every chunk offset pointing at its sample: one file with
/// its tracks in the other order, nothing else changed.
Uint8List swapTraks(Uint8List source) {
  final traks = Mp4Cenc.inspect(MemorySampleStore(source)).moov.descendants
      .where((b) => b.type == 'trak')
      .toList();
  if (traks.length != 2) throw StateError('需要两条轨道');
  final a = traks[0], b = traks[1];
  final out = Uint8List(source.length);
  var at = 0;
  void copy(List<int> bytes) {
    out.setRange(at, at + bytes.length, bytes);
    at += bytes.length;
  }

  copy(source.sublist(0, a.start));
  copy(source.sublist(b.start, b.end));
  copy(source.sublist(a.start, a.end));
  copy(source.sublist(b.end));
  return out;
}

/// The `elst` media time of the first track: where the encoder's priming offset
/// lives, and the field a timescale change has to move with it.
int firstMediaTime(Uint8List file) {
  final elst = Mp4Cenc.inspect(MemorySampleStore(file)).moov.descendants
      .firstWhere((b) => b.type == 'elst');
  final view = ByteData.sublistView(file);
  return file[elst.payload] == 1
      ? view.getInt64(elst.payload + 16, Endian.big)
      : view.getInt32(elst.payload + 12, Endian.big);
}

int firstTimescale(Uint8List file, String handler) {
  final source = Mp4Merger.read(MemorySampleStore(file));
  return source.tracks.firstWhere((t) => t.handler == handler).timescale;
}

void main() {
  test('three episodes merge into one file that keeps every sample', () {
    final episode = decrypted(), first = Mp4Merger.read(episode);
    final originals = sourceSamples(episode.bytes);
    final plan = Mp4Merger.plan([first, first, first]);
    final progress = <List<int>>[];
    final sink = MemoryMergeSink();
    Mp4Merger.write(plan, sink, onProgress: (d, t) => progress.add([d, t]));
    final out = sink.takeBytes();
    expect(out.length, plan.outputBytes);
    expect(progress.last, [plan.workBytes, plan.workBytes]);
    expect(progress.every((p) => p[1] == plan.workBytes), isTrue);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i][0], greaterThanOrEqualTo(progress[i - 1][0]));
    }

    final store = MemorySampleStore(out);
    final merged = Mp4Cenc.inspect(store);
    expect(merged.encryptedSamples, 0);
    expect(
      merged.tracks.map((t) => t.handler),
      first.tracks.map((t) => t.handler),
    );
    expect(sampleBytes(store, merged.tracks), [
      for (var t = 0; t < first.tracks.length; t++)
        [for (var part = 0; part < 3; part++) ...originals[t]],
    ]);

    final product = Mp4Merger.read(store);
    for (var t = 0; t < first.tracks.length; t++) {
      final track = first.tracks[t], grown = product.tracks[t];
      expect(grown.duration, track.duration * 3);
      expect(grown.samples, track.samples * 3);
      expect(grown.chunkCounts, [
        for (var part = 0; part < 3; part++) ...track.chunkCounts,
      ]);
      expect(
        grown.syncSamples,
        track.syncSamples == null
            ? isNull
            : [
                for (var part = 0; part < 3; part++)
                  for (final s in track.syncSamples!) s + part * track.samples,
              ],
      );
      expect(
        grown.composition?.length,
        track.composition == null ? null : track.composition!.length * 3,
      );
      expect(grown.cttsVersion, track.cttsVersion);
      expect(
        grown.chunkOffsets.first,
        greaterThanOrEqualTo(first.lead.length + 8),
      );
      for (var i = 1; i < grown.chunkOffsets.length; i++) {
        expect(
          grown.chunkOffsets[i],
          greaterThan(grown.chunkOffsets[i - 1]),
          reason: '${grown.handler} chunk $i',
        );
      }
    }
    expect(product.durationMs, closeTo(first.durationMs * 3, 1));
  });

  test('an append grows the product without moving its media', () {
    final temp = Directory.systemTemp.createTempSync('hongguo-merge-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final episode = decrypted(), first = Mp4Merger.read(episode);
    final originals = sourceSamples(episode.bytes);
    final file = File('${temp.path}/merged.mp4');
    final fresh = Mp4Merger.plan([first, first]);
    var raf = file.openSync(mode: FileMode.write);
    Mp4Merger.write(fresh, FileMergeSink(raf));
    raf.closeSync();
    final before = file.readAsBytesSync();
    expect(before.length, fresh.outputBytes);

    final product = Mp4Merger.read(MemorySampleStore(before));
    expect(product.tracks.map((t) => t.samples), [
      for (final t in first.tracks) t.samples * 2,
    ]);
    final grown = Mp4Merger.appendPlan(product, [first]);
    raf = file.openSync(mode: FileMode.append);
    Mp4Merger.append(grown, raf);
    raf.closeSync();

    final after = file.readAsBytesSync();
    expect(after.length, grown.outputBytes);
    // Inside the region that was already written, only the box that counts the
    // data may change: every media byte keeps its place.
    final cut = grown.appendAt!;
    final sizeField = {
      grown.mdatStart!,
      grown.mdatStart! + 1,
      grown.mdatStart! + 2,
      grown.mdatStart! + 3,
    };
    expect(
      [
        for (var i = 0; i < cut; i++)
          if (after[i] != before[i]) i,
      ].where((i) => !sizeField.contains(i)),
      isEmpty,
    );
    expect(
      ByteData.sublistView(after).getUint32(grown.mdatStart!),
      grown.mdatSize,
    );

    expect(sourceSamples(after), [
      for (var t = 0; t < first.tracks.length; t++)
        [for (var part = 0; part < 3; part++) ...originals[t]],
    ]);
    expect(
      Mp4Merger.read(MemorySampleStore(after)).tracks.map((t) => t.samples),
      [for (final t in first.tracks) t.samples * 3],
    );
  });

  test('a merge killed mid-copy resumes at the journal boundary', () {
    final temp = Directory.systemTemp.createTempSync('hongguo-resume-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final episode = decrypted(), first = Mp4Merger.read(episode);
    final base = Mp4Merger.plan([first, first]);

    Uint8List run(MergePlan plan, [int cut = 0]) {
      final file = File('${temp.path}/out-$cut-${plan.workBytes}.mp4')
        ..createSync();
      final raf = file.openSync(mode: FileMode.write);
      late int written;
      if (cut > 0) {
        expect(
          () => Mp4Merger.write(
            plan,
            FileMergeSink(raf),
            onProgress: (d, _) {
              written = d;
              if (d >= cut) throw const MergeReject('进程被杀');
            },
          ),
          throwsA(isA<MergeReject>()),
        );
        // A worker only trusts the journal up to a whole copy, and re-cuts the
        // part file to exactly there before it continues.
        final keep = plan.boundary(written);
        expect(written, allOf(greaterThan(0), lessThan(plan.workBytes)));
        raf.truncateSync(plan.prefixBytes + keep);
        raf.setPositionSync(plan.prefixBytes + keep);
        Mp4Merger.write(plan, FileMergeSink(raf), resumed: keep);
      } else {
        Mp4Merger.write(plan, FileMergeSink(raf));
      }
      raf.closeSync();
      return file.readAsBytesSync();
    }

    final uninterrupted = run(base);
    expect(run(base, base.workBytes ~/ 3), uninterrupted);

    final tail = Mp4Merger.appendPlan(
      Mp4Merger.read(MemorySampleStore(uninterrupted)),
      [first],
    );
    final reference = File('${temp.path}/append-ref.mp4')
      ..writeAsBytesSync(uninterrupted);
    var raf = reference.openSync(mode: FileMode.append);
    Mp4Merger.append(tail, raf);
    raf.closeSync();

    final interrupted = File('${temp.path}/append-part.mp4')
      ..writeAsBytesSync(uninterrupted);
    raf = interrupted.openSync(mode: FileMode.append);
    late int written;
    expect(
      () => Mp4Merger.append(
        tail,
        raf,
        onProgress: (d, _) {
          written = d;
          if (d >= tail.workBytes ~/ 3) throw const MergeReject('进程被杀');
        },
      ),
      throwsA(isA<MergeReject>()),
    );
    // The resume re-cuts the product itself, so bytes a killed write left past
    // the trusted boundary cannot survive into it.
    raf.truncateSync(tail.appendAt! + written + 4096);
    Mp4Merger.append(tail, raf, resumed: tail.boundary(written));
    raf.closeSync();
    expect(interrupted.readAsBytesSync(), reference.readAsBytesSync());
    expect(
      Mp4Merger.read(MemorySampleStore(interrupted.readAsBytesSync())).tracks
          .map((t) => t.samples),
      [for (final t in first.tracks) t.samples * 3],
    );
  });

  test('a fast-start source merges into a product that can grow', () {
    final fast = sourceOf(bytes('clear.mp4'));
    expect(
      () => Mp4Merger.appendPlan(fast, [fast]),
      throwsA(refusedBy('元数据在数据之前')),
    );
    final sink = MemoryMergeSink();
    Mp4Merger.write(Mp4Merger.plan([fast, fast]), sink);
    expect(
      () => Mp4Merger.appendPlan(sourceOf(sink.takeBytes()), [fast]),
      returnsNormally,
    );
  });

  test('a frame size is read from the sample entry, not the display hint', () {
    final clear = bytes('clear.mp4');
    final video = sourceOf(clear).tracks.firstWhere((t) => t.handler == 'vide');
    // A muxer may leave `tkhd`'s display size empty and still describe a real
    // picture: this file states 160x288 in its `avc1` entry and 160x0 in its
    // header. The coded frame is the number a decoder, and a re-encode, uses.
    expect([video.width, video.height], [160, 0]);
    expect([video.codedWidth, video.codedHeight], [160, 288]);

    // Editing the hint moves `width/height` alone, so the two fields keep their
    // separate meanings: what is shown versus what is stored.
    final hinted = edit(
      clear,
      'tkhd',
      0,
      (version) => version == 1 ? 90 : 78,
      576,
      width: 2,
    );
    final hintedVideo = sourceOf(hinted).tracks
        .firstWhere((t) => t.handler == 'vide');
    expect(hintedVideo.height, 576);
    expect(hintedVideo.codedHeight, 288);

    // An audio entry keeps numbers of its own where a video entry keeps its
    // frame, so nothing is invented for a track that has no picture.
    final sound = sourceOf(clear).tracks.firstWhere((t) => t.handler != 'vide');
    expect([sound.codedWidth, sound.codedHeight], [0, 0]);
  });

  test('episodes that differ only in their tables are re-dated, not refused', () {
    final clear = bytes('clear.mp4'), base = sourceOf(clear);
    final originals = sourceSamples(clear);
    Uint8List merge(Uint8List other) {
      final sink = MemoryMergeSink();
      Mp4Merger.write(Mp4Merger.plan([base, sourceOf(other)]), sink);
      return sink.takeBytes();
    }

    // A timescale is only a way of counting seconds, so two of them become the
    // least multiple of both and every delta, duration and edit follows.
    final wide = edit(clear, 'mdhd', 0, (v) => v == 1 ? 20 : 12, 15360);
    final rescaled = merge(wide);
    expect(Mp4Merger.rejectOf([base, sourceOf(wide)]), isNull);
    expect(firstTimescale(rescaled, 'vide'), 61440);
    // 18432/12288 + 18432/15360, counted in the timescale the merge settled on.
    expect(
      Mp4Merger.read(MemorySampleStore(rescaled)).tracks.first.durationMs,
      2700,
    );
    expect(firstMediaTime(rescaled), firstMediaTime(clear) * 5);
    expect(sourceSamples(rescaled), [
      for (final t in originals) [...t, ...t],
    ]);

    // A file with no composition table says its samples are pass-throughs, which
    // is one run of zero offsets in the shared table.
    final plain = merge(hideBox(clear, 'ctts'));
    final kept = Mp4Merger.read(MemorySampleStore(plain));
    expect(kept.tracks.first.composition!.fold(0, (a, c) => a + c.count), 36);
    expect(kept.tracks.first.composition!.last.offset, 0);
    expect(sourceSamples(plain), [
      for (final t in originals) [...t, ...t],
    ]);

    // v1 is the signed form of the same table: one v1 source lifts the merged
    // table without changing any offset.
    final signed = Mp4Merger.read(
      MemorySampleStore(merge(setVersion(clear, 'ctts', 1))),
    );
    expect(signed.tracks.first.cttsVersion, 1);
    expect(
      signed.tracks.first.composition!.take(18).map((c) => c.offset).toList(),
      base.tracks.first.composition!.map((c) => c.offset).toList(),
    );

    // Two tracks in the other order are the same two tracks.
    final swapped = swapTraks(clear);
    expect(Mp4Merger.rejectOf([base, sourceOf(swapped)]), isNull);
    final out = merge(swapped);
    expect(
      Mp4Merger.read(MemorySampleStore(out)).tracks.map((t) => t.handler),
      ['vide', 'soun'],
    );
    final other = sourceSamples(swapped);
    expect(sourceSamples(out), [
      [...originals[0], ...other[1]],
      [...originals[1], ...other[0]],
    ]);
  });

  test('episodes that do not share a format are refused with the reason', () {
    final clear = bytes('clear.mp4'), base = sourceOf(clear);
    expect(
      () => Mp4Merger.plan([
        base,
        sourceOf(
          edit(clear, 'tkhd', 0, (v) => v == 1 ? 88 : 76, 158, width: 2),
        ),
      ]),
      throwsA(
        isA<MergeReject>()
            .having((e) => e.reason, 'reason', contains('分辨率'))
            .having((e) => e.code, 'code', MergeRejectCode.resolution)
            .having((e) => e.position, 'position', 2),
      ),
    );
    expect(
      () => Mp4Merger.plan([base, sourceOf(bumpLast(clear, 'avcC'))]),
      throwsA(
        isA<MergeReject>()
            .having((e) => e.reason, 'reason', contains('编码参数'))
            .having((e) => e.code, 'code', MergeRejectCode.codec),
      ),
    );
    expect(
      () =>
          Mp4Merger.plan([base, sourceOf(edit(clear, 'stsz', 1, (_) => 8, 0))]),
      throwsA(refusedBy('轨道数量')),
    );
    expect(
      () => Mp4Merger.plan([base, sourceOf(setHandler(clear, 1, 'subt'))]),
      throwsA(refusedBy('轨道构成')),
    );
    // Timescales do reconcile, until the common one cannot be written: this pair
    // has no multiple that fits the field, and that is said plainly.
    expect(
      () => Mp4Merger.plan([
        base,
        sourceOf(edit(clear, 'mdhd', 0, (v) => v == 1 ? 20 : 12, 1000003)),
      ]),
      throwsA(
        isA<MergeReject>()
            .having((e) => e.reason, 'reason', contains('时间基'))
            .having((e) => e.code, 'code', MergeRejectCode.timescale),
      ),
    );
  });

  test('ciphertext and a lone episode never enter the merge', () {
    expect(
      () => Mp4Merger.read(MemorySampleStore(bytes('real.cenc.mp4'))),
      throwsA(refusedBy('加密')),
    );
    expect(
      () => Mp4Merger.plan([sourceOf(bytes('clear.mp4'))]),
      throwsA(refusedBy('至少选择两集')),
    );
  });

  test('the precheck answers with the verdict the writer would give', () {
    final clear = bytes('clear.mp4'), base = sourceOf(clear);
    expect(Mp4Merger.rejectOf([base, base]), isNull);
    // A lone episode never becomes a product, and the panel has to hear that
    // before it queues a job rather than after it fails.
    expect(Mp4Merger.rejectOf([base]), contains('至少选择两集'));
    expect(
      Mp4Merger.rejectOf([
        base,
        sourceOf(edit(clear, 'mdhd', 0, (v) => v == 1 ? 20 : 12, 12289)),
      ]),
      isNull,
    );
    expect(
      Mp4Merger.rejectOf([base, sourceOf(bumpLast(clear, 'avcC'))]),
      contains('编码参数'),
    );

    final product = MemoryMergeSink();
    Mp4Merger.write(
      Mp4Merger.plan([sourceOf(clear), sourceOf(clear)]),
      product,
    );
    final grown = sourceOf(product.takeBytes());
    expect(Mp4Merger.growRejectOf(grown, [base]), isNull);
    // The same two refusals the append path throws, word for word.
    final fast = sourceOf(clear);
    expect(Mp4Merger.growRejectOf(fast, [fast]), contains('元数据在数据之前'));
    expect(
      Mp4Merger.growRejectOf(grown, [sourceOf(bumpLast(clear, 'avcC'))]),
      contains('编码参数'),
    );
    // And the same normalisations: a product whose tables already settled on one
    // timescale still accepts an episode counted in another.
    expect(
      Mp4Merger.growRejectOf(grown, [
        sourceOf(edit(clear, 'mdhd', 0, (v) => v == 1 ? 20 : 12, 15360)),
      ]),
      isNull,
    );
  });

  test('the key the precheck groups by is what the writer compares', () {
    final clear = bytes('clear.mp4'), base = sourceOf(clear);
    final key = Mp4Merger.compatibilityKeyOf(base);
    // Every difference the rebuild normalises leaves the key where it was.
    for (final other in [
      edit(clear, 'mdhd', 0, (v) => v == 1 ? 20 : 12, 15360),
      hideBox(clear, 'ctts'),
      setVersion(clear, 'ctts', 1),
      swapTraks(clear),
    ]) {
      final source = sourceOf(other);
      expect(Mp4Merger.compatibilityKeyOf(source), key);
      expect(Mp4Merger.rejectOf([base, source]), isNull);
    }
    // Every difference it cannot answer moves the key, so a batch the panel forms
    // out of these keys is a batch the writer agrees to.
    for (final other in [
      edit(clear, 'tkhd', 0, (v) => v == 1 ? 88 : 76, 158, width: 2),
      bumpLast(clear, 'avcC'),
    ]) {
      final source = sourceOf(other);
      expect(Mp4Merger.compatibilityKeyOf(source), isNot(key));
      expect(Mp4Merger.rejectOf([base, source]), isNotNull);
    }
  });

  test('a plan is written by exactly one of the two lanes', () {
    final temp = Directory.systemTemp.createTempSync('hongguo-merge-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final fast = sourceOf(bytes('clear.mp4'));
    final fresh = Mp4Merger.plan([fast, fast]);
    final file = File('${temp.path}/merged.mp4')
      ..writeAsBytesSync(bytes('clear.mp4'));
    final raf = file.openSync(mode: FileMode.append);
    addTearDown(raf.closeSync);
    expect(() => Mp4Merger.append(fresh, raf), throwsArgumentError);
    final sink = MemoryMergeSink();
    Mp4Merger.write(fresh, sink);
    expect(
      () => Mp4Merger.write(
        Mp4Merger.appendPlan(sourceOf(sink.takeBytes()), [fast]),
        sink,
      ),
      throwsArgumentError,
    );
  });
}
