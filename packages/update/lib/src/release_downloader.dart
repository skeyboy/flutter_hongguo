import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'release_info.dart';

/// A download that will not be installed, in the language the dialog shows.
class UpdateFailure implements Exception {
  final String message;
  const UpdateFailure(this.message);
  @override
  String toString() => message;
}

/// A release file that is on this device and whose bytes were checked.
class DownloadedRelease {
  final String path;
  final int bytes;
  final String sha256;
  const DownloadedRelease({
    required this.path,
    required this.bytes,
    required this.sha256,
  });
}

/// Fetches one attachment and refuses to hand it over unless its hash matches
/// what the feed said. An installer nobody verified is the one thing an update
/// path must not do, so a missing digest is a failure rather than a shortcut.
class ReleaseDownloader {
  static const _allowedHosts = [
    'github.com',
    'api.github.com',
    'codeload.github.com',
    'objects.githubusercontent.com',
  ];

  final Dio dio;
  final Directory destination;

  const ReleaseDownloader({required this.dio, required this.destination});

  Future<DownloadedRelease> fetch(
    ReleaseAsset asset,
    ReleaseInfo release, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (asset.name != _basename(asset.name) || asset.name.isEmpty) {
      throw const UpdateFailure('发布附件名称不安全，已停止。');
    }
    final uri = Uri.tryParse(asset.downloadUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        !_allowedHosts.any(
          (host) => uri.host == host || uri.host.endsWith('.$host'),
        )) {
      throw const UpdateFailure('发布下载地址不是 GitHub，已停止。');
    }
    final expected = asset.sha256 ?? await _sumFromManifest(asset, release);
    if (expected == null) {
      throw const UpdateFailure('这个发布附件没有可对照的校验值，已停止安装。');
    }
    await destination.create(recursive: true);
    final part = File(
      '${destination.path}${Platform.pathSeparator}${asset.name}.part',
    );
    try {
      await dio.download(
        asset.downloadUrl,
        part.path,
        onReceiveProgress: (received, total) =>
            onProgress?.call(received, total),
      );
    } on DioException {
      await part.delete().catchError((Object _) => part);
      throw const UpdateFailure('更新文件没下载完，请稍后重试。');
    }
    final actual = await _sha256(part);
    if (actual != expected) {
      await part.delete().catchError((Object _) => part);
      throw const UpdateFailure('下载文件的校验值与发布记录不一致，已删除并停止安装。');
    }
    final file = File(
      '${destination.path}${Platform.pathSeparator}${asset.name}',
    );
    if (await file.exists()) await file.delete();
    await part.rename(file.path);
    return DownloadedRelease(
      path: file.path,
      bytes: await file.length(),
      sha256: actual,
    );
  }

  /// The release workflow also attaches `SHA256SUMS.txt`; when the feed gives no
  /// per-asset digest, that is where the expected hash comes from.
  Future<String?> _sumFromManifest(
    ReleaseAsset asset,
    ReleaseInfo release,
  ) async {
    final sums = release.assetNamed('SHA256SUMS.txt');
    if (sums == null) return null;
    try {
      final response = await dio.get<String>(
        sums.downloadUrl,
        options: Options(responseType: ResponseType.plain),
      );
      return parseSha256Sums(response.data ?? '')[asset.name];
    } on Object {
      return null;
    }
  }

  static Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static String _basename(String name) => name.split(RegExp(r'[/\\]')).last;
}
