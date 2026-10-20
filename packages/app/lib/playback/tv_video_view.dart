import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// TV uses Android's native video pipeline. Source preparation remains in the
/// shared runtime; this adapter owns only rendering and transport state.
class TvPlaybackController extends ChangeNotifier {
  VideoPlayerController? _video;
  int _revision = 0;
  VideoPlayerController? get video => _video;
  Duration get position => _video?.value.position ?? Duration.zero;
  Duration get duration => _video?.value.duration ?? Duration.zero;
  bool get playing => _video?.value.isPlaying ?? false;
  bool get completed => _video?.value.isCompleted ?? false;
  String? get error => _video?.value.errorDescription;
  void _changed() => notifyListeners();

  Future<void> open(
    String source, {
    Duration offset = Duration.zero,
    bool play = true,
  }) async {
    final ticket = ++_revision;
    final previous = _video;
    _video = null;
    previous?.removeListener(_changed);
    await previous?.dispose();
    if (ticket != _revision) return;
    // Android's DefaultDataSource handles file:// and content:// as local data,
    // as well as HTTPS. No extra HTTP server or video download is introduced.
    final next = VideoPlayerController.networkUrl(
      Uri.parse(source),
      // Native SurfaceView applies decoder crop/stride metadata correctly for
      // HEVC on affected Android TV devices; avoid the Flutter texture bridge.
      viewType: VideoViewType.platformView,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
    );
    _video = next;
    next.addListener(_changed);
    notifyListeners();
    try {
      await next.initialize();
      if (ticket != _revision) return;
      if (offset > Duration.zero) await next.seekTo(offset);
      if (ticket != _revision) return;
      if (play) await next.play();
    } catch (_) {
      if (ticket == _revision) rethrow;
    }
  }

  Future<void> toggle() async {
    final video = _video;
    if (video == null) return;
    if (video.value.isPlaying) {
      await video.pause();
    } else {
      await video.play();
    }
  }

  Future<void> pause() async => _video?.pause();
  Future<void> seek(Duration target) async {
    final end = duration.inMilliseconds;
    await _video?.seekTo(
      Duration(milliseconds: target.inMilliseconds.clamp(0, end)),
    );
  }

  Future<void> close() async {
    _revision++;
    final previous = _video;
    _video = null;
    previous?.removeListener(_changed);
    await previous?.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

class TvVideoView extends StatelessWidget {
  final TvPlaybackController controller;
  const TvVideoView({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) {
      final video = controller.video;
      return ColoredBox(
        color: Colors.black,
        child: video?.value.isInitialized == true
            ? Center(
                child: AspectRatio(
                  aspectRatio: video!.value.aspectRatio,
                  child: VideoPlayer(video),
                ),
              )
            : const SizedBox.expand(),
      );
    },
  );
}
