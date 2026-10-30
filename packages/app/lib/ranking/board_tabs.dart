import 'package:flutter/material.dart';

/// One selectable row of the 榜单 module: the 赛道 row and the 榜 row are the same
/// shape -- a short list of names, one of them current -- and both are built from
/// what upstream published in the last answer, never from a list pinned here.
///
/// The two input families get two different overflow rules, because the gesture
/// they have is different: a finger slides a row that does not fit, a mouse does
/// not (dragging a list sideways with a pointer is the thing the desktop build
/// already refuses to do for paging), so the desktop row stops at [overflowAfter]
/// and puts the remainder in 更多 ▾.
class RankSelectorRow extends StatelessWidget {
  final String label;

  /// `(id, label)` in the order upstream published them.
  final List<({String id, String label})> items;
  final String? selectedId;
  final ValueChanged<String> onPick;

  /// Every key on this row is namespaced by it, so a test and a live fixture can
  /// name one chip without also naming the other row's.
  final String keyPrefix;
  final bool scrollable;
  final int? overflowAfter;
  const RankSelectorRow({
    super.key,
    required this.label,
    required this.items,
    required this.selectedId,
    required this.onPick,
    required this.keyPrefix,
    this.scrollable = true,
    this.overflowAfter,
  });

  @override
  Widget build(BuildContext context) {
    // The limit is where the row stops, not a number of chips it owes: a 赛道
    // tree with three items in it has no tail, and 更多 ▾（0）is not a thing.
    final limit = (overflowAfter ?? items.length).clamp(0, items.length);
    final head = items.sublist(0, limit);
    final tail = items.length <= limit
        ? const <({String id, String label})>[]
        : items.sublist(limit);

    final chips = <Widget>[
      for (final item in head)
        _Choice(
          key: ValueKey('$keyPrefix-${item.id}'),
          label: item.label,
          selected: item.id == selectedId,
          onTap: () => onPick(item.id),
        ),
      if (tail.isNotEmpty)
        _MoreChoices(
          key: ValueKey('$keyPrefix-more'),
          label: '更多 ▾（${tail.length}）',
          items: tail,
          onPick: onPick,
        ),
    ];
    final row = Row(mainAxisSize: MainAxisSize.min, children: chips);
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: scrollable
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: row,
                    )
                  : row,
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        fontSize: 14,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
      visualDensity: VisualDensity.compact,
    ),
  );
}

class _MoreChoices extends StatelessWidget {
  final String label;
  final List<({String id, String label})> items;
  final ValueChanged<String> onPick;
  const _MoreChoices({
    super.key,
    required this.label,
    required this.items,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
    child: PopupMenuButton<String>(
      key: const ValueKey('rank-selector-more'),
      tooltip: label,
      onSelected: onPick,
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem(value: item.id, child: Text(item.label)),
      ],
      child: Chip(
        label: Text(label),
        visualDensity: VisualDensity.compact,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    ),
  );
}
