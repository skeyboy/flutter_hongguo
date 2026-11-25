import 'dart:convert';
import 'dart:io';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

void main() {
  final rows = jsonDecode(
    File('test/fixtures/account_signing_vectors.json').readAsStringSync(),
  ) as List<dynamic>;

  test('12 pinned Android signer vectors match byte for byte', () {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as Map<String, dynamic>;
      final ts = row['ts'] as int;
      final url = row['url'] as String;
      final query = url.substring(url.indexOf('?') + 1);
      final body = row['body'] == null
          ? null
          : utf8.encode(row['body'] as String);
      final device = Map<String, String>.from(AccountSigner.defaultDevice)
        ..['device_id'] = '1905892595378490'
        ..['iid'] = '1905892595382586';
      final signer = AccountSigner(clockMillis: () => ts * 1000, device: device)
        ..reseed(17);

      expect(signer.branch(query, body, ts), 0, reason: 'branch $i');
      final bodyMd5 = body == null ? null : md5(body);
      expect(
        hex(
          signer.hashF13(
            sm3(utf8.encode(query)),
            bodyMd5 ?? List<int>.filled(16, 0),
            ts,
          ),
        ),
        row['hash'],
        reason: 'hash $i',
      );
      expect(
        signer.gorgon(query, body, ts, 42131),
        row['gorgon'],
        reason: 'gorgon $i',
      );
      // The Kotlin oracle advances the shared LCG through helios before it
      // asks for medusa, so the call order here is part of the vector.
      expect(signer.helios(ts), row['helios'], reason: 'helios $i');
      expect(signer.medusa(url, body, ts), row['medusa'], reason: 'medusa $i');
    }
  });
}
