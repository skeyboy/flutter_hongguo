import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';

import 'runtime_contract.dart';

/// Web uses the documented server API; native platforms always use Dart core.
/// Configure at build time with --dart-define=HONGGUO_API_BASE=https://your-host.
Future<AppRuntime> createRuntime() async {
  const base = String.fromEnvironment('HONGGUO_API_BASE');
  if (base.isEmpty) {
    throw const CatalogError('浏览器版需要配置内容服务地址。独立播放请使用桌面或手机 App。');
  }
  final uri = Uri.parse(base);
  if (!['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const CatalogError('内容服务地址无效');
  }
  final dio = Dio(
    BaseOptions(baseUrl: base, connectTimeout: const Duration(seconds: 15)),
  );
  final r = await dio.get<dynamic>('/api-key');
  final data = r.data is String ? jsonDecode(r.data) : r.data;
  final key = data['api_key'] as String;
  return _RemoteRuntime(dio, key);
}

Map<String, dynamic> _map(dynamic v) => Map<String, dynamic>.from(v as Map);

class _RemoteRuntime implements AppRuntime, CatalogRepository {
  final Dio dio;
  final String key;
  _RemoteRuntime(this.dio, this.key);
  @override
  CatalogRepository get catalog => this;
  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> query,
  ) async {
    final r = await dio.get<dynamic>(
      path,
      queryParameters: query,
      options: Options(headers: {'x-api-key': key}),
    );
    return _map(r.data is String ? jsonDecode(r.data) : r.data);
  }

  CatalogPage _page(Map<String, dynamic> data, String list) => CatalogPage(
    (data[list] as List).map((v) => Drama.fromJson(_map(v))).toList(),
    nextCursor: data['has_more'] == true ? '${data['next_offset']}' : null,
  );
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async => _page(
    await _get('/browse', {
      'genre': genre,
      'sort': sort,
      'theme': ?theme,
      'offset': ?cursor,
      if (cursor != null || seen.isNotEmpty) 'seen': seen.join(','),
    }),
    'items',
  );
  @override
  Future<CatalogPage> search(String query, {String? cursor}) async =>
      _page(await _get('/search', {'q': query, 'offset': ?cursor}), 'results');
  @override
  Future<DramaDetail> detail(String id) async {
    final data = await _get('/episodes', {'series_id': id}),
        meta = _map(data['meta']);
    return DramaDetail(
      Drama.fromJson(meta),
      (data['episodes'] as List).map((v) {
        final e = _map(v);
        return Episode(
          vid: '${e['vid']}',
          index: (e['index'] as num).toInt(),
          title: '${e['title'] ?? ''}',
        );
      }).toList(),
    );
  }

  @override
  Future<List<CatalogFilter>> themes(String genre) async {
    final data = await _get('/filters', {'genre': genre});
    for (final raw in data['rows'] as List) {
      final row = _map(raw);
      if ('${row['type']}'.contains('theme')) {
        return (row['items'] as List)
            .map((v) => CatalogFilter('${v['name']}', '${v['id']}'))
            .toList();
      }
    }
    return [];
  }

  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) {
    final uri = Uri.parse(dio.options.baseUrl)
        .resolve('/stream')
        .replace(
          queryParameters: {'vid': vid, 'quality': quality, 'api_key': key},
        );
    return _RemoteJob(uri.toString());
  }

  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {}
  @override
  Future<int> cacheBytes() async => 0;
  @override
  Future<void> clearCache() async => throw const CatalogError('浏览器版缓存由内容服务管理');
  @override
  Future<void> dispose() async => dio.close(force: true);
}

class _RemoteJob implements PlaybackJob {
  final String url;
  _RemoteJob(this.url);
  @override
  Future<String> get source async => url;
  @override
  void cancel() {}
  @override
  void release() {}
}
