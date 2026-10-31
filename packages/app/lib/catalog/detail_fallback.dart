import 'package:hongguo_api/hongguo_api.dart';

/// The detail response is a partial record, not an authoritative one: the
/// upstream answers list requests with 题材词/封面/简介 filled in, while the
/// detail endpoint is the one that sometimes omits them. Both detail pages
/// therefore merge the row that led here over the response, so a page never
/// loses a field it already had -- and 「同题材 · X」 keeps its words, instead
/// of silently downgrading to the hot board (docs/design/video-detail-redesign.md §7).
DramaDetail mergeDetailFallbacks(DramaDetail result, Drama initial) {
  final drama = result.drama;
  return DramaDetail(
    Drama(
      id: drama.id.isEmpty ? initial.id : drama.id,
      title: drama.title.trim().isEmpty ? initial.title : drama.title,
      cover: drama.cover.isEmpty ? initial.cover : drama.cover,
      intro: drama.intro.isEmpty ? initial.intro : drama.intro,
      episodeCount: drama.episodeCount > 0
          ? drama.episodeCount
          : result.episodes.length,
      tagNames: drama.tagNames.isNotEmpty ? drama.tagNames : initial.tagNames,
    ),
    result.episodes,
  );
}
