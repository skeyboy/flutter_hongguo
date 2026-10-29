/// The release identity as the repository tags it, with the comparison rule the
/// update prompt rests on.
class ReleaseVersion {
  /// The dotted numbers before any `+build`, already parsed.
  final List<int> numbers;

  /// The `+build` half, kept for display; two builds of one tag are the same
  /// release, so [compareTo] ignores it on purpose -- otherwise a re-published
  /// tag would nag every user a second time.
  final int? build;

  /// What the feed actually said, e.g. `v0.3.13`.
  final String tag;

  const ReleaseVersion({required this.numbers, this.build, this.tag = ''});

  /// `0.3.13`, `v0.3.13` and `0.3.13+25` all parse. Unparseable segments count
  /// as zero so a stray suffix cannot make an older release look newer.
  static ReleaseVersion? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final head = trimmed.startsWith('v') || trimmed.startsWith('V')
        ? trimmed.substring(1)
        : trimmed;
    final parts = head.split('+');
    final numbers = <int>[];
    for (final raw in parts.first.split('.')) {
      final digits = raw.split(RegExp(r'[^0-9]')).first;
      if (digits.isEmpty) return null;
      numbers.add(int.tryParse(digits) ?? 0);
    }
    if (numbers.isEmpty) return null;
    return ReleaseVersion(
      numbers: List.unmodifiable(numbers),
      build: parts.length > 1 ? int.tryParse(parts[1].trim()) : null,
      tag: trimmed,
    );
  }

  /// Three-segment comparison, padded with zeros: `0.3.14` beats `0.3.13`,
  /// and `0.4` beats `0.3.9`.
  int compareTo(ReleaseVersion other) {
    final length = numbers.length > other.numbers.length
        ? numbers.length
        : other.numbers.length;
    for (var i = 0; i < length; i++) {
      final left = i < numbers.length ? numbers[i] : 0;
      final right = i < other.numbers.length ? other.numbers[i] : 0;
      if (left != right) return left < right ? -1 : 1;
    }
    return 0;
  }

  bool isNewerThan(ReleaseVersion other) => compareTo(other) > 0;

  /// `0.3.13`, for the release whose assets are named `Hongguo-0.3.13-…`.
  String get versionText => numbers.join('.');

  @override
  String toString() => tag.isNotEmpty ? tag : numbers.join('.');
}
