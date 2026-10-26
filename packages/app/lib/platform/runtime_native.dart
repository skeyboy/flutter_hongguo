import '../downloads/download_manager.dart';
import '../personal/personal_library.dart';
import '../search/search_history.dart';

import 'package:hongguo_tv/hongguo_tv.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_api/hongguo_native_api.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:path_provider/path_provider.dart';

import '../settings/settings_store.dart';
import 'background/native_downloads.dart';
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
  final runtime = NativeRuntime(root, store);
  try {
    await runtime.downloads.load();
    if (store.settings.backgroundDownloads) await runtime.restoreDownloads();
    await runtime.downloads.reconcile();
  } catch (_) {
    store.warning = '手动下载记录暂时不可用，请在下载管理中重试；已保留现有文件。';
  }
  runtime.downloads.attachLifecycle();
  return runtime;
}

class NativeRuntime
    implements
        ConfigurableRuntime,
        VideoQualityRuntime,
        LibraryCacheRuntime,
        LocalMediaRuntime,
        DramaMetadataRuntime,
        PersonalLibraryRuntime,
        SearchHistoryRuntime,
        DownloadRuntime,
        TransferLaneRuntime,
        PlaybackDiagnosticsRuntime {
  final SettingsStore store;
  @override
  late final DownloadManager downloads;
  @override
  late final PersonalLibrary personalLibrary;
  @override
  late final SearchHistory searchHistory;
  @override
  late final LibraryCache libraryCache;
  final _settingsEvents = StreamController<AppSettings>.broadcast();
  final Dio _dio = Dio();
  final _metadataTimings = <MetadataTiming>[];
  final _mediaTimings = <MediaPreparationTiming>[];
  final _playerTimings = <PlayerStartupTiming>[];
  List<MetadataTiming> get metadataTimings =>
      List.unmodifiable(_metadataTimings);
  List<MediaPreparationTiming> get mediaTimings =>
      List.unmodifiable(_mediaTimings);
  List<PlayerStartupTiming> get playerTimings =>
      List.unmodifiable(_playerTimings);
  void _retain<T>(List<T> records, T value) {
    records.add(value);
    if (records.length > 100) records.removeAt(0);
  }

  @override
  void recordPlayerStartup(PlayerStartupTiming value) =>
      _retain(_playerTimings, value);
  bool _clientsReady = false;
  late CatalogClient _catalog;
  late VideoModelClient _model;
  late final MediaCache _cache;
  late final NativeDownloads _downloads;
  final _retained = <String>{};
  late final ArtworkCache _artwork;
  NativeRuntime(Directory root, this.store) {
    personalLibrary = PersonalLibrary(
      backend: FilePreferencesBackend(
        File('${root.path}/personal-library.json'),
      ),
    );
    libraryCache = LibraryCache(
      backend: FilePreferencesBackend(File('${root.path}/library-cache.json')),
    );
    searchHistory = SearchHistory(
      backend: FilePreferencesBackend(File('${root.path}/search-history.json')),
    );
    _artwork = ArtworkCache(Directory('${root.path}/artwork-cache'));
    _rebuildClients();
    _downloads = NativeDownloads(
      () => tvBuild ? settings.copyWith(backgroundDownloads: false) : settings,
      _dio,
    );
    _cache = MediaCache(
      directory: Directory('${root.path}/media-cache'),
      dio: _dio,
      onTiming: (value) => _retain(_mediaTimings, value),
      download: _downloads.download,
      onJobFinished: (vid, quality, path) async {
        if (path != null) {
          await _downloads.finish(vid, quality, workingPath: path);
        }
      },
      maxFiles: settings.maxCacheFiles,
      maxBytes: settings.maxCacheMb * 1024 * 1024,
      maxConcurrent: tvBuild ? 1 : settings.concurrentPreparations,
      maxDownloadConcurrent: settings.downloadConcurrent,
      retainFile: (vid, quality) => downloads.retains(vid, quality),
      resolve: (vid, quality) => _model.fetchTrack(vid, quality: quality),
    );
    downloads = DownloadManager(
      backend: FilePreferencesBackend(
        File('${root.path}/episode-downloads.json'),
      ),
      settings: () =>
          tvBuild ? settings.copyWith(concurrentPreparations: 1) : settings,
      files: localEpisodes,
      remember: rememberDrama,
      mobile: Platform.isAndroid || Platform.isIOS,
      television: tvBuild,
      deleteFile: (vid, quality) => _cache.evict(vid, quality: quality),
      prepare: (task, progress) {
        final lease = _cache.prepare(
          task.episode.vid,
          quality: task.quality,
          background: true,
          manual: true,
          onProgress: (p) => progress(
            PreparationProgress.bytes(
              switch (p.stage) {
                MediaStage.queued => '正在排队',
                MediaStage.resolving => '正在获取片源',
                MediaStage.downloading => '正在下载',
                MediaStage.waitingNetwork => '等待 Wi-Fi 或网络',
                MediaStage.decrypting => '正在处理视频',
                MediaStage.validating => '正在校验',
                MediaStage.ready => '即将完成',
              },
              p.fraction,
              received: p.received,
              total: p.total,
            ),
          ),
        );
        unawaited(
          lease.result
              .then((_) => _artwork.ensure(task.drama))
              .catchError((Object _) {}),
        );
        return _NativeJob(lease, _cache);
      },
    );
  }
  Future<void> restoreDownloads() async {
    try {
      await _downloads.restore(_cache.adoptDownloaded);
    } catch (_) {
      store.warning = '后台任务恢复暂未完成，进入应用后可重试缓存。';
    }
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
    if (_clientsReady) {
      _catalog.close();
      _model.close();
    }
    _dio.options.connectTimeout = Duration(seconds: settings.timeoutSeconds);
    _catalog = CatalogClient(
      onTiming: (value) => _retain(_metadataTimings, value),
      browsePageSize: tvBuild ? settings.tvPageSize : 18,
      dio: _dio,
      deviceId: deviceId,
      protocol: settings,
      signLists: settings.signLists,
      sessionHeaders: credentials.headers,
    );
    _model = VideoModelClient(
      dio: _dio,
      onTiming: (value) => _retain(_metadataTimings, value),
      builder: VideoRequestBuilder(
        protocol: settings,
        sessionHeaders: credentials.headers,
      ),
    );
    _clientsReady = true;
  }

  @override
  Future<void> saveSettings(
    AppSettings value, {
    SessionCredentials? credentials,
  }) async {
    final oldTvPageSize = settings.tvPageSize;
    final changeDownloadPolicy =
        value.backgroundDownloads != settings.backgroundDownloads;
    final oldProtocol = jsonEncode(settings.protocolJson()),
        oldSession = jsonEncode(this.credentials.toJson());
    if (value.backgroundDownloads && !settings.backgroundDownloads) {
      await _downloads.initialize(requestNotification: true);
    }
    await store.save(value, session: credentials);
    if (changeDownloadPolicy) downloads.beginSettingsChange();
    try {
      if (changeDownloadPolicy && !value.backgroundDownloads) {
        await _downloads.cancel();
      }
      if (oldTvPageSize != settings.tvPageSize ||
          oldProtocol != jsonEncode(settings.protocolJson()) ||
          oldSession != jsonEncode(this.credentials.toJson())) {
        _cache.cancelBackground(keep: downloads.running);
        await libraryCache.clearFeeds().catchError((Object _) {
          store.warning = '目录快照清理未写入磁盘，其他设置已保存。';
        });
        _rebuildClients();
      }
      _settingsEvents.add(settings);
      if (!settings.prefetchEnabled) {
        _cache.cancelBackground(keep: downloads.running);
      }
      await _cache.configure(
        files: settings.maxCacheFiles,
        bytes: settings.maxCacheMb * 1024 * 1024,
        concurrency: tvBuild ? 1 : settings.concurrentPreparations,
        downloadConcurrency: settings.downloadConcurrent,
      );
    } finally {
      if (changeDownloadPolicy) {
        downloads.endSettingsChange();
      } else {
        downloads.policyChanged();
      }
    }
  }

  @override
  Future<void> refreshSigning() async {
    _cache.cancelBackground(keep: downloads.running);
    _rebuildClients();
  }

  @override
  Future<void> rotateDeviceIdentity() async {
    final nextId = VideoRequestBuilder.defaultDevice()['device_id']!;
    await store.save(settings, identity: nextId);
    await libraryCache.clearFeeds().catchError((Object _) {
      store.warning = '目录快照清理未写入磁盘，其他设置已保存。';
    });
    _cache.cancelBackground(keep: downloads.running);
    _rebuildClients();
  }

  @override
  ({int manual, int automatic}) get transferLanePeaks => (
    manual: _cache.peakManualTransfers,
    automatic: _cache.peakAutomaticTransfers,
  );

  @override
  void resetTransferLanePeaks() => _cache.resetPeakTransfers();

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
          MediaStage.waitingNetwork => '等待 Wi-Fi 或网络',
          MediaStage.decrypting => '正在处理视频',
          MediaStage.validating => '即将播放',
          MediaStage.ready => '已就绪',
        };
        onProgress?.call(PreparationProgress(label, p.fraction));
      },
    );
    if (background &&
        settings.backgroundDownloads &&
        _retained.length < settings.maxCacheFiles) {
      final key = '$vid:$quality';
      if (_retained.add(key)) {
        final retained = _cache.prepare(
          vid,
          quality: quality,
          background: true,
        );
        unawaited(
          retained.result
              .then<void>((_) {})
              .catchError((Object _) {})
              .whenComplete(() {
                _cache.release(retained);
                _retained.remove(key);
              }),
        );
      }
    }
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
  Future<void> evict(String vid, {String quality = 'best'}) async {
    final file = (await _cache.entries())
        .where((f) => f.vid == vid && f.quality == quality)
        .firstOrNull;
    if (file?.inUse == true) throw StateError('正在使用该视频，请结束播放后再删除');
    await _cache.evict(vid, quality: quality);
    if ((await _cache.entries()).any(
      (f) => f.vid == vid && f.quality == quality,
    )) {
      return;
    }
    await downloads.forget(vid, quality);
  }

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
  Future<List<VideoQuality>> videoQualities(String vid) =>
      _model.fetchQualities(vid);

  @override
  Future<int> cacheBytes() => _cache.cacheBytes();
  @override
  Future<void> clearCache() => _cache.clear();
  @override
  Future<void> dispose() async {
    await downloads.shutdown();
    downloads.dispose();
    await personalLibrary.flush();
    personalLibrary.dispose();
    await searchHistory.flush();
    _cache.close();
    _catalog.close();
    _model.close();
    await _downloads.cancel();
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
