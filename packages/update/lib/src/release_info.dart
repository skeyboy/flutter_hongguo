import 'release_version.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};
String _text(Object? value) => value is String ? value : '';
int? _int(Object? value) => value is int
    ? value
    : value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '');

/// One attachment of a release: what to fetch and what its bytes must hash to.
class ReleaseAsset {
  final String name;
  final int bytes;

  /// Lowercase hex, from the feed's `digest` (`sha256:…`) when GitHub supplies
  /// it. Null means the caller has to fall back to `SHA256SUMS.txt`.
  final String? sha256;
  final String downloadUrl;
  final String contentType;

  const ReleaseAsset({
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.downloadUrl,
    this.contentType = '',
  });

  static ReleaseAsset? fromJson(Object? value) {
    final json = _map(value);
    final name = _text(json['name']);
    final url = _text(json['browser_download_url']);
    if (name.isEmpty || url.isEmpty) return null;
    return ReleaseAsset(
      name: name,
      bytes: _int(json['size']) ?? 0,
      sha256: _digest(json['digest']),
      downloadUrl: url,
      contentType: _text(json['content_type']),
    );
  }

  /// GitHub's `digest` is `sha256:<hex>`; a bare 64-hex is accepted too, so an
  /// older or proxied answer still verifies instead of silently skipping.
  static String? _digest(Object? value) {
    var text = _text(value).trim().toLowerCase();
    if (text.startsWith('sha256:')) text = text.substring(7);
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(text) ? text : null;
  }
}

/// A published release, as far as this app needs to know about it.
class ReleaseInfo {
  final String tag;
  final ReleaseVersion version;
  final String title;

  /// The release note body -- the text the update dialog scrolls through.
  final String notes;
  final bool prerelease;
  final String htmlUrl;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.prerelease,
    required this.htmlUrl,
    required this.publishedAt,
    required this.assets,
  });

  ReleaseAsset? assetNamed(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  /// Throws rather than returning a half-read release: a shape change upstream
  /// must not look like "no update available".
  static ReleaseInfo fromJson(Object? value) {
    final json = _map(value);
    final tag = _text(json['tag_name']);
    final version = ReleaseVersion.tryParse(tag);
    if (version == null) {
      throw const FormatException('发布响应里没有可比较的版本号');
    }
    final published = DateTime.tryParse(_text(json['published_at']));
    return ReleaseInfo(
      tag: tag,
      version: version,
      title: _text(json['name']),
      notes: _text(json['body']),
      prerelease: json['prerelease'] == true,
      htmlUrl: _text(json['html_url']),
      publishedAt: published?.toUtc(),
      assets: [
        for (final entry
            in json['assets'] is List ? json['assets'] as List : const [])
          ?ReleaseAsset.fromJson(entry),
      ],
    );
  }
}

/// Parses the `SHA256SUMS.txt` the release workflow attaches
/// (`tool/ci/release_meta.py` writes `<hex>  <name>` lines).
Map<String, String> parseSha256Sums(String text) {
  final sums = <String, String>{};
  for (final line in text.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final hash = parts.first.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) continue;
    sums[parts.sublist(1).join(' ')] = hash;
  }
  return sums;
}
