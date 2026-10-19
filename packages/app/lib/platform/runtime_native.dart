import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:path_provider/path_provider.dart';

import '../settings/settings_store.dart';
import '../catalog/library_cache.dart';
import '../catalog/artwork_cache_native.dart';
import '../settings/settings_store_native.dart';
import 'runtime_contract.dart';

Future<AppRuntime> createRuntime() async {
  final root = await getApplicationSupportDirectory();
  await root.create(recursive: true);
  final identity = File('${root.path}/device-id.txt');
  var id = await identity.exists()
      ? (await identity.readAsString()).trim()
      : '';
  if (!RegExp(r'^\d{10,20}$').hasMatch(id)) {
    id = VideoRequestBuilder.defaultDevice()['device_id']!;
    await identity.writeAsString(id, flush: true);
  }
  final store = SettingsStore(
    backend: FilePreferencesBackend(File('${root.path}/settings.json')),
    vault: SystemSessionVault(),
    deviceId: id,
  );
  await store.load();
  return NativeRuntime(root, store);
}

class NativeRuntime
    implements
        ConfigurableRuntime,
        LibraryCacheRuntime,
        LocalMediaRuntime,
        DramaMetadataRuntime {
  final SettingsStore store;
  @override
  late final LibraryCache libraryCache;
  final _settingsEvents = StreamController<AppSettings>.broadcast();
  final Dio _dio = Dio();
  late CatalogClient _catalog;
  late VideoModelClient _model;
  late final MediaCache _cache;
  late final ArtworkCache _artwork;
  NativeRuntime(Directory root, this.store) {
    libraryCache = LibraryCache(
      backend: FilePreferencesBackend(File('${root.path}/library-cache.json')),
    );
    _artwork = ArtworkCache(Directory('${root.path}/artwork-cache'));
    _rebuildClients();
    _cache = MediaCache(
      directory: Directory('${root.path}/media-cache'),
      dio: _dio,
      maxFiles: settings.maxCacheFiles,
      maxBytes: settings.maxCacheMb * 1024 * 1024,
      maxConcurrent: settings.concurrentPreparations,
      resolve: (vid, quality) => _model.fetchTrack(vid, quality: quality),
    );
  }
  @override
  CatalogRepository get catalog => _catalog;
  @override
  AppSettings get settings => store.settings;
  @override
  Stream<AppSettings> get settingsChanges => _settingsEvents.stream;
  @override
  SessionCredentials get credentials => store.credentials;
  @override
  String get deviceId => store.deviceId;
  @override
  String? get settingsWarning => store.warning;
  void _rebuildClients() {
    _dio.options.connectTimeout = Duration(seconds: settings.timeoutSeconds);
    _catalog = CatalogClient(
      dio: _dio,
      deviceId: deviceId,
      protocol: settings,
      signLists: settings.signLists,
      sessionHeaders: credentials.headers,
    );
    _model = VideoModelClient(
      dio: _dio,
      builder: VideoRequestBuilder(
        protocol: settings,
        sessionHeaders: credentials.headers,
      ),
    );
  }

  @override
  Future<void> saveSettings(
    AppSettings value, {
    SessionCredentials? credentials,
  }) async {
    final oldProtocol = jsonEncode(settings.protocolJson()),
        oldSession = jsonEncode(this.credentials.toJson());
    await store.save(value, session: credentials);
    _settingsEvents.add(settings);
    if (oldProtocol != jsonEncode(settings.protocolJson()) ||
        oldSession != jsonEncode(this.credentials.toJson())) {
      _cache.cancelBackground();
      await libraryCache.clearFeeds().catchError((Object _) {
        store.warning = '目录快照清理未写入磁盘，其他设置已保存。';
      });
      _rebuildClients();
    }
    if (!settings.prefetchEnabled) _cache.cancelBackground();
    await _cache.configure(
      files: settings.maxCacheFiles,
      bytes: settings.maxCacheMb * 1024 * 1024,
      concurrency: settings.concurrentPreparations,
    );
  }

  @override
  Future<void> refreshSigning() async {
    _cache.cancelBackground();
    _rebuildClients();
  }

  @override
  Future<void> rotateDeviceIdentity() async {
    final nextId = VideoRequestBuilder.defaultDevice()['device_id']!;
    await store.save(settings, identity: nextId);
    await libraryCache.clearFeeds().catchError((Object _) {
      store.warning = '目录快照清理未写入磁盘，其他设置已保存。';
    });
    _cache.cancelBackground();
    _rebuildClients();
  }

  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) {
    final lease = _cache.prepare(
      vid,
      quality: quality,
      background: background,
      onProgress: (p) {
        final label = switch (p.stage) {
          MediaStage.queued => '正在排队',
          MediaStage.resolving => '正在获取片源',
          MediaStage.downloading => '正在下载',
          MediaStage.decrypting => '正在处理视频',
          MediaStage.validating => '即将播放',
          MediaStage.ready => '已就绪',
        };
        onProgress?.call(PreparationProgress(label, p.fraction));
      },
    );
    unawaited(
      lease.result
          .then((_) async {
            final detail = await libraryCache.detailForVideo(vid);
            if (detail != null) await _artwork.ensure(detail.drama);
          })
          .catchError((Object _) {}),
    );
    return _NativeJob(lease, _cache);
  }

  @override
  Future<void> evict(String vid, {String quality = 'best'}) =>
      _cache.evict(vid, quality: quality);
  @override
  PlaybackJob prepareLocal(String vid, {String quality = 'best'}) =>
      _NativeJob(_cache.prepareCached(vid, quality: quality), _cache);

  @override
  Future<void> rememberDrama(DramaDetail detail) async {
    await libraryCache.rememberDetail(detail);
    final cached = await _cache.entries();
    if (cached.any(
      (e) => detail.episodes.any((episode) => episode.vid == e.vid),
    )) {
      final merged = await libraryCache.readDetail(detail.drama.id);
      if (merged != null) await _artwork.ensure(merged.drama);
    }
  }

  @override
  Future<List<LocalEpisode>> localEpisodes() async {
    final entries = await _cache.entries();
    final details = await libraryCache.detailsForVideos(
      entries.map((e) => e.vid),
    );
    final covers = <String, String?>{};
    final result = <LocalEpisode>[];
    for (final e in entries) {
      final detail = details[e.vid];
      result.add(
        LocalEpisode(
          vid: e.vid,
          quality: e.quality,
          bytes: e.bytes,
          modified: e.modified,
          inUse: e.inUse,
          detail: detail,
          coverPath: detail == null
              ? null
              : covers.putIfAbsent(
                  detail.drama.id,
                  () => _artwork.lookup(detail.drama),
                ),
        ),
      );
    }
    return result;
  }

  @override
  Future<int> cacheBytes() => _cache.cacheBytes();
  @override
  Future<void> clearCache() => _cache.clear();
  @override
  Future<void> dispose() async {
    _cache.close();
    _artwork.close();
    _dio.close(force: true);
    await _settingsEvents.close();
  }
}

class _NativeJob implements PlaybackJob {
  final MediaPreparation lease;
  final MediaCache cache;
  _NativeJob(this.lease, this.cache);
  @override
  Future<String> get source =>
      lease.result.then((path) => File(path).uri.toString());
  @override
  void cancel() => lease.cancel();
  @override
  void release() => cache.release(lease);
}
