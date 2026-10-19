import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';
import 'package:test/test.dart';

Uint8List bytes(String name) =>
    File('test/fixtures/media/$name').readAsBytesSync();
void main() {
  final synthetic = jsonDecode(
    File('test/fixtures/media/synthetic.json').readAsStringSync(),
  );
  for (final layout in ['head', 'tail']) {
    test('decrypt $layout moov, preserve offsets and remove signaling', () {
      final store = MemorySampleStore(bytes('$layout.cenc.mp4'));
      final plan = Mp4Cenc.inspect(store);
      expect(plan.encryptedSamples, 2);
      expect(Mp4Cenc.decrypt(store, plan, unhex(synthetic['key'])), 2);
      final after = Mp4Cenc.inspect(store);
      expect(after.encryptedSamples, 0);
      final track = after.tracks.single;
      for (var i = 0; i < 2; i++) {
        expect(
          store.read(track.offsets[i], track.sizes[i]),
          decodeBase64(synthetic['plainSamples'][i]),
        );
      }
    });
  }
  test('wrong key is rejected before changing ciphertext', () {
    final original = bytes('head.cenc.mp4'),
        store = MemorySampleStore(bytes('head.cenc.mp4'));
    expect(
      () => Mp4Cenc.decrypt(store, Mp4Cenc.inspect(store), Uint8List(16)),
      throwsFormatException,
    );
    expect(store.bytes, original);
  });
  test(
    'standard real CENC H264/AAC subsamples match every original sample',
    () {
      final clear = MemorySampleStore(bytes('clear.mp4')),
          enc = MemorySampleStore(bytes('real.cenc.mp4'));
      final expected = Mp4Cenc.inspect(clear), plan = Mp4Cenc.inspect(enc);
      expect(plan.tracks.map((t) => t.handler), containsAll(['vide', 'soun']));
      final key = jsonDecode(
        File('test/fixtures/media/real.json').readAsStringSync(),
      )['key'];
      expect(Mp4Cenc.decrypt(enc, plan, unhex(key)), greaterThan(50));
      final actual = Mp4Cenc.inspect(enc);
      expect(actual.encryptedSamples, 0);
      for (var t = 0; t < expected.tracks.length; t++) {
        final a = actual.tracks[t], b = expected.tracks[t];
        expect(a.sizes, b.sizes);
        for (var i = 0; i < a.sizes.length; i++) {
          expect(
            enc.read(a.offsets[i], a.sizes[i]),
            clear.read(b.offsets[i], b.sizes[i]),
            reason: '${a.handler} sample $i',
          );
        }
      }
    },
  );
  test('random-access native output can be parsed as clear media', () async {
    final temp = Directory.systemTemp.createTempSync('hongguo-mp4-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/out.mp4';
    File(path).writeAsBytesSync(bytes('real.cenc.mp4'));
    final key = jsonDecode(
      File('test/fixtures/media/real.json').readAsStringSync(),
    )['key'];
    FileDecryptor.decryptWithKeySync(path, key);
    await FileDecryptor.validateClear(path);
  });
  test('malformed box lengths and truncated samples fail closed', () {
    for (final input in [
      Uint8List(3),
      Uint8List.fromList([0, 0, 0, 4, 109, 111, 111, 118]),
    ]) {
      expect(
        () => Mp4Cenc.inspect(MemorySampleStore(input)),
        throwsFormatException,
      );
    }
    final truncated = bytes('real.cenc.mp4').sublist(0, 100);
    expect(
      () => Mp4Cenc.inspect(MemorySampleStore(Uint8List.fromList(truncated))),
      throwsFormatException,
    );
  });
  test('overlapping chunk offsets are rejected before decryption', () {
    final media = bytes('real.cenc.mp4');
    final type = [115, 116, 99, 111];
    var at = -1;
    for (var i = 0; i < media.length - 4; i++) {
      if (List.generate(4, (j) => media[i + j]).toString() == type.toString()) {
        at = i;
        break;
      }
    }
    expect(at, greaterThan(0));
    final view = ByteData.sublistView(media);
    expect(view.getUint32(at + 8), greaterThan(1));
    view.setUint32(at + 16, view.getUint32(at + 12));
    expect(
      () => Mp4Cenc.inspect(MemorySampleStore(media)),
      throwsFormatException,
    );
  });
}
