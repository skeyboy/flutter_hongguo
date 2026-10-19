import 'dart:convert';
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';

import 'oracle_data.dart';

/// Same vector suite for native AOT and JS compilation; no dart:io import.
void main() {
  final fixture = jsonDecode(oracleJson) as Map<String, dynamic>;
  var checked = 0;
  for (final row in fixture['cases'] as List) {
    var state = row['seed'] as int;
    Uint8List entropy(int n) => Uint8List.fromList(
      List.generate(n, (_) {
        state = (state * 1664525 + 1013904223).toUnsigned(32);
        return state >> 24;
      }),
    );
    final signer = PureSign(
      clockMillis: () => row['now'] as int,
      entropy: entropy,
    );
    final body = row['body'] == null ? null : decodeBase64(row['body']);
    if (signer.branchOf(row['url'], body, row['timestamp']) != row['branch']) {
      throw StateError('Branch mismatch: seed ${row['seed']}');
    }
    final actual = signer.sign(row['url'], body, row['timestamp']);
    for (final key in (row['headers'] as Map).keys) {
      if (actual[key] != row['headers'][key]) {
        throw StateError('$key mismatch: seed ${row['seed']}');
      }
    }
    checked++;
  }
  for (final row in fixture['spade'] as List) {
    if (Spade.unwrapV1(unhex(row['raw'])) != row['key']) {
      throw StateError('Spade mismatch');
    }
    checked++;
  }
  final url = fixture['url'];
  if (MediaUrlDecoder.decrypt(url['cipher'], decodeBase64(url['seed'])) !=
      url['plain']) {
    throw StateError('URL mismatch');
  }
  final ctr = fixture['ctr'];
  if (base64Encode(
        aesCtr(unhex(ctr['key']), unhex(ctr['iv']), decodeBase64(ctr['plain'])),
      ) !=
      ctr['cipher']) {
    throw StateError('CTR mismatch');
  }
  checked += 2;
  print(
    'Portable Dart oracle: $checked vectors passed (including 96 six-header signatures).',
  );
}
