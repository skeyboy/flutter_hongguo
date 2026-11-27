import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'environment.dart';

/// One semantic/keyboard target; the child is visual only to avoid double focus.
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onActivate;
  final bool autofocus, selected;
  final bool? checked;
  final FocusNode? focusNode;
  final String label;
  final ValueChanged<bool>? onFocusChange;
  const TvFocusable({
    super.key,
    required this.child,
    required this.label,
    this.onActivate,
    this.autofocus = false,
    this.selected = false,
    this.checked,
    this.focusNode,
    this.onFocusChange,
  });
  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late FocusNode node;
  bool get ownsNode => widget.focusNode == null;
  @override
  void initState() {
    super.initState();
    node = widget.focusNode ?? FocusNode(debugLabel: widget.label);
  }

  @override
  void didUpdateWidget(TvFocusable old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      if (old.focusNode == null) node.dispose();
      node = widget.focusNode ?? FocusNode(debugLabel: widget.label);
    }
  }

  @override
  void dispose() {
    if (ownsNode) node.dispose();
    super.dispose();
  }

  void _activateControl() {
    widget.onActivate?.call();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    checked: widget.checked,
    selected: widget.selected,
    enabled: widget.onActivate != null,
    child: Actions(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activateControl();
            return null;
          },
        ),
      },
      child: Focus(
        focusNode: node,
        autofocus: widget.autofocus,
        // Inert must not mean unfocusable: flipping `canRequestFocus` off a
        // node that holds the primary focus drops the focus to the scope, and
        // a scope has no focus for the remote to sit on. `skipTraversal` keeps
        // it out of the D-pad walk instead.
        skipTraversal: widget.onActivate == null,
        onFocusChange: (focused) {
          widget.onFocusChange?.call(focused);
          setState(() {});
          if (focused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && node.hasFocus) {
                // All the scrollables around the item, not just the nearest: a
                // cell of a nested grid sits in a viewport that cannot scroll,
                // so revealing only that one leaves the focus off the screen --
                // measured on the emulator, where the walk into the third
                // episode row vanished from the accessibility tree.
                //
                // And centered, not `keepVisibleAtEnd`: that policy never
                // reduces the offset, so an item above the fold is never
                // revealed and walking back up out of the grid lost the focus
                // too (emulator, up from the last episode row).
                Scrollable.ensureVisible(
                  context,
                  alignment: 0.5,
                  duration: const Duration(milliseconds: 100),
                );
              }
            });
          }
        },
        onKeyEvent: (_, event) {
          if (isRemoteConfirm(event.logicalKey)) {
            if (event is KeyDownEvent) _activateControl();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onActivate,
          // The 10-foot contract: the focused tile steps forward (a moderate
          // scale, never clipping its 14px grid gutter), catches light on its
          // rim and carries a soft primary glow. All engine-built effects --
          // no runtime fragment shader, so Impeller and low-end TV GPUs never
          // pay the Skia-fallback tax for a decoration.
          child: AnimatedScale(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            scale: node.hasFocus ? 1.05 : 1.0,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 100),
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: widget.selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: node.hasFocus
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                  width: 3,
                ),
                boxShadow: node.hasFocus
                    ? [
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.40),
                          blurRadius: 16,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              // The "shader" garnish: a soft top-lit sheen over the focused
              // tile, clipped to its own rim. Read as light hitting the card.
              foregroundDecoration: node.hasFocus
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.10),
                          Colors.transparent,
                        ],
                        stops: const [0, 0.45],
                      ),
                    )
                  : null,
              child: ExcludeFocus(child: widget.child),
            ),
          ),
        ),
      ),
    ),
  );
}
