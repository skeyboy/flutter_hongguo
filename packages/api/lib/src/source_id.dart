import 'dart:convert';

import 'catalog.dart';

/// 来源种类。单一定义放在本文件：source_adapter.dart 会 re-export。
/// 放这里而不是放 adapter，是为了让 ID 工具不依赖 core 的 SourceSettings，
/// 避免 media_cache → source_id → source_adapter → core 的环形依赖。
enum SourceKind { builtin, custom }

/// 严格解析结果。[segments] 不含来源前缀；hongguo 没有前缀，段即自身。
class ParsedSourceId {
  final String source;
  final List<String> segments;
  final bool isEpisode;

  const ParsedSourceId({
    required this.source,
    required this.segments,
    required this.isEpisode,
  });
}

// ── 错误分类（契约 §5）────────────────────────────────────────────
// 契约把这三个类写在 source_adapter.dart；这里定义并由该文件 re-export，
// 保证单一定义的同时，让 parseSourceId 抛错不必反向 import adapter。
sealed class SourceException implements Exception {
  const SourceException(this.sourceId, this.message);

  final String sourceId;
  final String message;

  @override
  String toString() => '$runtimeType($sourceId): $message';
}

/// 锁集：当前来源不可播，引导官方平台。不绕过付费/CDN 鉴权。
class SourceLocked extends SourceException {
  const SourceLocked(super.sourceId, super.message);
}

/// 上游不可达 / 超时 / 解析失败。可重试。
class SourceUnavailable extends SourceException {
  const SourceUnavailable(super.sourceId, super.message);
}

/// 参数 / 配置 / ID 非法（含私网 URL、坏 UUID、跨源 ID 不匹配）。不可重试。
class SourceRejected extends SourceException {
  const SourceRejected(super.sourceId, super.message);
}

// ── 来源解析 ──────────────────────────────────────────────────────

const _knownPrefixes = ['xifan', 'hema', 'reelshort', 'dramabox', 'custom'];
final _digits = RegExp(r'^\d{1,30}$');
final _segment = RegExp(r'^[A-Za-z0-9_-]+$');
final _positiveDigits = RegExp(r'^\d+$');
final _channel = RegExp(r'^[A-Za-z0-9_]+$');
final _slug = RegExp(r'^[a-z0-9-]+$');
// RFC 4122 v4：第三段必须以 4 开头，第四段高 2 位为 8/9/a/b。
final _uuidV4 = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

/// 段数表**含来源前缀**计数（契约 §2.2），与 [ParsedSourceId.segments] 不同。
/// hongguo 无前缀，自身算一段。
const _minSeriesSegments = {
  'hongguo': 1,
  'xifan': 3,
  'hema': 2,
  'dramabox': 2,
  'reelshort': 3,
  'custom': 3,
};
const _minEpisodeSegments = {
  'hongguo': 1,
  'xifan': 4,
  'hema': 3,
  'dramabox': 3,
  'reelshort': 5,
  'custom': 5,
};

/// 只靠前缀反推来源；未知前缀/纯数字 → hongguo，永远不抛。
/// 顺序敏感：先判历史纯数字，再逐前缀匹配。
String sourceOf(String id) {
  if (_digits.hasMatch(id)) return 'hongguo';
  for (final prefix in _knownPrefixes) {
    if (id.startsWith('$prefix:')) return prefix;
  }
  return 'hongguo'; // 历史脏数据兜底，由 adapter.matches 精确判定
}

/// 严格解析：段数不足、非法字符、坏 UUID / slug / 渠道号均抛 [SourceRejected]。
ParsedSourceId parseSourceId(String id) {
  final source = sourceOf(id);

  if (source == 'hongguo') {
    if (!_digits.hasMatch(id)) {
      throw const SourceRejected('hongguo', '红果 ID 必须是 1–30 位纯数字');
    }
    return ParsedSourceId(source: source, segments: [id], isEpisode: true);
  }

  final parts = id.split(':');
  final minSeries = _minSeriesSegments[source]!;
  if (parts.length < minSeries) {
    throw SourceRejected(source, 'ID 段数不足（${parts.length} < $minSeries）：$id');
  }
  final segments = parts.skip(1).toList();

  for (final seg in segments) {
    if (!_segment.hasMatch(seg)) {
      throw SourceRejected(source, 'ID 段含非法字符：$seg');
    }
    // 纯数字段必须可解析为正整数；tryParse 同时挡住过长导致的溢出。
    if (_positiveDigits.hasMatch(seg)) {
      final value = int.tryParse(seg);
      if (value == null || value <= 0) {
        throw SourceRejected(source, '数字 ID 段必须为正整数：$seg');
      }
    }
  }

  switch (source) {
    case 'custom':
      if (!_uuidV4.hasMatch(segments[0])) {
        throw SourceRejected(source, '自定义源 UUID 非法：${segments[0]}');
      }
    case 'xifan':
      if (!_channel.hasMatch(segments[0])) {
        throw SourceRejected(source, '西饭渠道号非法：${segments[0]}');
      }
    case 'reelshort':
      // segments 已去掉前缀：bookId=0, slug=1
      if (!_slug.hasMatch(segments[1])) {
        throw SourceRejected(source, 'ReelShort slug 非法：${segments[1]}');
      }
  }

  return ParsedSourceId(
    source: source,
    segments: segments,
    isEpisode: parts.length >= _minEpisodeSegments[source]!,
  );
}

/// 校验 vid 是否属于 sid：同来源 + 剧集段逐段相等。
/// 非法 ID 直接判 false，由调用方决定抛 [SourceRejected]。
bool belongsTo(String vid, String seriesId) {
  late final ParsedSourceId v, s;
  try {
    v = parseSourceId(vid);
    s = parseSourceId(seriesId);
  } on SourceRejected {
    return false;
  }
  if (v.source != s.source) return false;
  // 红果的形态都是纯数字，分集 vid 是独立 ID，不强制与 sid 相等。
  if (s.source == 'hongguo') return true;
  if (v.segments.length < s.segments.length) return false;
  for (var i = 0; i < s.segments.length; i++) {
    if (v.segments[i] != s.segments[i]) return false;
  }
  return true;
}

/// 缓存文件名安全转义。输出字母表严格限定 [A-Za-z0-9_-]：
/// 合法字符原样保留，`_` 本身和所有非 ASCII / 标点按 UTF-8 字节写成 `_XX`。
/// `_` 永不裸出现，因此解码唯一，映射单射，不会像 `_`→`_c_` 那样碰撞。
String mediaKeyEscape(String id) {
  final out = StringBuffer();
  for (final byte in utf8.encode(id)) {
    final upper = byte >= 0x41 && byte <= 0x5A;
    final lower = byte >= 0x61 && byte <= 0x7A;
    final digit = byte >= 0x30 && byte <= 0x39;
    if (upper || lower || digit || byte == 0x2D) {
      out.writeCharCode(byte);
    } else {
      out.write('_');
      out.write(byte.toRadixString(16).padLeft(2, '0'));
    }
  }
  return out.toString();
}

/// 跨源去重键：标题归一 + 集数区间（粗粒度）。来源标签留在 Drama.source，
/// 去重不吞掉来源信息。
String dedupKey(Drama d) => '${_normalizeTitle(d.title)}|${d.episodeCount}';

String _normalizeTitle(String title) {
  final buffer = StringBuffer();
  for (final rune in title.runes) {
    if (rune == 0x3000) {
      buffer.write(' '); // 全角空格 → 半角空格，随后一起去掉
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0); // 全角 ASCII → 半角
    } else {
      buffer.writeCharCode(rune);
    }
  }
  // 去空白 + 大小写不敏感（英文源）；繁简刻意不归一，避免误合并不同剧。
  return buffer.toString().replaceAll(RegExp(r'\s'), '').toLowerCase();
}
