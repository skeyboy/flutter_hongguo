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

  /// Whether these bytes were already on the device, so nothing was fetched.
  final bool reused;

  const DownloadedRelease({
    required this.path,
    required this.bytes,
    required this.sha256,
    this.reused = false,
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

  /// One live transfer per address, shared by every downloader instance.
  ///
  /// A viewer who presses 立即更新 twice -- and a second controller mounted beside
  /// this one -- must not pay for the same installer twice, and two writers into
  /// one `.part` file corrupt each other's bytes.
  static final _inFlight = <String, Future<DownloadedRelease>>{};

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
    final live = _inFlight[asset.downloadUrl];
    if (live != null) {
      // A shared transfer reports to the caller that started it. The second one
      // is owed only the value it cannot get from that stream -- the whole file.
      final file = await live;
      onProgress?.call(file.bytes, file.bytes);
      return file;
    }
    // Registered before the first await, so a second press inside the same
    // frame joins this transfer instead of starting its own.
    final transfer = _take(asset, release, onProgress);
    _inFlight[asset.downloadUrl] = transfer;
    try {
      return await transfer;
    } finally {
      // Only the entry this call installed: a later press may own one already.
      if (identical(_inFlight[asset.downloadUrl], transfer)) {
        _inFlight.remove(asset.downloadUrl);
      }
    }
  }

  Future<DownloadedRelease> _take(
    ReleaseAsset asset,
    ReleaseInfo release,
    void Function(int received, int total)? onProgress,
  ) async {
    final expected = await expectedDigest(asset, release);
    if (expected == null) {
      throw const UpdateFailure('这个发布附件没有可对照的校验值，已停止安装。');
    }
    final settled = await this.settled(asset, expected);
    if (settled != null) {
      // The bar still has to reach its end: a dialog that starts a transfer it
      // never receives a byte of would sit at 0% over a finished file.
      onProgress?.call(settled.bytes, settled.bytes);
      return settled;
    }
    return _transfer(asset, expected, onProgress);
  }

  /// The digest this file has to carry: the feed's own, or its line in the
  /// release's `SHA256SUMS.txt`. Public because a transfer the system finished
  /// while this app slept has to be checked against the same number.
  Future<String?> expectedDigest(
    ReleaseAsset asset,
    ReleaseInfo release,
  ) async => asset.sha256 ?? await _sumFromManifest(asset, release);

  /// Whether the bytes at [path] are the ones the release describes.
  static Future<bool> verify(
    String path,
    String expectedSha256, {
    int bytes = 0,
  }) async {
    try {
      final file = File(path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return false;
      if (bytes > 0 && stat.size != bytes) return false;
      return await _sha256(file) == expectedSha256;
    } on FileSystemException {
      return false;
    }
  }

  /// The verified bytes already on disk, or null.
  ///
  /// Decided by hashing, not by a note beside the file: a package that survived a
  /// storage cleanup keeps its digest, and one that did not survive it whole does
  /// not get to claim it did.
  Future<DownloadedRelease?> settled(
    ReleaseAsset asset,
    String expectedSha256,
  ) async {
    final path = '${destination.path}${Platform.pathSeparator}${asset.name}';
    if (!await verify(path, expectedSha256, bytes: asset.bytes)) return null;
    return DownloadedRelease(
      path: path,
      bytes: asset.bytes,
      sha256: expectedSha256,
      reused: true,
    );
  }

  Future<DownloadedRelease> _transfer(
    ReleaseAsset asset,
    String expected,
    void Function(int received, int total)? onProgress,
  ) async {
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
