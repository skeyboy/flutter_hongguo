import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:test/test.dart';

class PageAdapter implements HttpClientAdapter {
  final bodies = <Map<String, dynamic>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    final json = jsonDecode(
      utf8.decode(await body!.expand((b) => b).toList()),
    ) as Map<String, dynamic>;
    bodies.add(json);
    final limit = json['limit'] as int, offset = json['offset'] as int;
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'data': {
          'video_data': [
            for (var i = 0; i < (offset == 0 ? limit : 7); i++)
              {'series_id': '${offset + i}', 'title': '测试 $i'},
          ],
          if (offset > 0) 'has_more': false,
        },
      }),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final size in [30, 50]) {
    test(
      'request $size rows and use raw response cursor without assuming 18 rows',
      () async {
        final adapter = PageAdapter(), dio = Dio();
        dio.httpClientAdapter = adapter;
        addTearDown(dio.close);
        final client = CatalogClient(
          dio: dio,
          deviceId: '1234567890123456',
          browsePageSize: size,
        );
        final first = await client.browse(
          genre: 'ai_series',
          sort: 'hot_collect',
        );
        expect(first.items.length, size);
        expect(first.nextCursor, '$size');
        final next = await client.browse(
          genre: 'ai_series',
          cursor: first.nextCursor,
        );
        expect(next.items.length, 7);
        expect(next.nextCursor, isNull);
        expect(adapter.bodies.every((b) => b['limit'] == size), isTrue);
        expect(adapter.bodies.last['offset'], size);
      },
    );
  }
  test('reject oversized page requests before sending network traffic', () {
    final dio = Dio();
    addTearDown(dio.close);
    expect(
      () => CatalogClient(
        dio: dio,
        deviceId: '1234567890123456',
        browsePageSize: 51,
      ),
      throwsArgumentError,
    );
  });
}
