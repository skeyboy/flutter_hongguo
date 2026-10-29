import 'dart:async';

import 'package:media_kit/media_kit.dart' as mk;

/// The slice of the player the control bar reads and drives.
///
/// The bar used to take a `media_kit` [mk.Player] directly, which made it
/// untestable: a [mk.Player] binds libmpv on construction, so no widget test can
/// hand one over. Everything the bar needs fits here, and the tests pass a fake.
abstract class TransportPlayer {
  Stream<Duration> get position;
  Stream<Duration> get duration;

  /// How far the backend has data, as a position on the timeline. A local file
  /// reports the whole clip, so a renderer must treat `buffer >= duration` as
  /// "nothing worth drawing".
  Stream<Duration> get buffer;
  Stream<bool> get buffering;
  Stream<double> get volume;
  Stream<double> get rate;

  Duration get positionValue;
  Duration get durationValue;
  Duration get bufferValue;
  bool get bufferingValue;
  double get volumeValue;
  double get rateValue;

  Future<void> seek(Duration target);

  /// 0–100, the unit the backend and the slider both speak.
  Future<void> setVolume(double percent);
  Future<void> setRate(double rate);
  Future<void> playOrPause();
}

/// The only place the control side is allowed to touch `media_kit`.
class MediaKitTransport implements TransportPlayer {
  final mk.Player player;
  const MediaKitTransport(this.player);

  @override
  Stream<Duration> get position => player.stream.position;
  @override
  Stream<Duration> get duration => player.stream.duration;
  @override
  Stream<Duration> get buffer => player.stream.buffer;
  @override
  Stream<bool> get buffering => player.stream.buffering;
  @override
  Stream<double> get volume => player.stream.volume;
  @override
  Stream<double> get rate => player.stream.rate;

  @override
  Duration get positionValue => player.state.position;
  @override
  Duration get durationValue => player.state.duration;
  @override
  Duration get bufferValue => player.state.buffer;
  @override
  bool get bufferingValue => player.state.buffering;
  @override
  double get volumeValue => player.state.volume;
  @override
  double get rateValue => player.state.rate;

  @override
  Future<void> seek(Duration target) => player.seek(target);
  @override
  Future<void> setVolume(double percent) => player.setVolume(percent);
  @override
  Future<void> setRate(double rate) => player.setRate(rate);
  @override
  Future<void> playOrPause() => player.playOrPause();
}
