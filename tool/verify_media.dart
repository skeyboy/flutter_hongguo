import 'dart:convert';
import 'dart:io';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_core/hongguo_native.dart';

void main() {
  const fixture = 'packages/core/test/fixtures/media';
  final key =
      jsonDecode(File('$fixture/real.json').readAsStringSync())['key']
          as String;
  final output = File('build/verification/offline-decrypted.mp4')
    ..parent.createSync(recursive: true);
  File('$fixture/real.cenc.mp4').copySync(output.path);
  final count = FileDecryptor.decryptWithKeySync(output.path, key);
  final file = output.openSync();
  try {
    final plan = Mp4Cenc.inspect(FileSampleStore(file));
    final summary = {
      'decryptedSamples': count,
      'encryptedSamplesRemaining': plan.encryptedSamples,
      'tracks': [
        for (final t in plan.tracks)
          {'handler': t.handler, 'codec': t.codec, 'samples': t.sizes.length},
      ],
      'output': output.path,
    };
    File('build/verification/media-summary.json')
        .writeAsStringSync('${jsonEncode(summary)}\n');
    print(jsonEncode(summary));
  } finally {
    file.closeSync();
  }
}
