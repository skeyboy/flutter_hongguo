import 'dart:convert';
import 'dart:io';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

void main() {
  final truths =
      jsonDecode(File('test/fixtures/spade.json').readAsStringSync()) as List;
  for (var i = 0; i < truths.length; i++) {
    test('Spade runtime truth $i', () {
      final row = truths[i];
      expect(Spade.unwrapV1(unhex(row[0])), row[1]);
      expect(Spade.toKey(base64Encode(unhex(row[0]))).key, row[1]);
    });
  }
  test('Spade rejects malformed input', () {
    for (final value in ['', '!', 'YQ==', base64Encode(List.filled(60, 0))]) {
      expect(Spade.toKey(value).key, isNull);
    }
  });
  test('Node CBC encrypted URL', () {
    final v = jsonDecode(File('test/fixtures/url.json').readAsStringSync());
    expect(decryptSpadeUrl(v['value'], base64Decode(v['seed'])), v['plain']);
  });
  test('Ordered query preserves Python encoding', () {
    expect(
      orderedQuery({'q': "红果 !'()* +/~"}),
      'q=%E7%BA%A2%E6%9E%9C%20%21%27%28%29%2A%20%2B%2F~',
    );
  });
  test('URL host checks include credentials and nondefault ports', () {
    for (final u in [
      'http://a.fqnovel.com/x',
      'https://fqnovel.com.evil.test/x',
      'https://user@fqnovel.com/x',
      'https://fqnovel.com:444/x',
    ]) {
      expect(() => checkedUrl(u, ['fqnovel.com']), throwsFormatException);
    }
    expect(
      checkedUrl('https://a.fqnovel.com/x', ['fqnovel.com']).host,
      'a.fqnovel.com',
    );
  });
  final mp4 = jsonDecode(File('test/fixtures/mp4.json').readAsStringSync());
  for (final name in ['head', 'tail']) {
    test(
      'Node $name MP4 parse, CTR plaintext, remove CENC without offset relocation',
      () {
        final store = MemoryStore(
          File('test/fixtures/$name.mp4').readAsBytesSync(),
        );
        final span = findMoov(store),
            view = ByteView(store.read(span.start, span.size), span.start),
            analysis = analyzeMp4(view);
        expect(analysis.tracks, hasLength(1));
        final track = analysis.tracks.single;
        expect(track.handler, 'vide');
        expect(track.sizes, hasLength(2));
        decryptTrack(store, track, unhex(mp4['key']));
        for (var i = 0; i < track.sizes.length; i++) {
          expect(
            hex(store.read(track.offsets[i], track.sizes[i])),
            mp4['samples'][i],
          );
        }
        final clean = stripEncryption(view);
        expect(clean.length, span.size);
        store.write(span.start, clean);
        final rebuilt = analyzeMp4(
          ByteView(store.read(span.start, span.size), span.start),
        );
        expect(rebuilt.moov.find('senc'), isNull);
        expect(rebuilt.moov.find('sinf'), isNull);
        expect(rebuilt.moov.find('hvc1'), isNotNull);
        expect(rebuilt.tracks.single.offsets, track.offsets);
      },
    );
  }
  test('Wrong content key fails before mutation', () {
    final store = MemoryStore(File('test/fixtures/head.mp4').readAsBytesSync()),
        before = File('test/fixtures/head.mp4').readAsBytesSync();
    final a = analyzeMp4(ByteView(store.data));
    expect(
      () => decryptTrack(store, a.tracks.single, List.filled(16, 0)),
      throwsFormatException,
    );
    expect(store.data, before);
  });
  test('IV layout and carry', () {
    expect(
      hex(ivToCounter('0000000000000001')),
      '00000000000000010000000000000000',
    );
    expect(
      hex(ctrCounter('ffffffffffffffff', 1)),
      '00000000000000000000000000000000',
    );
    expect(
      hex(ivToCounter('00000000000000010000000000000009')),
      '00000000000000010000000000000009',
    );
  });
  test('Malformed box is rejected', () {
    expect(
      () => parseBoxes(ByteView([0, 0, 0, 30, 109, 111, 111, 118])),
      throwsFormatException,
    );
  });
  test('H264 preference and backup URL fallback', () {
    final chosen = AppSource.selectTrack({
      'video_list': {
        'hevc': {
          'codec_type': 'hevc',
          'definition': '1080p',
          'main_url': 'https://a.fqnovelvod.com/h.mp4',
          'width': 1920,
          'height': 1080,
        },
        'h264': {
          'codec_type': 'h264',
          'definition': '720p',
          'main_url': 'https://evil.test/x',
          'backup_url': 'https://a.fqnovelvod.com/a.mp4',
          'width': 1280,
          'height': 720,
        },
      },
    });
    expect(chosen.definition, '720p');
    expect(chosen.url.path, '/a.mp4');
  });
  test('SSR scanner respects escaped delimiters and strings', () {
    expect(
      WebSource.embedded(
        r'<script>{"searchList":[{"title":"a]b\"c"}],"x":0}</script>',
        'searchList',
      ),
      [
        {'title': 'a]b"c'},
      ],
    );
  });
}
