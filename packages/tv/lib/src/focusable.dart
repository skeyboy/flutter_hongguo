import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'environment.dart';

/// One semantic/keyboard target; the child is visual only to avoid double focus.
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onActivate;
  final bool autofocus, selected;
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
        canRequestFocus: widget.onActivate != null,
        onFocusChange: (focused) {
          widget.onFocusChange?.call(focused);
          setState(() {});
          if (focused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && node.hasFocus) {
                Scrollable.maybeOf(context)?.position.ensureVisible(
                  context.findRenderObject()!,
                  alignmentPolicy:
                      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
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
            ),
            child: ExcludeFocus(child: widget.child),
          ),
        ),
      ),
    ),
  );
}
