import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'adapters/backend.dart';
import 'adapters/web/bootstrap.dart'
    if (dart.library.io) 'adapters/native/bootstrap.dart'
    as platform;
import 'features/catalog/catalog_page.dart';
import 'features/library/library_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  try {
    final backend = await platform.createBackend();
    final library = LibraryStore(await SharedPreferences.getInstance());
    runApp(HongguoApp(backend: backend, library: library));
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('启动失败：$e'))),
      ),
    );
  }
}

class HongguoApp extends StatefulWidget {
  final Backend backend;
  final LibraryStore library;
  const HongguoApp({super.key, required this.backend, required this.library});
  @override
  State<HongguoApp> createState() => _HongguoAppState();
}

class _HongguoAppState extends State<HongguoApp> {
  @override
  void dispose() {
    widget.backend.close();
    widget.library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '红果',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffdd3557)),
      useMaterial3: true,
    ),
    home: CatalogPage(backend: widget.backend, library: widget.library),
  );
}
