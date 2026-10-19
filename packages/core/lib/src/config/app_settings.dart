/// Preferences shared by native runtimes. Secret session data is stored separately.
class AppSettings {
  final bool prefetchEnabled, autoNext, autoLoadMore, signLists;
  final int prefetchEpisodes,
      maxCacheFiles,
      maxCacheMb,
      concurrentPreparations,
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
    this.prefetchEnabled = true,
    this.prefetchEpisodes = 3,
    this.autoNext = true,
    this.autoLoadMore = true,
    this.themeMode = 'system',
    this.defaultQuality = 'best',
    this.maxCacheFiles = 30,
    this.maxCacheMb = 512,
    this.concurrentPreparations = 2,
    this.timeoutSeconds = 30,
    this.signLists = false,
    this.apiHost = 'api5-normal-sinfonlinea.fqnovel.com',
    this.videoHost = 'api5-normal-sinfonlineb.fqnovel.com',
    this.catalogVersion = '7.2.2.32',
    this.catalogVersionCode = '72232',
    this.videoVersion = '7.1.3.32',
    this.videoVersionCode = '71332',
    this.videoUserAgent = defaultVideoUserAgent,
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
    'prefetchEnabled': prefetchEnabled,
    'prefetchEpisodes': prefetchEpisodes,
    'autoNext': autoNext,
    'autoLoadMore': autoLoadMore,
    'themeMode': themeMode,
    'defaultQuality': defaultQuality,
    'maxCacheFiles': maxCacheFiles,
    'maxCacheMb': maxCacheMb,
    'concurrentPreparations': concurrentPreparations,
  };
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const defaults = AppSettings();
    T read<T>(String key, T fallback) =>
        json[key] is T ? json[key] as T : fallback;
    return AppSettings(
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
    );
  }
  AppSettings copyWith({
    bool? prefetchEnabled,
    int? prefetchEpisodes,
    bool? autoNext,
    bool? autoLoadMore,
    String? themeMode,
    String? defaultQuality,
    int? maxCacheFiles,
    int? maxCacheMb,
    int? concurrentPreparations,
    int? timeoutSeconds,
    bool? signLists,
    String? apiHost,
    String? videoHost,
    String? catalogVersion,
    String? catalogVersionCode,
    String? videoVersion,
    String? videoVersionCode,
    String? videoUserAgent,
  }) => AppSettings.fromJson({
    ...toJson(),
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
    'timeoutSeconds': timeoutSeconds ?? this.timeoutSeconds,
    'signLists': signLists ?? this.signLists,
    'apiHost': apiHost ?? this.apiHost,
    'videoHost': videoHost ?? this.videoHost,
    'catalogVersion': catalogVersion ?? this.catalogVersion,
    'catalogVersionCode': catalogVersionCode ?? this.catalogVersionCode,
    'videoVersion': videoVersion ?? this.videoVersion,
    'videoVersionCode': videoVersionCode ?? this.videoVersionCode,
    'videoUserAgent': videoUserAgent ?? this.videoUserAgent,
  });
  void validate() {
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
