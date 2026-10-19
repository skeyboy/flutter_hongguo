import 'dart:convert';
import 'dart:io';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../backend.dart';
import '../http_transport.dart';
import 'media_repository.dart';
import 'json_store.dart';

Future<Backend> createBackend() async {
  final transport = HttpTransport();
  const remote = String.fromEnvironment('HONGGUO_API_BASE');
  if (remote.isNotEmpty) {
    final repository = RemoteRepository(
      transport,
      Uri.parse(remote),
      apiKey: const String.fromEnvironment('HONGGUO_API_KEY'),
    );
    return Backend(
      repository,
      repository,
      label: '远程服务',
      close: transport.close,
    );
  }
  final support = await getApplicationSupportDirectory(),
      cache = await getApplicationCacheDirectory();
  await support.create(recursive: true);
  final identityFile = File(p.join(support.path, 'device.json'));
  Map<String, String>? identity;
  if (await identityFile.exists()) {
    identity = Map<String, String>.from(
      jsonDecode(await identityFile.readAsString()),
    );
  }
  identity ??= SignedClient.createDevice(SecureRandomSource());
  if (!await identityFile.exists()) {
    await identityFile.writeAsString(jsonEncode(identity), flush: true);
  }
  final mediaDir = Directory(p.join(cache.path, 'media'));
  if (await mediaDir.exists()) {
    await for (final entry in mediaDir.list()) {
      if (entry is File && entry.path.endsWith('.part')) await entry.delete();
    }
  }
  final signed = SignedClient(transport, identity: identity);
  return Backend(
    CachedCatalog(
      NativeCatalog(signed),
      NativeJsonStore(Directory(p.join(support.path, 'metadata'))),
    ),
    NativePlaybackRepository(
      AppSource(signed),
      Directory(p.join(cache.path, 'media')),
    ),
    label: '本地 Dart 核心',
    close: transport.close,
  );
}
