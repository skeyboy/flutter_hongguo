import 'package:dio/dio.dart';

class IncompleteCatalogResponse implements Exception {
  final String message;
  const IncompleteCatalogResponse(this.message);
  @override
  String toString() => message;
}

/// Bounded retries for read-only operations; the default policy handles
/// temporary transport/server failures. Catalog callers can classify bad payloads.
/// Requests must be rebuilt per attempt (not replay an exhausted body stream).
class NetworkRetry {
  final List<Duration> delays;
  final Future<void> Function(Duration) wait;
  NetworkRetry({
    this.delays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    Future<void> Function(Duration)? wait,
  }) : wait = wait ?? Future<void>.delayed;

  static bool transient(Object error) {
    if (error is IncompleteCatalogResponse) return true;
    if (error is! DioException) return false;
    if ({
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.connectionError,
    }.contains(error.type)) {
      return true;
    }
    final status = error.response?.statusCode;
    return error.type == DioExceptionType.badResponse &&
        (status == 408 ||
            status == 429 ||
            (status != null && status >= 500 && status <= 599));
  }

  Future<T> run<T>(
    Future<T> Function() operation, {
    bool Function(Object)? shouldRetry,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await operation();
      } catch (error) {
        if (attempt >= delays.length || !(shouldRetry ?? transient)(error)) {
          rethrow;
        }
        var delay = delays[attempt];
        if (error is DioException && error.response?.statusCode == 429) {
          final header = error.response?.headers.value('retry-after');
          final seconds = int.tryParse(header ?? '');
          if (seconds != null && seconds > delay.inSeconds) {
            delay = Duration(seconds: seconds.clamp(0, 30));
          }
        }
        await wait(delay);
      }
    }
  }
}
