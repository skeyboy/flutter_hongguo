import '../models/models.dart';
import '../ports/repository.dart';
import '../upstream/signed_client.dart';
import '../upstream/url_codec.dart';
import '../upstream/web_source.dart';

class NativeCatalog implements CatalogRepository {
  final SignedClient client;
  final WebSource web;
  final String host;
  NativeCatalog(
    this.client, {
    this.host = 'api5-normal-sinfonlinea.fqnovel.com',
  }) : web = WebSource(client.transport);
  @override
  Future<Page<Series>> search(
    String query, {
    int offset = 0,
    int limit = 20,
  }) async {
    if (query.trim().isEmpty) return const Page([]);
    _pageArgs(offset, limit);
    try {
      final items = await web.search(query);
      if (items.isNotEmpty) {
        final end = (offset + limit).clamp(0, items.length),
            start = offset.clamp(0, items.length);
        return Page(
          items.sublist(start, end),
          hasMore: end < items.length,
          nextOffset: end,
        );
      }
    } catch (_) {
      /* The signed API is the metadata fallback. */
    }
    var cursor = 0, hasMore = true;
    var passback = '', searchId = '';
    final rows = <Series>[], seen = <String>{};
    for (
      var page = 0;
      page < 60 && hasMore && rows.length < offset + limit;
      page++
    ) {
      final j = await client.request(
        'https://$host/reading/bookapi/search/tab/v',
        query: {
          'query': query,
          'tab_name': 'feed',
          'search_source': '1',
          'offset': '$cursor',
          'count': '10',
          'use_correct': 'true',
          if (passback.isNotEmpty) 'passback': passback,
          if (searchId.isNotEmpty) 'search_id': searchId,
        },
      );
      final tabs = j['search_tabs'] as List? ?? [];
      if (tabs.isEmpty) {
        hasMore = false;
        break;
      }
      final tab = asObject(tabs.first), data = tab['data'] as List? ?? [];
      for (final item in data) {
        final cell = asObject(item), vd = asObject(cell['video_detail']);
        final raw = cell['video_data'];
        final video = asObject(raw is List && raw.isNotEmpty ? raw.first : raw),
            inner = asObject(video['video_detail']);
        final sid = textValue(cell['book_id'] ?? cell['search_result_id']);
        final ep = intValue(
          vd['episode_cnt'],
          intValue(video['episode_cnt'], intValue(inner['episode_cnt'])),
        );
        if (sid.isEmpty || ep == 0 || !seen.add(sid)) continue;
        final title =
            asObject(asObject(cell['search_high_light'])['title'])['text'] ??
            vd['series_title'] ??
            video['title'] ??
            inner['series_title'];
        rows.add(
          Series(
            id: sid,
            title: textValue(title).replaceAll(RegExp('<[^>]*>'), ''),
            episodeCount: ep,
            cover: textValue(video['cover'] ?? inner['series_cover']),
            intro: textValue(inner['series_intro'] ?? vd['series_intro']),
          ),
        );
      }
      final next = intValue(tab['next_offset'], cursor + data.length);
      hasMore =
          (tab['has_more'] == true || tab['has_more'] == 1) &&
          data.isNotEmpty &&
          next > cursor;
      cursor = next;
      passback = textValue(tab['passback']);
      searchId = textValue(tab['search_id']);
    }
    final start = offset.clamp(0, rows.length),
        end = (offset + limit).clamp(0, rows.length);
    return Page(
      rows.sublist(start, end),
      hasMore: hasMore || end < rows.length,
      nextOffset: end,
    );
  }

  @override
  Future<Page<Series>> browse({
    String genre = 'short_play',
    int offset = 0,
    int limit = 20,
    Set<String> seen = const {},
  }) async {
    _pageArgs(offset, limit);
    if (!{'short_play', 'comic_series', 'ai_series'}.contains(genre))
      throw ArgumentError.value(genre);
    final j = await client.request(
      'https://$host/reading/distribution/category/landpage/v',
      signed: false,
      body: {
        'filter_ids': seen.join(','),
        'req_scene': genre == 'short_play' ? 'default' : genre,
        'offset': offset,
        'need_selector_panel': false,
        'limit': limit,
        'select_items': {
          'category_dim_epoch': [],
          'online_time': [],
          'gender': [],
          'category_dim_role': [],
          'genre': [genre],
          'sort': ['online_time'],
          'category_dim_theme': [],
        },
        'session_id': '',
        'req_type': 'only_content',
        'client_req_type': 3,
      },
    );
    final data = asObject(j['data']), raw = data['video_data'] as List? ?? [];
    final unique = <String>{...seen}, items = <Series>[];
    for (final row in raw) {
      final s = Series.fromJson(asObject(row));
      if (s.id.isNotEmpty && unique.add(s.id)) items.add(s);
    }
    return Page(
      items,
      hasMore:
          data['has_more'] != false && data['has_more'] != 0 && raw.isNotEmpty,
      nextOffset: intValue(data['next_offset'], offset + raw.length),
    );
  }

  @override
  Future<SeriesDetail> detail(String seriesId) async {
    if (!RegExp(r'^\d{1,30}$').hasMatch(seriesId))
      throw ArgumentError('剧集编号无效');
    try {
      final j = await client.request(
        'https://$host/novel/player/multi_video_detail/preload/v1',
        body: {
          'biz_param': {
            'detail_page_version': 0,
            'disable_digg_stat': false,
            'image_shrink_datas_str':
                'W3siaW1hZ2VfdHlwZSI6MywiaW1hZ2Vfd2lkdGgiOjkwMCwic2hyaW5rX3R5cGUiOjN9LHsiaW1hZ2VfdHlwZSI6NCwiaW1hZ2Vfd2lkdGgiOjU0LCJzaHJpbmtfdHlwZSI6NH1d',
            'need_all_video_definition': false,
            'need_mp4_align': false,
            'screen_width_px': '900',
            'source': 7,
            'use_os_player': false,
            'use_server_dns': false,
          },
          'dr_scene': 'preload',
          'series_id': seriesId,
        },
      );
      final video = asObject(
        asObject(asObject(j['data'])[seriesId])['video_data'],
      );
      final episodes = [
        for (final row in video['video_list'] as List? ?? [])
          Episode.fromJson(asObject(row)),
      ]..sort((a, b) => a.index.compareTo(b.index));
      if (episodes.isEmpty) throw StateError('App 未提供分集');
      return SeriesDetail(
        Series.fromJson({
          ...video,
          'series_id': seriesId,
          'title': video['series_title'],
          'abstract': video['series_intro'],
        }),
        episodes,
      );
    } catch (_) {
      return web.detail(seriesId);
    }
  }

  void _pageArgs(int offset, int limit) {
    if (offset < 0 || limit < 1 || limit > 120)
      throw ArgumentError('Invalid page range');
  }
}
