import 'package:hongguo_api/hongguo_api.dart';
import 'package:test/test.dart';

Drama fromVideoData(Map<String, dynamic> videoData) =>
    Drama.fromJson({'video_data': videoData});

void main() {
  group('Drama.fromJson tagNames', () {
    test('parses the stringified category_schema of a browse row', () {
      final drama = fromVideoData({
        'series_id': '7661622467441478681',
        'series_title': '测试剧名',
        'category_schema':
            '[{"id":"cate_7","name":"都市"},{"id":"cate_9","name":"逆袭"},'
            '{"name":"都市"},{"name":""},{"other":1}]',
      });
      expect(drama.id, '7661622467441478681');
      expect(drama.tagNames, ['都市', '逆袭']);
    });

    test('accepts an already decoded category_schema list', () {
      final drama = fromVideoData({
        'series_id': '1',
        'category_schema': [
          {'name': '古装'},
          {'name': '穿越'},
          '热血',
        ],
      });
      expect(drama.tagNames, ['古装', '穿越']);
    });

    test('falls back to tag_info.text and the nested video_detail copy', () {
      expect(
        fromVideoData({
          'series_id': '1',
          'tag_info': {'text': '<b>亲情</b>'},
        }).tagNames,
        ['亲情'],
      );
      expect(
        fromVideoData({
          'series_id': '1',
          'video_detail': {'category_schema': '[{"name":"奇幻"}]'},
        }).tagNames,
        ['奇幻'],
      );
    });

    test('cover badges are not 题材 and never become tagNames', () {
      final drama = fromVideoData({
        'series_id': '1',
        'cover_tag_info_list': [
          {'text': '爆剧'},
          {'content': '独播'},
          '新剧',
        ],
      });
      expect(drama.tagNames, isEmpty);
    });

    test(
      'missing or malformed input yields an empty list without throwing',
      () {
        expect(fromVideoData({'series_id': '1', 'title': '无标签'}).tagNames, []);
        expect(
          fromVideoData({'series_id': '1', 'category_schema': '都市'}).tagNames,
          [],
        );
        expect(
          fromVideoData({'series_id': '1', 'category_schema': <Object>[]})
              .tagNames,
          [],
        );
        expect(
          fromVideoData({
            'series_id': '1',
            'category_schema': [
              {'other': '丢弃'},
              1,
              2.5,
              null,
            ],
          }).tagNames,
          [],
        );
        expect(
          fromVideoData({
            'series_id': '1',
            'category_schema': <Object, Object>{},
            'tag_info': <Object, Object>{},
          }).tagNames,
          [],
        );
      },
    );

    test('default Drama keeps an empty tagNames', () {
      expect(const Drama(id: '1', title: '手造').tagNames, isEmpty);
    });
  });
}
