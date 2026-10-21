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
