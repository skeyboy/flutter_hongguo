import 'dart:convert';

import 'package:dio/dio.dart';

import 'release_info.dart';

enum ReleaseFeedStatus { available, notModified, unavailable }

/// One trip to the release feed: either a release, or why there is none.
class ReleaseFeedResult {
  final ReleaseFeedStatus status;
  final ReleaseInfo? release;

  /// The `ETag` to send back as `If-None-Match` next time, so a user who is
  /// already current costs the shared unauthenticated quota (60/hour/IP)
  /// nothing but a 304.
  final String? etag;
  final String message;

  const ReleaseFeedResult({
    required this.status,
    this.release,
    this.etag,
    this.message = '',
  });
}

/// `GET /repos/<repo>/releases/latest` -- the feed the release workflow already
/// publishes, so updating needs no backend of its own.
class ReleaseFeed {
  static const host = 'api.github.com';

  final Dio dio;
  final String repository;

  /// Optional, and only ever sent to `api.github.com`; a release is public, so
  /// an absent token just means the shared anonymous quota applies.
  final String? token;

  const ReleaseFeed({
    required this.dio,
    this.repository = 'skeyboy/flutter_hongguo',
    this.token,
  });

  Uri get endpoint => Uri.https(host, '/repos/$repository/releases/latest');

  Future<ReleaseFeedResult> latest({String? ifNoneMatch}) async {
    try {
      final response = await dio.get<String>(
        endpoint.toString(),
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            if (token != null && token!.isNotEmpty)
              'Authorization': 'Bearer $token',
            if (ifNoneMatch != null && ifNoneMatch.isNotEmpty)
              'If-None-Match': ifNoneMatch,
          },
          // 304 has no body, so it has to be an accepted answer here rather
          // than an error the retry machinery would mask.
          validateStatus: (code) => code == 200 || code == 304,
        ),
      );
      final etag = response.headers.value('etag');
      if (response.statusCode == 304) {
        return ReleaseFeedResult(
          status: ReleaseFeedStatus.notModified,
          etag: ifNoneMatch ?? etag,
        );
      }
      final text = response.data ?? '';
      if (text.trim().isEmpty) {
        return const ReleaseFeedResult(
          status: ReleaseFeedStatus.unavailable,
          message: '发布接口返回了空内容，请稍后重试。',
        );
      }
      return ReleaseFeedResult(
        status: ReleaseFeedStatus.available,
        release: ReleaseInfo.fromJson(jsonDecode(text)),
        etag: etag,
      );
    } on FormatException catch (error) {
      return ReleaseFeedResult(
        status: ReleaseFeedStatus.unavailable,
        message: '发布响应读不懂：${error.message}',
      );
    } on DioException catch (error) {
      return ReleaseFeedResult(
        status: ReleaseFeedStatus.unavailable,
        message: _audience(error),
      );
    }
  }

  static String _audience(DioException error) {
    final code = error.response?.statusCode;
    if (code == 403 || code == 429) {
      return '更新检查太频繁，GitHub 暂时限流，请稍后再试。';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return '更新检查超时，请检查网络后重试。';
    }
    if (error.type == DioExceptionType.connectionError) {
      return '连不上 GitHub 的发布接口，请检查网络后重试。';
    }
    return '更新检查未完成，请稍后重试。';
  }
}
