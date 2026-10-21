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
