import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/src/request_control.dart';
import 'package:test/test.dart';

import 'catalog_retry_test.dart' show ScriptedAdapter, response, page, themes;

class HeldAdapter implements HttpClientAdapter {
  final started = Completer<RequestOptions>();
  final cancelled = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) {
    if (!started.isCompleted) started.complete(options);
    cancel?.then((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('shared request survives cancellation of only one subscriber', () async {
    final gate = Completer<ResponseBody>(), started = Completer<void>();
    final adapter = ScriptedAdapter((_, _) async {
      started.complete();
      return gate.future;
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(dio: dio, deviceId: '1234567890123456');
    final a = CatalogRequestScope(), b = CatalogRequestScope();
    final cancelled = expectLater(
      a.run(() => client.browse()),
      throwsA(isA<RequestCancelled>()),
    );
    final survivor = b.run(() => client.browse());
    await started.future;
    a.cancel();
    await cancelled;
    expect(adapter.requests.single.cancelToken!.isCancelled, isFalse);
    gate.complete(response(page));
    expect((await survivor).items.single.id, '123');
    expect(adapter.requests, hasLength(1));
  });
  test('last subscriber cancellation reaches transport', () async {
    final adapter = HeldAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(dio: dio, deviceId: '1234567890123456');
    final scope = CatalogRequestScope();
    final result = expectLater(
      scope.run(() => client.browse()),
      throwsA(isA<RequestCancelled>()),
    );
    await adapter.started.future;
    scope.cancel();
    await result;
    await adapter.cancelled.future.timeout(const Duration(seconds: 1));
  });
  test('deadline aborts an unresponsive transport', () async {
    final adapter = HeldAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final traces = <MetadataTiming>[];
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      onTiming: traces.add,
      requestDeadline: const Duration(milliseconds: 60),
    );
    await expectLater(
      client.browse(),
      throwsA(isA<MetadataDeadlineExceeded>()),
    );
    await adapter.cancelled.future.timeout(const Duration(seconds: 1));
    expect(traces.single.stages['transport'], greaterThan(Duration.zero));
    expect(traces.single.attempts, 1);
  });
  test(
    'queued cancellation does not send or poison subsequent requests',
    () async {
      final adapter = ScriptedAdapter((_, _) async => response(page));
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = CatalogClient(dio: dio, deviceId: '1234567890123456');
      await client.browse();
      final scope = CatalogRequestScope();
      final pending = expectLater(
        scope.run(() => client.browse(theme: '1')),
        throwsA(isA<RequestCancelled>()),
      );
      scope.cancel();
      await pending;
      await client.browse(theme: '2');
      expect(adapter.requests, hasLength(2));
      expect(adapter.bodies.last['select_items']['category_dim_theme'], ['2']);
    },
  );
  test('cancellation interrupts retry sleep', () async {
    final waiting = Completer<void>(), gate = Completer<void>();
    var calls = 0;
    final adapter = ScriptedAdapter((_, _) async {
      calls++;
      return ResponseBody.fromString('', 200);
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      retry: NetworkRetry(
        wait: (_) {
          waiting.complete();
          return gate.future;
        },
      ),
    );
    final scope = CatalogRequestScope();
    final pending = expectLater(
      scope.run(() => client.browse()),
      throwsA(isA<RequestCancelled>()),
    );
    await waiting.future;
    scope.cancel();
    await pending;
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(calls, 1);
  });
  test(
    'themes expire by genre and failed responses never replace cache',
    () async {
      var clock = DateTime.utc(2026, 10, 21);
      var broken = false;
      final adapter = ScriptedAdapter(
        (_, _) async => broken ? response({'code': 123}) : response(themes),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = CatalogClient(
        dio: dio,
        deviceId: '1234567890123456',
        now: () => clock,
      );
      await client.themes('short_play');
      await client.themes('short_play');
      expect(adapter.requests, hasLength(1));
      await client.themes('comic_series');
      expect(adapter.requests, hasLength(2));
      clock = clock.add(const Duration(hours: 7));
      broken = true;
      await expectLater(
        client.themes('short_play'),
        throwsA(isA<CatalogError>()),
      );
      broken = false;
      await client.themes('short_play');
      expect(adapter.requests, hasLength(4));
    },
  );
  test('cursor and exclusions distinguish shared request keys', () async {
    final adapter = ScriptedAdapter((_, _) async => response(page));
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(dio: dio, deviceId: '1234567890123456');
    await Future.wait([
      client.browse(cursor: '1'),
      client.browse(cursor: '2'),
      client.browse(cursor: '1', seen: ['55']),
    ]);
    expect(adapter.requests, hasLength(3));
  });
  test('detail primary and website fallback share one deadline', () async {
    final adapter = ScriptedAdapter((options, _) async {
      if (options.uri.path.contains('preload')) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        return response({'code': 110001, 'message': 'unavailable'});
      }
      return Completer<ResponseBody>().future;
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      requestDeadline: const Duration(milliseconds: 150),
    );
    await expectLater(
      client.detail('123'),
      throwsA(isA<MetadataDeadlineExceeded>()),
    );
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.cancelToken!.isCancelled, isTrue);
  });

  test('Retry-After numeric and HTTP-date are never shortened', () async {
    final now = DateTime.utc(2026, 10, 21);
    for (final header in ['3', 'Wed, 21 Oct 2026 00:00:03 GMT']) {
      final waits = <Duration>[];
      var calls = 0;
      await NetworkRetry(
        delays: [const Duration(milliseconds: 400)],
        now: () => now,
        wait: (d) async => waits.add(d),
      ).run(() async {
        if (++calls == 1) {
          throw DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: RequestOptions(),
              statusCode: 429,
              headers: Headers.fromMap({
                'retry-after': [header],
              }),
            ),
          );
        }
        return true;
      });
      expect(waits, [const Duration(seconds: 3)]);
    }
  });
  test('fallback phases share the total deadline', () async {
    final budget = RequestBudget(const Duration(milliseconds: 120));
    addTearDown(budget.close);
    CancelToken? fallback;
    final result = budget.run(() async {
      await RequestBudget.current.phase(
        const Duration(milliseconds: 70),
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      fallback = RequestBudget.current.token;
      return RequestBudget.current.guard(Completer<bool>().future);
    });
    await expectLater(result, throwsA(isA<MetadataDeadlineExceeded>()));
    expect(fallback!.isCancelled, isTrue);
  });
  test('trace separates queue signing transport and backoff without sensitive fields', () async {
    var calls = 0;
    final adapter = ScriptedAdapter(
      (_, _) async =>
          ++calls == 1 ? ResponseBody.fromString('', 200) : response(page),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final timings = <MetadataTiming>[];
    final client = CatalogClient(
      dio: dio,
      deviceId: '1234567890123456',
      onTiming: timings.add,
      retry: NetworkRetry(delays: [Duration.zero], wait: (_) async {}),
    );
    await client.browse();
    final t = timings.single;
    expect(t.operation, 'catalog.browse');
    expect(t.failureType, isNull);
    expect(
      t.stages.keys,
      containsAll(['queue', 'sign', 'transport', 'backoff']),
    );
    expect(t.elapsed, greaterThan(Duration.zero));
  });
}
