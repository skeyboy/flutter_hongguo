// Read-only upstream smoke check. Never prints signed URLs, keys or content keys.
import 'dart:io';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_flutter/adapters/http_transport.dart';
import 'package:hongguo_flutter/adapters/native/media_repository.dart';

Future<void> main(List<String> args) async {
  final transport = HttpTransport();
  final client = SignedClient(transport);
  final catalog = NativeCatalog(client);
  try {
    final page = await catalog.browse(limit: 1);
    stdout.writeln(
      'browse: count=${page.items.length}, has_more=${page.hasMore}',
    );
    final searched = await catalog.search('总裁', limit: 1);
    stdout.writeln('search: count=${searched.items.length}');
    final series = page.items.isNotEmpty
        ? page.items.first
        : searched.items.first;
    final detail = await catalog.detail(series.id);
    stdout.writeln('detail: episode_count=${detail.episodes.length}');
    if (detail.episodes.isNotEmpty) {
      final track = await AppSource(client).fetch(detail.episodes.first.vid);
      stdout.writeln(
        'model: definition=${track.definition}, encrypted=${track.encrypted}, size=${track.size}',
      );
      if (args.contains('--prepare')) {
        final temp = await Directory.systemTemp.createTemp(
          'hongguo-upstream-smoke-',
        );
        try {
          final media = await NativePlaybackRepository(AppSource(client), temp)
              .prepare(
                detail.episodes.first.vid,
                onState: (s) => stdout.writeln('prepare: ${s.name}'),
              );
          stdout.writeln(
            'prepare: validated_bytes=${await File(media.location).length()}',
          );
        } finally {
          await temp.delete(recursive: true);
        }
      }
    }
  } catch (e) {
    stderr.writeln('upstream smoke: ${e.runtimeType}: $e');
    exitCode = 1;
  } finally {
    transport.close();
  }
}
