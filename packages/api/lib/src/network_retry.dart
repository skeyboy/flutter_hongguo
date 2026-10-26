import 'dart:math';

import 'package:dio/dio.dart';

import 'request_control.dart';

class IncompleteCatalogResponse implements Exception {
  final String message;
  const IncompleteCatalogResponse(this.message);
  @override
  String toString() => message;
}

/// Short, bounded recovery for interactive metadata, not media transfers.
class NetworkRetry {
  final List<Duration> delays;
  final Future<void> Function(Duration) wait;
  final DateTime Function() now;
  NetworkRetry({
    List<Duration>? delays,
    Future<void> Function(Duration)? wait,
    DateTime Function()? now,
  }) : delays =
           delays ??
           [
             Duration(milliseconds: 300 + Random().nextInt(201)),
             Duration(milliseconds: 800 + Random().nextInt(201)),
           ],
       wait = wait ?? Future<void>.delayed,
       now = now ?? DateTime.now;

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

  // IMF-fixdate is the HTTP-date form used by Retry-After. Invalid server
  // guidance stops this recovery rather than risking an early repeat request.
  Duration? _retryAfter(String value) {
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);
    final match = RegExp(
      r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final month =
        const [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ].indexOf(match[2]!) +
        1;
    if (month == 0) return null;
    final at = DateTime.utc(
      int.parse(match[3]!),
      month,
      int.parse(match[1]!),
      int.parse(match[4]!),
      int.parse(match[5]!),
      int.parse(match[6]!),
    );
    final delay = at.difference(now().toUtc());
    return delay.isNegative ? Duration.zero : delay;
  }

  Future<T> run<T>(
    Future<T> Function() operation, {
    bool Function(Object)? shouldRetry,
    RequestBudget? budget,
  }) async {
    for (var attempt = 0; ; attempt++) {
      budget?.check();
      try {
        return await (budget == null
            ? operation()
            : budget.guard(Future.sync(operation)));
      } catch (error) {
        budget?.check();
        // Empty/incomplete responses get at most two recoveries; transport and
        // server failures get one. Deterministic business errors never qualify.
        final maximum = error is IncompleteCatalogResponse ? 2 : 1;
        if (attempt >= delays.length ||
            attempt >= maximum ||
            !(shouldRetry ?? transient)(error)) {
          rethrow;
        }
        var delay = delays[attempt];
        if (error is DioException && error.response?.statusCode == 429) {
          final header = error.response?.headers.value('retry-after');
          if (header != null) {
            final requested = _retryAfter(header);
            if (requested == null) rethrow;
            if (requested > delay) delay = requested;
          }
          // Do not sleep beyond an interactive deadline or truncate server advice.
          if (delay >= (budget?.remaining ?? const Duration(seconds: 12))) {
            rethrow;
          }
        }
        if (budget == null) {
          await wait(delay);
        } else {
          await budget.pause(delay, wait);
        }
      }
    }
  }
}
