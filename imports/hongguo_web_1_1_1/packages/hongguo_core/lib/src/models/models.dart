import '../upstream/url_codec.dart';

int intValue(dynamic v, [int fallback = 0]) =>
    v is num ? v.toInt() : int.tryParse('$v') ?? fallback;
String textValue(dynamic v) => v?.toString() ?? '';

class Series {
  final String id, title, cover, intro;
  final int episodeCount;
  const Series({
    required this.id,
    required this.title,
    this.cover = '',
    this.intro = '',
    this.episodeCount = 0,
  });
  factory Series.fromJson(Map<String, dynamic> j) => Series(
    id: textValue(j['series_id'] ?? j['book_id']),
    title: textValue(j['title'] ?? j['series_title'] ?? j['name']),
    cover: cleanUrl(textValue(j['cover'] ?? j['series_cover'])),
    intro: textValue(j['abstract'] ?? j['series_intro']),
    episodeCount: intValue(j['episode_cnt']),
  );
  Map<String, dynamic> toJson() => {
    'series_id': id,
    'title': title,
    'cover': cover,
    'abstract': intro,
    'episode_cnt': episodeCount,
  };
}

class Episode {
  final String vid, title;
  final int index, duration;
  const Episode({
    required this.vid,
    required this.index,
    this.title = '',
    this.duration = 0,
  });
  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
    vid: textValue(j['vid']),
    index: intValue(j['index'] ?? j['vid_index']),
    title: textValue(j['title']),
    duration: intValue(j['duration']),
  );
}

class SeriesDetail {
  final Series series;
  final List<Episode> episodes;
  const SeriesDetail(this.series, this.episodes);
  factory SeriesDetail.fromJson(Map<String, dynamic> j) =>
      SeriesDetail(Series.fromJson(asObject(j['meta'])), [
        for (final row in (j['episodes'] as List? ?? []))
          Episode.fromJson(asObject(row)),
      ]);
}

class Page<T> {
  final List<T> items;
  final bool hasMore;
  final int nextOffset;
  const Page(this.items, {this.hasMore = false, this.nextOffset = 0});
}

class PlaybackTrack {
  final Uri url;
  final String spadeA, definition;
  final int size;
  const PlaybackTrack({
    required this.url,
    this.spadeA = '',
    this.definition = '?',
    this.size = 0,
  });
  bool get encrypted => spadeA.isNotEmpty;
}

class MediaSource {
  final String location;
  final bool isLocal;
  const MediaSource(this.location, {this.isLocal = false});
}
