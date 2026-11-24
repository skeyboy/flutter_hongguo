import '../downloads/download_manager.dart';
import '../merge/merge_manager.dart';
import '../merge/merge_transcode.dart';
import '../merge/merged_library.dart';
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

import '../settings/settings_store.dart';
import 'background/native_downloads.dart';
import 'data_root.dart';
import '../catalog/library_cache.dart';
import '../catalog/artwork_cache_native.dart';
import '../settings/settings_store_native.dart';
import 'runtime_contract.dart';

Future<AppRuntime> createRuntime() async {
  final dataRoot = await currentDataRoot();
  final root = dataRoot.root;
  await root.create(recursive: true);
  final identity = File('${root.path}/device-id.txt');
  var id = await identity.exists()
      ? (await identity.readAsString()).trim()
      : '';
  if (!RegExp(r'^\d{10,20}$').hasMatch(id)) {
    id = newCatalogDeviceId();
    await identity.writeAsString(id, flush: true);
  }
  final store = SettingsStore(
    backend: FilePreferencesBackend(File('${root.path}/settings.json')),
    vault: SystemSessionVault(),
    deviceId: id,
  );
  await store.load();
  // 缓存目录单独配置：解析一次，运行期不变；无效路径回退到数据根下的
  // media-cache，避免设置写错后整个 App 起不来。
  Directory? configuredCache;
  final wanted = store.settings.cacheDir;
  if (wanted.isNotEmpty) {
    try {
      final candidate = Directory(wanted);
      if (candidate.isAbsolute) {
        await candidate.create(recursive: true);
        configuredCache = candidate;
      }
    } catch (_) {
      store.warning = '缓存目录无法使用，已回退到应用数据目录；请在设置中重新选择。';
    }
  }
  final runtime = NativeRuntime(
    root,
    store,
    cacheDirectory: configuredCache,
    portableMode: dataRoot.portable,
  );
  try {
    await runtime.downloads.load();
    if (store.settings.backgroundDownloads) await runtime.restoreDownloads();
    await runtime.downloads.reconcile();
  } catch (_) {
    store.warning = '手动下载记录暂时不可用，请在下载管理中重试；已保留现有文件。';
  }
  try {
    // Merge journals are read before the queue shows anything: a product that
    // reached disk is finished work, and a cut that never published is redone.
    await runtime.merges.reconcile();
  } catch (_) {
    store.warning = '合成记录暂时不可用，请在合并资源页重试；已保留现有文件。';
  }
  runtime.downloads.attachLifecycle();
  runtime.merges.attachLifecycle();
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
        MergeRuntime,
        TransferLaneRuntime,
        PlaybackDiagnosticsRuntime {
  final SettingsStore store;
  @override
  late final DownloadManager downloads;
  @override
  late final MergeManager merges;
  @override
  late final MergedLibrary mergedLibrary;
  @override
  late final PersonalLibrary personalLibrary;
  @override
  late final SearchHistory searchHistory;
  @override
  late final LibraryCache libraryCache;
  final _settingsEvents = StreamController<AppSettings>.broadcast();
  final Dio _dio = Dio();

  /// The one registration lane, shared by every client rebuild. The player
  /// endpoint answers a registered identity once per window and soft-blocks
  /// replays, so each ask registers a fresh pair rather than reusing one.
  late final PlaybackDeviceRegistry _playbackDevices;
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

  /// 多源路由门面：上层只认 CatalogRepository，来源分派在门面内完成。
  /// P0 只有红果适配器，方法委托 primary，行为与旧 CatalogClient 一致。
  late RoutingCatalogRepository _routingCatalog;

  /// 取址路由：vid 自带来源前缀，红果走旧 VideoModelClient（保留 preferApp
  /// 的官网/App 分层），第三方源走各自适配器的明文取址。
  late SourceRegistry _sourceRegistry;

  /// 自定义源在途请求注册表：设置变更时撤销旧源请求（配置热变更防护）。
  final CancelTokenRegistry _customTokens = CancelTokenRegistry();

  Future<VideoTrack> _resolveTrack(String vid, String quality) async {
    final adapter = _sourceRegistry.forId(vid);
    if (adapter == null || adapter.id == 'hongguo') {
      return _model.fetchTrack(
        vid,
        quality: quality,
        preferApp: settings.progressivePlayback && !tvBuild,
      );
    }
    return adapter.fetchTrack(vid, quality: quality);
  }

  /// Answers kept per vid across client rebuilds, so a settings change in the
  /// middle of a batch cannot make the rest of the queue re-register and
  /// re-ask for episodes the upstream already answered for.
  final _videoInfo = <String, PlaybackInfoEntry>{};
  late final MediaCache _cache;
  late final NativeDownloads _downloads;
  final _retained = <String>{};
  late final ArtworkCache _artwork;

  /// Resolved once at startup. A cache-directory setting change is picked up
  /// on the next launch, so running leases and the download journal never
  /// disagree about where a published file lives.
  final Directory cacheDirectory;

  /// True when data is kept next to the executable (portable ZIP).
  final bool portableMode;

  NativeRuntime(
    Directory root,
    this.store, {
    Directory? cacheDirectory,
    this.portableMode = false,
  }) : cacheDirectory =
           cacheDirectory ?? Directory('${root.path}/media-cache') {
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
    _playbackDevices = PlaybackDeviceRegistry(dio: _dio);
    _rebuildClients();
    _downloads = NativeDownloads(
      () => tvBuild ? settings.copyWith(backgroundDownloads: false) : settings,
      _dio,
      journalDirectory: Directory('${root.path}/download-journal'),
      cacheDirectory: this.cacheDirectory,
    );
    _cache = MediaCache(
      directory: this.cacheDirectory,
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
      onEvict: (vid, quality) => _videoInfo.remove(vid),
      progressivePlayback: () => settings.progressivePlayback && !tvBuild,
      // 渐进通道只吃带 CENC 的分片：官网直链是明文 MP4，得整段下完才能播，
      // 开着「边下边看」时它反而是慢的那条路，让 App 层先答。
      resolve: _resolveTrack,
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
    mergedLibrary = MergedLibrary(Directory('${root.path}/merged'));
    merges = MergeManager(
      backend: FilePreferencesBackend(File('${root.path}/merge-tasks.json')),
      library: mergedLibrary,
      journals: Directory('${root.path}/merge-journal'),
      sourcePath: mediaPath,
      mobile: Platform.isAndroid || Platform.isIOS,
      television: tvBuild,
      // 兼容合成 needs a native H.264 encoder. On a desktop the viewer may already
      // have one on PATH, and the lane probes for it; on a phone the FFmpeg build
      // itself would have to ship inside the app, which is the native step still
      // open in the design (docs/design/video-merge.md, 二期设计).
      transcoder: Platform.isWindows || Platform.isLinux || Platform.isMacOS
          ? FfmpegTranscoder()
          : const UnavailableTranscoder(reason: '手机端暂未内置 ffmpeg，请改用无损合成'),
    );
  }

  /// The published media-cache file for one episode. A merge reads exactly what
  /// the media lane validated, so it is addressed the same way everywhere.
  @override
  String mediaPath(String vid, String quality) =>
      '${_cache.directory.path}/${vid}_$quality.mp4';
  Future<void> restoreDownloads() async {
    try {
      await _downloads.restore(_cache.adoptDownloaded);
    } catch (_) {
      store.warning = '后台任务恢复暂未完成，进入应用后可重试缓存。';
    }
  }

  @override
  CatalogRepository get catalog => _routingCatalog;
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
      devices: _playbackDevices,
      builder: VideoRequestBuilder(protocol: settings),
      info: _videoInfo,
    );
    // 注册表在每次客户端重建时按当前设置重新装配：P0 清单只有红果，
    // 但设置变更带来的 sources 改动将自然在下一次重建生效。
    // 自定义源配置变更前先撤销其所有在途请求，避免热变更期间旧配置继续发请求。
    for (final config in settings.sources.customSources) {
      _customTokens.cancel(config.uuid);
    }
    final registry = SourceRegistry(
      defaultSourceFactories(
        catalog: () => _catalog,
        model: () => _model,
        dio: () => _dio,
      ),
      settings.sources,
      expansiveFactories: [
        (sourceSettings) => customSourceAdapters(
          dio: () => _dio,
          currentSources: () => this.settings.sources.customSources,
          tokens: _customTokens,
        ),
      ],
    );
    _sourceRegistry = registry;
    _routingCatalog = RoutingCatalogRepository(
      registry: registry,
      primary: _catalog,
      rank: _catalog,
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
    final nextId = newCatalogDeviceId();
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

  /// A merged product lives outside the media cache, in the library's own
  /// directory: the player gets the file it already has, with nothing to pin.
  @override
  PlaybackJob prepareMerged(String mergeId) {
    final path = mergedLibrary.pathFor(mergeId);
    return File(path).existsSync()
        ? _MergedJob(File(path).uri.toString())
        : _MergedJob(null);
  }

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
  Future<void> clearCache() async {
    await _cache.clear();
    _videoInfo.clear();
  }

  @override
  Future<void> dispose() async {
    await downloads.shutdown();
    downloads.dispose();
    await merges.shutdown();
    merges.dispose();
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

class _NativeJob implements PlaybackJob, EarlyPlayableJob {
  final MediaPreparation lease;
  final MediaCache cache;
  _NativeJob(this.lease, this.cache);
  @override
  Future<String> get source =>
      lease.result.then((path) => File(path).uri.toString());

  /// Already a URL: the loopback origin serves the prefix this job is still
  /// writing, so the player opens it as-is instead of as a file path.
  @override
  Future<String?> get earlySource => lease.early;
  @override
  void cancel() => lease.cancel();
  @override
  void release() => cache.release(lease);
}

/// A merged product, already a plain file on disk: no lease, no progress, and
/// the player's own error path reports the one case that can fail -- the file
/// was removed between the list opening and the tap.
class _MergedJob implements PlaybackJob {
  final String? uri;
  _MergedJob(this.uri);
  @override
  Future<String> get source => uri == null
      ? Future.error(StateError('合并资源已不存在，请重新合成'))
      : Future.value(uri);
  @override
  void cancel() {}
  @override
  void release() {}
}
