import 'package:hongguo_api/src/catalog.dart';
import 'package:hongguo_api/src/source_id.dart';
import 'package:test/test.dart';

const _uuid = '550e8400-e29b-41d4-a716-446655440000';

Drama _drama(String title, [int episodeCount = 12]) =>
    Drama(id: '1', title: title, episodeCount: episodeCount);

void main() {
  group('sourceOf 判定表（契约 §2.1，顺序敏感）', () {
    const cases = [
      ('123456789012345678901234567890', 'hongguo'), // 30 位纯数字
      ('xifan:ch:123', 'xifan'),
      ('hema:42', 'hema'),
      ('reelshort:7:my-slug', 'reelshort'),
      ('dramabox:99', 'dramabox'),
      ('custom:$_uuid:vod:1:2', 'custom'),
      ('unknown:whatever', 'hongguo'), // 未知前缀兜底，不抛
    ];
    for (final (id, expected) in cases) {
      test('$id → $expected', () {
        expect(sourceOf(id), expected);
      });
    }
    test('纯字母脏数据也兜底 hongguo', () {
      expect(sourceOf('abc'), 'hongguo');
    });
  });

  group('parseSourceId 六源合法样例', () {
    test('hongguo', () {
      final p = parseSourceId('123456');
      expect(p.source, 'hongguo');
      expect(p.segments, ['123456']);
      expect(p.isEpisode, isTrue);
    });

    test('xifan 剧集 3 段 / 分集 4 段', () {
      final series = parseSourceId('xifan:ch:123');
      expect(series.source, 'xifan');
      expect(series.segments, ['ch', '123']);
      expect(series.isEpisode, isFalse);
      expect(parseSourceId('xifan:ch:123:2').isEpisode, isTrue);
    });

    test('hema 剧集 2 段 / 分集 3 段', () {
      expect(parseSourceId('hema:42').isEpisode, isFalse);
      final episode = parseSourceId('hema:42:7');
      expect(episode.segments, ['42', '7']);
      expect(episode.isEpisode, isTrue);
    });

    test('dramabox 剧集 2 段 / 分集 3 段', () {
      expect(parseSourceId('dramabox:99').isEpisode, isFalse);
      expect(parseSourceId('dramabox:99:1').isEpisode, isTrue);
    });

    test('reelshort 剧集 3 段 / 分集 5 段', () {
      final series = parseSourceId('reelshort:7:my-slug');
      expect(series.segments, ['7', 'my-slug']);
      expect(series.isEpisode, isFalse);
      final episode = parseSourceId('reelshort:7:my-slug:1:100');
      expect(episode.segments, ['7', 'my-slug', '1', '100']);
      expect(episode.isEpisode, isTrue);
    });

    test('custom 剧集 3 段 / 分集 5 段', () {
      final series = parseSourceId('custom:$_uuid:vod');
      expect(series.source, 'custom');
      expect(series.segments, [_uuid, 'vod']);
      expect(series.isEpisode, isFalse);
      final episode = parseSourceId('custom:$_uuid:vod:1:2');
      expect(episode.segments, [_uuid, 'vod', '1', '2']);
      expect(episode.isEpisode, isTrue);
    });
  });

  group('parseSourceId 六源非法样例（均抛 SourceRejected）', () {
    const invalid = [
      'abc', // hongguo 非纯数字
      'xifan:ch', // 段数不足 3
      'hema:', // 空段
      'dramabox:', // 空段
      'reelshort:7:Bad_Slug', // slug 非小写连字符
      'custom:not-a-uuid:vod:1:2', // 坏 UUID
    ];
    for (final id in invalid) {
      test(id, () {
        expect(() => parseSourceId(id), throwsA(isA<SourceRejected>()));
      });
    }
  });

  group('belongsTo（契约 §2.3）', () {
    test('同前缀且剧集段相等 → true', () {
      expect(belongsTo('xifan:a:b:2', 'xifan:a:b'), isTrue);
      expect(belongsTo('custom:$_uuid:vod:1:2', 'custom:$_uuid:vod'), isTrue);
    });

    test('跨源 / 剧集段不同 → false', () {
      expect(belongsTo('hema:x:1', 'xifan:a:b'), isFalse);
      expect(
        belongsTo(
          'custom:11111111-1111-4111-8111-111111111111:vod:1:2',
          'custom:$_uuid:vod',
        ),
        isFalse,
      );
    });

    test('hongguo 纯数字形态一致即可，不强制相等；非法 ID 判 false', () {
      expect(belongsTo('123', '456'), isTrue);
      expect(belongsTo('bad!', 'xifan:a:b'), isFalse);
    });
  });

  group('mediaKeyEscape 单射 + 平台合法（契约 §5）', () {
    test('冒号分段不会碰撞', () {
      expect(
        mediaKeyEscape('custom:u:v:1:2'),
        isNot(mediaKeyEscape('custom:u:v:12')),
      );
    });

    test('一组含边界字符的 ID 全部映射到 [A-Za-z0-9_-] 且互不碰撞', () {
      final ids = [
        '123',
        'xifan:a:b:2',
        'custom:u:v:1:2',
        'custom:u:v:12',
        'a_b',
        'a_5fb',
        '中文:剧集',
        'a/b',
        'a%b',
        '..',
      ];
      final escaped = ids.map(mediaKeyEscape).toList();
      expect(escaped.toSet().length, ids.length);
      for (final value in escaped) {
        expect(
          RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value),
          isTrue,
          reason: '$value 含平台非法字符',
        );
      }
    });
  });

  group('dedupKey 归一化（契约 §3 / §5）', () {
    test('全角半角、大小写、空白归一后一致', () {
      expect(dedupKey(_drama('测试的ＡＢＣ')), dedupKey(_drama('测试的abc')));
      expect(dedupKey(_drama(' 测试的 ABC ')), dedupKey(_drama('测试的abc')));
    });

    test('繁简不合并，集数不同不合并', () {
      expect(dedupKey(_drama('后')), isNot(dedupKey(_drama('後'))));
      expect(dedupKey(_drama('A', 12)), isNot(dedupKey(_drama('A', 13))));
    });
  });
}
