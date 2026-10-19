import 'dart:convert';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

class FakeTransport implements Transport {
  final Future<TransportResponse> Function(TransportRequest) handler;
  FakeTransport(this.handler);
  @override
  Future<TransportResponse> send(TransportRequest request) => handler(request);
}

TransportResponse jsonResponse(Object value) =>
    TransportResponse(200, utf8Bytes(jsonEncode(value)));

class MemoryKV implements KeyValueStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class FakeCatalog implements CatalogRepository {
  bool fail = false;
  int detailCalls = 0;
  @override
  Future<SeriesDetail> detail(String id) async {
    detailCalls++;
    if (fail) throw StateError('offline');
    return SeriesDetail(Series(id: id, title: '剧集'), [
      const Episode(vid: '9999999999999999999', index: 1),
    ]);
  }

  @override
  Future<Page<Series>> search(
    String query, {
    int offset = 0,
    int limit = 20,
  }) async => const Page([]);
  @override
  Future<Page<Series>> browse({
    String genre = 'short_play',
    int offset = 0,
    int limit = 20,
    Set<String> seen = const {},
  }) async => const Page([]);
}

class TestClock implements Clock {
  @override
  int milliseconds = 1780000000123;
}

void main() {
  test(
    'Signed POST body is serialized once, exact query and stub are sent',
    () async {
      final transport = FakeTransport((request) async {
        expect(request.method, 'POST');
        expect(request.uri.query, contains('resolution=1280%2A2772'));
        expect(
          utf8.decode(request.body!),
          '{"q":"红果","id":"7693917197759958040"}',
        );
        expect(
          request.headers['x-ss-stub'],
          hex(md5Bytes(request.body!)).toUpperCase(),
        );
        expect(
          request.headers.keys,
          containsAll([
            'x-gorgon',
            'x-khronos',
            'x-helios',
            'x-medusa',
            'x-argus',
            'x-ladon',
          ]),
        );
        expect(
          PureSign().branchOf(
            request.uri.toString(),
            request.body,
            int.parse(request.headers['x-khronos']!),
          ),
          isNot(1),
        );
        return jsonResponse({'data': {}});
      });
      await SignedClient(transport).request(
        'https://example.test/api',
        body: {'q': '红果', 'id': '7693917197759958040'},
      );
    },
  );
  test(
    'Web adapter follows legacy paths, string IDs and stream credentials',
    () async {
      final seen = <TransportRequest>[];
      final transport = FakeTransport((r) async {
        seen.add(r);
        return jsonResponse({
          'results': [
            {'series_id': '9999999999999999999', 'title': '长 ID'},
          ],
          'has_more': true,
          'next_offset': 20,
          'items': [],
        });
      });
      final repo = RemoteRepository(
        transport,
        Uri.parse('https://api.example.test'),
        apiKey: 'local-test-key',
      );
      final page = await repo.search('红果');
      expect(page.items.single.id, '9999999999999999999');
      expect(page.hasMore, isTrue);
      await repo.browse(offset: 20);
      expect(seen.last.uri.queryParameters['seen'], '0');
      final media = await repo.prepare('123');
      final uri = Uri.parse(media.location);
      expect(uri.path, '/stream');
      expect(uri.queryParameters['api_key'], 'local-test-key');
      expect(seen.first.headers['x-api-key'], 'local-test-key');
    },
  );
  test(
    'Native browser keeps string IDs and never repeats stationary cursor',
    () async {
      var calls = 0;
      final transport = FakeTransport((r) async {
        calls++;
        if (r.uri.host == 'hongguoduanju.com')
          return TransportResponse(200, utf8Bytes('<html></html>'));
        return jsonResponse({
          'search_tabs': [
            {
              'data': [
                {
                  'book_id': '9999999999999999999',
                  'video_detail': {'series_title': '短剧', 'episode_cnt': 5},
                },
              ],
              'next_offset': 0,
              'has_more': true,
            },
          ],
        });
      });
      final result = await NativeCatalog(SignedClient(transport)).search('测试');
      expect(result.items.single.id, '9999999999999999999');
      expect(result.hasMore, isFalse);
      expect(calls, 2);
    },
  );
  test(
    'Detail persists across repository instances and serves stale metadata offline',
    () async {
      final source = FakeCatalog(), store = MemoryKV(), clock = TestClock();
      final first = CachedCatalog(source, store, clock: clock);
      await first.detail('123');
      expect(source.detailCalls, 1);
      source.fail = true;
      clock.milliseconds += const Duration(days: 1).inMilliseconds;
      final restarted = CachedCatalog(source, store, clock: clock);
      final cached = await restarted.detail('123');
      expect(cached.episodes.single.vid, '9999999999999999999');
      expect(source.detailCalls, 2);
    },
  );
  test('Scheduler bounds concurrency and releases failed task', () async {
    final scheduler = MediaScheduler();
    var active = 0, peak = 0;
    Future<int> job(int i) => scheduler.run(CancellationToken(), () async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(Duration.zero);
      active--;
      if (i == 0) throw StateError('failed');
      return i;
    });
    final failed = job(0);
    final next = job(1);
    await expectLater(failed, throwsStateError);
    expect(await next, 1);
    expect(peak, 1);
  });
}
