import '../downloads/download_manager.dart';
import '../personal/personal_library.dart';
import '../search/search_history.dart';

import 'package:hongguo_api/hongguo_api.dart';

import '../catalog/library_cache.dart';

import 'package:hongguo_core/hongguo_core.dart';

class PreparationProgress {
  final String label;
  final double? fraction;
  final int received, total;
  const PreparationProgress(this.label, [this.fraction])
    : received = 0,
      total = 0;
  const PreparationProgress.bytes(
    this.label,
    this.fraction, {
    this.received = 0,
    this.total = 0,
  });
}

abstract interface class PlaybackJob {
  Future<String> get source;
  void cancel();
  void release();
}

/// Local startup metrics distinguish preparation from player opening; not first-frame timing.
class PlayerStartupTiming {
  final Duration preparation, open, elapsed;
  final String? failureType;
  const PlayerStartupTiming({
    required this.preparation,
    required this.open,
    required this.elapsed,
    this.failureType,
  });
}

abstract interface class PlaybackDiagnosticsRuntime implements AppRuntime {
  void recordPlayerStartup(PlayerStartupTiming value);
}

abstract interface class AppRuntime {
  CatalogRepository get catalog;
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  });
  Future<void> evict(String vid, {String quality = 'best'});
  Future<int> cacheBytes();
  Future<void> clearCache();
  Future<void> dispose();
}

abstract interface class VideoQualityRuntime implements AppRuntime {
  Future<List<VideoQuality>> videoQualities(String vid);
}

/// Native user configuration without imposing storage plugins on test/Web runtimes.
abstract interface class ConfigurableRuntime implements AppRuntime {
  AppSettings get settings;
  Stream<AppSettings> get settingsChanges;
  SessionCredentials get credentials;
  String get deviceId;
  String? get settingsWarning;
  Future<void> saveSettings(
    AppSettings value, {
    SessionCredentials? credentials,
  });
  Future<void> refreshSigning();
  Future<void> rotateDeviceIdentity();
}

AppSettings settingsFor(AppRuntime runtime) =>
    runtime is ConfigurableRuntime ? runtime.settings : const AppSettings();

class LocalEpisode {
  final String vid, quality;
  final int bytes;
  final DateTime modified;
  final bool inUse;
  final DramaDetail? detail;
  final String? coverPath;
  const LocalEpisode({
    required this.vid,
    required this.quality,
    required this.bytes,
    required this.modified,
    required this.inUse,
    this.detail,
    this.coverPath,
  });
  String get label {
    final data = detail;
    if (data == null) return '视频 $vid';
    final episode = data.episodes.where((e) => e.vid == vid).firstOrNull;
    return '${data.drama.title} · 第 ${episode?.index ?? "?"} 集';
  }
}

abstract interface class LibraryCacheRuntime implements AppRuntime {
  LibraryCache get libraryCache;
}

abstract interface class LocalMediaRuntime implements AppRuntime {
  PlaybackJob prepareLocal(String vid, {String quality = 'best'});
  Future<List<LocalEpisode>> localEpisodes();
}

Future<void> rememberDramaMetadata(AppRuntime runtime, DramaDetail detail) =>
    runtime is DramaMetadataRuntime
    ? runtime.rememberDrama(detail)
    : runtime is LibraryCacheRuntime
    ? runtime.libraryCache.rememberDetail(detail)
    : Future.value();

abstract interface class DramaMetadataRuntime implements AppRuntime {
  Future<void> rememberDrama(DramaDetail detail);
}

abstract interface class PersonalLibraryRuntime implements AppRuntime {
  PersonalLibrary get personalLibrary;
}

final _sessionLibraries = Expando<PersonalLibrary>();
PersonalLibrary personalLibraryFor(AppRuntime runtime) =>
    runtime is PersonalLibraryRuntime
    ? runtime.personalLibrary
    : (_sessionLibraries[runtime] ??= PersonalLibrary());

abstract interface class SearchHistoryRuntime implements AppRuntime {
  SearchHistory get searchHistory;
}

/// Runtimes without a preferences file keep recent searches for the session only.
final _sessionSearchHistory = Expando<SearchHistory>();
SearchHistory searchHistoryFor(AppRuntime runtime) =>
    runtime is SearchHistoryRuntime
    ? runtime.searchHistory
    : (_sessionSearchHistory[runtime] ??= SearchHistory());

abstract interface class DownloadRuntime implements LocalMediaRuntime {
  DownloadManager get downloads;
}

/// The media scheduler's own record of how many transfers it had in flight at
/// the same instant, per lane. Reading it beats polling the task list: a short
/// episode can start and finish between two samples, so a poll reports fewer
/// concurrent transfers than really ran.
abstract interface class TransferLaneRuntime implements AppRuntime {
  ({int manual, int automatic}) get transferLanePeaks;

  /// Starts a fresh measurement window. The peaks only mean something to a run
  /// that zeroes them before causing the traffic it wants to measure.
  void resetTransferLanePeaks();
}
