import 'dart:async';

import 'package:dio/dio.dart';

class RequestCancelled implements Exception {
  const RequestCancelled();
  @override
  String toString() => '请求已取消';
}

class MetadataDeadlineExceeded implements Exception {
  const MetadataDeadlineExceeded();
  @override
  String toString() => '内容加载超时，请重试';
}

/// Privacy-safe timings: operation names and durations, never request keys/URLs.
class MetadataTiming {
  final int requestId;
  final String operation;
  final Duration elapsed;
  final Map<String, Duration> stages;
  final String? failureType;
  final bool cacheHit;
  final int attempts;
  MetadataTiming({
    required this.requestId,
    required this.operation,
    required this.elapsed,
    required Map<String, Duration> stages,
    this.failureType,
    required this.cacheHit,
    required this.attempts,
  }) : stages = Map.unmodifiable(stages);
}

/// Caller-owned cancellation without exposing a transport type to widgets.
/// Scope propagation also works through repository adapters and test doubles.
class CatalogRequestScope {
  static final _key = Object();
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  static CatalogRequestScope? get current =>
      Zone.current[_key] as CatalogRequestScope?;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  Future<T> run<T>(Future<T> Function() work) {
    if (isCancelled) return Future.error(const RequestCancelled());
    return runZoned(work, zoneValues: {_key: this});
  }
}

/// A monotonic deadline shared by every attempt and fallback of an operation.
/// Expiry cancels the real Dio transport, not just its observing Future.
class RequestBudget {
  static final _key = Object();
  static RequestBudget get current => Zone.current[_key] as RequestBudget;
  final Duration limit;
  final RequestBudget? parent;
  final stages = <String, Duration>{};
  final _activeStages = <Stopwatch, String>{};
  Map<String, Duration> get stageSnapshot {
    final result = Map<String, Duration>.of(stages);
    for (final entry in _activeStages.entries) {
      result[entry.value] =
          (result[entry.value] ?? Duration.zero) + entry.key.elapsed;
    }
    return result;
  }

  void _begin(String stage, Stopwatch clock) {
    _activeStages[clock] = stage;
    parent?._begin(stage, clock);
  }

  void _end(Stopwatch clock) {
    _activeStages.remove(clock);
    parent?._end(clock);
  }

  bool cacheHit = false;
  int attempts = 0;
  final token = CancelToken();
  final _clock = Stopwatch()..start();
  final _ended = Completer<Object>();
  late final Timer _timer;
  bool _closed = false;
  RequestBudget(this.limit, {this.parent}) {
    if (limit <= Duration.zero) throw ArgumentError.value(limit, 'limit');
    _timer = Timer(limit, () => cancel(const MetadataDeadlineExceeded()));
  }
  Duration get remaining => limit - _clock.elapsed;
  Duration get elapsed => _clock.elapsed;
  Duration timeout(Duration maximum) {
    check();
    return remaining < maximum ? remaining : maximum;
  }

  void record(String stage, Duration value) {
    stages[stage] = (stages[stage] ?? Duration.zero) + value;
    parent?.record(stage, value);
  }

  void _attempt() {
    attempts++;
    parent?._attempt();
  }

  Future<T> transport<T>(Future<T> Function() work) {
    check();
    _attempt();
    return measure('transport', work);
  }

  Future<T> measure<T>(String stage, Future<T> Function() work) async {
    check();
    final clock = Stopwatch()..start();
    _begin(stage, clock);
    try {
      return await guard(Future.sync(work));
    } finally {
      clock.stop();
      _end(clock);
      record(stage, clock.elapsed);
    }
  }

  void check() {
    if (_ended.isCompleted) {
      throw token.cancelError?.error ?? const RequestCancelled();
    }
    if (remaining <= Duration.zero) {
      cancel(const MetadataDeadlineExceeded());
      throw const MetadataDeadlineExceeded();
    }
  }

  void cancel([Object reason = const RequestCancelled()]) {
    if (_closed || _ended.isCompleted) return;
    token.cancel(reason);
    _ended.complete(reason);
  }

  Future<T> guard<T>(Future<T> work) {
    check();
    return Future.any([work, _ended.future.then<T>((reason) => throw reason)]);
  }

  Future<void> pause(Duration delay, Future<void> Function(Duration) wait) {
    check();
    if (delay >= remaining) {
      return Future.error(const MetadataDeadlineExceeded());
    }
    return measure('backoff', () => wait(delay));
  }

  Future<T> run<T>(Future<T> Function() work) => runZoned(() {
    check();
    return guard(Future.sync(work));
  }, zoneValues: {_key: this});
  Future<T> phase<T>(Duration maximum, Future<T> Function() work) async {
    check();
    final child = RequestBudget(
      remaining < maximum ? remaining : maximum,
      parent: this,
    );
    // Parent cancellation must abort the active phase's transport too.
    unawaited(_ended.future.then((reason) => child.cancel(reason)));
    try {
      return await guard(child.run(work));
    } finally {
      child.close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
  }
}

class _Flight {
  final RequestBudget budget;
  late final Future<Object?> result;
  int consumers = 0;
  _Flight(this.budget);
}

/// Per-client identity/protocol namespace. Results are not retained on failure.
class CatalogRequests {
  final Duration deadline;
  final void Function(MetadataTiming)? onTiming;
  int _serial = 0;
  final _flights = <String, _Flight>{};
  CatalogRequests({this.deadline = const Duration(seconds: 12), this.onTiming});
  Future<T> run<T>(
    String key,
    Future<T> Function() operation, {
    String label = 'metadata',
  }) async {
    final scope = CatalogRequestScope.current;
    if (scope?.isCancelled == true) throw const RequestCancelled();
    var flight = _flights[key];
    if (flight == null) {
      flight = _Flight(RequestBudget(deadline));
      final created = flight;
      _flights[key] = created;
      final id = ++_serial;
      void report(Object? failure) {
        try {
          onTiming?.call(
            MetadataTiming(
              requestId: id,
              operation: label,
              elapsed: created.budget.elapsed,
              stages: created.budget.stageSnapshot,
              cacheHit: created.budget.cacheHit,
              attempts: created.budget.attempts,
              failureType: failure?.runtimeType.toString(),
            ),
          );
        } catch (_) {
          /* Diagnostics cannot fail a request. */
        }
      }

      created.result = created.budget
          .run(operation)
          .then<Object?>(
            (value) {
              report(null);
              return value;
            },
            onError: (Object error, StackTrace stack) {
              report(error);
              Error.throwWithStackTrace(error, stack);
            },
          )
          .whenComplete(() {
            created.budget.close();
            if (identical(_flights[key], created)) _flights.remove(key);
          });
    }
    flight.consumers++;
    final active = flight;
    try {
      final result = scope == null
          ? await active.result
          : await Future.any<Object?>([
              active.result,
              scope._cancelled.future.then<Object?>(
                (_) => throw const RequestCancelled(),
              ),
            ]);
      return result as T;
    } finally {
      active.consumers--;
      if (active.consumers == 0 && identical(_flights[key], active)) {
        _flights.remove(key);
        active.budget.cancel();
      }
    }
  }

  void cancelAll() {
    for (final flight in _flights.values) {
      flight.budget.cancel();
    }
    _flights.clear();
  }
}
