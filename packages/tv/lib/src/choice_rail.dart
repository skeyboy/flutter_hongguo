import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'focusable.dart';
import 'pane_boundary.dart';

class TvChoice {
  final String id, label;
  const TvChoice(this.id, this.label);
}

/// All choices stay mounted, so remote navigation can reach every label.
/// Focus selects; the host owns request debouncing and stale response rejection.
class TvChoiceRail extends StatefulWidget {
  final List<TvChoice> choices;
  final String selected;
  final ValueChanged<String> onSelected;
  final FocusNode? trailingFocusNode, lastChoiceFocusNode;
  const TvChoiceRail({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelected,
    this.trailingFocusNode,
    this.lastChoiceFocusNode,
  });
  @override
  State<TvChoiceRail> createState() => _TvChoiceRailState();
}

class _TvChoiceRailState extends State<TvChoiceRail> {
  final scroll = ScrollController();
  final nodes = <String, FocusNode>{};
  FocusNode node(String id) =>
      id == widget.choices.lastOrNull?.id && widget.lastChoiceFocusNode != null
      ? widget.lastChoiceFocusNode!
      : nodes.putIfAbsent(id, () => FocusNode(debugLabel: 'tv-theme-$id'));
  @override
  void dispose() {
    scroll.dispose();
    for (final n in nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: SingleChildScrollView(
      key: const ValueKey('tv-theme-scroll'),
      controller: scroll,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < widget.choices.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Focus(
                canRequestFocus: false,
                onKeyEvent: (_, event) {
                  if (event is KeyUpEvent) return KeyEventResult.ignored;
                  final delta = event.logicalKey == LogicalKeyboardKey.arrowLeft
                      ? -1
                      : event.logicalKey == LogicalKeyboardKey.arrowRight
                      ? 1
                      : 0;
                  if (delta == 0) return KeyEventResult.ignored;
                  final next = i + delta;
                  if (next >= widget.choices.length &&
                      widget.trailingFocusNode != null) {
                    widget.trailingFocusNode!.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (next < 0) {
                    final pane = TvPaneBoundary.maybeOf(context);
                    if (pane != null) {
                      pane.exitLeft();
                      return KeyEventResult.handled;
                    }
                  }
                  if (next < 0 || next >= widget.choices.length) {
                    return KeyEventResult.ignored;
                  }
                  node(widget.choices[next].id).requestFocus();
                  return KeyEventResult.handled;
                },
                child: TvFocusable(
                  key: ValueKey('tv-theme-${widget.choices[i].id}'),
                  focusNode: node(widget.choices[i].id),
                  label: widget.choices[i].label,
                  selected: widget.selected == widget.choices[i].id,
                  onFocusChange: (focused) {
                    if (focused && widget.selected != widget.choices[i].id) {
                      widget.onSelected(widget.choices[i].id);
                    }
                  },
                  onActivate: () => widget.onSelected(widget.choices[i].id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      widget.choices[i].label,
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
