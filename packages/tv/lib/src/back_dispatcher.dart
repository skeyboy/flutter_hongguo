import 'package:flutter/material.dart';

/// One owner for both Android system Back and TV keyboard/gamepad Back.
/// Install outside MaterialApp so this observer runs before WidgetsApp's
/// fallback, which would otherwise close the Activity at the root route.
class TvBackDispatcher extends StatefulWidget {
  final Widget Function(BuildContext, GlobalKey<NavigatorState>) builder;
  const TvBackDispatcher({super.key, required this.builder});

  static Future<void>? dispatch(BuildContext context) =>
      context.findAncestorStateOfType<_TvBackDispatcherState>()?.back();

  @override
  State<TvBackDispatcher> createState() => _TvBackDispatcherState();
}

class _TvBackDispatcherState extends State<TvBackDispatcher>
    with WidgetsBindingObserver {
  final navigatorKey = GlobalKey<NavigatorState>();
  bool handling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> back() async {
    if (handling || !mounted) return;
    handling = true;
    try {
      final focusContext = FocusManager.instance.primaryFocus?.context;
      NavigatorState? target;
      // Retained auto_route tabs have their own Navigators. Walk outwards,
      // choosing only one stack that can pop; never cascade after a pop.
      focusContext?.visitAncestorElements((element) {
        if (element is StatefulElement && element.state is NavigatorState) {
          final candidate = element.state as NavigatorState;
          if (candidate.canPop()) {
            target = candidate;
            return false;
          }
        }
        return true;
      });
      target ??= navigatorKey.currentState;
      if (target == null) return;
      // Capture the route before awaiting: a delayed return must never act on
      // the page revealed underneath it.
      ModalRoute<dynamic>? route;
      target!.popUntil((candidate) {
        if (candidate is ModalRoute<dynamic>) route = candidate;
        return true;
      });
      final animation = route?.animation;
      if (animation?.status == AnimationStatus.reverse) {
        return;
      }
      await target!.maybePop(); // Respects dialogs and player PopScope layers.
      await WidgetsBinding.instance.endOfFrame;
      if (route is TransitionRoute<dynamic> && !route!.isCurrent) {
        await (route as TransitionRoute<dynamic>).completed;
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'hongguo_tv',
          context: ErrorDescription('while handling a TV Back event'),
        ),
      );
    } finally {
      handling = false;
    }
  }

  @override
  Future<bool> didPopRoute() async {
    await back();
    return true; // Root Back is consumed; TV never calls SystemNavigator.pop.
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, navigatorKey);
}
