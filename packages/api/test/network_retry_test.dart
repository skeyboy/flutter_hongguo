import 'dart:io' show CertificateException, HandshakeException;

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:test/test.dart';

DioException wrapped(Object error) => DioException(
  requestOptions: RequestOptions(path: '/'),
  type: DioExceptionType.unknown,
  error: error,
);

void main() {
  test('Dio 的 unknown 里包着握手失败时识别为瞬时故障', () {
    const handshake = HandshakeException(
      'Connection terminated during handshake',
    );
    expect(isHandshakeFailure(handshake), isTrue);
    expect(isHandshakeFailure(wrapped(handshake)), isTrue);
    expect(NetworkRetry.transient(handshake), isTrue);
    expect(NetworkRetry.transient(wrapped(handshake)), isTrue);
  });

  test('证书校验失败和普通 unknown 不重试', () {
    expect(
      NetworkRetry.transient(wrapped(const CertificateException('bad cert'))),
      isFalse,
    );
    expect(
      NetworkRetry.transient(wrapped(const FormatException('boom'))),
      isFalse,
    );
  });

  test('握手失败只重试一次就成功', () async {
    final retry = NetworkRetry(
      delays: const [Duration(milliseconds: 1)],
      wait: (_) async {},
    );
    var calls = 0;
    final result = await retry.run(() async {
      calls++;
      if (calls == 1) {
        throw wrapped(
          const HandshakeException('Connection terminated during handshake'),
        );
      }
      return 'ok';
    });
    expect(result, 'ok');
    expect(calls, 2);
  });
}
