import 'dart:async';
import '../ports/repository.dart';

/// Bounds work globally while callers retain cancellation of their own requests.
class MediaScheduler {
  Future<void> _tail = Future.value();
  Future<T> run<T>(CancellationToken token, Future<T> Function() work) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return (() async {
      try {
        await previous;
        token.check();
        return await work();
      } finally {
        done.complete();
      }
    })();
  }
}
