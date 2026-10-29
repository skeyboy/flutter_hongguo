/// Preferences shared by native runtimes. Secret session data is stored separately.
class AppSettings {
  final bool prefetchEnabled, autoNext, autoLoadMore, signLists;
  final bool backgroundPlayback,
      backgroundDownloads,
      floatingPlayback,
      backgroundWifiOnly;
  final bool backgroundPlaybackPrompted,
      floatingPlaybackPrompted,
      episodeSwipeHintShown;
  final int tvPageSize;
  final String catalogSort;

  /// Release checks: the switch, the tag the user dismissed with 忽略本次更新,
  /// and when a check last ran (epoch milliseconds, 0 for "never").
  final bool updateChecksEnabled;
  final String ignoredUpdateVersion;
  final int lastUpdateCheckAt;

  /// The feed's `ETag`, so a user who is already current costs the anonymous
  /// quota nothing but a 304.
  final String updateFeedEtag;
  final int prefetchEpisodes,
      maxCacheFiles,
      maxCacheMb,
      concurrentPreparations,
      downloadConcurrent,
      timeoutSeconds;
  final String themeMode,
      defaultQuality,
      apiHost,
      videoHost,
      catalogVersion,
      catalogVersionCode,
      videoVersion,
      videoVersionCode,
      videoUserAgent;
  static const defaultVideoUserAgent =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';
  const AppSettings({
    this.catalogSort = 'hot_score',
    this.tvPageSize = 30,
    this.backgroundPlayback = false,
    this.backgroundDownloads = false,
    this.floatingPlayback = false,
    this.backgroundWifiOnly = true,
    this.backgroundPlaybackPrompted = false,
    this.floatingPlaybackPrompted = false,
    this.episodeSwipeHintShown = false,
    this.prefetchEnabled = true,
    this.prefetchEpisodes = 3,
    this.autoNext = true,
    this.autoLoadMore = true,
    this.themeMode = 'system',
    this.defaultQuality = 'best',
    this.maxCacheFiles = 30,
    this.maxCacheMb = 512,
    this.concurrentPreparations = 2,
    this.downloadConcurrent = 1,
    this.timeoutSeconds = 60,
    this.signLists = true,
    this.apiHost = 'api5-normal-sinfonlinea.fqnovel.com',
    this.videoHost = 'api5-normal-sinfonlineb.fqnovel.com',
    this.catalogVersion = '7.2.2.32',
    this.catalogVersionCode = '72232',
    this.videoVersion = '7.1.3.32',
    this.videoVersionCode = '71332',
    this.videoUserAgent = defaultVideoUserAgent,
    this.updateChecksEnabled = true,
    this.ignoredUpdateVersion = '',
    this.lastUpdateCheckAt = 0,
    this.updateFeedEtag = '',
  });

  Map<String, dynamic> protocolJson() => {
    'apiHost': apiHost,
    'videoHost': videoHost,
    'catalogVersion': catalogVersion,
    'catalogVersionCode': catalogVersionCode,
    'videoVersion': videoVersion,
    'videoVersionCode': videoVersionCode,
    'videoUserAgent': videoUserAgent,
    'signLists': signLists,
    'timeoutSeconds': timeoutSeconds,
  };
  Map<String, dynamic> toJson() => {
    ...protocolJson(),
    'backgroundPlayback': backgroundPlayback,
    'backgroundDownloads': backgroundDownloads,
    'floatingPlayback': floatingPlayback,
    'backgroundWifiOnly': backgroundWifiOnly,
    'backgroundPlaybackPrompted': backgroundPlaybackPrompted,
    'floatingPlaybackPrompted': floatingPlaybackPrompted,
    'episodeSwipeHintShown': episodeSwipeHintShown,
    'prefetchEnabled': prefetchEnabled,
    'prefetchEpisodes': prefetchEpisodes,
    'autoNext': autoNext,
    'autoLoadMore': autoLoadMore,
    'catalogSort': catalogSort,
    'tvPageSize': tvPageSize,
    'themeMode': themeMode,
    'defaultQuality': defaultQuality,
    'maxCacheFiles': maxCacheFiles,
    'maxCacheMb': maxCacheMb,
    'concurrentPreparations': concurrentPreparations,
    'downloadConcurrent': downloadConcurrent,
    'updateChecksEnabled': updateChecksEnabled,
    'ignoredUpdateVersion': ignoredUpdateVersion,
    'lastUpdateCheckAt': lastUpdateCheckAt,
    'updateFeedEtag': updateFeedEtag,
  };
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const defaults = AppSettings();
    T read<T>(String key, T fallback) =>
        json[key] is T ? json[key] as T : fallback;
    return AppSettings(
      catalogSort: read('catalogSort', defaults.catalogSort),
      tvPageSize: read('tvPageSize', defaults.tvPageSize),
      backgroundPlayback: read(
        'backgroundPlayback',
        defaults.backgroundPlayback,
      ),
      backgroundDownloads: read(
        'backgroundDownloads',
        defaults.backgroundDownloads,
      ),
      floatingPlayback: read('floatingPlayback', defaults.floatingPlayback),
      backgroundPlaybackPrompted: read('backgroundPlaybackPrompted', false),
      floatingPlaybackPrompted: read('floatingPlaybackPrompted', false),
      episodeSwipeHintShown: read('episodeSwipeHintShown', false),
      backgroundWifiOnly: read(
        'backgroundWifiOnly',
        defaults.backgroundWifiOnly,
      ),
      prefetchEnabled: read('prefetchEnabled', defaults.prefetchEnabled),
      prefetchEpisodes: read('prefetchEpisodes', defaults.prefetchEpisodes),
      autoNext: read('autoNext', defaults.autoNext),
      autoLoadMore: read('autoLoadMore', defaults.autoLoadMore),
      themeMode: read('themeMode', defaults.themeMode),
      defaultQuality: read('defaultQuality', defaults.defaultQuality),
      maxCacheFiles: read('maxCacheFiles', defaults.maxCacheFiles),
      maxCacheMb: read('maxCacheMb', defaults.maxCacheMb),
      concurrentPreparations: read(
        'concurrentPreparations',
        defaults.concurrentPreparations,
      ),
      downloadConcurrent: read('downloadConcurrent', 1),
      timeoutSeconds: read('timeoutSeconds', defaults.timeoutSeconds),
      signLists: read('signLists', defaults.signLists),
      apiHost: read('apiHost', defaults.apiHost),
      videoHost: read('videoHost', defaults.videoHost),
      catalogVersion: read('catalogVersion', defaults.catalogVersion),
      catalogVersionCode: read(
        'catalogVersionCode',
        defaults.catalogVersionCode,
      ),
      videoVersion: read('videoVersion', defaults.videoVersion),
      videoVersionCode: read('videoVersionCode', defaults.videoVersionCode),
      videoUserAgent: read('videoUserAgent', defaults.videoUserAgent),
      updateChecksEnabled: read('updateChecksEnabled', true),
      ignoredUpdateVersion: read('ignoredUpdateVersion', ''),
      lastUpdateCheckAt: read('lastUpdateCheckAt', 0),
      updateFeedEtag: read('updateFeedEtag', ''),
    );
  }
  AppSettings copyWith({
    String? catalogSort,
    int? tvPageSize,
    bool? backgroundPlayback,
    bool? backgroundDownloads,
    bool? floatingPlayback,
    bool? backgroundWifiOnly,
    bool? backgroundPlaybackPrompted,
    bool? floatingPlaybackPrompted,
    bool? episodeSwipeHintShown,
    bool? prefetchEnabled,
    int? prefetchEpisodes,
    bool? autoNext,
    bool? autoLoadMore,
    String? themeMode,
    String? defaultQuality,
    int? maxCacheFiles,
    int? maxCacheMb,
    int? concurrentPreparations,
    int? downloadConcurrent,
    int? timeoutSeconds,
    bool? signLists,
    String? apiHost,
    String? videoHost,
    String? catalogVersion,
    String? catalogVersionCode,
    String? videoVersion,
    String? videoVersionCode,
    String? videoUserAgent,
    bool? updateChecksEnabled,
    String? ignoredUpdateVersion,
    int? lastUpdateCheckAt,
    String? updateFeedEtag,
  }) => AppSettings.fromJson({
    ...toJson(),
    'catalogSort': catalogSort ?? this.catalogSort,
    'tvPageSize': tvPageSize ?? this.tvPageSize,
    'backgroundPlayback': backgroundPlayback ?? this.backgroundPlayback,
    'backgroundDownloads': backgroundDownloads ?? this.backgroundDownloads,
    'floatingPlayback': floatingPlayback ?? this.floatingPlayback,
    'backgroundWifiOnly': backgroundWifiOnly ?? this.backgroundWifiOnly,
    'backgroundPlaybackPrompted':
        backgroundPlaybackPrompted ?? this.backgroundPlaybackPrompted,
    'floatingPlaybackPrompted':
        floatingPlaybackPrompted ?? this.floatingPlaybackPrompted,
    'episodeSwipeHintShown':
        episodeSwipeHintShown ?? this.episodeSwipeHintShown,
    'prefetchEnabled': prefetchEnabled ?? this.prefetchEnabled,
    'prefetchEpisodes': prefetchEpisodes ?? this.prefetchEpisodes,
    'autoNext': autoNext ?? this.autoNext,
    'autoLoadMore': autoLoadMore ?? this.autoLoadMore,
    'themeMode': themeMode ?? this.themeMode,
    'defaultQuality': defaultQuality ?? this.defaultQuality,
    'maxCacheFiles': maxCacheFiles ?? this.maxCacheFiles,
    'maxCacheMb': maxCacheMb ?? this.maxCacheMb,
    'concurrentPreparations':
        concurrentPreparations ?? this.concurrentPreparations,
    'downloadConcurrent': downloadConcurrent ?? this.downloadConcurrent,
    'timeoutSeconds': timeoutSeconds ?? this.timeoutSeconds,
    'signLists': signLists ?? this.signLists,
    'apiHost': apiHost ?? this.apiHost,
    'videoHost': videoHost ?? this.videoHost,
    'catalogVersion': catalogVersion ?? this.catalogVersion,
    'catalogVersionCode': catalogVersionCode ?? this.catalogVersionCode,
    'videoVersion': videoVersion ?? this.videoVersion,
    'videoVersionCode': videoVersionCode ?? this.videoVersionCode,
    'videoUserAgent': videoUserAgent ?? this.videoUserAgent,
    'updateChecksEnabled': updateChecksEnabled ?? this.updateChecksEnabled,
    'ignoredUpdateVersion': ignoredUpdateVersion ?? this.ignoredUpdateVersion,
    'lastUpdateCheckAt': lastUpdateCheckAt ?? this.lastUpdateCheckAt,
    'updateFeedEtag': updateFeedEtag ?? this.updateFeedEtag,
  });
  void validate() {
    if (!['online_time', 'hot_score', 'hot_collect'].contains(catalogSort)) {
      throw const FormatException('目录排序无效');
    }
    if (![30, 50].contains(tvPageSize)) {
      throw const FormatException('TV 每页条数应为 30 或 50');
    }
    if (prefetchEpisodes < 3 || prefetchEpisodes > 5) {
      throw const FormatException('预缓存集数应为 3～5 集');
    }
    if (maxCacheFiles < 10 || maxCacheFiles > 200) {
      throw const FormatException('缓存数量应为 10～200 集');
    }
    if (maxCacheMb < 128 || maxCacheMb > 4096) {
      throw const FormatException('缓存空间应为 128～4096 MB');
    }
    if (concurrentPreparations < 1 || concurrentPreparations > 3) {
      throw const FormatException('同时准备数量应为 1～3');
    }
    if (downloadConcurrent < 1 || downloadConcurrent > 5) {
      throw const FormatException('同时下载数量应为 1～5');
    }
    if (timeoutSeconds < 10 || timeoutSeconds > 120) {
      throw const FormatException('请求超时应为 10～120 秒');
    }
    if (!['system', 'light', 'dark'].contains(themeMode)) {
      throw const FormatException('主题模式无效');
    }
    if (!['best', '720p', '1080p'].contains(defaultQuality)) {
      throw const FormatException('默认清晰度无效');
    }
    for (final host in [apiHost, videoHost]) {
      final uri = Uri.tryParse('https://$host');
      if (uri == null ||
          uri.host != host ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          ![
            'fqnovel.com',
            'snssdk.com',
          ].any((d) => host == d || host.endsWith('.$d'))) {
        throw const FormatException(
          '接口域名需为 fqnovel.com 或 snssdk.com 的合法子域，不包含协议或路径',
        );
      }
    }
    for (final version in [catalogVersion, videoVersion]) {
      if (!RegExp(r'^\d+(?:\.\d+){1,4}$').hasMatch(version)) {
        throw const FormatException('版本号格式应类似 7.1.3.32');
      }
    }
    for (final code in [catalogVersionCode, videoVersionCode]) {
      if (!RegExp(r'^\d{1,10}$').hasMatch(code)) {
        throw const FormatException('版本代码需为数字');
      }
    }
    if (ignoredUpdateVersion.length > 40 ||
        RegExp(r'[\r\n]').hasMatch(ignoredUpdateVersion)) {
      throw const FormatException('已忽略的版本号无效');
    }
    if (lastUpdateCheckAt < 0) {
      throw const FormatException('上次检查更新的时间无效');
    }
    if (updateFeedEtag.length > 120 ||
        RegExp(r'[\r\n]').hasMatch(updateFeedEtag)) {
      throw const FormatException('更新接口的缓存标识无效');
    }
    if (videoUserAgent.trim().isEmpty ||
        RegExp(r'[\r\n]').hasMatch(videoUserAgent)) {
      throw const FormatException('User-Agent 无效');
    }
  }
}

class SessionCredentials {
  final String cookie, ttToken;
  const SessionCredentials({this.cookie = '', this.ttToken = ''});
  bool get isEmpty => cookie.isEmpty && ttToken.isEmpty;
  Map<String, String> get headers => {
    if (cookie.isNotEmpty) 'cookie': cookie,
    if (ttToken.isNotEmpty) 'x-tt-token': ttToken,
  };
  Map<String, dynamic> toJson() => {'cookie': cookie, 'ttToken': ttToken};
  factory SessionCredentials.fromJson(Map<String, dynamic> json) =>
      SessionCredentials(
        cookie: json['cookie'] is String ? json['cookie'] as String : '',
        ttToken: json['ttToken'] is String ? json['ttToken'] as String : '',
      );
  void validate() {
    if (RegExp(r'[\r\n]').hasMatch(cookie + ttToken)) {
      throw const FormatException('会话凭据不能包含换行');
    }
  }
}
