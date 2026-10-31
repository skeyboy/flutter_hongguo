import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

/// A confirmation the remote can actually answer.
///
/// `AlertDialog`'s Material actions assume the dialog route takes the focus for
/// itself. On TV the ring is still on the row that opened the dialog, and the
/// D-pad walk searches the focused node's own scope, so it cannot cross into the
/// dialog: the viewer is left with a message and no way to answer it. The TV
/// branch builds the actions as `TvFocusable` and parks the ring on 取消, so a
/// stray 确认 press can never destroy anything.
Future<bool?> showTvConfirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) {
  final tv = TvEnvironment.of(context);
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: TextStyle(fontSize: tv ? 26 : null)),
      content: Text(body, style: TextStyle(fontSize: tv ? 20 : null)),
      actions: tv
          ? [
              TvFocusable(
                label: '取消',
                autofocus: true,
                onActivate: () => Navigator.pop(context, false),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('取消', style: TextStyle(fontSize: 20)),
                ),
              ),
              TvFocusable(
                label: confirmLabel,
                onActivate: () => Navigator.pop(context, true),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    confirmLabel,
                    style: TextStyle(
                      fontSize: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmLabel),
              ),
            ],
    ),
  );
}
