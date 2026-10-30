import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

/// L3 排序, in the shape the mouse family uses: one control that says which 档
/// is in force, and a menu of exactly the three values upstream accepts.
///
/// Hover opens it (120ms -- any faster and it flickers under a pointer that is
/// simply crossing the row) and leaving closes it (300ms, cancelled by moving
/// into the menu), but a click always opens it too: a touchscreen driven as a
/// mouse has no hover at all, and a control only reachable by hovering is a
/// control that cannot be used.
///
/// Changing the 档 asks for the same page with a different `select_items.sort`.
/// It does not turn a page and does not move the list -- see `_reQuery` in
/// `features/library_page.dart`.
class SortMenu extends StatefulWidget {
  const SortMenu({
    super.key,
    required this.selected,
    required this.onPick,
    this.onOpenChanged,
    this.focusNode,
  });

  /// The sort actually in force, whether it came from this control or from 设置.
  final String selected;
  final ValueChanged<String> onPick;

  /// Lets the page own `O` and `Esc` without reaching into this widget's state:
  /// the single key toggles, and a toggle needs to know what is open.
  final ValueChanged<bool>? onOpenChanged;

  /// The chip's node, handed in by the page so 「Esc 把焦点还给触发它的控件」有一处
  /// 可还：菜单里的焦点是借来的，还开着的层就是一次还没还的借。
  final FocusNode? focusNode;

  @override
  State<SortMenu> createState() => SortMenuState();
}

class SortMenuState extends State<SortMenu> {
  static const _hoverIn = Duration(milliseconds: 120);
  static const _hoverOut = Duration(milliseconds: 300);

  final MenuController _menu = MenuController();
  Timer? _timer;
  bool _shown = false;

  /// Whether this dropdown is the layer currently on screen -- which is what the
  /// page needs before it decides an `Esc` has something to close.
  bool get isOpen => _menu.isOpen;

  void _tell(bool value) {
    if (_shown == value) return;
    _shown = value;
    widget.onOpenChanged?.call(value);
  }

  void _schedule(VoidCallback action, Duration wait) {
    _timer?.cancel();
    _timer = Timer(wait, action);
  }

  void open() {
    _timer?.cancel();
    if (mounted) _menu.open();
  }

  void close() {
    _timer?.cancel();
    _menu.close();
  }

  void toggle() => _menu.isOpen ? close() : open();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _schedule(open, _hoverIn),
    // Crossing the gap between the chip and the menu is not a decision to close
    // it: entering the menu (below) cancels this, and the menu's own scrim
    // answers a pointer that really did leave.
    onExit: (_) => _schedule(close, _hoverOut),
    child: MenuAnchor(
      controller: _menu,
      onOpen: () => _tell(true),
      onClose: () => _tell(false),
      menuChildren: [
        MouseRegion(
          onEnter: (_) => _timer?.cancel(),
          onExit: (_) => _schedule(close, _hoverOut),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final key in catalogSortKeys)
                MenuItemButton(
                  key: ValueKey('sort-$key'),
                  onPressed: () => widget.onPick(key),
                  leadingIcon: key == widget.selected
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  child: Text(catalogSortLabels[key] ?? key),
                ),
            ],
          ),
        ),
      ],
      builder: (context, controller, child) => TextButton(
        key: const ValueKey('sort-menu'),
        focusNode: widget.focusNode,
        onPressed: toggle,
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          backgroundColor: _shown
              ? Theme.of(context).colorScheme.secondaryContainer
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '排序 · ${catalogSortLabels[widget.selected] ?? widget.selected}',
              style: const TextStyle(fontSize: 13),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    ),
  );
}

/// L3 排序, in the shape the touch family uses: the same three 档 from the same
/// upstream row, arriving as a bottom sheet instead of a dropdown.
///
/// A menu anchored to the tail chip of a 390-point screen has no room to open
/// into, and the row it sits in is 52 points tall -- so this family gets the
/// sheet the design draws. [SortMenu]'s hover timings have no counterpart here:
/// a finger has no hover, and the chip is pressed exactly like every other chip
/// in the row.
///
/// Picking a 档 closes the sheet, which is the opposite of 更多筛选's drawer: this
/// is one question with one answer, and what §6.1.4 promises is that the list
/// changes while the page and its scroll position do not.
class SortSheet extends StatelessWidget {
  const SortSheet({
    super.key,
    required this.selected,
    required this.onPick,
    this.onDismiss,
  });

  /// The sort actually in force, whether it came from here or from 设置.
  final String selected;
  final ValueChanged<String> onPick;

  /// The way out that is not an answer: the design's sheet header repeats 收起
  /// because a finger that opened the sheet to look has to be able to stop
  /// looking without hitting a 档. Null falls back to popping the route.
  final VoidCallback? onDismiss;

  /// The sheet as the page opens it: the route is popped on the way out so that
  /// the list change is not stacked behind a layer nobody asked to keep.
  static Future<void> show(
    BuildContext context, {
    required String selected,
    required ValueChanged<String> onPick,
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => SortSheet(
      selected: selected,
      onDismiss: () => Navigator.of(sheetContext).pop(),
      onPick: (value) {
        Navigator.of(sheetContext).pop();
        onPick(value);
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        key: const ValueKey('sort-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '排序',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '只改请求，不换页',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey('sort-sheet-dismiss'),
                onPressed: onDismiss ?? () => Navigator.of(context).pop(),
                child: const Text('收起'),
              ),
            ],
          ),
          for (final key in catalogSortKeys)
            InkWell(
              key: ValueKey('sort-$key'),
              onTap: () => onPick(key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        catalogSortLabels[key] ?? key,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: key == selected
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: key == selected
                              ? scheme.primary
                              : scheme.onSurface,
                        ),
                      ),
                    ),
                    if (key == selected)
                      Icon(Icons.check, size: 18, color: scheme.primary),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              '三档就是上游全部：没有「推荐」，也没有「追剧」。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
