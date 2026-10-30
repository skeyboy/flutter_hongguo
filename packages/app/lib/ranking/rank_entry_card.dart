import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

/// 发现页's way into 榜单, beside the destination itself.
///
/// The main products keep two entrances (Netflix puts a Top 10 strip on the home
/// page as well as a list of its own), because promoting 榜单 to a destination
/// makes the entrance deeper than the chip it replaced. This is the strip that
/// pays that back on the touch family, where a bottom bar already carries four
/// destinations and one more tap is the difference between seeing a board and
/// hunting for it.
///
/// What it borrows is content only: the position comes from the same array index
/// the board itself ranks by, and the number is `rec_text_item` verbatim -- the
/// one 热度 the app is allowed to state (§8.5). What it deliberately does not carry
/// is any of the discover page's own levels: `rankBoard` takes neither 类型 nor
/// 题材, so tapping this switches the destination and changes nothing else.
class RankEntryCard extends StatelessWidget {
  const RankEntryCard({
    super.key,
    required this.title,
    required this.entries,
    required this.onOpen,
  });

  /// Which 榜 these rows are from, in upstream's own names (`漫剧 · 热播榜`).
  final String title;
  final List<RankEntry> entries;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = entries.take(3).toList();
    if (top.isEmpty) return const SizedBox.shrink();
    return Padding(
      // Only the rhythm above and below: the page owns the gutter, the same way
      // the section title's sliver does, so the card's edge lines up with the
      // grid's instead of sitting 12 points further in.
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: const ValueKey('rank-entry-card'),
          borderRadius: BorderRadius.circular(12),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.emoji_events_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 前 3 名横滚: a 390-point row has no room for three numbers and
                // the name that owns them, and the design's answer is a strip the
                // finger can keep pulling on rather than text that gets cut.
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final entry in top)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _Place(entry: entry, label: title),
                          ),
                      ],
                    ),
                  ),
                ),
                // 入口自己做自己那枚手指的目标：整张卡已经点得开，但「全部榜单 ›」
                // 是原型写出来的那个动作，它要单独接得住一次点击，而不是只在卡上
                // 借一个位置。
                InkWell(
                  key: const ValueKey('rank-entry-more'),
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Text(
                      '全部榜单 ›',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 位次 + 热度, which are the two things this strip is allowed to claim. The
/// drama's own name stays on the board page: three of them plus their numbers
/// will not fit a 390-point row, and cutting them mid-word tells the viewer
/// nothing the number does not.
class _Place extends StatelessWidget {
  const _Place({required this.entry, required this.label});

  final RankEntry entry;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final heat = entry.heat;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        heat == null
            ? '${entry.position + 1}.'
            : '${entry.position + 1}. $heat',
        key: ValueKey('rank-entry-heat-${entry.position}'),
        semanticsLabel: label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}
