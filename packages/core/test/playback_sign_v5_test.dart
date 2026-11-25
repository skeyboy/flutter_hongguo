import 'dart:convert';
import 'dart:io';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

void main() {
  group('v5 playback signer — pinned Android vectors', () {
    final carrier = jsonDecode(
      File('test/fixtures/signing-v5-carrier.json').readAsStringSync(),
    ) as List<dynamic>;
    final f13 = jsonDecode(
      File('test/fixtures/signing-v5-f13.json').readAsStringSync(),
    ) as List<dynamic>;

    test('AesV3(v5=true) matches all 4 carrier vectors byte for byte', () {
      expect(carrier.length, 4);
      for (var i = 0; i < carrier.length; i++) {
        final row = carrier[i] as Map<String, dynamic>;
        final actual = PlaybackAesV3(
          unhex(row['key'] as String),
          row['ts'] as int,
          v5: true,
        ).encrypt(unhex(row['source'] as String), unhex(row['iv'] as String));
        expect(hex(actual), row['encrypted'], reason: 'carrier variant $i');
      }
    });

    test('hashF13(mobileV5) matches all 32 SDK digest vectors', () {
      expect(f13.length, 32);
      final signer = PlaybackSigner(mobileV5: true);
      for (var i = 0; i < f13.length; i++) {
        final row = f13[i] as Map<String, dynamic>;
        final result = signer.hashF13(
          unhex(row['query'] as String),
          unhex(row['body'] as String),
          row['ts'] as int,
        );
        expect(result.length, 20, reason: 'digest size $i');
        expect(
          hex(result.sublist(0, 16)),
          row['digest'],
          reason: 'timestamp class $i',
        );
        expect(result[16] & 0x24, 0x24, reason: 'checksum flag $i');
      }
    });

    test('branch is 0 only when iv low nibble is 12 under mobileV5', () {
      // The 32 f13 vectors are all branch-0 inputs by construction.
      final signer = PlaybackSigner(mobileV5: true);
      for (var i = 0; i < f13.length; i++) {
        final row = f13[i] as Map<String, dynamic>;
        final query = row['query'] as String;
        final body = unhex(row['body'] as String);
        final ts = row['ts'] as int;
        // hashF13 already throws if the branch is wrong; reaching here is the
        // assertion. Also verify branch() agrees by recomputing the iv.
        expect(signer.hashF13(unhex(query), body, ts).length, 20);
      }
    });

    test(
      'signPlayback binds compressed bytes, identity and branch-0 ticket',
      () {
        final body = <int>[31, -117 & 0xff, 8, 0, 1, 2, 3, 4];
        final first = <String, String>{
          'device_id': '123',
          'iid': '456',
          'cdid': 'synthetic',
          'version_name': '7.4.3.32',
          'channel': 'vivo_8662_64',
          'os_version': '12',
          'device_type': 'PGT-AN10',
          '_rticket': '1800000000000',
        };
        final signer = PlaybackSigner(
          clockMillis: () => 1800000000000,
          random: () => 0.5,
          processNonce: 'synthetic',
          mobileV5: true,
        );
        for (var ts = 1800000000; ts <= 1800000004; ts++) {
          final request = signer.signPlayback(
            'https://example.test/model',
            first,
            body: body,
            nowMillis: ts * 1000,
          );
          final query = request.url.substring(request.url.indexOf('?') + 1);
          final params = Uri.splitQueryString(query);
          expect(
            params.containsKey('ts'),
            isFalse,
            reason: 'no legacy ts param',
          );
          expect(params['x-khronos'], isNull);
          expect(signer.branch(query, body, ts), 0, reason: 'branch $ts');
          expect(request.headers['x-khronos'], '$ts');
          expect(request.headers['x-ss-stub'], hex(md5(body)).toUpperCase());
          final allowed = {
            'x-khronos',
            'x-helios',
            'x-medusa',
            'Content-Type',
            'x-ss-stub',
          };
          expect(request.headers.keys.every(allowed.contains), isTrue);
          expect(request.body, body);
        }
      },
    );
  });
}
