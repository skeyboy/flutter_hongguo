/// Read-only account identity boundary, mirroring the Android account protocol
/// without enabling any login, cloud read or progress upload.
///
/// Website cookies, anonymous device cookies and the business user ID are
/// deliberately separate fields: mixing them is what makes account requests
/// leak into media requests (or vice versa) in the reference client.
library;

const appDeviceCookieKeys = <String>[
  'install_id',
  'ttreq',
  'store-region',
  'store-region-src',
];

class AccountCredentials {
  const AccountCredentials({
    this.websiteCookie = '',
    this.appDeviceCookie = '',
    this.deviceId = '',
    this.installId = '',
    this.bizUserId = '',
    this.agw = false,
    this.generation = 0,
  });

  /// Website session (`sessionid` / `sessionid_ss`). Never sent to the media
  /// or update endpoints.
  final String websiteCookie;

  /// Anonymous registration cookie, whitelisted by [appDeviceCookieKeys].
  /// Never sent to the website passport endpoints.
  final String appDeviceCookie;

  final String deviceId, installId;

  /// Opaque identifier: keep it as a string, never parse it as a number.
  final String bizUserId;

  /// `X-Tt-Agw-Login` signal from the gateway.
  final bool agw;

  /// Monotonic account generation. Storage keys and in-flight writes are
  /// namespaced by it so a switch cannot write an old account back.
  final int generation;

  bool get isEmpty =>
      websiteCookie.isEmpty && appDeviceCookie.isEmpty && bizUserId.isEmpty;

  /// Storage namespace for the session vault. No credential value is a key.
  String get storageKey => 'account.v$generation';

  Map<String, String> get websiteHeaders => {
    if (websiteCookie.isNotEmpty) 'cookie': websiteCookie,
  };

  /// Account-protocol requests combine the website session with only the
  /// whitelisted device cookies, matching `appRequestCookie()` in Android.
  Map<String, String> get accountRequestHeaders => {
    if (websiteCookie.isNotEmpty) 'cookie': _mergedCookie,
  };

  /// Media/update requests may carry device cookies only.
  Map<String, String> get mediaHeaders => {
    if (_deviceCookie().isNotEmpty) 'cookie': _deviceCookie(),
  };

  String _deviceCookie() {
    final parts = appDeviceCookie.split(';');
    final kept = <String>[];
    for (final part in parts) {
      final key = part.split('=').first.trim();
      if (appDeviceCookieKeys.contains(key)) kept.add(part.trim());
    }
    return kept.join('; ');
  }

  String get _mergedCookie => [
    websiteCookie,
    _deviceCookie(),
  ].where((part) => part.isNotEmpty).join('; ');

  Map<String, dynamic> toJson() => {
    'websiteCookie': websiteCookie,
    'appDeviceCookie': appDeviceCookie,
    'deviceId': deviceId,
    'installId': installId,
    'bizUserId': bizUserId,
    'agw': agw,
    'generation': generation,
  };

  factory AccountCredentials.fromJson(Map<String, dynamic> json) {
    String read(String key) => json[key] is String ? json[key] as String : '';
    return AccountCredentials(
      websiteCookie: read('websiteCookie'),
      appDeviceCookie: read('appDeviceCookie'),
      deviceId: read('deviceId'),
      installId: read('installId'),
      bizUserId: read('bizUserId'),
      agw: json['agw'] is bool ? json['agw'] as bool : false,
      generation: json['generation'] is int ? json['generation'] as int : 0,
    );
  }

  AccountCredentials copyWith({
    String? websiteCookie,
    String? appDeviceCookie,
    String? deviceId,
    String? installId,
    String? bizUserId,
    bool? agw,
    int? generation,
  }) => AccountCredentials(
    websiteCookie: websiteCookie ?? this.websiteCookie,
    appDeviceCookie: appDeviceCookie ?? this.appDeviceCookie,
    deviceId: deviceId ?? this.deviceId,
    installId: installId ?? this.installId,
    bizUserId: bizUserId ?? this.bizUserId,
    agw: agw ?? this.agw,
    generation: generation ?? this.generation,
  );

  void validate() {
    if (RegExp(r'[\r\n]').hasMatch(websiteCookie + appDeviceCookie)) {
      throw const FormatException('Cookie 不能包含换行');
    }
    if (bizUserId.length > 64) {
      throw const FormatException('业务身份过长');
    }
    if (generation < 0 || generation > 1 << 30) {
      throw const FormatException('账号代次无效');
    }
  }
}
