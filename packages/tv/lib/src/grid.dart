import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'focusable.dart';
import 'pane_boundary.dart';

/// Index navigation materializes off-screen items before requesting focus.
/// IDs, rather than indices, own nodes so appends and route returns are stable.
class TvGrid extends StatefulWidget {
  final List<String> ids;
  final Widget Function(BuildContext, int) itemBuilder;
  final String Function(int) label;
  final ValueChanged<int> activate;
  final double maxExtent, aspectRatio;
  final VoidCallback? onNearEnd;
  final bool hasMore, navigationEnabled;
  final String? initialFocusId;
  const TvGrid({
    super.key,
    required this.ids,
    required this.itemBuilder,
    required this.label,
    required this.activate,
    this.maxExtent = 240,
    this.aspectRatio = .62,
    this.onNearEnd,
    this.hasMore = false,
    this.navigationEnabled = true,
    this.initialFocusId,
  });
  @override
  State<TvGrid> createState() => _TvGridState();
}

class _TvGridState extends State<TvGrid> {
  final scroll = ScrollController();
  final nodes = <String, FocusNode>{};
  int revision = 0;
  String? logicalTarget, issuedFocus, pendingRight;
  bool continuationScheduled = false;
  int columns = 1;
  double rowHeight = 1;

  void cancelMoves() {
    revision++;
    logicalTarget = null;
    issuedFocus = null;
    pendingRight = null;
  }

  @override
  void didUpdateWidget(TvGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.navigationEnabled ||
        (logicalTarget != null && !widget.ids.contains(logicalTarget))) {
      cancelMoves();
    }
    continueRight();
  }

  void continueRight() {
    if (pendingRight == null || continuationScheduled) return;
    continuationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      continuationScheduled = false;
      if (!mounted || !widget.navigationEnabled || pendingRight == null) return;
      final anchor = pendingRight!;
      final index = widget.ids.indexOf(anchor);
      if (index < 0 || (index + 1 >= widget.ids.length && !widget.hasMore)) {
        pendingRight = null;
        return;
      }
      if (index + 1 < widget.ids.length && node(anchor).hasPrimaryFocus) {
        pendingRight = null;
        move(index + 1, columns, rowHeight);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    scroll.addListener(_nearEnd);
    if (widget.initialFocusId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final index = widget.ids.indexOf(widget.initialFocusId!);
        if (index >= 0) move(index, columns, rowHeight);
      });
    }
  }

  void _nearEnd() {
    if (scroll.hasClients &&
        scroll.position.extentAfter < scroll.position.viewportDimension) {
      widget.onNearEnd?.call();
    }
  }

  FocusNode node(String id) =>
      nodes.putIfAbsent(id, () => FocusNode(debugLabel: 'tv-grid-$id'));
  Future<void> move(int index, int columns, double rowHeight) async {
    if (index < 0 || index >= widget.ids.length) return;
    final ticket = ++revision, id = widget.ids[index];
    logicalTarget = id;
    if (scroll.hasClients) {
      final offset = index ~/ columns * rowHeight;
      final current = scroll.offset;
      final height = scroll.position.viewportDimension;
      if (offset < current || offset + rowHeight > current + height) {
        await scroll.animateTo(
          (offset < current ? offset : offset + rowHeight - height).clamp(
            0,
            scroll.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    }
    WidgetsBinding.instance.ensureVisualUpdate();
    await WidgetsBinding.instance.endOfFrame;
    if (mounted &&
        widget.navigationEnabled &&
        ticket == revision &&
        widget.ids.contains(id)) {
      issuedFocus = id;
      node(id).requestFocus();
    }
  }

  @override
  void dispose() {
    revision++;
    scroll.dispose();
    for (final n in nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onFocusChange: (focused) {
      if (!focused) cancelMoves();
    },
    child: LayoutBuilder(
      builder: (context, size) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _nearEnd();
        });
        final columns = math.max(
          1,
          ((size.maxWidth + 14) / (widget.maxExtent + 14)).ceil(),
        );
        final width = (size.maxWidth - (columns - 1) * 14) / columns,
            rowHeight = width / widget.aspectRatio + 14;
        this.columns = columns;
        this.rowHeight = rowHeight;
        return GridView.builder(
          controller: scroll,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: widget.aspectRatio,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
          ),
          itemCount: widget.ids.length,
          findChildIndexCallback: (key) {
            final index = widget.ids.indexOf(
              (key as ValueKey<String>).value.substring('tv-grid-item-'.length),
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (context, i) => Focus(
            key: ValueKey('tv-grid-item-${widget.ids[i]}'),
            canRequestFocus: false,
            onKeyEvent: (_, e) {
              if (e is KeyUpEvent) return KeyEventResult.ignored;
              final k = e.logicalKey;
              if (!widget.navigationEnabled) return KeyEventResult.handled;
              final pendingIndex = logicalTarget == null
                  ? -1
                  : widget.ids.indexOf(logicalTarget!);
              final current = pendingIndex < 0 ? i : pendingIndex;
              final horizontal =
                  k == LogicalKeyboardKey.arrowLeft ||
                  k == LogicalKeyboardKey.arrowRight;
              if (k != LogicalKeyboardKey.arrowRight) pendingRight = null;
              if (k == LogicalKeyboardKey.arrowLeft && current == 0) {
                cancelMoves();
                TvPaneBoundary.maybeOf(context)?.exitLeft();
                return KeyEventResult.handled;
              }
              final next = k == LogicalKeyboardKey.arrowDown
                  ? current + columns
                  : k == LogicalKeyboardKey.arrowUp
                  ? current - columns
                  : k == LogicalKeyboardKey.arrowLeft
                  ? current - 1
                  : k == LogicalKeyboardKey.arrowRight
                  ? current + 1
                  : null;
              if (next == null) return KeyEventResult.ignored;
              if (next < 0 || next >= widget.ids.length) {
                if (k == LogicalKeyboardKey.arrowRight && widget.hasMore) {
                  pendingRight = widget.ids[current];
                  widget.onNearEnd?.call();
                }
                // A horizontal edge belongs to this grid. Never let geometric
                // traversal send Right to the theme/search controls above it.
                return horizontal
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored;
              }
              move(next, columns, rowHeight);
              return KeyEventResult.handled;
            },
            child: TvFocusable(
              key: ValueKey(widget.ids[i]),
              focusNode: node(widget.ids[i]),
              label: widget.label(i),
              onActivate: () => widget.activate(i),
              onFocusChange: (focused) {
                if (focused) {
                  if (issuedFocus == widget.ids[i]) {
                    issuedFocus = null;
                    if (logicalTarget == widget.ids[i]) logicalTarget = null;
                  } else {
                    cancelMoves();
                  }
                  continueRight();
                }
                if (focused && i >= widget.ids.length - columns * 2) {
                  widget.onNearEnd?.call();
                }
              },
              child: widget.itemBuilder(context, i),
            ),
          ),
        );
      },
    ),
  );
}
