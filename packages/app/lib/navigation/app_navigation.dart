import 'dart:async';

import '../cast/cast_floating_window.dart';
import '../cast/cast_remote_page.dart';
import '../cast/cast_service.dart';
import '../platform/macos_window.dart';
import '../platform/background/host_policy.dart';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AppScreen {
  detail('DramaDetail', '/detail'),
  player('VideoPlayer', '/player'),
  cast('CastRemote', '/cast'),
  settings('AppSettings', '/settings'),
  cache('LocalCache', '/cache'),
  downloads('EpisodeDownloads', '/downloads'),
  localEpisodes('LocalEpisodes', '/cache/episodes'),
  cacheMetadata('CacheMetadata', '/cache/metadata');

  final String routeName, path;
  const AppScreen(this.routeName, this.path);
}

class _ScreenArguments {
  final WidgetBuilder builder;
  const _ScreenArguments(this.builder);
}

class AppNavigation extends InheritedWidget {
  final RootStackRouter router;
  const AppNavigation({super.key, required this.router, required super.child});
  static AppNavigation? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppNavigation>();
  @override
  bool updateShouldNotify(AppNavigation oldWidget) =>
      router != oldWidget.router;
}

/// Push comes in from the right edge and pop leaves back to it, the one
/// transition every build animates with. The platform defaults this app would
/// otherwise get (fade-forwards on Android, zoom on Windows/Linux) differ per
/// build and read as a cross-fade.
Widget slidePageTransitions(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final forward = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
  );
  final back = CurvedAnimation(
    parent: secondaryAnimation,
    curve: Curves.easeOutCubic,
  );
  return SlideTransition(
    position: Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(forward),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.3, 0),
      ).animate(back),
      child: child,
    ),
  );
}

/// The theme-facing form of [slidePageTransitions].
class SlidePageTransitions extends PageTransitionsBuilder {
  const SlidePageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => slidePageTransitions(context, animation, secondaryAnimation, child);
}

/// Used by `MaterialPageRoute` pushes (the TV build has no auto_route stack).
const PageTransitionsTheme slidePageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: SlidePageTransitions(),
    TargetPlatform.fuchsia: SlidePageTransitions(),
    TargetPlatform.iOS: SlidePageTransitions(),
    TargetPlatform.linux: SlidePageTransitions(),
    TargetPlatform.macOS: SlidePageTransitions(),
    TargetPlatform.windows: SlidePageTransitions(),
  },
);

Future<T?> pushAppPage<T>(
  BuildContext context,
  AppScreen screen,
  WidgetBuilder builder,
) {
  final navigation = AppNavigation.maybeOf(context);
  if (navigation != null) {
    return navigation.router.push<T>(
      NamedRoute(screen.routeName, args: _ScreenArguments(builder)),
    );
  }
  // Shared pages can also be hosted in the isolated TV router or widget tests.
  return Navigator.of(context).push<T>(
    MaterialPageRoute(
      settings: RouteSettings(name: screen.path),
      builder: builder,
    ),
  );
}

/// PC/mobile use a stable auto_route stack. Updating runtime/theme must not
/// recreate the router, discard feed scroll positions or replace a playing page.
class RoutedApplication extends StatefulWidget {
  final MaterialApp configuration;
  final WidgetBuilder? settingsBuilder;

  /// When set, a running cast keeps a handle on every page of the app.
  final CastService? cast;
  const RoutedApplication({
    super.key,
    required this.configuration,
    this.settingsBuilder,
    this.cast,
  });
  @override
  State<RoutedApplication> createState() => _RoutedApplicationState();
}

class _RoutedApplicationState extends State<RoutedApplication> {
  late final home = ValueNotifier<Widget>(widget.configuration.home!);
  late final router = RootStackRouter.build(
    // The router builds its own routes, which look their transition up here and
    // not in the app theme.
    defaultRouteType: RouteType.custom(
      transitionsBuilder: slidePageTransitions,
    ),
    routes: [
      NamedRouteDef(
        name: 'Catalog',
        path: '/',
        initial: true,
        builder: (_, _) => ValueListenableBuilder<Widget>(
          valueListenable: home,
          builder: (_, child, _) => child,
        ),
      ),
      for (final screen in AppScreen.values)
        NamedRouteDef(
          name: screen.routeName,
          path: screen.path,
          builder: (context, data) =>
              data.argsAs<_ScreenArguments>().builder(context),
        ),
    ],
  );
  @override
  void initState() {
    super.initState();
    if (macHost) {
      MacWindow.channel.setMethodCallHandler((call) async {
        if (call.method == 'settings' &&
            mounted &&
            widget.settingsBuilder != null &&
            router.current.name != AppScreen.settings.routeName) {
          unawaited(
            router.push(
              NamedRoute(
                AppScreen.settings.routeName,
                args: _ScreenArguments(widget.settingsBuilder!),
              ),
            ),
          );
        }
      });
      unawaited(MacWindow.invoke('configure', widget.settingsBuilder != null));
    }
  }

  @override
  void didUpdateWidget(covariant RoutedApplication oldWidget) {
    super.didUpdateWidget(oldWidget);
    home.value = widget.configuration.home!;
    unawaited(MacWindow.invoke('configure', widget.settingsBuilder != null));
  }

  @override
  void dispose() {
    if (macHost) MacWindow.channel.setMethodCallHandler(null);
    router.dispose();
    home.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.configuration;
    return AppNavigation(
      router: router,
      child: MaterialApp.router(
        routerConfig: router.config(
          navigatorObservers: () => [macPlaybackRoutes],
        ),
        title: config.title,
        theme: config.theme,
        darkTheme: config.darkTheme,
        themeMode: config.themeMode,
        locale: config.locale,
        supportedLocales: config.supportedLocales,
        localizationsDelegates: config.localizationsDelegates,
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          final content = config.builder?.call(context, child) ?? child!;
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.arrowLeft,
                alt: true,
              ): () {
                router.maybePop();
              },
            },
            child: ListenableBuilder(
              listenable: router,
              builder: (context, _) {
                final framed = MacWindowFrame(
                  immersive: router.current.name == AppScreen.player.routeName,
                  child: content,
                );
                final cast = widget.cast;
                if (cast == null) return framed;
                // Above the router, so no page transition can hide the handle;
                // the window itself stays out of the way while its own page is up.
                return CastFloatingLayer(
                  service: cast,
                  visible: router.current.name != AppScreen.cast.routeName,
                  onTap: () => unawaited(
                    pushAppPage(
                      context,
                      AppScreen.cast,
                      (_) => CastRemotePage(service: cast),
                    ),
                  ),
                  child: framed,
                );
              },
            ),
          );
        },
      ),
    );
  }
}
