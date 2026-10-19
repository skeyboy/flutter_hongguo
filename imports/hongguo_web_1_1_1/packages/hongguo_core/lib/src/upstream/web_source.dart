// Ported from the corresponding hongguo-web JS module; see root THIRD_PARTY_NOTICES.md.
import 'dart:convert';
import '../models/models.dart';
import '../ports/transport.dart';
import 'url_codec.dart';

class WebSource {
  final Transport transport;
  WebSource(this.transport);
  Future<String> _html(String path) async {
    final response = await transport.send(
      TransportRequest(
        Uri.parse('https://hongguoduanju.com$path'),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/122.0.0.0 Safari/537.36',
          'Accept': 'text/html',
          'Accept-Language': 'zh-CN,zh;q=0.9',
          'Referer': 'https://hongguoduanju.com/',
        },
      ),
    );
    if (response.status != 200) throw StateError('官网 HTTP ${response.status}');
    return response.text;
  }

  static dynamic embedded(String html, String key) {
    final match = RegExp('"${RegExp.escape(key)}"\\s*:\\s*').firstMatch(html);
    if (match == null) return null;
    final start = match.end;
    if (start >= html.length) return null;
    var inString = false, escape = false, depth = 0;
    final first = html[start];
    if (first != '[' && first != '{' && first != '"') {
      final scalar = RegExp(
        r'^(?:\d+|true|false|null)',
      ).firstMatch(html.substring(start));
      return scalar == null ? null : jsonDecode(scalar.group(0)!);
    }
    for (var i = start; i < html.length; i++) {
      final c = html[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (inString) {
        if (c == r'\') {
          escape = true;
        } else if (c == '"') {
          inString = false;
          if (first == '"' && depth == 0)
            return jsonDecode(html.substring(start, i + 1));
        }
        continue;
      }
      if (c == '"') {
        inString = true;
        continue;
      }
      if (c == '[' || c == '{') depth++;
      if (c == ']' || c == '}') {
        depth--;
        if (depth == 0) return jsonDecode(html.substring(start, i + 1));
      }
    }
    throw FormatException('Truncated embedded JSON: $key');
  }

  Future<List<Series>> search(String query) async {
    final html = await _html('/search/${encodeQueryComponent(query.trim())}');
    final list = embedded(html, 'searchList');
    if (list is! List) return [];
    return [
      for (final item in list)
        Series.fromJson(asObject(asObject(item)['video_data'] ?? item)),
    ].where((s) => s.id.isNotEmpty).toList();
  }

  Future<SeriesDetail> detail(String sid) async {
    final html = await _html('/player/${encodeQueryComponent(sid)}');
    final vids = embedded(html, 'vid_list');
    if (vids is! List || vids.isEmpty) throw StateError('官网未提供分集列表');
    return SeriesDetail(
      Series(
        id: sid,
        title: textValue(embedded(html, 'series_name')),
        cover: textValue(embedded(html, 'series_cover')),
        episodeCount: vids.length,
      ),
      [
        for (var i = 0; i < vids.length; i++)
          Episode(vid: textValue(vids[i]), index: i + 1),
      ],
    );
  }
}
