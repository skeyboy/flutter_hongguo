import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show tvBuild;
import 'package:path_provider/path_provider.dart';

import '../platform/macos_window.dart';
import '../platform/runtime.dart';
import 'update_controller.dart';
import 'update_dialog.dart';
import 'update_transfer.dart';

/// Updates belong to an installed app. A browser tab has no installer to run
/// and a television is side-loaded by hand, so neither gets the feature at all.
bool get updateSupported => !kIsWeb && !tvBuild;

/// One controller per runtime, exactly like [castServiceFor] does: the daily
/// throttle, the retained ETag and an undismissed offer all have to survive
/// leaving the settings page, and none of them belong to a page.
final _controllers = Expando<UpdateController>();

UpdateController sharedUpdateController(AppRuntime runtime, {Dio? transport}) =>
    _controllers[runtime] ??= UpdateController(
      // Not the runtime's transport: its timeouts and headers are the upstream
      // video API's, and a version check is a GitHub request.
      dio:
          transport ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
            ),
          ),
      readSettings: () => settingsFor(runtime),
      writeSettings: (value) => runtime is ConfigurableRuntime
          ? runtime.saveSettings(value)
          : Future.value(),
      stageDirectory: stageDirectoryFor,
    );

/// Where a downloaded installer waits to be verified and handed over.
///
/// The same folder under the app's support directory on every platform, because
/// that is the only place the system's transfer lane can be pointed at: it
/// addresses files relative to that base, and a stage folder it cannot name would
/// leave the download and the note about it in two different places.
Future<String> stageDirectoryFor() async {
  final support = await getApplicationSupportDirectory();
  final updates = Directory(
    '${support.path}${Platform.pathSeparator}$updatePackagePath',
  );
  await updates.create(recursive: true);
  return updates.path;
}

/// Mounts the version prompt above the root page.
///
/// The check itself runs without any widget -- a resumed app or the settings
/// row can find a new version while the player owns the screen. This host only
/// decides *when* it is allowed to interrupt: never over a route of its own,
/// and never a second time for the same offer.
class UpdatePromptHost extends StatefulWidget {
  final UpdateController controller;
  final Widget child;
  const UpdatePromptHost({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends State<UpdatePromptHost> with RouteAware {
  UpdateController get controller => widget.controller;

  PageRoute<dynamic>? _route;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_offerMayBeShown);
    controller.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `macPlaybackRoutes` is the app-wide route observer, not a macOS-only one:
    // it is the navigator observer this stack already publishes.
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) macPlaybackRoutes.unsubscribe(this);
      _route = route;
      macPlaybackRoutes.subscribe(this, route);
    }
  }

  @override
  void didPopNext() => _offerMayBeShown();

  @override
  void dispose() {
    macPlaybackRoutes.unsubscribe(this);
    controller.removeListener(_offerMayBeShown);
    super.dispose();
  }

  void _offerMayBeShown() {
    if (_dialogOpen || controller.unseenOffer == null || !mounted) return;
    // A check completes inside a frame of its own, and a dialog cannot be
    // mounted while the tree is still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _show();
    });
  }

  Future<void> _show() async {
    if (_dialogOpen) return;
    final route = ModalRoute.of(context);
    // The player, a download or the cast page owns the screen: the prompt waits
    // until that route is gone instead of cutting the task short.
    if (route == null || !route.isCurrent) return;
    _dialogOpen = true;
    await showUpdateDialog(context, controller);
    _dialogOpen = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
