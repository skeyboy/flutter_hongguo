import 'dart:convert';

import 'package:hongguo_core/hongguo_core.dart';

abstract interface class PreferencesBackend {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

abstract interface class SessionVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Non-secret preferences are committed atomically. Session values live only in
/// the platform vault, under a new key until the preferences commit succeeds.
class SettingsStore {
  final PreferencesBackend backend;
  final SessionVault vault;
  AppSettings settings = const AppSettings();
  SessionCredentials credentials = const SessionCredentials();
  String deviceId;
  String? warning, _sessionRef;
  Future<void> _writes = Future.value();
  SettingsStore({
    required this.backend,
    required this.vault,
    required this.deviceId,
  });
  Future<void> load() async {
    Map<String, dynamic>? data;
    try {
      data = await backend.read();
      if (data != null) {
        if (data['deviceId'] is String &&
            RegExp(r'^\d{10,20}$').hasMatch(data['deviceId'])) {
          deviceId = data['deviceId'] as String;
        }
        final ref = data['sessionRef'];
        _sessionRef = ref is String && ref.startsWith('hongguo.session.')
            ? ref
            : null;
        final prefs = AppSettings.fromJson(
          Map<String, dynamic>.from(data['preferences'] as Map),
        );
        prefs.validate();
        settings =
            data['networkPolicyVersion'] == null && prefs.timeoutSeconds == 30
            ? prefs.copyWith(timeoutSeconds: 60)
            : prefs;
        if (data['playbackPolicyVersion'] == null) {
          settings = settings.copyWith(autoNext: true);
        }
      }
    } catch (_) {
      warning = '设置文件无法读取，已使用默认偏好。';
    }
    if (_sessionRef != null) {
      try {
        final raw = await vault.read(_sessionRef!);
        if (raw == null) throw StateError('Missing session');
        final value = SessionCredentials.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        value.validate();
        credentials = value;
      } catch (_) {
        warning = '系统安全存储中的会话暂不可用；未将凭据写入普通设置文件。';
      }
    }
  }

  Future<void> save(
    AppSettings next, {
    SessionCredentials? session,
    String? identity,
  }) {
    next.validate();
    session?.validate();
    final nextId = identity ?? deviceId;
    if (!RegExp(r'^\d{10,20}$').hasMatch(nextId)) {
      throw const FormatException('设备编号无效');
    }
    final operation = _writes.then((_) async {
      final oldRef = _sessionRef;
      String? newRef = oldRef;
      var created = false;
      final changed =
          session != null &&
          jsonEncode(session.toJson()) != jsonEncode(credentials.toJson());
      // Explicitly clearing a currently inaccessible record is also meaningful.
      final clearing = session != null && session.isEmpty && oldRef != null;
      if (changed || clearing) {
        newRef = null;
        if (!session.isEmpty) {
          newRef =
              'hongguo.session.${DateTime.now().microsecondsSinceEpoch}.${hex(secureBytes(8))}';
          await vault.write(newRef, jsonEncode(session.toJson()));
          created = true;
        }
      }
      try {
        await backend.write({
          'version': 1,
          'preferences': next.toJson(),
          'networkPolicyVersion': 1,
          'playbackPolicyVersion': 1,
          'deviceId': nextId,
          'sessionRef': newRef,
        });
      } catch (_) {
        if (created && newRef != null) {
          try {
            await vault.delete(newRef);
          } catch (_) {
            /* next vault cleanup */
          }
        }
        rethrow;
      }
      settings = next;
      deviceId = nextId;
      _sessionRef = newRef;
      if (session != null) {
        credentials = session;
        warning = null;
      } else if (warning?.startsWith('设置文件') ?? false) {
        warning = null;
      }
      if (oldRef != null && oldRef != newRef) {
        try {
          await vault.delete(oldRef);
        } catch (_) {
          /* stale vault key, not referenced */
        }
      }
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }
}
