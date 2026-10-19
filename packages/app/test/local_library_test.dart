import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/local_library.dart';
import 'package:hongguo_app/platform/runtime.dart';

LocalEpisode file(
  String vid, {
  DramaDetail? detail,
  String quality = 'best',
  int day = 1,
}) => LocalEpisode(
  vid: vid,
  quality: quality,
  bytes: 1024,
  modified: DateTime(2026, 10, day),
  inUse: false,
  detail: detail,
);
void main() {
  test(
    'one card per series; variants count once and episodes sort by index',
    () {
      const detail = DramaDetail(
        Drama(id: '1', title: '故事', episodeCount: 30),
        [
          Episode(vid: '90', index: 2, title: '重逢'),
          Episode(vid: '91', index: 1, title: '初见'),
        ],
      );
      final group = groupLocalEpisodes([
        file('90', detail: detail),
        file('91', detail: detail),
        file('91', detail: detail, quality: '720p'),
      ]).single;
      expect(group.episodeCount, 2);
      expect(group.files.length, 3);
      expect(group.bytes, 3072);
      expect(group.badge, '已缓存 2 / 30 集');
      expect(group.sortedFiles().map((e) => group.episodeFor(e)!.index), [
        1,
        1,
        2,
      ]);
    },
  );
  test('same title different series stay separate; unknown or contradictory mapping is isolated', () {
    const first = DramaDetail(Drama(id: '1', title: '同名'), [
      Episode(vid: '1', index: 1),
    ]);
    const second = DramaDetail(Drama(id: '2', title: '同名'), [
      Episode(vid: '2', index: 1),
    ]);
    final groups = groupLocalEpisodes([
      file('1', detail: first),
      file('2', detail: second, day: 2),
      file('3'),
      file('4', detail: first),
    ]);
    expect(groups.map((g) => g.id), ['2', '1', '__unidentified__']);
    expect(groups.last.files.length, 2);
  });
}
