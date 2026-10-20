import 'dart:async';

import 'package:flutter/widgets.dart';

import 'window_title_stub.dart'
    if (dart.library.io) 'window_title_native.dart'
    as window_title;

String applicationName(Locale locale) {
  if (locale.languageCode != 'zh') return 'Hongguo';
  final traditional =
      locale.scriptCode == 'Hant' ||
      (locale.scriptCode != 'Hans' &&
          const ['TW', 'HK', 'MO'].contains(locale.countryCode));
  return traditional ? '紅果劇場' : '红果剧场';
}

String applicationNameForLocales(Iterable<Locale> locales) {
  for (final locale in locales) {
    if (locale.languageCode == 'zh' || locale.languageCode == 'en') {
      return applicationName(locale);
    }
  }
  return 'Hongguo';
}

/// App-switcher names follow the OS locale independently of content language.
class ApplicationName extends StatefulWidget {
  final Widget Function(String) builder;
  const ApplicationName({super.key, required this.builder});

  static String of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_NameScope>()?.name ??
      applicationNameForLocales(
        WidgetsBinding.instance.platformDispatcher.locales,
      );
  @override
  State<ApplicationName> createState() => _ApplicationNameState();
}

class _ApplicationNameState extends State<ApplicationName>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String? _windowName;

  @override
  Widget build(BuildContext context) {
    final name = applicationNameForLocales(
      WidgetsBinding.instance.platformDispatcher.locales,
    );
    if (_windowName != name) {
      _windowName = name;
      unawaited(window_title.updateWindowTitle(name));
    }
    return _NameScope(name: name, child: widget.builder(name));
  }
}

class _NameScope extends InheritedWidget {
  final String name;
  const _NameScope({required this.name, required super.child});

  @override
  bool updateShouldNotify(_NameScope oldWidget) => name != oldWidget.name;
}
