import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'bootstrap.dart';
import 'features/library_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const ProviderScope(child: HongguoApp()));
}

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xffd54738),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xfff08475) : const Color(0xffc74334),
        onPrimary: dark ? const Color(0xff420b05) : Colors.white,
        surface: dark ? const Color(0xff18181e) : Colors.white,
      );
  final background = dark ? const Color(0xff101014) : const Color(0xfffaf9f6);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dividerColor: scheme.outlineVariant,
  );
}

class HongguoApp extends ConsumerWidget {
  const HongguoApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(appSettingsProvider).asData?.value ?? const AppSettings();
    return MaterialApp(
      title: '红果剧场',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: switch (settings.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: ref
          .watch(runtimeProvider)
          .when(
            data: (runtime) => LibraryPage(runtime: runtime),
            loading: () => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off_rounded, size: 40),
                      const SizedBox(height: 16),
                      const Text(
                        '暂时无法打开剧场',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('$error', textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () => ref.invalidate(runtimeProvider),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
    );
  }
}
