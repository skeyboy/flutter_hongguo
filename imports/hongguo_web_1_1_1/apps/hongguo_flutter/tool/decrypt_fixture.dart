import 'dart:convert';
import 'dart:io';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_flutter/adapters/native/file_store.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/decrypt_fixture.dart <encrypted.mp4> <output.mp4>',
    );
    exitCode = 64;
    return;
  }
  final truths =
      jsonDecode(
            File(
              '../../packages/hongguo_core/test/fixtures/spade.json',
            ).readAsStringSync(),
          )
          as List;
  File(args[0]).copySync(args[1]);
  decryptFile({'path': args[1], 'spade': base64Encode(unhex(truths[0][0]))});
  stdout.writeln('Validated decrypted fixture: ${args[1]}');
}
