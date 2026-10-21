import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:window_manager/window_manager.dart';

class _MediaHandler extends BaseAudioHandler {
  bool foregroundOnly = false;
  mk.Player? player;
  Future<void> Function(int)? step;
  Future<void> Function(String, [int?])? external;
  final subscriptions = <StreamSubscription<dynamic>>[];
  void bind(mk.Player value, String title, Future<void> Function(int) next) {
    for (final s in subscriptions) {
      unawaited(s.cancel());
    }
    subscriptions.clear();
    player = value;
    step = next;
    mediaItem.add(
      MediaItem(id: 'hongguo-current', title: title, artist: '红果剧场'),
    );
    void update() {
      if (external != null) return;
      final state = value.state;
      playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            state.playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
            MediaControl.stop,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
          processingState: state.duration == Duration.zero
              ? AudioProcessingState.loading
              : AudioProcessingState.ready,
          playing: state.playing,
          updatePosition: state.position,
          bufferedPosition: state.buffer,
        ),
      );
    }

    subscriptions.add(value.stream.playing.listen((_) => update()));
    subscriptions.add(value.stream.position.listen((_) => update()));
    subscriptions.add(
      value.stream.duration.listen((duration) {
        mediaItem.add(mediaItem.value!.copyWith(duration: duration));
        update();
      }),
    );
    update();
  }

  @override
  Future<void> play() async {
    if (foregroundOnly &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (external != null) {
      await external!('play');
    } else {
      await player?.play();
    }
  }

  @override
  Future<void> pause() async {
    if (external != null) {
      await external!('pause');
    } else {
      await player?.pause();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (external != null) {
      await external!('seek', position.inMilliseconds);
    } else {
      await player?.seek(position);
    }
  }

  @override
  Future<void> skipToNext() async {
    if (external == null) await step?.call(1);
  }

  @override
  Future<void> skipToPrevious() async {
    if (external == null) await step?.call(-1);
  }

  @override
  Future<void> stop() async {
    await pause();
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
    await super.stop();
  }

  Future<void> detach(mk.Player owner) async {
    if (!identical(owner, player)) return;
    for (final s in subscriptions) {
      await s.cancel();
    }
    subscriptions.clear();
    external = null;
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
    mediaItem.add(null);
    player = null;
    step = null;
  }
}

Future<_MediaHandler>? _handler;

class PlaybackPlatform with WindowListener {
  static const _channel = MethodChannel('hongguo/platform-playback');
  final nativeFullscreen = ValueNotifier<bool?>(null);
  bool _observingWindow = false;
  VoidCallback? onWindowFocused;

  @override
  void onWindowFocus() => onWindowFocused?.call();
  final floating = ValueNotifier(false);
  final platformPip = ValueNotifier(false);
  bool get nativeHandoff => Platform.isIOS || Platform.isMacOS;
  Duration? externalPosition;
  bool? externalPlaying;
  VoidCallback? onExternalProgress;
  bool get mobile => Platform.isAndroid || Platform.isIOS;
  bool get transitioning => _transition;
  Future<bool> supportsFloating() async {
    if (!mobile && !nativeHandoff) return true;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void>? _exiting;
  Completer<void>? _restorePending;
  DateTime? _pipExitAt;
  bool get restoringPip =>
      Platform.isAndroid &&
      _pipExitAt != null &&
      DateTime.now().difference(_pipExitAt!) < const Duration(seconds: 2);
  mk.Player? _player;
  AppSettings _settings = const AppSettings();
  _MediaHandler? _media;
  final _audioEvents = <StreamSubscription<dynamic>>[];
  VoidCallback? onExternalCompleted;
  Rect? _bounds;
  bool _top = false, _maximized = false, _fullscreen = false;
  bool _closed = false, _transition = false;
  PlaybackPlatform() {
    if (mobile || nativeHandoff) _channel.setMethodCallHandler(_nativeEvent);
  }

  Future<void> _watchWindow() async {
    if (!Platform.isMacOS || _observingWindow || _closed) return;
    try {
      await windowManager.ensureInitialized();
      if (_closed) return;
      windowManager.addListener(this);
      _observingWindow = true;
      final value = await windowManager.isFullScreen();
      if (!_closed) nativeFullscreen.value = value;
    } catch (_) {
      /* A window may not exist in headless tests. */
    }
  }

  @override
  void onWindowEnterFullScreen() {
    if (!_closed) nativeFullscreen.value = true;
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!_closed) nativeFullscreen.value = false;
  }

  Future<void> configure(
    mk.Player player,
    AppSettings settings,
    String title, {
    required Future<void> Function(int) step,
    bool foregroundMedia = false,
  }) async {
    if (_closed) return;
    await _watchWindow();
    _player = player;
    _settings = settings;
    if (!settings.floatingPlayback && floating.value) await exit(player);
    if (!mobile) return;
    if (!settings.backgroundPlayback && !foregroundMedia && _media != null) {
      await _media!.detach(player);
      _media = null;
      for (final event in _audioEvents) {
        await event.cancel();
      }
      _audioEvents.clear();
    }
    if ((settings.backgroundPlayback || foregroundMedia) && _media == null) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      if (!await session.setActive(true)) throw StateError('系统音频会话暂不可用');
      _audioEvents.add(
        session.interruptionEventStream.listen((event) {
          if (event.begin) unawaited(_media?.pause() ?? player.pause());
        }),
      );
      _audioEvents.add(
        session.becomingNoisyEventStream.listen(
          (_) => _media?.pause() ?? player.pause(),
        ),
      );
      _media = await (_handler ??= AudioService.init(
        builder: _MediaHandler.new,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'hongguo.playback',
          androidNotificationChannelName: '后台播放',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'mipmap/ic_launcher',
        ),
      ));
    }
    if (_closed) {
      await _media?.detach(player);
      return;
    }
    _media?.foregroundOnly = foregroundMedia;
    _media?.bind(player, title, step);
  }

  Future<void> enter(mk.Player player, String source) async {
    if (_closed || _transition || floating.value) return;
    if (!_settings.floatingPlayback) throw StateError('请先在设置中开启悬浮播放');
    _transition = true;
    try {
      if (Platform.isAndroid) {
        floating.value = true;
        platformPip.value = true;
        await WidgetsBinding.instance.endOfFrame;
        final ok = await _channel.invokeMethod<bool>('enter', {
          'width': player.state.width ?? 9,
          'height': player.state.height ?? 16,
        });
        if (ok != true) throw StateError('当前系统未允许画中画，请检查应用的画中画权限');
        floating.value = true;
      } else if (nativeHandoff) {
        final wasPlaying = player.state.playing;
        await player.pause();
        try {
          final ok = await _channel.invokeMethod<bool>('enter', {
            'source': source.startsWith('/')
                ? Uri.file(source).toString()
                : source,
            'position': player.state.position.inMilliseconds,
            'playing': wasPlaying,
            'rate': player.state.rate,
            'volume': player.state.volume / 100,
          });
          if (ok != true) throw StateError('当前设备暂不能进入画中画');
          platformPip.value = true;
          floating.value = true;
          _media?.external = (action, [position]) async =>
              _channel.invokeMethod('control', {
                'action': action,
                'position': position,
              });
        } catch (_) {
          externalPosition = null;
          if (!_closed &&
              wasPlaying &&
              (!mobile ||
                  _settings.backgroundPlayback ||
                  WidgetsBinding.instance.lifecycleState ==
                      AppLifecycleState.resumed)) {
            await player.play();
          }
          rethrow;
        }
      } else {
        await windowManager.ensureInitialized();
        _bounds = await windowManager.getBounds();
        _top = await windowManager.isAlwaysOnTop();
        _maximized = await windowManager.isMaximized();
        _fullscreen = await windowManager.isFullScreen();
        if (_fullscreen) await windowManager.setFullScreen(false);
        if (_maximized) await windowManager.unmaximize();
        final ratio = (player.state.width ?? 9) / (player.state.height ?? 16);
        await windowManager.setSize(
          ratio < 1 ? const Size(300, 500) : const Size(520, 340),
        );
        await windowManager.setAlwaysOnTop(true);
        if (!await windowManager.isAlwaysOnTop()) {
          throw StateError('当前桌面环境不支持窗口置顶');
        }
        floating.value = true;
      }
    } catch (_) {
      if (!mobile && _bounds != null) {
        try {
          await exit(player);
        } catch (_) {}
      }
      floating.value = false;
      platformPip.value = false;
      rethrow;
    } finally {
      _transition = false;
    }
  }

  Future<dynamic> _nativeEvent(MethodCall call) async {
    if (_closed) return;
    if (call.method == 'pip') {
      final active = call.arguments == true;
      if (!active && platformPip.value) _pipExitAt = DateTime.now();
      platformPip.value = active;
      floating.value = active;
      if (!active &&
          mobile &&
          !_settings.backgroundPlayback &&
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        await _player?.pause();
      }
    } else if (call.method == 'restore') {
      _media?.external = null;
      final data = Map<String, dynamic>.from(call.arguments as Map);
      externalPosition = Duration(
        milliseconds: (data['position'] as num).toInt(),
      );
      onExternalProgress?.call();
      await _player?.seek(
        Duration(milliseconds: (data['position'] as num).toInt()),
      );
      externalPosition = null;
      platformPip.value = false;
      floating.value = false;
      if (data['ended'] == true) {
        if (!mobile ||
            _settings.backgroundPlayback ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          onExternalCompleted?.call();
        }
      } else if (data['playing'] == true &&
          (!mobile ||
              _settings.backgroundPlayback ||
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed)) {
        await _player?.play();
      }
      _restorePending?.complete();
      _restorePending = null;
    } else if (call.method == 'progress') {
      final data = call.arguments as Map;
      externalPlaying = data['playing'] == true;
      externalPosition = Duration(
        milliseconds: (data['position'] as num).toInt(),
      );
      onExternalProgress?.call();
      if (_media == null) return;
      _media!.playbackState.add(
        _media!.playbackState.value.copyWith(
          processingState: AudioProcessingState.ready,
          playing: data['playing'] == true,
          updatePosition: Duration(
            milliseconds: (data['position'] as num).toInt(),
          ),
        ),
      );
    }
  }

  Future<void> exit(mk.Player player) =>
      _exiting ??= _exit(player).whenComplete(() => _exiting = null);

  Future<void> _exit(mk.Player player) async {
    if (mobile || nativeHandoff) {
      if (floating.value) {
        _pipExitAt = DateTime.now();
        if (nativeHandoff) _restorePending ??= Completer<void>();
        await _channel.invokeMethod('exit');
        if (nativeHandoff) {
          await _restorePending?.future.timeout(const Duration(seconds: 5));
          return;
        }
      }
    } else if (_bounds != null) {
      await windowManager.setAlwaysOnTop(_top);
      await windowManager.setBounds(_bounds!);
      if (_maximized) await windowManager.maximize();
      if (_fullscreen) await windowManager.setFullScreen(true);
      _bounds = null;
    }
    floating.value = false;
    platformPip.value = false;
  }

  Future<void> dispose(mk.Player player) async {
    if (_closed) return;
    try {
      if (Platform.isMacOS) {
        _closed = true;
        await _channel.invokeMethod('dispose');
      } else {
        await exit(player);
      }
    } catch (_) {
      /* Window may already be closing. */
    }
    _closed = true;
    if (_observingWindow) windowManager.removeListener(this);
    nativeFullscreen.dispose();
    await _media?.detach(player);
    for (final event in _audioEvents) {
      await event.cancel();
    }
    _audioEvents.clear();
    if (mobile || nativeHandoff) _channel.setMethodCallHandler(null);
    floating.dispose();
    platformPip.dispose();
  }
}
