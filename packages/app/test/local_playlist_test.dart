import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/playback/local_playlist.dart';

LocalEpisode file(String vid, {DramaDetail? detail, String quality = 'best'}) =>
    LocalEpisode(
      vid: vid,
      quality: quality,
      bytes: 1024,
      modified: DateTime(2026),
      inUse: false,
      detail: detail,
    );
void main() {
  test('local queue sorts episodes, deduplicates variants and starts at selected episode', () {
    const detail = DramaDetail(Drama(id: '1', title: '本地故事'), [
      Episode(vid: '13', index: 3),
      Episode(vid: '11', index: 1),
      Episode(vid: '12', index: 2),
    ]);
    final selected = file('12', detail: detail, quality: '720p');
    final group = groupLocalEpisodes([
      file('13', detail: detail),
      selected,
      file('11', detail: detail),
      file('12', detail: detail),
    ]).single;
    final queue = localPlaybackQueue(group, selected);
    expect(queue.detail.episodes.map((e) => e.vid), ['11', '12', '13']);
    expect(queue.initialPosition, 1);
  });
  test(
    'unidentified files never become an invented multi-series autoplay queue',
    () {
      final files = [file('11'), file('12')];
      final queue = localPlaybackQueue(
        groupLocalEpisodes(files).single,
        files.last,
      );
      expect(queue.detail.episodes.single.vid, '12');
      expect(queue.initialPosition, 0);
    },
  );
  test('quality prefers original selection, falls back only to existing files, and reports missing', () {
    final files = [
      file('11', quality: '720p'),
      file('11', quality: '1080p'),
      file('12'),
      file('13', quality: '720p'),
    ];
    expect(localQualityFor('11', files, '720p'), '720p');
    expect(localQualityFor('12', files, '720p'), 'best');
    expect(localQualityFor('13', files, '720p'), '720p');
    expect(localQualityFor('11', files, 'best'), '1080p');
    expect(localQualityFor('14', files, '720p'), isNull);
  });
  test('auto-next never silently skips missing episode indices', () {
    const first = Episode(vid: '11', index: 1);
    expect(
      localEpisodesAreConsecutive(first, const Episode(vid: '12', index: 2)),
      isTrue,
    );
    expect(
      localEpisodesAreConsecutive(first, const Episode(vid: '13', index: 3)),
      isFalse,
    );
  });
}
