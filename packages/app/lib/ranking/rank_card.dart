import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../widgets/drama_cover.dart';

/// One row of one 榜.
///
/// A rank list is not a grid: the thing being communicated is the ordering, and
/// a vertical chain of numbers is the only shape that reads as one (the multi-
/// column grids the discover page uses would put 4 and 5 side by side). So this
/// is 位次 + 封面 + 标题 + the signals upstream sends and `Drama` dropped --
/// 热度、收藏、评分、徽标、题材·集数, each of them hidden when the answer did not
/// carry it.
///
/// `play_cnt` is deliberately not shown anywhere on this card: on the 热播榜 it
/// disagreed with the 热度 sentence by four orders of magnitude (1035 beside
/// 「6182万热度」), and one card may state one 热度.
class RankCard extends StatelessWidget {
  final RankEntry entry;
  final VoidCallback onTap;
  final ImageProvider? coverImage;
  final bool allowNetworkCover;
  const RankCard({
    super.key,
    required this.entry,
    required this.onTap,
    this.coverImage,
    this.allowNetworkCover = true,
  });

  /// 1–3 carry the weight a rank list is expected to have; below that the number
  /// is enough on its own, and a medal for 第十一名 would be decoration.
  static const _medal = {
    1: Color(0xffc8a45c),
    2: Color(0xffa8adb8),
    3: Color(0xffb5764a),
  };

  @override
  Widget build(BuildContext context) {
    final drama = entry.drama;
    final scheme = Theme.of(context).colorScheme;
    final medal = _medal[entry.position];
    final tint = _parseColor(entry.dominateColor);
    final lines = <Widget>[
      Text(
        drama.title.isEmpty ? '未命名短剧' : drama.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      _MetaRow(entry: entry),
    ];
    if (drama.intro.isNotEmpty) {
      lines.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            drama.intro,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return InkWell(
      key: ValueKey('rank-card-${drama.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        // 占位主色, which upstream measured off the cover: a tint behind the row
        // is the least it can be used for without inventing artwork.
        color: tint?.withValues(
          alpha:
              0.06 *
              (Theme.of(context).brightness == Brightness.dark ? 1.6 : 1),
        ),
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: Column(
                children: [
                  Container(
                    key: ValueKey('rank-position-${entry.position}'),
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: medal ?? scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(
                        medal == null ? 8 : 16,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${entry.position}',
                      style: TextStyle(
                        fontSize: medal == null ? 15 : 17,
                        fontWeight: FontWeight.w700,
                        color: medal == null
                            ? scheme.onSurfaceVariant
                            : Colors.white,
                      ),
                    ),
                  ),
                  // 趋势 has a field upstream sends (`rec_arrow_type`) but every
                  // card in four samples carried the same value, so its meaning is
                  // unproven: the slot is drawn as a placeholder, never as a fake
                  // arrow.
                  const SizedBox(height: 6),
                  const _TrendPlaceholder(),
                ],
              ),
            ),
            SizedBox(
              width: 62,
              height: 82,
              child: DramaCover(
                drama: drama,
                imageProvider: coverImage,
                allowNetwork: allowNetworkCover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: lines,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 评分 · 徽标 · 题材集数 · 热度 · 收藏, in that order, each only when the answer
/// carried it. The strings are upstream's own wording, so no number here is a
/// front-end calculation.
class _MetaRow extends StatelessWidget {
  final RankEntry entry;
  const _MetaRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <Widget>[];
    void add(String text, {Color? color, bool badge = false}) {
      parts.add(
        Container(
          padding: badge
              ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
              : null,
          decoration: badge
              ? BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(4),
                )
              : null,
          child: Text(
            text,
            style: TextStyle(
              fontSize: badge ? 11 : 12,
              fontWeight: badge ? FontWeight.w600 : FontWeight.w400,
              color: badge
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    if (entry.badge != null) add(entry.badge!, badge: true);
    if (entry.score != null) add('评分 ${entry.score}');
    if (entry.subtitle != null) add(entry.subtitle!);
    if (entry.heat != null) add(entry.heat!);
    if (entry.collect != null) add(entry.collect!);
    if (parts.isEmpty) {
      return Text(
        entry.drama.episodeCount > 0 ? '全 ${entry.drama.episodeCount} 集' : '',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      );
    }
    return Wrap(
      key: ValueKey('rank-meta-${entry.drama.id}'),
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: parts,
    );
  }
}

class _TrendPlaceholder extends StatelessWidget {
  const _TrendPlaceholder();
  @override
  Widget build(BuildContext context) => Tooltip(
    message: '趋势：上游有这一位（rec_arrow_type），四次取样全为 0，语义未证实',
    child: Container(
      key: const ValueKey('rank-trend-unknown'),
      width: 22,
      height: 14,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: Theme.of(context).dividerColor, width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        '—',
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

Color? _parseColor(String? value) {
  final text = value ?? '';
  final match = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').firstMatch(text);
  if (match == null) return null;
  final digits = match.group(1)!;
  final rgb = int.tryParse(digits.substring(digits.length - 6), radix: 16);
  if (rgb == null) return null;
  final alpha = digits.length == 8
      ? (int.tryParse(digits.substring(0, 2), radix: 16) ?? 255) / 255
      : 1.0;
  return Color(rgb | 0xff000000).withValues(alpha: alpha);
}
