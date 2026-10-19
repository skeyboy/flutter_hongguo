import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:path/path.dart' as p;
import 'file_store.dart';

class NativePlaybackRepository implements PlaybackRepository {
  final AppSource source;
  final Directory directory;
  final int maxBytes, maxFiles;
  final MediaScheduler scheduler = MediaScheduler();
  final Map<String, Future<MediaSource>> _pending = {};
  NativePlaybackRepository(
    this.source,
    this.directory, {
    this.maxBytes = 1024 * 1024 * 1024,
    this.maxFiles = 30,
  });
  @override
  Future<MediaSource> prepare(
    String vid, {
    String quality = 'best',
    CancellationToken? cancellation,
    void Function(PreparationState)? onState,
  }) async {
    if (!RegExp(r'^\d{1,30}$').hasMatch(vid) ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,20}$').hasMatch(quality)) {
      throw ArgumentError('Invalid media cache key');
    }
    final token = cancellation ?? CancellationToken();
    token.check();
    final key = '$vid-$quality';
    // One active download/decrypt at a time. A second caller waits, then rechecks cache.
    final previous = _pending[key];
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
      token.check();
    }
    onState?.call(PreparationState.queued);
    final job = scheduler.run(token, () async {
      await directory.create(recursive: true);
      token.check();
      final output = File(p.join(directory.path, '$key.mp4'));
      final marker = File('${output.path}.ready.json');
      if (await _ready(output, marker)) {
        token.check();
        await output.setLastModified(DateTime.now());
        onState?.call(PreparationState.ready);
        return MediaSource(output.path, isLocal: true);
      }
      for (final stale in [output, marker]) {
        if (await stale.exists()) await stale.delete();
      }
      final temporary = File('${output.path}.part');
      try {
        token.check();
        final track = await source.fetch(vid, quality: quality);
        token.check();
        onState?.call(PreparationState.downloading);
        await _download(track, temporary, token);
        token.check();
        onState?.call(PreparationState.decrypting);
        await _worker({'path': temporary.path, 'spade': track.spadeA}, token);
        token.check();
        onState?.call(PreparationState.remuxing);
        // Publish only a completely validated file. A crash between renames lacks a marker.
        final size = await temporary.length();
        if (size > maxBytes) throw StateError('单集超过缓存预算');
        await temporary.rename(output.path);
        token.check();
        final pendingMarker = File('${marker.path}.part');
        await pendingMarker.writeAsString(
          jsonEncode({'version': 1, 'size': size}),
          flush: true,
        );
        token.check();
        await pendingMarker.rename(marker.path);
        await _evict(protect: output.path);
        token.check();
        onState?.call(PreparationState.ready);
        return MediaSource(output.path, isLocal: true);
      } catch (e) {
        for (final f in [
          temporary,
          output,
          marker,
          File('${marker.path}.part'),
        ]) {
          if (await f.exists()) await f.delete();
        }
        onState?.call(
          e is PreparationCancelled
              ? PreparationState.cancelled
              : PreparationState.failed,
        );
        rethrow;
      }
    });
    _pending[key] = job;
    try {
      return await job;
    } finally {
      if (identical(_pending[key], job)) _pending.remove(key);
    }
  }

  Future<bool> _ready(File file, File marker) async {
    try {
      final m = jsonDecode(await marker.readAsString());
      return m['version'] == 1 &&
          m['size'] is int &&
          m['size'] > 16 &&
          await file.length() == m['size'];
    } catch (_) {
      return false;
    }
  }

  Future<void> _download(
    PlaybackTrack track,
    File file,
    CancellationToken token,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final unlisten = token.listen(() => client.close(force: true));
    IOSink? sink;
    try {
      var mediaUri = track.url;
      late HttpClientResponse response;
      for (var redirects = 0; redirects <= 5; redirects++) {
        token.check();
        final request = await client.getUrl(mediaUri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
        response = await request.close().timeout(const Duration(seconds: 30));
        if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects == 5) {
          throw const HttpException('媒体重定向过多或缺少地址');
        }
        final next = mediaUri.resolve(location);
        try {
          checkedUrl(next.toString(), mediaDomains);
        } on FormatException {
          throw HttpException('媒体重定向到不支持的域名: ${next.host}');
        }
        await response.drain<void>().timeout(const Duration(seconds: 30));
        mediaUri = next;
      }
      if (response.statusCode != 200) {
        throw HttpException('媒体 HTTP ${response.statusCode}');
      }
      if (response.contentLength > maxBytes) throw StateError('媒体超过缓存预算');
      sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        token.check();
        received += chunk.length;
        if (received > maxBytes) throw StateError('媒体超过缓存预算');
        // addStream applies sink backpressure instead of queueing the whole file.
        await sink.addStream(Stream.value(chunk));
      }
      if (received < 16 ||
          (response.contentLength >= 0 && received != response.contentLength)) {
        throw const FormatException('下载文件长度不完整');
      }
      await sink.flush();
    } catch (_) {
      token.check();
      rethrow;
    } finally {
      await sink?.close();
      unlisten();
      client.close(force: true);
    }
  }

  Future<void> _worker(
    Map<String, String> args,
    CancellationToken token,
  ) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerEntry,
      [receive.sendPort, args],
      onError: receive.sendPort,
      onExit: receive.sendPort,
    );
    final remove = token.listen(
      () => isolate.kill(priority: Isolate.immediate),
    );
    try {
      token.check();
      final message = await receive.first;
      token.check();
      if (message != 'ok') {
        throw StateError(
          message is List ? message.first.toString() : '媒体 worker 提前退出',
        );
      }
    } finally {
      remove();
      isolate.kill(priority: Isolate.immediate);
      receive.close();
    }
  }

  static void _workerEntry(List<dynamic> message) {
    final port = message[0] as SendPort;
    try {
      decryptFile(Map<String, String>.from(message[1]));
      port.send('ok');
    } catch (e) {
      port.send([e.toString()]);
    }
  }

  Future<void> _evict({required String protect}) async {
    final files = await directory
        .list()
        .where((e) => e is File && e.path.endsWith('.mp4'))
        .cast<File>()
        .toList();
    final modified = <String, DateTime>{};
    var total = 0;
    for (final f in files) {
      final stat = await f.stat();
      total += stat.size;
      modified[f.path] = stat.modified;
    }
    files.sort((a, b) => modified[a.path]!.compareTo(modified[b.path]!));
    var count = files.length;
    for (final f in files) {
      if (total <= maxBytes && count <= maxFiles) break;
      if (f.path == protect) continue;
      total -= await f.length();
      count--;
      await f.delete();
      final marker = File('${f.path}.ready.json');
      if (await marker.exists()) await marker.delete();
    }
  }
}
