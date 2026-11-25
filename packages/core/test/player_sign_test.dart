// Byte-for-byte pinned vectors from hongguo-android
// api/core/PlayerSignTest.java (GPL-3.0-only). The 11-byte nonce is injected
// so every output is deterministic.
import 'dart:convert';
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

Uint8List _body(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  group('legacy single-episode player signer — pinned Android vectors', () {
    const query = 'aid=8662&device_id=123456789';
    final body = _body('{"video_id":"123"}');
    final nonce = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

    test('gorgon matches the reference vector', () {
      expect(
        LegacyPlayerSign.gorgon(query, body, 1700000000),
        '8404401c0000f27a76e6957ca1b97022103fad22c9d970977ebb',
      );
    });

    test('ladon matches the reference vector', () {
      expect(
        LegacyPlayerSign.ladon(
          1700000000,
          Uint8List.fromList(nonce.sublist(2, 6)),
        ),
        'AgMEBVbVr6bCGXEl3RbL1aAkpFHJpdxRfjTl94yWLoz6K/SQ',
      );
    });

    test('argus matches the reference vector', () {
      expect(
        LegacyPlayerSign.argus(query, body, 1700000000, '123456789', nonce),
        'PMw3qMRaFflguIKYlC2mdpV2IWcBCwn1Koj5IoaLq5b3ZXfATS3iituUmnt2HJF'
        'xDCWIpwc/xgRjqtkv5n4uLADEdr1fboupPgZ/Kabe2EMEaQ3/o7oMc8hY3WR/n/'
        'piCdIOxKzo9jPh8pSH+K+pvGX42LJEU1ciK+i5QxX7TOyhmIHS+K9t673Uc5uP'
        'BA18ECoTk5nn361Gl9LORhAI2E5sgtZNeEdG0ZiGxg8C5aL1iFWeyfmPcEQPxd'
        'Th/1DX2LE5dW23fo7nBJN4BnwtNwMYQKz+Lx6nN1D5KGt2wQ9f+w==',
      );
    });

    test('headers carry timestamp, stub and all three signatures', () {
      final h = LegacyPlayerSign.headers(
        query: 'a=1',
        body: _body('{}'),
        nowMillis: 1700000000123,
        deviceId: '42',
        nonce: nonce,
      );
      expect(h['x-khronos'], '1700000000');
      expect(h['x-ss-req-ticket'], '1700000000123');
      expect(h['x-ss-stub']!.length, 32);
      expect(h['x-gorgon']!.startsWith('8404401c0000'), isTrue);
      expect(h.containsKey('x-argus'), isTrue);
      expect(h.containsKey('x-ladon'), isTrue);
    });

    test('rejects a non-numeric device id like upstream', () {
      expect(
        () => LegacyPlayerSign.headers(
          query: 'a=1',
          body: _body('{}'),
          nowMillis: 1700000000123,
          deviceId: 'abc',
        ),
        throwsArgumentError,
      );
    });
  });
}
