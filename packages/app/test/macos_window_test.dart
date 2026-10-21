import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/platform/macos_window.dart';
import 'package:hongguo_app/navigation/app_navigation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(MacWindow.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  test(
    'older player disposal cannot restore titlebar over a newer player',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final values = <bool>[];
      messenger.setMockMethodCallHandler(MacWindow.channel, (call) async {
        if (call.method == 'immersive') values.add(call.arguments as bool);
        return null;
      });
      final oldPlayer = Object(), newPlayer = Object();
      await MacWindow.playerVisible(oldPlayer, true);
      await MacWindow.playerVisible(newPlayer, true);
      await MacWindow.playerVisible(oldPlayer, false);
      await MacWindow.playerVisible(newPlayer, false);
      expect(values, [true, true, true, false]);
    },
  );
  test('only visible pinned player owns the floating level', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var topmost = false;
    messenger.setMockMethodCallHandler(MacWindow.channel, (call) async {
      if (call.method == 'topmost') topmost = call.arguments as bool;
      return null;
    });
    final first = Object(), second = Object();
    await MacWindow.playerVisible(first, true);
    await MacWindow.playerPinned(first, true);
    expect(topmost, isTrue);
    await MacWindow.playerVisible(first, false);
    expect(topmost, isFalse);
    await MacWindow.playerVisible(first, true);
    expect(topmost, isTrue);
    await MacWindow.playerVisible(second, true);
    await MacWindow.playerPinned(second, true);
    await MacWindow.releasePlayer(first);
    expect(topmost, isTrue);
    await MacWindow.releasePlayer(second);
    expect(topmost, isFalse);
  });
  testWidgets(
    'caption reserves content space and immersion preserves child state',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final actions = <String>[];
      messenger.setMockMethodCallHandler(MacWindow.channel, (call) async {
        actions.add(call.method);
        return null;
      });
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late StateSetter update;
      var immersive = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return MacWindowFrame(
                immersive: immersive,
                child: const _PersistentContent(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = tester.state(find.byType(_PersistentContent));
      final body = find.byKey(const ValueKey('mac-frame-content'));
      expect(tester.getRect(body).top, 32);
      expect(tester.getRect(body).height, 568);
      for (final action in ['hide', 'minimize', 'fullscreenToggle']) {
        await tester.tap(find.byKey(ValueKey('mac-window-$action')));
        await tester.pump();
      }
      expect(actions, ['hide', 'minimize', 'fullscreenToggle']);
      update(() => immersive = true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mac-window-caption')), findsNothing);
      expect(tester.getRect(body).top, 0);
      expect(tester.getRect(body).height, 600);
      expect(tester.state(find.byType(_PersistentContent)), same(original));
      update(() => immersive = false);
      await tester.pumpAndSettle();
      expect(tester.getRect(body).top, 32);
      expect(tester.state(find.byType(_PersistentContent)), same(original));
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'native settings menu opens one existing route and returns to catalog',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      messenger.setMockMethodCallHandler(MacWindow.channel, (_) async => null);
      await tester.pumpWidget(
        RoutedApplication(
          configuration: const MaterialApp(
            home: Scaffold(body: Text('catalog')),
          ),
          settingsBuilder: (_) =>
              Scaffold(appBar: AppBar(title: const Text('menu settings'))),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> clickSettings() async {
        await messenger.handlePlatformMessage(
          MacWindow.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('settings'),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await clickSettings();
      expect(find.text('menu settings'), findsOneWidget);
      await clickSettings();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('catalog'), findsOneWidget);
      expect(find.text('menu settings'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

class _PersistentContent extends StatefulWidget {
  const _PersistentContent();
  @override
  State<_PersistentContent> createState() => _PersistentContentState();
}

class _PersistentContentState extends State<_PersistentContent> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand(
    key: ValueKey('mac-frame-content'),
    child: ColoredBox(color: Colors.black),
  );
}
