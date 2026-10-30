import 'package:flutter/material.dart';

/// One panel hanging under a rect the caller already measured, over a scrim that
/// dismisses it.
///
/// The house way of putting a filter drawer on screen: the page keeps an
/// `OverlayEntry` it can remove from anywhere (a destination change, an `Esc`,
/// another panel opening), and the panel itself is handed the same `close` the
/// scrim calls, so 「完成」and「点遮罩」are one code path rather than two.
///
/// It is anchored rather than centred because the drawer belongs to the chip that
/// opened it: the viewer's eye is already at the end of the row, and a dialog in
/// the middle of the window would make them find the row again when it went.
OverlayEntry showAnchoredPanel({
  required BuildContext context,
  required Rect anchor,
  required String id,
  required Widget Function(BuildContext context, VoidCallback close) panel,
  bool alignRight = true,
  double? width,

  /// Called on the way out, whichever door was used. The page holds this entry,
  /// so a panel that dismisses itself through the handed `close` has to report
  /// it -- otherwise the page still believes the drawer is on screen.
  VoidCallback? onDismiss,
}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  void close() {
    entry.remove();
    onDismiss?.call();
  }

  entry = OverlayEntry(
    builder: (context) => Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: ValueKey('$id-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: close,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            top: anchor.bottom + 6,
            left: alignRight ? null : anchor.left,
            right: alignRight ? 12 : null,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: width ?? 380,
                maxHeight:
                    MediaQuery.sizeOf(context).height - anchor.bottom - 24,
              ),
              child: anchoredSurface(
                context: context,
                child: Builder(builder: (context) => panel(context, close)),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  overlay.insert(entry);
  return entry;
}

/// The floating card of a hover preview: the same surface as a panel, with no
/// scrim and no modal claim.
///
/// A preview is not a decision the viewer has agreed to make -- they were
/// crossing the grid -- so nothing may be dimmed or blocked behind it, and the
/// pointer has to be able to travel from the card into the preview and stay
/// there. That travel is what [onPointerEnter] reports: the page cancels its own
/// 300ms close when it hears it, and re-arms it on [onPointerExit].
///
/// It flips above the anchor when there is no room below, because a preview that
/// is clipped to the bottom of the window is a preview with no actions in it.
OverlayEntry showAnchoredPeek({
  required BuildContext context,
  required Rect anchor,
  required Widget Function(BuildContext context) card,
  VoidCallback? onPointerEnter,
  VoidCallback? onPointerExit,
  double width = 300,
}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) {
      final size = MediaQuery.sizeOf(context);
      final below = size.height - anchor.bottom - 24;
      final above = anchor.top - 8;
      final flip = below < 200 && above > below;
      final maxLeft = size.width - width - 12;
      return Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned(
              left: maxLeft <= 12
                  ? 12
                  : anchor.left.clamp(12.0, maxLeft).toDouble(),
              top: flip ? null : anchor.bottom + 8,
              bottom: flip ? size.height - anchor.top + 8 : null,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: width,
                  maxHeight: flip ? above : below,
                ),
                child: MouseRegion(
                  onEnter: (_) => onPointerEnter?.call(),
                  onExit: (_) => onPointerExit?.call(),
                  child: anchoredSurface(
                    context: context,
                    child: Builder(builder: card),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  overlay.insert(entry);
  return entry;
}

/// The rounded elevated surface both anchored overlays are drawn on.
Widget anchoredSurface({
  required BuildContext context,
  required Widget child,
}) => Material(
  elevation: 8,
  color: Theme.of(context).colorScheme.surface,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(14),
    side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
  ),
  clipBehavior: Clip.antiAlias,
  child: child,
);

/// Where a widget of the page ends up on screen, in the global coordinates an
/// `OverlayEntry` is laid out in. Null while the widget has not been laid out --
/// which is the same moment the viewer cannot be looking at it either.
Rect? globalRectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  final origin = box.localToGlobal(Offset.zero);
  return origin & box.size;
}
