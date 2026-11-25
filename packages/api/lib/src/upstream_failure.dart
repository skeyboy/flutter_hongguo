/// Lightweight upstream failure taxonomy shared by catalog and playback hops.
///
/// The Android reference distinguishes transport trouble from risk control and
/// expired sessions: only the first may be replayed. This file keeps that
/// boundary in one place while leaving the existing public exception types
/// (`IncompleteCatalogResponse`, `PlaybackUnavailable`) untouched for callers.
library;

import 'package:dio/dio.dart';

import 'network_retry.dart' show IncompleteCatalogResponse, isHandshakeFailure;

const _riskCodes = <int>{429, 110001, 110002, 110003};
const _authCodes = <int>{401, 403, 8, 1001};
const _riskWords = <String>[
  'verify',
  'captcha',
  'risk',
  'rate limit',
  'too many',
  '频繁',
  '稍后',
  '验证',
];
const _authWords = <String>['token', 'login', 'unauthor', '登录', '未登录'];

/// Kinds are deliberately exhaustive so new categories must be classified
/// explicitly instead of falling into a generic "retry me" bucket.
enum UpstreamFailureKind {
  transport,
  emptyEnvelope,
  riskControl,
  authExpired,
  business,
}

sealed class UpstreamFailure implements Exception {
  const UpstreamFailure(this.message, {this.statusCode, this.businessCode});

  final String message;
  final int? statusCode;
  final int? businessCode;

  /// Only transport and empty-envelope failures may be submitted again.
  bool get replayable => switch (kind) {
    UpstreamFailureKind.transport || UpstreamFailureKind.emptyEnvelope => true,
    _ => false,
  };

  UpstreamFailureKind get kind;

  /// Stable, log-safe identifier. Never contains a URL, cookie or signature.
  String get diagnosticId => switch (kind) {
    UpstreamFailureKind.transport => 'transport',
    UpstreamFailureKind.emptyEnvelope => 'empty-envelope',
    UpstreamFailureKind.riskControl => 'risk-control',
    UpstreamFailureKind.authExpired => 'auth-expired',
    UpstreamFailureKind.business => 'business',
  };

  @override
  String toString() =>
      '$diagnosticId${businessCode == null ? '' : ':$businessCode'}';
}

final class TransportFailure extends UpstreamFailure {
  const TransportFailure(super.message, {super.statusCode, super.businessCode});
  @override
  UpstreamFailureKind get kind => UpstreamFailureKind.transport;
}

final class EmptyEnvelope extends UpstreamFailure {
  const EmptyEnvelope(super.message, {super.statusCode});
  @override
  UpstreamFailureKind get kind => UpstreamFailureKind.emptyEnvelope;
}

final class RiskControlFailure extends UpstreamFailure {
  const RiskControlFailure(
    super.message, {
    super.statusCode,
    super.businessCode,
  });
  @override
  UpstreamFailureKind get kind => UpstreamFailureKind.riskControl;
}

final class AuthExpiredFailure extends UpstreamFailure {
  const AuthExpiredFailure(
    super.message, {
    super.statusCode,
    super.businessCode,
  });
  @override
  UpstreamFailureKind get kind => UpstreamFailureKind.authExpired;
}

final class BusinessFailure extends UpstreamFailure {
  const BusinessFailure(super.message, {super.statusCode, super.businessCode});
  @override
  UpstreamFailureKind get kind => UpstreamFailureKind.business;
}

bool _hasWord(String text, List<String> words) {
  final lower = text.toLowerCase();
  for (final word in words) {
    if (lower.contains(word)) return true;
  }
  return false;
}

int? _businessCode(Object? data) {
  if (data is Map) {
    final raw = data['code'] ?? data['errno'] ?? data['error_code'];
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw);
  }
  return null;
}

/// Map an error to a taxonomy entry. Returns null for errors we deliberately
/// leave to the caller (parse errors, assertion failures, cancellation).
UpstreamFailure? classifyUpstreamFailure(Object error) {
  if (error is UpstreamFailure) return error;
  if (error is IncompleteCatalogResponse) {
    return EmptyEnvelope(error.message);
  }
  if (isHandshakeFailure(error)) {
    return const TransportFailure('handshake interrupted');
  }
  if (error is! DioException) {
    final text = error.toString();
    // CatalogError renders as `内容接口返回 110001：...`; keep the taxonomy
    // consistent with the same code arriving inside a Dio response body.
    final renderedCode = RegExp(r'(?:code|Code|返回)\s*[:=]?\s*(\d+)')
        .firstMatch(text)
        ?.group(1);
    final parsed = renderedCode == null ? null : int.tryParse(renderedCode);
    if (parsed != null && _riskCodes.contains(parsed)) {
      return RiskControlFailure(text, businessCode: parsed);
    }
    if (parsed != null && _authCodes.contains(parsed)) {
      return AuthExpiredFailure(text, businessCode: parsed);
    }
    if (_hasWord(text, _riskWords)) return RiskControlFailure(text);
    if (_hasWord(text, _authWords)) return AuthExpiredFailure(text);
    return null;
  }

  final status = error.response?.statusCode;
  final code = _businessCode(error.response?.data);
  final body = error.response?.data?.toString() ?? error.message ?? '';
  // Business codes win over the HTTP envelope: upstream answers 200 with a
  // risk-control code in the JSON body.
  if (code != null && _riskCodes.contains(code)) {
    return RiskControlFailure(body, statusCode: status, businessCode: code);
  }
  if (code != null && _authCodes.contains(code)) {
    return AuthExpiredFailure(body, statusCode: status, businessCode: code);
  }
  if (status != null && _authCodes.contains(status)) {
    return AuthExpiredFailure(body, statusCode: status, businessCode: code);
  }
  if (status == 429) {
    // A server-supplied Retry-After is guidance we may obey once; without it
    // a 429 is a refusal and must not be replayed blindly.
    final retryAfter = error.response?.headers.value('retry-after');
    if (retryAfter == null || retryAfter.isEmpty) {
      return RiskControlFailure(body, statusCode: status, businessCode: code);
    }
    return TransportFailure(body, statusCode: status, businessCode: code);
  }
  if (status != null && status >= 500 && status <= 599) {
    return TransportFailure(body, statusCode: status, businessCode: code);
  }
  if ({
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionError,
  }.contains(error.type)) {
    return TransportFailure(body, statusCode: status, businessCode: code);
  }
  if (_hasWord(body, _riskWords)) {
    return RiskControlFailure(body, statusCode: status, businessCode: code);
  }
  if (_hasWord(body, _authWords)) {
    return AuthExpiredFailure(body, statusCode: status, businessCode: code);
  }
  if (code != null) {
    return BusinessFailure(body, statusCode: status, businessCode: code);
  }
  return null;
}

/// Convenience for retry callers that only need the replay decision.
bool mayReplay(Object error) =>
    classifyUpstreamFailure(error)?.replayable ?? false;

/// True when the error must clear/expire any cached session before surfacing.
bool invalidatesSession(Object error) =>
    classifyUpstreamFailure(error) is AuthExpiredFailure;
