import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

/// Node's stubbed generator from tool/generate_register_vector.cjs: one 32-bit
/// step per byte, high byte first. Replaying it makes the Dart envelope and the
/// reference envelope describe the same session, down to the bytes that went
/// into the compressor.
Uint8List Function(int) lcgEntropy(int seed) {
  var state = seed;
  return (int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
      out[i] = state >> 24;
    }
    return out;
  };
}

String Function() countedUuid() {
  var calls = 0;
  return () => 'uuid-${++calls}';
}

/// Records the registration exchange and answers with the fixture's response.
class RegisterAdapter implements HttpClientAdapter {
  RegisterAdapter(this.body, {this.status = 200});
  final String body;
  final int status;
  final List<RequestOptions> requests = [];
  final List<Uint8List> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      bodies.add(
        Uint8List.fromList(
          await requestStream.expand((chunk) => chunk).toList(),
        ),
      );
    }
    return ResponseBody.fromString(body, status);
  }

  @override
  void close({bool force = false}) {}
}

/// Answers every registration with a different pair, so a test can tell the
/// identity this process holds from one it just registered.
class RotatingRegisterAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  int _serial = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final serial = ++_serial;
    return ResponseBody.fromString(
      '{"code":0,"device_id_str":"76616224674414700$serial",'
      '"install_id_str":"39120885448500$serial"}',
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/register_vector.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final vectors = (fixture['vectors'] as List).cast<Map<String, dynamic>>();
  final responseText = jsonEncode(fixture['response']);

  PlaybackDeviceRegistry replay(
    Map<String, dynamic> vector, {
    String Function()? uuid,
  }) => PlaybackDeviceRegistry(
    dio: Dio(),
    clockMillis: () => vector['now'] as int,
    entropy: lcgEntropy(vector['seed'] as int),
    uuid: uuid ?? countedUuid(),
  );

  test('the registration envelope replays the reference framing, key schedule and payload', () {
    for (final vector in vectors) {
      final uuid = countedUuid();
      final registry = replay(vector, uuid: uuid);
      // _register asks for the cdid before sealing the envelope, so the counter
      // has to be advanced the same way for clientudid and req_id to line up.
      final body = registry.buildBody(vector['now'] as int, uuid());
      expect(hex(body.sublist(0, 6)), vector['prefixHex']);
      final session = Uint8List.sublistView(body, 6, 38);
      expect(
        hex(session),
        vector['randomHex'],
        reason: 'the session random travels in the clear, ahead of the cipher',
      );
      // What follows is AES-128-CBC under sha512(sha512(session) || salt), over
      // sha512(gzip) || gzip. Undoing it proves the key schedule and the
      // framing; the deflate stream itself is a property of whichever zlib
      // built this binary, so the comparison is made on the bytes that go into
      // the compressor -- which is what the endpoint actually reads.
      final derived = sha512([
        ...sha512(session),
        ...unhex(PlaybackDeviceRegistry.kdfSaltHex),
      ]);
      final sealed = aesCbcDecryptPkcs7(
        Uint8List.sublistView(derived, 0, 16),
        Uint8List.sublistView(derived, 16, 32),
        Uint8List.sublistView(body, 38),
      );
      final compressed = Uint8List.sublistView(sealed, 64);
      expect(
        hex(Uint8List.sublistView(sealed, 0, 64)),
        hex(sha512(compressed)),
        reason:
            'vector ${vector['index']} seals the envelope over its own gzip',
      );
      expect(
        base64Encode(gzip.decode(compressed)),
        vector['plaintextBase64'],
        reason: 'vector ${vector['index']} payload',
      );
      expect(PlaybackDeviceRegistry.registerUrl, vector['url']);
      final headers = PlaybackDeviceRegistry.requestHeaders(
        vector['now'] as int,
        body,
      );
      expect(
        Map.of(headers)..remove('x-ss-stub'),
        vector['headers'],
        reason: 'every header but the digest of the body is the reference set',
      );
      expect(
        headers['x-ss-stub'],
        hex(md5(body)).toUpperCase(),
        reason: 'the stub is the MD5 of the bytes this process actually sent',
      );
    }
  });
  test('the registered identity is read from the string fields', () {
    final device = PlaybackDeviceRegistry.parseDevice(responseText, 'uuid-1');
    // The fixture keeps the response as Node parsed it, where the numeric
    // device_id lost its last digits; the _str field is what survives.
    expect(
      '${jsonDecode(responseText)['device_id']}',
      isNot('7661622467441478681'),
    );
    expect(device.deviceId, '7661622467441478681');
    expect(device.iid, '3912088544850522');
    // The response's cdid is not trusted; the one this process generated is kept.
    expect(device.cdid, 'uuid-1');
  });
  test('the registration posts the sealed envelope, and the next ask registers again', () async {
    final adapter = RegisterAdapter(responseText);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final registry = PlaybackDeviceRegistry(
      dio: dio,
      registerInterval: Duration.zero,
      clockMillis: () => 1700000000123,
      entropy: lcgEntropy(1000),
      uuid: countedUuid(),
    );
    final first = await registry.get();
    expect(first.deviceId, '7661622467441478681');
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.first.method, 'POST');
    expect(adapter.requests.first.uri.host, 'log5-applog-lf.fqnovel.com');
    final sent = adapter.bodies.single;
    expect(hex(sent.sublist(0, 6)), vectors.first['prefixHex']);
    expect(
      hex(Uint8List.sublistView(sent, 6, 38)),
      vectors.first['randomHex'],
      reason: 'what left this process is the envelope the oracle framed',
    );
    expect(
      adapter.requests.first.headers['Content-Type'],
      'application/octet-stream;tt-data=a',
    );
    // An anonymous registration carries no account material and no signature.
    for (final header in ['x-argus', 'x-gorgon', 'cookie', 'x-tt-token']) {
      expect(adapter.requests.first.headers.containsKey(header), isFalse);
    }
    // A settled registration is never replayed: the player endpoint answers
    // one identity once per window and soft-blocks the replay, so the next
    // fetch gets a registration this process has not spent.
    await registry.get(cancelToken: CancelToken());
    expect(adapter.requests, hasLength(2));
  });
  test(
    'an empty registration answer is named, not left to the decoder',
    () async {
      final adapter = RegisterAdapter('');
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      await expectLater(
        PlaybackDeviceRegistry(dio: dio, registerInterval: Duration.zero).get(),
        throwsA(
          isA<IncompleteCatalogResponse>().having(
            (IncompleteCatalogResponse e) => '$e',
            'message',
            '播放设备注册未返回数据，请稍后重试',
          ),
        ),
      );
    },
  );
  test(
    'a refused registration is held for a cooldown instead of re-hit per ask',
    () async {
      final adapter = RegisterAdapter('{"code":7}');
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final registry = PlaybackDeviceRegistry(
        dio: dio,
        registerInterval: Duration.zero,
        registerFailureCooldown: const Duration(milliseconds: 250),
      );
      // A batch queue asks once per episode. While the endpoint is refusing,
      // those asks must not each buy their own POST -- that is the burst which
      // the viewer's next online play then pays for.
      await expectLater(
        registry.get(),
        throwsA(isA<IncompleteCatalogResponse>()),
      );
      await expectLater(
        registry.get(),
        throwsA(isA<IncompleteCatalogResponse>()),
      );
      await expectLater(
        registry.get(),
        throwsA(isA<IncompleteCatalogResponse>()),
      );
      expect(
        adapter.requests,
        hasLength(1),
        reason: 'two asks rode the cooldown',
      );
      // The cooldown is a pause, not a verdict: after it the endpoint is asked
      // again, and a fresh answer ends it.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final ok = RegisterAdapter(responseText);
      dio.httpClientAdapter = ok;
      final device = await registry.get();
      expect(device.deviceId, '7661622467441478681');
      expect(ok.requests, hasLength(1));
    },
  );
  test('a batch of asks shares one registration, and the next one waits its interval', () async {
    final adapter = RotatingRegisterAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final registry = PlaybackDeviceRegistry(
      dio: dio,
      registerInterval: const Duration(milliseconds: 80),
    );
    // Five resolutions released by one batch task register once, not once
    // per caller -- the endpoint is a log service, not a per-request toll.
    final racing = await Future.wait([
      registry.get(),
      registry.get(),
      registry.get(),
      registry.get(),
      registry.get(),
    ]);
    expect(racing.map((device) => device.deviceId).toSet(), hasLength(1));
    expect(adapter.requests, hasLength(1));
    // The ask after that is a fresh identity, but its start is spaced: the
    // queue's next episode does not join a burst at the log endpoint.
    final gate = Stopwatch()..start();
    final next = await registry.get();
    expect(next.deviceId, isNot(racing.first.deviceId));
    expect(
      gate.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 60)),
      reason: 'the second registration paid the interval, not the queue',
    );
    expect(adapter.requests, hasLength(2));
  });
  test('a failed registration is not cached as an identity', () async {
    final adapter = RegisterAdapter('{"code":7}');
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final registry = PlaybackDeviceRegistry(
      dio: dio,
      registerInterval: Duration.zero,
      registerFailureCooldown: Duration.zero,
    );
    await expectLater(
      registry.get(),
      throwsA(isA<IncompleteCatalogResponse>()),
    );
    await expectLater(
      registry.get(),
      throwsA(isA<IncompleteCatalogResponse>()),
    );
    expect(adapter.requests, hasLength(2));
  });
  test('concurrent asks share the in-flight registration, then each ask registers again', () async {
    final adapter = RotatingRegisterAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final registry = PlaybackDeviceRegistry(
      dio: dio,
      registerInterval: Duration.zero,
    );
    // A burst of simultaneous resolutions registers once, not once per
    // caller -- the endpoint is a log service, not a per-request toll.
    final racing = await Future.wait([registry.get(), registry.get()]);
    expect(racing.first.deviceId, racing.last.deviceId);
    expect(adapter.requests, hasLength(1));
    // Whoever asks after that registration has settled is handed a pair
    // this process never spent, because replaying a spent pair only buys
    // the HTTP 200 with nothing the player gives a refused identity.
    final renewed = await registry.get();
    expect(renewed.deviceId, isNot(racing.first.deviceId));
    expect(adapter.requests, hasLength(2));
  });
}
