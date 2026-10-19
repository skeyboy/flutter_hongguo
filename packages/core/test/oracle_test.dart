import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/node_oracle.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  for (final row in fixture['cases'] as List) {
    test(
      'six headers match Node: seed ${row['seed']}, branch ${row['branch']}',
      () {
        var state = row['seed'] as int;
        Uint8List entropy(int n) => Uint8List.fromList(
          List.generate(n, (_) {
            state = (state * 1664525 + 1013904223).toUnsigned(32);
            return state >> 24;
          }),
        );
        final sign = PureSign(
          clockMillis: () => row['now'] as int,
          entropy: entropy,
        );
        final body = row['body'] == null
            ? null
            : decodeBase64(row['body'] as String);
        expect(
          sign.branchOf(row['url'], body, row['timestamp']),
          row['branch'],
        );
        final actual = sign.sign(
          row['url'] as String,
          body,
          row['timestamp'] as int,
        );
        expect(actual, row['headers']);
      },
    );
  }
  for (final row in fixture['spade'] as List) {
    test('spade v1 ${row['key']}', () {
      final raw = unhex(row['raw'] as String);
      expect(Spade.unwrapV1(raw), row['key']);
      expect(Spade.decode(base64Encode(raw))?.hex, row['key']);
    });
  }
  test('URL SHA512 derivation and AES-CBC match Node', () {
    final row = fixture['url'];
    expect(
      MediaUrlDecoder.decrypt(row['cipher'], decodeBase64(row['seed'])),
      row['plain'],
    );
  });
  test('AES-CTR matches Node across block boundaries', () {
    final row = fixture['ctr'];
    final key = unhex(row['key']), iv = unhex(row['iv']);
    final plain = decodeBase64(row['plain']),
        cipher = decodeBase64(row['cipher']);
    expect(aesCtr(key, iv, plain), cipher);
    expect(aesCtr(key, iv, cipher), plain);
  });
  test('reject invalid keys, URL hosts and truncated envelopes', () {
    expect(Spade.decode('bad!'), isNull);
    expect(Spade.unwrapV1(Uint8List(2)), isNull);
    expect(
      () => MediaUrlDecoder.decrypt(base64Encode([1, 2, 3]), Uint8List(0)),
      throwsFormatException,
    );
    for (final value in [
      'http://fqnovel.com/a',
      'https://fqnovel.com.evil.test/a',
      'https://user@fqnovel.com/a',
      'https://fqnovel.com:444/a',
    ]) {
      expect(
        () => MediaUrlDecoder.checked(value, ['fqnovel.com']),
        throwsFormatException,
      );
    }
    expect(
      MediaUrlDecoder.checked('https://a.fqnovel.com/a', ['fqnovel.com']).host,
      'a.fqnovel.com',
    );
  });
}
