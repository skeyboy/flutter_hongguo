import 'dart:io' show HandshakeException;
import 'dart:math';

import 'package:dio/dio.dart';

import 'request_control.dart';
import 'upstream_failure.dart' show EmptyEnvelope, classifyUpstreamFailure;

class IncompleteCatalogResponse implements Exception {
  final String message;
  const IncompleteCatalogResponse(this.message);
  @override
  String toString() => message;
}

/// TLS handshake failures are `IOException`s, not `SocketException`s (Dart 3.47
/// routes them through `TlsException`). Dio's IO adapter only catches
/// `SocketException`, so a dropped handshake surfaces as a `DioException` of
/// type `unknown` with the real cause in `error.error`. Look through both
/// wrappers so retry policy and user-facing classification agree on what
/// happened: the HTTPS connection never came up, which is usually transient.
bool isHandshakeFailure(Object error) {
  Object? current = error;
  for (var hop = 0; hop < 4 && current != null; hop++) {
    if (current is HandshakeException) return true;
    current = current is DioException ? current.error : null;
  }
  return false;
}

/// Short, bounded recovery for interactive metadata, not media transfers.
class NetworkRetry {
  final List<Duration> delays;
  final Future<void> Function(Duration) wait;
  final DateTime Function() now;

  /// How many times an envelope that never arrived may be asked again. Two is
  /// what the catalog hops need; the player hop is given more because the
  /// upstream answer is keyed to a window of seconds, not to the request.
  final int maxRecoveries;
  NetworkRetry({
    List<Duration>? delays,
    Future<void> Function(Duration)? wait,
    DateTime Function()? now,
    this.maxRecoveries = 2,
  }) : delays =
           delays ??
           [
             Duration(milliseconds: 300 + Random().nextInt(201)),
             Duration(milliseconds: 800 + Random().nextInt(201)),
           ],
       wait = wait ?? Future<void>.delayed,
       now = now ?? DateTime.now;

  static bool transient(Object error) {
    // Taxonomy first: risk control, expired sessions and business refusals are
    // never replayed even when a caller supplies a looser shouldRetry.
    final classified = classifyUpstreamFailure(error);
    if (classified != null) return classified.replayable;
    if (error is IncompleteCatalogResponse) return true;
    // A handshake that was cut off is worth one more ask: proxies and mobile
    // networks drop them intermittently. A certificate that failed validation
    // is deliberately NOT retried -- repeating the same untrusted chain just
    // burns the interactive deadline.
    if (isHandshakeFailure(error)) return true;
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
        // Empty/incomplete responses get the configured recoveries; transport
        // and server failures get one. Risk control, expired sessions and
        // business errors are refused outright, even with a custom predicate.
        final classified = classifyUpstreamFailure(error);
        if (classified != null && !classified.replayable) rethrow;
        final maximum =
            classified is EmptyEnvelope || error is IncompleteCatalogResponse
            ? maxRecoveries
            : 1;
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
