import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:hongguo_core/src/crypto/pure_sign.dart';
import 'package:hongguo_core/src/ports/runtime.dart';
import 'package:test/test.dart';

class FixedClock implements Clock {
  @override
  int get milliseconds => 1780000000123;
}

class FixedRandom implements RandomSource {
  int cursor = 0;
  @override
  Uint8List bytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => (cursor++ * 73 + 41) & 255));
  @override
  int nextInt(int n) => ((cursor++ * 7919 + 12345) & 0xffffffff) % n;
}

void main() {
  final vectors =
      jsonDecode(File('test/fixtures/sign.json').readAsStringSync()) as List;
  for (final v in vectors) {
    test('Node six headers branch ${v['branch']} ts ${v['ts']}', () {
      final rng = FixedRandom();
      final signer = PureSign(clock: FixedClock(), random: rng);
      final body = v['body'] == null ? null : base64Decode(v['body']);
      expect(signer.branchOf(v['url'], body, v['ts']), v['branch']);
      expect(signer.sign(v['url'], body, v['ts']), v['headers']);
    });
  }
}
