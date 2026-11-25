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

  test('风控/登录失效/业务错都有分类且不重放', () {
    DioException upstream(Object data, {int status = 200, String? retryAfter}) {
      final headers = <String, List<String>>{};
      if (retryAfter != null) headers['retry-after'] = [retryAfter];
      final options = RequestOptions(path: '/');
      return DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: status,
          data: data,
          headers: Headers.fromMap(headers),
        ),
      );
    }

    final empty = classifyUpstreamFailure(const IncompleteCatalogResponse('空'));
    expect(empty, isA<EmptyEnvelope>());
    expect(empty!.replayable, isTrue);

    final risk = classifyUpstreamFailure(upstream({'code': 110001}));
    expect(risk, isA<RiskControlFailure>());
    expect(risk!.replayable, isFalse);
    expect(NetworkRetry.transient(upstream({'code': 110001})), isFalse);

    final expired = classifyUpstreamFailure(upstream({'code': 8}));
    expect(expired, isA<AuthExpiredFailure>());
    expect(expired!.replayable, isFalse);
    expect(NetworkRetry.transient(upstream('', status: 403)), isFalse);

    final business = classifyUpstreamFailure(upstream({'code': 4242}));
    expect(business, isA<BusinessFailure>());
    expect(business!.replayable, isFalse);

    // 429 有合法 Retry-After 才允许重试；没有则按拒绝处理。
    expect(
      classifyUpstreamFailure(upstream({'code': 0}, status: 429)),
      isA<RiskControlFailure>(),
    );
    expect(
      classifyUpstreamFailure(
        upstream({'code': 0}, status: 429, retryAfter: '1'),
      ),
      isA<TransportFailure>(),
    );

    // 目录客户端把业务码包进普通异常时仍然识别为风控。
    expect(
      classifyUpstreamFailure(Exception('内容接口返回 110001：稍后重试')),
      isA<RiskControlFailure>(),
    );
  });

  test('自定义 shouldRetry 也不能重放确定性错误', () async {
    final retry = NetworkRetry(
      delays: const [Duration(milliseconds: 1)],
      wait: (_) async {},
    );
    var calls = 0;
    await expectLater(
      retry.run(() async {
        calls++;
        throw classifyUpstreamFailure(Exception('内容接口返回 110001：稍后重试'))!;
      }, shouldRetry: (_) => true),
      throwsA(isA<RiskControlFailure>()),
    );
    expect(calls, 1);
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
