import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

String? _latestTitle;

Future<void> updateWindowTitle(String name) async {
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) return;
  _latestTitle = name;
  try {
    await windowManager.ensureInitialized();
    // Locale changes during initialization must not restore an older title.
    await windowManager.setTitle(_latestTitle!);
  } on MissingPluginException {
    // Widget tests and hosts without a native window do not register this plugin.
  } on PlatformException {
    // Keep the native startup title if the window has already closed.
  }
}
