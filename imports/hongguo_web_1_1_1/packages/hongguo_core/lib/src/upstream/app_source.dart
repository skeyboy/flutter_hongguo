import 'dart:convert';
import '../crypto/spade.dart';
import '../models/models.dart';
import '../ports/transport.dart';
import 'signed_client.dart';
import 'url_codec.dart';

class _Row {
  final Map<String, dynamic> item;
  late final int rank, pixels, size;
  int shortSide = 0;
  late final String definition;
  _Row(this.item) {
    final meta = asObject(item['video_meta']);
    final codec = textValue(
      item['codec_type'] ?? meta['codec_type'],
    ).toLowerCase();
    rank = {'h264', 'avc', 'avc1'}.contains(codec)
        ? 0
        : {'hevc', 'h265', 'hvc1', 'hev1', 'bytevc1'}.contains(codec)
        ? 1
        : 2;
    definition = [
      item['quality_desc'],
      item['definition'],
      item['height'],
      item['vheight'],
      meta['definition'],
    ].map(textValue).firstWhere((s) => s.isNotEmpty, orElse: () => '?');
    pixels = intValue(RegExp(r'\d+').firstMatch(definition)?.group(0));

    for (final pair in [
      [item['vwidth'], item['vheight']],
      [item['width'], item['height']],
      [meta['vwidth'], meta['vheight']],
      [meta['width'], meta['height']],
    ]) {
      final w = intValue(pair[0]), h = intValue(pair[1]);
      if (w > 0 && h > 0) {
        shortSide = w < h ? w : h;
        break;
      }
    }
    size = intValue(meta['size'], intValue(item['size']));
  }
}

class AppSource {
  final SignedClient client;
  AppSource(this.client);
  Future<PlaybackTrack> fetch(String vid, {String quality = 'best'}) async {
    if (!RegExp(r'^\d{1,30}$').hasMatch(vid)) throw ArgumentError('分集编号无效');
    final j = await client.request(
      'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/',
      body: {
        'biz_param': {
          'detail_page_version': 0,
          'device_level': 3,
          'disable_digg_stat': false,
          'need_all_video_definition': true,
          'need_mp4_align': false,
          'use_os_player': false,
          'use_server_dns': false,
          'video_platform': 1024,
        },
        'mixed_video_id_map': {
          '1004': [vid],
        },
      },
    );
    if (intValue(j['Code']) != 0 || intValue(j['code']) != 0)
      throw StateError('App 接口拒绝播放请求');
    final model = asObject(asObject(asObject(j['data'])[vid])['video_model']);
    final fallback = checkedUrl(parseFallback(model['fallback_api']), [
      'fqnovel.com',
      'snssdk.com',
    ]);
    final outer = (await client.transport.send(
      TransportRequest(fallback, headers: {'User-Agent': videoUserAgent}),
    )).json();
    final info = asObject(outer['video_info']);
    if (intValue(outer['Code']) != 0 ||
        intValue(outer['code']) != 0 ||
        intValue(info['Code']) != 0)
      throw StateError('Fallback 接口拒绝播放请求');
    return selectTrack(asObject(info['data']), quality: quality);
  }

  static PlaybackTrack selectTrack(
    Map<String, dynamic> info, {
    String quality = 'best',
  }) {
    final auto = {'', 'auto', 'best'}.contains(quality);
    final want = intValue(RegExp(r'\d+').firstMatch(quality)?.group(0));
    final rows = asObject(info['video_list']).values
        .map((v) => _Row(asObject(v)))
        .where((r) => r.rank < 2 && (auto || want == 0 || r.shortSide >= want))
        .toList();
    rows.sort((a, b) {
      if (auto) {
        final codec = a.rank.compareTo(b.rank);
        return codec != 0 ? codec : b.pixels.compareTo(a.pixels);
      }
      final size = a.shortSide.compareTo(b.shortSide);
      return size != 0 ? size : a.rank.compareTo(b.rank);
    });
    final seedText = textValue(info['key_seed']);
    final seed = seedText.isEmpty ? null : base64Decode(seedText);
    for (final row in rows) {
      final spade = textValue(
        row.item['spade_a'] ?? asObject(row.item['encrypt_info'])['spade_a'],
      );
      if (spade.isNotEmpty && !Spade.isValidKey(Spade.toKey(spade).key))
        continue;
      final urls = [
        row.item['main_url'],
        row.item['backup_url'],
        ...(row.item['backup_url_list'] as List? ?? []),
      ];
      for (final candidate in urls.whereType<String>().where(
        (s) => s.isNotEmpty,
      )) {
        try {
          final url = checkedUrl(
            seed == null ? candidate : decryptSpadeUrl(candidate, seed),
            mediaDomains,
          );
          return PlaybackTrack(
            url: url,
            spadeA: spade,
            definition: row.definition,
            size: row.size,
          );
        } on FormatException {
          continue;
        }
      }
    }
    throw StateError('本集暂无可解析的 H.264/HEVC 片源（仅支持 spade v1）');
  }
}
