/// 官网（hongguoduanju.com）协议解析与直链提取。
///
/// 移植自 hongguo-drama 8.0（GPL-3.0，来源链见 NOTICE.md）：
/// `src/native/hongguo.js`（官网层）、`src/native/catalog.js`（readRouterData）、
/// `src/native/hongguo-search.js`（JSON 搜索）。策略与参考一致：官网网页版
/// 优先，页面里的数据全部免签；任何字段改名都必须「解析失败可识别」，调用方
/// 据此回退，不得把解析失败当空结果吞掉。
library;

import 'dart:convert';

import 'package:hongguo_core/hongguo_core.dart';

/// 官网根。
const siteOrigin = 'https://hongguoduanju.com';

/// 官网请求的桌面 UA 与 Referer。
const webUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
const webReferer = '$siteOrigin/';

/// 官网公开兜底取址接口（player 页同款，免签 POST，`{item_id: vid}`）。
const publicFallbackPlayPath = '/api/video/protected/fallback-play-info';

/// 官网搜索 JSON 接口（搜索页前端自己的数据源，免签 GET）。
const searchResultPath = '/api/search/result';

/// 官网 CDN 白名单（web-media-guard.js 的域名族，官方片源只落在这些域上）。
///
/// 与下载层共用 [webMediaDomains]：这里放行的域，`MediaUrlDecoder.checked`
/// 必须同样放行，否则取到的直链会在下载前被判非法。
bool _allowedHost(String host) => webMediaDomains.any(
  (domain) => host == domain || host.toLowerCase().endsWith('.$domain'),
);

/// MP4 直链归一：去 HTML/JSON 转义并剥掉 Range 参数，让 CDN 回整段。
String normalizeVideoUrl(String raw) {
  var value = raw
      .replaceAll(r'\u002F', '/')
      .replaceAll(r'\u0026', '&')
      .replaceAll(r'\/', '/')
      .replaceAll('&amp;', '&');
  value = value.replaceAllMapped(
    RegExp(r'([?&])Range=[^&]*', caseSensitive: false),
    (m) => m.group(1)!,
  );
  // 剥掉首参 Range 后可能残留 `?&`，收敛成 `?`。
  value = value.replaceFirst('?&', '?');
  while (value.endsWith('?') || value.endsWith('&')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// 官网 CDN 白名单校验：仅 HTTPS、无凭据，域命中白名单。
bool isPublicMediaUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return false;
  }
  return _allowedHost(uri.host.toLowerCase());
}

/// 从 SSR 页面提取 `_ROUTER_DATA` JSON（花括号配平，容忍转义字符串）。
/// 没有该数据时返回 null，由调用方回退到旧的正则解析。
Map<String, dynamic>? readRouterData(String html) {
  final match = RegExp(r'(?:window\.)?_ROUTER_DATA\s*=\s*\{').firstMatch(html);
  if (match == null) return null;
  final start = match.end - 1;
  var depth = 0, quoted = false, escaped = false;
  for (var i = start; i < html.length; i++) {
    final char = html[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
    } else if (char == '"') {
      quoted = true;
    } else if (char == '{') {
      depth++;
    } else if (char == '}') {
      if (--depth == 0) {
        try {
          final value = jsonDecode(html.substring(start, i + 1));
          return value is Map ? Map<String, dynamic>.from(value) : null;
        } on FormatException {
          return null;
        }
      }
    }
  }
  return null;
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<dynamic> _list(Object? value) => value is List ? value : const [];
String _text(Object? value) => value == null ? '' : '$value';

/// player/detail 页解析出的分集列表。
class WebEpisodeList {
  final String seriesId, seriesTitle, cover;
  final List<String> vids;

  /// 官网限免展示的前缀长度；null 表示页面未给（不代表全集可播）。
  final int? accessibleEpisodes;
  const WebEpisodeList({
    required this.seriesId,
    required this.seriesTitle,
    required this.cover,
    required this.vids,
    required this.accessibleEpisodes,
  });
}

/// 从 player 或 detail 页的 `_ROUTER_DATA` 里读完整分集列表。
///
/// 身份校验与参考一致：series_id 必须与请求一致且为数字、vid 全为数字且
/// 不重复；recommendations 区块永不作为数据源。解析不出 router 数据、
/// 数据不完整或身份不符都返回 null（调用方换下一路）。
WebEpisodeList? parseEpisodeListHtml(String html, String seriesId) {
  final router = readRouterData(html);
  if (router == null) return null;
  final loader = _map(router['loaderData']);
  Map<String, dynamic>? data;
  for (final key in [
    'player_(series_id)/page',
    'player_(series_id)/(vid)/page',
    'detail_page',
  ]) {
    final candidate = _map(loader[key]);
    if (candidate.isNotEmpty) {
      data = candidate;
      break;
    }
  }
  if (data == null || data['isSuccess'] == false) return null;
  final detail = _map(data['seriesDetail']);
  final actualSid = _text(detail['series_id']);
  if (!RegExp(r'^\d{1,30}$').hasMatch(actualSid) || actualSid != seriesId) {
    return null;
  }
  if (data['series_id'] != null && _text(data['series_id']) != seriesId) {
    return null;
  }
  final vids = _list(detail['vid_list']).map(_text).toList();
  if (vids.isEmpty ||
      vids.any((vid) => !RegExp(r'^\d{1,30}$').hasMatch(vid)) ||
      vids.toSet().length != vids.length) {
    return null;
  }
  final accessibleText = _text(detail['accessible_episode_cnt']);
  final accessible = RegExp(r'^\d+$').hasMatch(accessibleText)
      ? // 限免展示数不会超过真实分集数。
        min(int.parse(accessibleText), vids.length)
      : null;
  return WebEpisodeList(
    seriesId: actualSid,
    seriesTitle: detail['series_name'] is String
        ? detail['series_name'] as String
        : '',
    cover: detail['series_cover'] is String
        ? detail['series_cover'] as String
        : '',
    vids: vids,
    accessibleEpisodes: accessible,
  );
}

/// 官网页里与当前分集绑定的明文 MP4 直链（无 CENC，不需要 spade/解密）。
class WebPlayUrl {
  final String url;
  final String quality;
  final int width, height;
  const WebPlayUrl({
    required this.url,
    this.quality = '',
    this.width = 0,
    this.height = 0,
  });
}

/// `player` 页能否作为这一集的直链来源：返回页面自己确认的 series_id。
///
/// 官方对未公开分集只挂一段 SEO 预览片（元数据时长对得上，内容只有开头），
/// 所以 `publicVideoSeo.available`、`protectedPlayback`、`vid` 与两处
/// series_id 必须逐项核对；任一不满足返回 null，让调用方换下一路，而不是
/// 悄悄播一段几十秒的预告。
String? playablePageSeries(String html, String vid) {
  final router = readRouterData(html);
  if (router == null) return null;
  final loader = _map(router['loaderData']);
  Map<String, dynamic>? data;
  for (final key in [
    'player_(series_id)/(vid)/page',
    'player_(series_id)/page',
  ]) {
    final candidate = _map(loader[key]);
    if (candidate.isNotEmpty) {
      data = candidate;
      break;
    }
  }
  if (data == null || data['isSuccess'] == false) return null;
  final sid = _text(_map(data['seriesDetail'])['series_id']);
  if (!RegExp(r'^\d{1,30}$').hasMatch(sid)) return null;
  if (data['series_id'] != null && _text(data['series_id']) != sid) return null;
  if (_text(data['vid']) != vid) return null;
  if (data['protectedPlayback'] == true) return null;
  final seo = _map(data['publicVideoSeo']);
  if (seo['available'] != true) return null;
  if (_text(seo['itemId']) != vid || _text(seo['seriesId']) != sid) return null;
  return sid;
}

/// 官网播放页 ld+json `VideoObject.contentUrl` 提取。
///
/// 与参考一致的三道绑定校验：media 的 `url`/`@id` 必须指向当前
/// `/player/{sid}/{vid}` 页（或 `/player/{sid}` 且路径含 `/video/public/{vid}/`），
/// contentUrl 域必须命中 CDN 白名单。任一不符返回 null。
String? extractLdJsonPlayUrl(String html, String seriesId, String vid) {
  final playerPattern = RegExp(
    r'/player/' +
        RegExp.escape(seriesId) +
        r'(?:/' +
        RegExp.escape(vid) +
        r')?$',
  );
  for (final script in RegExp(
    r'<script\b([^>]*)>([\s\S]*?)<\/script\s*>',
    caseSensitive: false,
  ).allMatches(html)) {
    final attrs = script.group(1) ?? '';
    if (!RegExp(
      r'''type\s*=\s*["']application/ld\+json["']''',
      caseSensitive: false,
    ).hasMatch(attrs)) {
      continue;
    }
    Object? video;
    try {
      video = jsonDecode(script.group(2) ?? '');
    } on FormatException {
      continue;
    }
    final data = _map(video);
    if (_text(data['@type']) != 'VideoObject') continue;
    final rawUrl = normalizeVideoUrl(_text(data['contentUrl']));
    final media = Uri.tryParse(rawUrl);
    if (media == null || !isPublicMediaUrl(rawUrl)) continue;
    // 绑定校验：绝不取页面里推荐位视频的地址。
    bool matchesPlayer(String value) {
      final target = Uri.tryParse(value);
      if (target == null ||
          target.origin != siteOrigin ||
          target.userInfo.isNotEmpty) {
        return false;
      }
      return playerPattern.hasMatch(target.path) ||
          (target.path == '/player/$seriesId' &&
              media.origin == siteOrigin &&
              media.path.startsWith('/video/public/$vid/'));
    }

    if (!matchesPlayer(_text(data['url']))) continue;
    if (_text(data['@id']).isNotEmpty && !matchesPlayer(_text(data['@id']))) {
      continue;
    }
    return rawUrl;
  }
  return null;
}

/// 官网公开兜底接口（`/api/video/protected/fallback-play-info`）响应解析。
///
/// `nowMillis` 用于过期检查：`url_expire` 在 5 秒余量内到期的地址直接拒绝。
/// 业务码非 0、缺 `main_url`、域不在白名单或已过期都返回 null。
WebPlayUrl? parsePublicFallbackPlayUrl(
  Map<String, dynamic> payload, {
  required int nowMillis,
}) {
  final base = _map(payload['base_resp']);
  final code = base['StatusCode'] ?? payload['code'] ?? 0;
  if ((num.tryParse(_text(code)) ?? 0) != 0) return null;
  final raw = normalizeVideoUrl(_text(payload['main_url']));
  if (raw.isEmpty || !isPublicMediaUrl(raw)) return null;
  final host = Uri.tryParse(raw)?.host.toLowerCase() ?? '';
  // 兜底接口只会回签名 CDN 的地址，用窄表；宽表留给页面 ld+json 那一路。
  if (!appMediaDomains.any(
    (domain) => host == domain || host.endsWith('.$domain'),
  )) {
    return null;
  }
  final expires = num.tryParse(_text(payload['url_expire']));
  if (expires != null && expires > 0 && expires * 1000 <= nowMillis + 5000) {
    return null;
  }
  return WebPlayUrl(url: raw, quality: '360p', width: 360, height: 640);
}

/// 官网搜索 JSON 响应 → `Drama.fromJson` 可消费的条目（字段归一到上游键名）。
///
/// 结构与 hongguo-search.js `parseSearchResponse` 一致：`searchList` 缺失、
/// 条目全不可识别（非空列表但零产出）都会抛出，调用方以此识别「字段改名」
/// 并回退 SSR，而不是把解析失败当「没有结果」。
List<Map<String, dynamic>> searchListFromJson(Object? payload) {
  if (payload is! Map) {
    throw const FormatException('搜索返回异常数据');
  }
  final data = Map<String, dynamic>.from(payload);
  if (data['code'] is String) {
    throw FormatException('搜索服务暂不可用（${_text(data['message'])}）');
  }
  if (data['searchList'] is! List) {
    throw const FormatException('搜索返回异常数据');
  }
  final results = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final item in _list(data['searchList'])) {
    final entry = _map(item);
    final videoData = _map(entry['video_data']);
    final video = videoData.isNotEmpty ? videoData : entry;
    final seriesId = _text(
      video['series_id'] ?? entry['series_id'] ?? entry['keyword'],
    ).trim();
    final title = _cleanText(
      _text(video['series_name'] ?? video['series_title'] ?? entry['name']),
    );
    if (!RegExp(r'^\d{6,}$').hasMatch(seriesId) ||
        title.isEmpty ||
        seen.contains(seriesId)) {
      continue;
    }
    seen.add(seriesId);
    final cover = _safeCover(_text(video['series_cover'] ?? video['cover']));
    final tags = _tagTexts(video);
    results.add({
      'series_id': seriesId,
      'series_title': title,
      if (cover.isNotEmpty) 'series_cover': cover,
      if (_cleanText(_text(video['series_intro'])).isNotEmpty)
        'series_intro': _cleanText(_text(video['series_intro'])),
      'episode_cnt': _episodeCount(video, entry),
      if (tags.isNotEmpty) 'tag_info': {'text': tags.join('·')},
    });
  }
  if (results.isEmpty && _list(data['searchList']).isNotEmpty) {
    throw const FormatException('搜索返回的条目无法识别');
  }
  return results;
}

/// 搜索 JSON 是否还有下一页。
///
/// 参考实现以 `hasMore` 为准，`totalPages` 只作旧字段兜底：有 `hasMore`
/// 就不再拿总数推算（上游对越界页仍会回 200，只是列表为空）。
bool searchHasMore(Object? payload) {
  final data = _map(payload);
  final flag = data['hasMore'] ?? data['has_more'];
  if (flag == true || flag == 1 || flag == 'true') return true;
  if (flag == false || flag == 0 || flag == 'false') return false;
  final page = num.tryParse(_text(data['pageNum']));
  final pages = num.tryParse(_text(data['totalPages']));
  return page != null && pages != null && pages > page;
}

/// `tags`/`category_list`（字符串或 `{name}` 混合）→ 最多 4 个去重标签。
List<String> _tagTexts(Map<String, dynamic> video) {
  final tags = <String>[];
  for (final source in [
    ..._list(video['tags']),
    ..._list(video['category_list']),
  ]) {
    final label = source is String
        ? source
        : _map(source)['name'] ?? _map(source)['tag_name'];
    final text = _cleanText(_text(label));
    if (text.isNotEmpty && !tags.contains(text)) tags.add(text);
    if (tags.length >= 4) break;
  }
  return tags;
}

/// 集数优先 `episode_cnt`，缺失时从「共 N 集」文案回推。
int _episodeCount(Map<String, dynamic> video, Map<String, dynamic> entry) {
  final count = num.tryParse(
    _text(video['episode_cnt'] ?? entry['episode_cnt']),
  );
  if (count != null && count > 0) return count.toInt();
  final right = _text(
    video['episode_right_text'] ?? entry['episode_right_text'],
  );
  return int.tryParse(RegExp(r'(\d+)\s*集').firstMatch(right)?.group(1) ?? '') ??
      0;
}

String _cleanText(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'")
    .replaceAll('&amp;', '&')
    .trim();

String _safeCover(String value) {
  final url = value
      .replaceAll(r'\u002F', '/')
      .replaceAll(r'\/', '/')
      .replaceAll(r'\u0026', '&')
      .replaceAll('&amp;', '&');
  return RegExp(r'^https?://', caseSensitive: false).hasMatch(url) ? url : '';
}

// `min` 来自 dart:math；本文件避免引入其它依赖。
int min(int a, int b) => a < b ? a : b;
