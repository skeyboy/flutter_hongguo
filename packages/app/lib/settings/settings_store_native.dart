import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'settings_store.dart';

class FilePreferencesBackend implements PreferencesBackend {
  final File file;
  int _serial = 0;
  FilePreferencesBackend(this.file);
  @override
  Future<Map<String, dynamic>?> read() async => await file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map)
      : null;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    final working = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.${_serial++}.tmp',
    );
    try {
      await working.writeAsString(jsonEncode(value), flush: true);
      await working.rename(file.path);
    } finally {
      if (await working.exists()) await working.delete();
    }
  }
}

class SystemSessionVault implements SessionVault {
  // Ordinary macOS Keychain avoids introducing Keychain Sharing/provisioning
  // requirements into the independently distributed desktop App.
  final FlutterSecureStorage storage;
  SystemSessionVault()
    : storage = Platform.isMacOS
          ? const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            )
          : const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}
