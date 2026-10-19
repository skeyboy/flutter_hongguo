import '../models/models.dart';
import '../ports/repository.dart';
import '../ports/transport.dart';
import '../upstream/url_codec.dart';

/// Browser backend: uses the existing same-origin Node API contract.
class RemoteRepository implements CatalogRepository, PlaybackRepository {
  final Transport transport;
  final Uri base;
  final String apiKey;
  RemoteRepository(this.transport, this.base, {this.apiKey = ''}) {
    if (!{'http', 'https'}.contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty)
      throw ArgumentError('Invalid API base URL');
  }
  Uri _uri(String path, Map<String, String> query) =>
      base.resolve(path).replace(queryParameters: query);
  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async => (await transport.send(
    TransportRequest(
      _uri(path, query),
      headers: {if (apiKey.isNotEmpty) 'x-api-key': apiKey},
    ),
  )).json();
  Page<Series> _page(Map<String, dynamic> j, String field, int offset) => Page(
    [for (final row in j[field] as List? ?? []) Series.fromJson(asObject(row))],
    hasMore: j['has_more'] == true,
    nextOffset: intValue(
      j['next_offset'],
      offset + (j[field] as List? ?? []).length,
    ),
  );
  @override
  Future<Page<Series>> search(
    String query, {
    int offset = 0,
    int limit = 20,
  }) async => _page(
    await _get('/search/page', {
      'q': query,
      'offset': '$offset',
      'limit': '$limit',
    }),
    'results',
    offset,
  );
  @override
  Future<Page<Series>> browse({
    String genre = 'short_play',
    int offset = 0,
    int limit = 20,
    Set<String> seen = const {},
  }) async {
    // The legacy server cannot split an absent seen value on subsequent pages.
    final j = await _get('/browse', {
      'genre': genre,
      'offset': '$offset',
      'limit': '$limit',
      'seen': seen.isEmpty ? '0' : seen.join(','),
    });
    return _page(j, 'items', offset);
  }

  @override
  Future<SeriesDetail> detail(String seriesId) async =>
      SeriesDetail.fromJson(await _get('/episodes', {'series_id': seriesId}));
  @override
  Future<MediaSource> prepare(
    String vid, {
    String quality = 'best',
    CancellationToken? cancellation,
    void Function(PreparationState)? onState,
  }) async {
    cancellation?.check();
    // /stream performs preparation and serves bytes with Range; never report a local cache hit.
    onState?.call(PreparationState.ready);
    return MediaSource(
      _uri('/stream', {
        'vid': vid,
        'quality': quality,
        if (apiKey.isNotEmpty) 'api_key': apiKey,
      }).toString(),
    );
  }
}
