import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../features/library/library_store.dart';

class PlaybackController extends ChangeNotifier with WidgetsBindingObserver {
  final PlaybackRepository repository;
  final LibraryStore library;
  final SeriesDetail detail;
  final Player player = Player();
  late final VideoController video = VideoController(player);
  CancellationToken? _token;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int selected = -1;
  String quality = 'best';
  PreparationState? state;
  String? error;
  bool _disposed = false;
  Duration _lastSaved = Duration.zero;
  Future<void> _commands = Future.value();
  PlaybackController(this.repository, this.library, this.detail) {
    WidgetsBinding.instance.addObserver(this);
    _subscriptions.add(
      player.stream.error.listen((message) {
        if (!_disposed) {
          error = message;
          notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      player.stream.completed.listen((done) {
        if (done && selected + 1 < detail.episodes.length) {
          unawaited(select(selected + 1));
        }
      }),
    );
    _subscriptions.add(
      player.stream.position.listen((position) {
        if (selected >= 0 &&
            (position - _lastSaved).abs() >= const Duration(seconds: 5)) {
          _lastSaved = position;
          _record(position);
        }
      }),
    );
  }
  Future<void> select(int index, {String? newQuality, Duration? resume}) async {
    if (index < 0 || index >= detail.episodes.length || _disposed) return;
    _record(player.state.position);
    _token?.cancel();
    final token = CancellationToken();
    _token = token;
    selected = index;
    quality = newQuality ?? quality;
    state = PreparationState.queued;
    error = null;
    notifyListeners();
    // Serialize commands to the player. Request generation is checked inside the queue.
    await _command(token, () => player.stop());
    if (token.isCancelled || _disposed) return;
    try {
      final source = await repository.prepare(
        detail.episodes[index].vid,
        quality: quality,
        cancellation: token,
        onState: (s) {
          if (!token.isCancelled && !_disposed) {
            state = s;
            notifyListeners();
          }
        },
      );
      token.check();
      if (_disposed) return;
      await _command(token, () async {
        await player.open(Media(source.location), play: false);
        token.check();
        if (resume != null && resume > Duration.zero) await player.seek(resume);
        token.check();
        await player.play();
      });
      token.check();
      if (_disposed) return;
      _lastSaved = resume ?? Duration.zero;
      _record(resume ?? Duration.zero);
      state = PreparationState.ready;
      notifyListeners();
    } on PreparationCancelled {
      /* a newer selection owns the UI */
    } catch (e) {
      if (!token.isCancelled && !_disposed) {
        error = e.toString();
        state = PreparationState.failed;
        notifyListeners();
      }
    }
  }

  Future<void> _command(
    CancellationToken token,
    Future<void> Function() command,
  ) {
    return _commands = _commands.catchError((_) {}).then((_) async {
      if (!token.isCancelled && !_disposed) await command();
    });
  }

  void cancel() {
    _token?.cancel();
    if (!_disposed) {
      state = PreparationState.cancelled;
      notifyListeners();
    }
  }

  void _record(Duration position) {
    if (selected >= 0 && state == PreparationState.ready) {
      unawaited(
        library.record(
          detail.series,
          detail.episodes[selected].index,
          position,
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _record(player.state.position);
      cancel();
      unawaited(player.pause());
    }
  }

  @override
  void dispose() {
    _record(player.state.position);
    _disposed = true;
    _token?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_commands.catchError((_) {}).then((_) => player.dispose()));
    super.dispose();
  }
}
