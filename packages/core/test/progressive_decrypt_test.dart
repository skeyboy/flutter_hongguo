import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';
import 'package:test/test.dart';

Uint8List bytes(String name) =>
    File('test/fixtures/media/$name').readAsBytesSync();

/// Whole-file reference: the shipped in-place decrypt pipeline.
Uint8List decryptAll(Uint8List source, String keyHex) {
  final store = MemorySampleStore(Uint8List.fromList(source));
  Mp4Cenc.decrypt(store, Mp4Cenc.inspect(store), unhex(keyHex));
  return store.bytes;
}

/// A store over a file that is still downloading: only the head boxes and the
/// region from [metadataStart] are readable, the payload in between is not.
class PartialStore implements SampleStore {
  final Uint8List bytes;
  final int metadataStart;
  int delivered;
  PartialStore(this.bytes, this.metadataStart, {this.delivered = 0});
  @override
  int get length => bytes.length;
  @override
  Uint8List read(int offset, int size) {
    if (offset + size <= delivered) {
      return Uint8List.sublistView(bytes, offset, offset + size);
    }
    if (offset >= metadataStart) {
      return Uint8List.sublistView(bytes, offset, offset + size);
    }
    throw const FormatException('Region still downloading');
  }

  @override
  void write(int offset, Uint8List value) =>
      throw UnsupportedError('Read-only store');
}

/// Runs the progressive writer over [source] delivered in [chunk] pieces.
Future<Uint8List> progressiveThrough(
  Uint8List source,
  ProgressivePlan plan,
  int chunk,
) async {
  final temp = Directory.systemTemp.createTempSync('hongguo-progressive-');
  try {
    final input = File('${temp.path}/x.part')..writeAsBytesSync(Uint8List(0));
    final output = '${temp.path}/x.stream';
    final writer = await ProgressiveDecrypt.open(input.path, output, plan);
    for (var at = 0; at < source.length; at += chunk) {
      final end = (at + chunk).clamp(0, source.length);
      await input.writeAsBytes(
        Uint8List.sublistView(source, 0, end),
        flush: true,
      );
      await writer.pump(end);
    }
    final total = await writer.pump(source.length, downloadComplete: true);
    await writer.close();
    expect(total, source.length);
    return File(output).readAsBytesSync();
  } finally {
    await temp.delete(recursive: true);
  }
}

void main() {
  final real = jsonDecode(
    File('test/fixtures/media/real.json').readAsStringSync(),
  );
  final realKey = real['key'] as String;
  final synthetic = jsonDecode(
    File('test/fixtures/media/synthetic.json').readAsStringSync(),
  );

  group('tail-moov relocation', () {
    late Uint8List source;
    late ProgressivePlan plan;
    late int headSize, moovSize, payloadStart, moovStart;
    setUp(() {
      source = bytes('real.cenc.mp4');
      final layout = Mp4Cenc.inspect(MemorySampleStore(source));
      final mdat = layout.top.firstWhere((b) => b.type == 'mdat');
      headSize = mdat.start;
      payloadStart = mdat.payload;
      moovSize = layout.moov.size;
      moovStart = layout.moov.start;
      plan = ProgressivePlan.build(MemorySampleStore(source), realKey);
    });

    test('metadata alone is enough to build the recipe', () {
      // Head boxes and the remote moov are in hand, the payload is still
      // downloading: exactly what the API layer can offer before playback.
      // The header walk reads 16 bytes at every top-level box start.
      final early = ProgressivePlan.build(
        PartialStore(source, moovStart, delivered: headSize + 16),
        realKey,
      );
      expect(early.delta, plan.delta);
      expect(early.pieces.length, plan.pieces.length);
      expect(early.moovPatch, plan.moovPatch);
      expect(early.encryptions.length, plan.encryptions.length);
    });

    test('output is clear, moov-first, byte-conserving', () async {
      final out = await progressiveThrough(source, plan, 4096);
      expect(out.length, source.length);
      final reparsed = Mp4Cenc.inspect(MemorySampleStore(out));
      expect(reparsed.encryptedSamples, 0);
      expect(reparsed.moov.start, headSize);
      expect(reparsed.moov.end, headSize + moovSize);
      expect(
        reparsed.top.firstWhere((b) => b.type == 'mdat').payload,
        headSize + moovSize + 8,
      );
    });

    test('media bytes match the whole-file decrypt after remapping', () async {
      final out = await progressiveThrough(source, plan, 4096);
      final whole = decryptAll(source, realKey);
      final reference = Mp4Cenc.inspect(MemorySampleStore(whole));
      final relocated = Mp4Cenc.inspect(MemorySampleStore(out));
      for (var t = 0; t < reference.tracks.length; t++) {
        final a = relocated.tracks[t], b = reference.tracks[t];
        expect(a.sizes, b.sizes);
        for (var i = 0; i < a.sizes.length; i++) {
          expect(
            out.sublist(a.offsets[i], a.offsets[i] + a.sizes[i]),
            whole.sublist(b.offsets[i], b.offsets[i] + b.sizes[i]),
            reason: 'track $t sample $i differs after relocation',
          );
        }
      }
    });

    test('playable prefix grows with the download', () async {
      final temp = Directory.systemTemp.createTempSync('hongguo-progressive-');
      try {
        final input = File('${temp.path}/x.part')
          ..writeAsBytesSync(Uint8List(0));
        final writer = await ProgressiveDecrypt.open(
          input.path,
          '${temp.path}/x.stream',
          plan,
        );
        final end = payloadStart + 6000;
        await input.writeAsBytes(
          Uint8List.sublistView(source, 0, end),
          flush: true,
        );
        final available = await writer.pump(end);
        // Head boxes + the relocated moov + as many decrypted samples as
        // the download covers.
        expect(available, greaterThan(headSize + moovSize));
        expect(available, lessThan(source.length));
        await writer.close();
        expect(writer.completed, isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    });

    test('stalled span exposes exactly the contiguous prefix', () async {
      // Deliver everything except the middle of mdat: the writer must not
      // skip ahead (output stays monotonic for the HTTP range server).
      final temp = Directory.systemTemp.createTempSync('hongguo-progressive-');
      final input = File('${temp.path}/x.part')..writeAsBytesSync(Uint8List(0));
      final writer = await ProgressiveDecrypt.open(
        input.path,
        '${temp.path}/x.stream',
        plan,
      );
      // Windows refuses to delete a directory while its files are open, so
      // cleanup runs in teardown, in reverse order, and the close happens
      // exactly once (a second close would fail on the closed output file).
      var writerClosed = false;
      Future<void> closeWriter() async {
        if (writerClosed) return;
        writerClosed = true;
        await writer.close();
      }

      addTearDown(() => temp.delete(recursive: true));
      addTearDown(closeWriter);
      final stop = payloadStart + 2000;
      await input.writeAsBytes(
        Uint8List.sublistView(source, 0, stop),
        flush: true,
      );
      final first = await writer.pump(stop);
      expect(first, lessThan(source.length));
      // A transfer reports the bytes it received, but its sink buffers, so the
      // file can lag behind. Those bytes land a moment later, so the pump holds
      // at the readable prefix instead of failing a stream the player is
      // already watching.
      expect(await writer.pump(source.length), first);
      // Growing the file again resumes exactly where it stalled.
      final next = payloadStart + 6000;
      await input.writeAsBytes(
        Uint8List.sublistView(source, 0, next),
        flush: true,
      );
      final grew = await writer.pump(next);
      expect(grew, greaterThan(first));
      final full = await progressiveThrough(source, plan, 4096);
      await closeWriter();
      final out = File('${temp.path}/x.stream').readAsBytesSync();
      expect(out.length, grew);
      // What the stalled stream served is the head of the finished file.
      expect(out, full.sublist(0, grew));
    });
  });

  group('head-moov identity', () {
    test('output equals the whole-file decrypt byte for byte', () async {
      final source = bytes('head.cenc.mp4');
      final plan = ProgressivePlan.build(
        MemorySampleStore(source),
        synthetic['key'] as String,
      );
      expect(plan.delta, 0);
      final out = await progressiveThrough(source, plan, 37);
      expect(out, decryptAll(source, synthetic['key'] as String));
    });
  });

  test('plain files are rejected for progressive use', () {
    final source = bytes('clear.mp4');
    expect(
      () => ProgressivePlan.build(MemorySampleStore(source), realKey),
      throwsFormatException,
    );
  });

  test('writer refuses input beyond the plan', () async {
    final source = bytes('head.cenc.mp4');
    final plan = ProgressivePlan.build(
      MemorySampleStore(source),
      synthetic['key'] as String,
    );
    final temp = Directory.systemTemp.createTempSync('hongguo-progressive-');
    try {
      final input = File('${temp.path}/x.part')..writeAsBytesSync(source);
      final writer = await ProgressiveDecrypt.open(
        input.path,
        '${temp.path}/x.stream',
        plan,
      );
      await expectLater(writer.pump(source.length + 1), throwsFormatException);
      await writer.close();
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
