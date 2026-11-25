import '../crypto/bytes.dart';
import '../crypto/media_url.dart';

/// 详情取源顺序。默认官网优先，保住现有缓存快照与红果测试行为；`appFirst`
/// 对齐 Android 的 App 接口优先，但只作为显式开关，不默认启用。
enum DetailSourceOrder { webFirst, appFirst }

/// 播放设备身份策略。`freshPerAsk` 是 Flutter 现状，也与 Android
/// `PlaybackDevice.java` 一致；`reuseOnSuccess` 对应 `AppSource` 的成功复用路径，
/// 需真网 A/B 后才开放。
enum PlaybackIdentityPolicy { freshPerAsk, reuseOnSuccess }

/// 播放路由集合。默认 `extended`；`current` 仅保留旧三层用于显式兼容。
enum PlaybackRouteSet { current, extended }

DetailSourceOrder _readDetailSourceOrder(Object? value) => value == 'appFirst'
    ? DetailSourceOrder.appFirst
    : DetailSourceOrder.webFirst;

PlaybackIdentityPolicy _readIdentityPolicy(Object? value) =>
    value == 'reuseOnSuccess'
    ? PlaybackIdentityPolicy.reuseOnSuccess
    : PlaybackIdentityPolicy.freshPerAsk;

PlaybackRouteSet _readPlaybackRouteSet(Object? value) =>
    value == 'current' ? PlaybackRouteSet.current : PlaybackRouteSet.extended;

/// Preferences shared by native runtimes. Secret session data is stored separately.
class AppSettings {
  final bool prefetchEnabled, autoNext, autoLoadMore, signLists;
  final bool backgroundPlayback,
      backgroundDownloads,
      floatingPlayback,
      backgroundWifiOnly;

  /// Play the decrypted prefix while the download is still running. Off by
  /// default: it needs a local origin, doubles the transient disk use of one
  /// episode, and can only help encrypted sources.
  final bool progressivePlayback;
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

  /// Where 导出 hands the merged file. Empty means 每次显式选择 —— the export panel
  /// always asks, and this only remembers the last answer as its starting place.
  final String mergeExportDir;

  /// Optional absolute path for the video cache. Empty means the app data
  /// directory's `media-cache` child. Changing it takes effect on next launch:
  /// the native runtime resolves its cache directory once, at construction.
  final String cacheDir;

  /// 多源开关与自定义源配置。默认全红果行为，老 JSON 缺字段时走默认值。
  final SourceSettings sources;

  /// 对齐 Android 的三项协议开关。默认官网优先、每次新身份、完整路由梯。
  final DetailSourceOrder detailSourceOrder;
  final PlaybackIdentityPolicy identityPolicy;
  final PlaybackRouteSet playbackRouteSet;
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
    this.progressivePlayback = false,
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
    this.mergeExportDir = '',
    this.cacheDir = '',
    this.updateChecksEnabled = true,
    this.ignoredUpdateVersion = '',
    this.lastUpdateCheckAt = 0,
    this.updateFeedEtag = '',
    this.sources = const SourceSettings(),
    this.detailSourceOrder = DetailSourceOrder.webFirst,
    this.identityPolicy = PlaybackIdentityPolicy.freshPerAsk,
    this.playbackRouteSet = PlaybackRouteSet.extended,
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
    'detailSourceOrder': detailSourceOrder.name,
    'identityPolicy': identityPolicy.name,
    'playbackRouteSet': playbackRouteSet.name,
  };
  Map<String, dynamic> toJson() => {
    ...protocolJson(),
    'backgroundPlayback': backgroundPlayback,
    'backgroundDownloads': backgroundDownloads,
    'floatingPlayback': floatingPlayback,
    'backgroundWifiOnly': backgroundWifiOnly,
    'progressivePlayback': progressivePlayback,
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
    'mergeExportDir': mergeExportDir,
    'cacheDir': cacheDir,
    'updateChecksEnabled': updateChecksEnabled,
    'ignoredUpdateVersion': ignoredUpdateVersion,
    'lastUpdateCheckAt': lastUpdateCheckAt,
    'updateFeedEtag': updateFeedEtag,
    'sources': sources.toJson(),
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
      progressivePlayback: read(
        'progressivePlayback',
        defaults.progressivePlayback,
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
      mergeExportDir: read('mergeExportDir', ''),
      cacheDir: read('cacheDir', ''),
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
      detailSourceOrder: _readDetailSourceOrder(json['detailSourceOrder']),
      identityPolicy: _readIdentityPolicy(json['identityPolicy']),
      playbackRouteSet: _readPlaybackRouteSet(json['playbackRouteSet']),
      // 老 JSON 没有 sources，或字段类型被写坏，都回退默认值。
      sources: json['sources'] is Map
          ? SourceSettings.fromJson(
              Map<String, dynamic>.from(json['sources'] as Map),
            )
          : const SourceSettings(),
    );
  }
  AppSettings copyWith({
    String? catalogSort,
    int? tvPageSize,
    bool? backgroundPlayback,
    bool? backgroundDownloads,
    bool? floatingPlayback,
    bool? backgroundWifiOnly,
    bool? progressivePlayback,
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
    String? mergeExportDir,
    String? cacheDir,
    bool? updateChecksEnabled,
    String? ignoredUpdateVersion,
    int? lastUpdateCheckAt,
    String? updateFeedEtag,
    SourceSettings? sources,
    DetailSourceOrder? detailSourceOrder,
    PlaybackIdentityPolicy? identityPolicy,
    PlaybackRouteSet? playbackRouteSet,
  }) => AppSettings.fromJson({
    ...toJson(),
    'catalogSort': catalogSort ?? this.catalogSort,
    'tvPageSize': tvPageSize ?? this.tvPageSize,
    'backgroundPlayback': backgroundPlayback ?? this.backgroundPlayback,
    'backgroundDownloads': backgroundDownloads ?? this.backgroundDownloads,
    'floatingPlayback': floatingPlayback ?? this.floatingPlayback,
    'backgroundWifiOnly': backgroundWifiOnly ?? this.backgroundWifiOnly,
    'progressivePlayback': progressivePlayback ?? this.progressivePlayback,
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
    'mergeExportDir': mergeExportDir ?? this.mergeExportDir,
    'cacheDir': cacheDir ?? this.cacheDir,
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
    'sources': (sources ?? this.sources).toJson(),
    'detailSourceOrder': (detailSourceOrder ?? this.detailSourceOrder).name,
    'identityPolicy': (identityPolicy ?? this.identityPolicy).name,
    'playbackRouteSet': (playbackRouteSet ?? this.playbackRouteSet).name,
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
    if (mergeExportDir.length > 1024 ||
        RegExp(r'[\r\n\u0000]').hasMatch(mergeExportDir)) {
      throw const FormatException('导出目录无效');
    }
    if (cacheDir.length > 1024 || RegExp(r'[\r\n\u0000]').hasMatch(cacheDir)) {
      throw const FormatException('缓存目录无效');
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
    sources.validate();
  }
}

/// 用户手动添加的片源。url 在配置期就过公网校验，运行期逐跳再校验一次。
class CustomSourceConfig {
  final String uuid; // UUID v4
  final String name; // 1–40 字
  final String url; // https、无凭据、公网
  final bool enabled;

  const CustomSourceConfig({
    this.uuid = '',
    this.name = '',
    this.url = '',
    this.enabled = false,
  });

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'name': name,
    'url': url,
    'enabled': enabled,
  };

  factory CustomSourceConfig.fromJson(Map<String, dynamic> json) {
    String read(String key) => json[key] is String ? json[key] as String : '';
    return CustomSourceConfig(
      uuid: read('uuid'),
      name: read('name'),
      url: read('url'),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : false,
    );
  }
}

/// 新增自定义片源时生成 RFC 4122 v4 UUID（设置页与测试共用）。
String newSourceUuid() {
  final bytes = secureBytes(16);
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final value = hex(bytes);
  return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
      '${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}';
}

/// 内置源开关 + 自定义源列表。hongguo 不可关闭，其余按表或逐条 enabled。
class SourceSettings {
  static const _defaultBuiltin = <String, bool>{
    'hongguo': true,
    'xifan': true,
    'hema': true,
    'reelshort': false,
    'dramabox': false,
  };

  final Map<String, bool> builtin;
  final List<CustomSourceConfig> customSources;

  const SourceSettings({
    this.builtin = _defaultBuiltin,
    this.customSources = const [],
  });

  /// 路由与 UI 共用的唯一判定入口：历史纯数字 ID 未知时按未启用处理。
  bool isEnabled(String sourceId) {
    if (sourceId == 'hongguo') return true;
    if (sourceId.startsWith('custom:')) {
      final uuid = sourceId.substring('custom:'.length);
      for (final config in customSources) {
        if (config.uuid == uuid) return config.enabled;
      }
      return false;
    }
    return builtin[sourceId] ?? false;
  }

  /// 除红果外是否还有其它启用来源。限免/锁定标记的收敛判据：有备选来源
  /// 时不展示「限免外」样式（点击失败会走跨源解析兜底），单源时如实标注。
  bool get hasAlternativeSources =>
      customSources.any((config) => config.enabled) ||
      builtin.entries.any((entry) => entry.key != 'hongguo' && entry.value);

  /// 内置源开关（hongguo 不可关，守门在此，UI 无需重复判断）。
  SourceSettings withBuiltin(String sourceId, bool enabled) {
    if (sourceId == 'hongguo') return this;
    return SourceSettings(
      builtin: {...builtin, sourceId: enabled},
      customSources: customSources,
    );
  }

  /// 新增或替换一条自定义源（按 uuid）。返回新实例，交给 AppSettings.copyWith
  /// 与 settings_store 事务持久化。
  SourceSettings upsertCustom(CustomSourceConfig config) {
    final next = List<CustomSourceConfig>.from(customSources);
    final index = next.indexWhere((item) => item.uuid == config.uuid);
    if (index >= 0) {
      next[index] = config;
    } else {
      next.add(config);
    }
    return SourceSettings(builtin: builtin, customSources: next);
  }

  /// 按 uuid 删除一条自定义源。
  SourceSettings removeCustom(String uuid) => SourceSettings(
    builtin: builtin,
    customSources: customSources.where((item) => item.uuid != uuid).toList(),
  );

  /// 切换一条自定义源的启用态。
  SourceSettings toggleCustom(String uuid, bool enabled) {
    final index = customSources.indexWhere((item) => item.uuid == uuid);
    if (index < 0) return this;
    final next = List<CustomSourceConfig>.from(customSources);
    next[index] = CustomSourceConfig(
      uuid: next[index].uuid,
      name: next[index].name,
      url: next[index].url,
      enabled: enabled,
    );
    return SourceSettings(builtin: builtin, customSources: next);
  }

  Map<String, dynamic> toJson() => {
    'builtin': Map<String, bool>.from(builtin),
    'customSources': customSources.map((config) => config.toJson()).toList(),
  };

  factory SourceSettings.fromJson(Map<String, dynamic> json) {
    final builtin = Map<String, bool>.of(_defaultBuiltin);
    if (json['builtin'] is Map) {
      for (final entry in (json['builtin'] as Map).entries) {
        if (entry.key is String && entry.value is bool) {
          builtin[entry.key as String] = entry.value as bool;
        }
      }
    }
    final customSources = <CustomSourceConfig>[];
    if (json['customSources'] is List) {
      for (final item in json['customSources'] as List) {
        if (item is Map<String, dynamic>) {
          customSources.add(CustomSourceConfig.fromJson(item));
        } else if (item is Map) {
          customSources.add(
            CustomSourceConfig.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return SourceSettings(builtin: builtin, customSources: customSources);
  }

  void validate() {
    // hongguo 恒开：const 构造的 map 不可写，由 isEnabled 兜底。
    if (builtin['hongguo'] != true) {
      try {
        builtin['hongguo'] = true;
      } on UnsupportedError {
        // 不可变 map（如 const SourceSettings），isEnabled 已保证恒开。
      }
    }
    for (final config in customSources) {
      if (!RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
      ).hasMatch(config.uuid)) {
        throw const FormatException('自定义源 UUID 需为 v4 格式');
      }
      if (config.name.isEmpty ||
          config.name.length > 40 ||
          RegExp(r'[\r\n]').hasMatch(config.name)) {
        throw const FormatException('自定义源名称应为 1～40 字且不含换行');
      }
      if (config.url.length > 2000) {
        throw const FormatException('自定义源地址过长');
      }
      final uri = Uri.tryParse(config.url);
      if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
        throw const FormatException('自定义源地址需为 HTTPS 且不含凭据');
      }
      final reason = isPublicMediaUrl(uri);
      if (reason != null) {
        throw FormatException('自定义源地址无效：$reason');
      }
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
