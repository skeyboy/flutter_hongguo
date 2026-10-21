import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

class ScriptedAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions, Map<String, dynamic>)
  reply;
  final requests = <RequestOptions>[];
  final bodies = <Map<String, dynamic>>[];
  ScriptedAdapter(this.reply);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final body = stream == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(
            jsonDecode(utf8.decode(await stream.expand((v) => v).toList())),
          );
    bodies.add(body);
    return reply(options, body);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody response(Object value, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(value), status);
const page = {
  'code': 0,
  'data': {
    'video_data': [
      {'series_id': '123', 'title': '恢复的剧集'},
    ],
    'has_more': false,
  },
};
const themes = {
  'code': 0,
  'data': {
    'selector_rows': [
      {
        'type': 'category_dim_theme',
        'items': [
          {'show_name': '都市', 'selector_item_id': '1'},
        ],
      },
    ],
  },
};

void main() {
  test('queued legacy lists reuse the discovered signature requirement before sending', () async {
    final adapter = ScriptedAdapter((request, body) async {
      if (!request.headers.containsKey('x-argus')) {
        return ResponseBody.fromString('', 200);
      }
      return response(body['need_selector_panel'] == true ? themes : page);
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      signLists: false,
      retry: NetworkRetry(wait: (_) async {}),
    );
    await Future.wait<Object>([client.themes('short_play'), client.browse()]);
    expect(adapter.requests, hasLength(3));
    expect(
      adapter.requests.where((r) => !r.headers.containsKey('x-argus')),
      hasLength(1),
    );
  });

  test('signature fallback never retries rejected authorization or changes session headers', () async {
    final adapter = ScriptedAdapter(
      (request, _) async => request.headers.containsKey('x-argus')
          ? response({}, 401)
          : ResponseBody.fromString('', 200),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      signLists: false,
      sessionHeaders: const {
        'cookie': 'fixture-session',
        'x-tt-token': 'fixture-token',
      },
      retry: NetworkRetry(wait: (_) async {}),
    );
    await expectLater(
      client.themes('short_play'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          401,
        ),
      ),
    );
    expect(adapter.requests, hasLength(2));
    for (final request in adapter.requests) {
      expect(request.headers['cookie'], 'fixture-session');
      expect(request.headers['x-tt-token'], 'fixture-token');
      expect(request.uri.queryParameters['device_id'], '1234567890123456');
    }
  });

  test('catalog requests are signed by default', () async {
    final adapter = ScriptedAdapter((_, _) async => response(themes));
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    await CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
    ).themes('short_play');
    expect(adapter.requests.single.headers['x-argus'], isNotEmpty);
  });
  test('legacy unsigned empty body upgrades once and subsequent lists remain signed', () async {
    final waits = <Duration>[];
    final adapter = ScriptedAdapter((options, _) async {
      if (!options.headers.containsKey('x-argus')) {
        return ResponseBody.fromString('', 200);
      }
      return response(themes);
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      signLists: false,
      retry: NetworkRetry(wait: (d) async => waits.add(d)),
    );
    expect(await client.themes('short_play'), hasLength(1));
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.first.headers.containsKey('x-argus'), isFalse);
    expect(adapter.requests.last.headers['x-argus'], isNotEmpty);
    expect(adapter.bodies[0], adapter.bodies[1]);
    expect(
      adapter.requests[0].uri.queryParameters['device_id'],
      adapter.requests[1].uri.queryParameters['device_id'],
    );
    expect(waits, [const Duration(seconds: 1)]);
    await client.themes('comic_series');
    expect(adapter.requests, hasLength(3));
    expect(adapter.requests.last.headers['x-argus'], isNotEmpty);
  });
  test('empty signed responses exhaust the same four-attempt bound', () async {
    final adapter = ScriptedAdapter(
      (_, _) async => ResponseBody.fromString('  ', 200),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      retry: NetworkRetry(wait: (_) async {}),
    );
    await expectLater(
      client.themes('short_play'),
      throwsA(isA<IncompleteCatalogResponse>()),
    );
    expect(adapter.requests, hasLength(4));
  });

  test(
    'theme timeouts retry with fresh POST bodies and extended timeouts',
    () async {
      var calls = 0;
      final waits = <Duration>[];
      final adapter = ScriptedAdapter((options, _) async {
        if (++calls < 4) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return response(themes);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = CatalogClient(
        dio: dio,
        deviceId: '1234567890123456',
        signLists: true,
        retry: NetworkRetry(wait: (v) async => waits.add(v)),
      );
      expect((await client.themes('short_play')).single.name, '都市');
      expect(calls, 4);
      expect(waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      expect(adapter.bodies, everyElement(adapter.bodies.first));
      expect(
        adapter.requests.map((r) => r.uri.queryParameters['_rticket']).toSet(),
        hasLength(4),
      );
      for (final request in adapter.requests) {
        expect(request.connectTimeout, const Duration(seconds: 60));
        expect(request.receiveTimeout, const Duration(seconds: 60));
        expect(request.sendTimeout, const Duration(seconds: 60));
        expect(request.headers['x-argus'], isNotNull);
      }
    },
  );
  test(
    'list 503 then success retains requested cursor, size and seen IDs',
    () async {
      var calls = 0;
      final adapter = ScriptedAdapter(
        (_, _) async => ++calls == 1 ? response({}, 503) : response(page),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = CatalogClient(
        dio: dio,
        deviceId: '1234567890123456',
        browsePageSize: 50,
        retry: NetworkRetry(wait: (_) async {}),
      );
      expect(
        (await client.browse(cursor: '50', seen: ['12'])).items.single.id,
        '123',
      );
      expect(calls, 2);
      for (final body in adapter.bodies) {
        expect(body['offset'], 50);
        expect(body['limit'], 50);
        expect(body['filter_ids'], '12');
      }
    },
  );
  test('persistent failure stops after the initial request and three retries, and a later request can recover', () async {
    var broken = true;
    final adapter = ScriptedAdapter(
      (_, _) async => broken ? response({}, 502) : response(page),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      retry: NetworkRetry(wait: (_) async {}),
    );
    await expectLater(client.browse(), throwsA(isA<DioException>()));
    expect(adapter.requests, hasLength(4));
    broken = false;
    expect((await client.browse()).items, hasLength(1));
  });
  test('401 is not retried; business errors exhaust three retries; custom timeout is honored', () async {
    for (final status in [401, 200]) {
      final adapter = ScriptedAdapter(
        (_, _) async => status == 401
            ? response({}, 401)
            : response({'code': 110001, 'message': 'denied'}),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = CatalogClient(
        dio: dio,
        deviceId: '1234567890123456',
        protocol: const AppSettings(timeoutSeconds: 90),
        retry: NetworkRetry(wait: (_) async {}),
      );
      await expectLater(client.browse(), throwsA(anything));
      expect(adapter.requests, hasLength(status == 401 ? 1 : 4));
      expect(
        adapter.requests.first.connectTimeout,
        const Duration(seconds: 90),
      );
    }
  });
  test(
    'missing selector payload is retried, valid empty choices are not',
    () async {
      var calls = 0;
      final adapter = ScriptedAdapter(
        (_, _) async => response(
          ++calls == 1
              ? {'code': 0, 'data': {}}
              : {
                  'code': 0,
                  'data': {'selector_rows': []},
                },
        ),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = CatalogClient(
        dio: dio,
        deviceId: '1234567890123456',
        retry: NetworkRetry(wait: (_) async {}),
      );
      expect(await client.themes('short_play'), isEmpty);
      expect(calls, 2);
    },
  );
  test('slow themes do not block independent list request', () async {
    final gate = Completer<ResponseBody>();
    final started = Completer<void>();
    final adapter = ScriptedAdapter((_, body) async {
      if (body['need_selector_panel'] == true) {
        started.complete();
        return gate.future;
      }
      return response(page);
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(dio: dio, deviceId: '1234567890123456');
    final pending = client.themes('short_play');
    await started.future;
    expect(
      (await client.browse().timeout(const Duration(seconds: 2))).items,
      hasLength(1),
    );
    gate.complete(response(themes));
    expect(await pending, hasLength(1));
  });
  test('cancellation and bad certificates are never retried; 429 honors bounded Retry-After', () async {
    for (final type in [
      DioExceptionType.cancel,
      DioExceptionType.badCertificate,
    ]) {
      var calls = 0;
      await expectLater(
        NetworkRetry(wait: (_) async {}).run<void>(() async {
          calls++;
          throw DioException(requestOptions: RequestOptions(), type: type);
        }),
        throwsA(isA<DioException>()),
      );
      expect(calls, 1);
    }
    final waits = <Duration>[];
    var calls = 0;
    await NetworkRetry(wait: (v) async => waits.add(v)).run(() async {
      if (++calls == 1) {
        throw DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(),
            statusCode: 429,
            headers: Headers.fromMap({
              'retry-after': ['120'],
            }),
          ),
        );
      }
    });
    expect(waits, [const Duration(seconds: 30)]);
  });
}
