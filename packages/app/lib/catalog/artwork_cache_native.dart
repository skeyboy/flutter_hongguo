import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_core/hongguo_core.dart';

/// Best-effort posters, isolated from authenticated API/media clients.
class ArtworkCache {
  final Directory directory;
  final Dio dio;
  final _pending = <String, Future<void>>{};
  bool closed = false;
  ArtworkCache(this.directory, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
            ),
          );
  String _path(Drama drama) =>
      '${directory.path}/${hex(md5(utf8.encode('${drama.id}:${drama.cover}')))}.image';
  String? lookup(Drama drama) {
    try {
      final file = File(_path(drama));
      return file.existsSync() && file.lengthSync() > 0 ? file.path : null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> ensure(Drama drama) {
    if (closed || drama.cover.isEmpty || lookup(drama) != null) {
      return Future.value();
    }
    final path = _path(drama);
    return _pending.putIfAbsent(
      path,
      () => _download(drama, path).whenComplete(() {
        _pending.remove(path);
      }),
    );
  }

  Future<void> _download(Drama drama, String path) async {
    final uri = Uri.tryParse(
      drama.cover.startsWith('//') ? 'https:${drama.cover}' : drama.cover,
    );
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    const max = 2 * 1024 * 1024;
    final token = CancelToken();
    final working = File('$path.part');
    try {
      final response = await dio.get<List<int>>(
        uri.toString(),
        cancelToken: token,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
        ),
        onReceiveProgress: (received, total) {
          if (received > max || total > max) token.cancel('Poster too large');
        },
      );
      final bytes = response.data;
      if (closed || bytes == null || bytes.length < 12 || bytes.length > max) {
        return;
      }
      final image =
          (bytes[0] == 0xff && bytes[1] == 0xd8) ||
          (bytes[0] == 0x89 &&
              bytes[1] == 0x50 &&
              bytes[2] == 0x4e &&
              bytes[3] == 0x47) ||
          ascii.decode(bytes.take(4).toList(), allowInvalid: true) == 'RIFF' ||
          ascii.decode(bytes.take(3).toList(), allowInvalid: true) == 'GIF';
      if (!image) return;
      await directory.create(recursive: true);
      await working.writeAsBytes(bytes, flush: true);
      if (closed) return;
      await working.rename(path);
      await _prune();
    } catch (_) {
      /* Offline playback never depends on artwork. */
    } finally {
      if (await working.exists()) await working.delete();
    }
  }

  Future<void> _prune() async {
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.image'))
            .toList()
          ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
    var bytes = 0;
    for (final file in files) {
      bytes += file.lengthSync();
      if (bytes > 32 * 1024 * 1024) await file.delete();
    }
  }

  void close() {
    closed = true;
    dio.close(force: true);
  }
}
