import 'dart:async';

import '../protocol/description.dart';
import '../protocol/didl.dart';
import '../protocol/soap.dart';
import '../protocol/time.dart';
import '../upnp_exception.dart';

enum CastPhase { idle, preparing, streaming, paused, stopped, failed }

/// What the control surface needs to draw: state, playhead and the failure
/// text, in one immutable value so the UI never has to merge two sources.
class CastSnapshot {
  const CastSnapshot({
    required this.phase,
    this.item,
    this.position = Duration.zero,
    this.duration,
    this.volumePercent,
    this.error,
  });

  final CastPhase phase;
  final DidlItem? item;
  final Duration position;
  final Duration? duration;
  final int? volumePercent;
  final String? error;

  bool get isActive =>
      phase == CastPhase.preparing ||
      phase == CastPhase.streaming ||
      phase == CastPhase.paused;

  CastSnapshot copyWith({
    CastPhase? phase,
    DidlItem? item,
    Duration? position,
    Duration? duration,
    int? volumePercent,
    String? error,
    bool clearError = false,
  }) => CastSnapshot(
    phase: phase ?? this.phase,
    item: item ?? this.item,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    volumePercent: volumePercent ?? this.volumePercent,
    error: clearError ? null : error ?? this.error,
  );

  @override
  String toString() => 'CastSnapshot(${phase.name}, $position)';
}

/// Controls one MediaRenderer through its AVTransport and RenderingControl
/// services.
///
/// Renderers are unreliable neighbours: they answer SOAP faults with HTTP 500,
/// go quiet while buffering, and do not all implement every action. Every
/// command therefore ends in a snapshot, never in a thrown exception the UI has
/// to catch.
class CastSession {
  CastSession({
    required this.device,
    SoapPoster? post,
    this.pollInterval = const Duration(seconds: 2),
    this.maxMissedPolls = 3,
  }) : _av = _bind(device, (service) => service.isAvTransport, post),
       _rc = _bind(device, (service) => service.isRenderingControl, post);

  final UpnpDevice device;
  final Duration pollInterval;
  final int maxMissedPolls;

  final SoapService? _av;
  final SoapService? _rc;

  final StreamController<CastSnapshot> _controller =
      StreamController<CastSnapshot>.broadcast();
  CastSnapshot _snapshot = const CastSnapshot(phase: CastPhase.idle);
  Timer? _pollTimer;
  int _missedPolls = 0;
  bool _disposed = false;

  CastSnapshot get snapshot => _snapshot;

  Stream<CastSnapshot> get updates => _controller.stream;

  Future<void> cast(DidlItem item) async {
    final av = _av;
    if (av == null) {
      _fail('设备未提供 AVTransport 服务', item: item);
      return;
    }
    _emit(
      _snapshot.copyWith(
        phase: CastPhase.preparing,
        item: item,
        clearError: true,
      ),
    );
    try {
      await av.call(
        'SetAVTransportURI',
        arguments: {
          'InstanceID': '0',
          'CurrentURI': item.uri.toString(),
          'CurrentURIMetaData': buildDidl(item),
        },
      );
      await av.call(
        'Play',
        arguments: const {'InstanceID': '0', 'TransportSpeed': '1'},
      );
    } on UpnpException catch (error) {
      _fail(error.message, item: item);
      return;
    }
    _missedPolls = 0;
    _startPolling();
    _emit(
      _snapshot.copyWith(
        phase: CastPhase.streaming,
        duration: item.duration,
        position: Duration.zero,
      ),
    );
  }

  Future<void> pause() => _command('Pause', CastPhase.paused);

  Future<void> resume() => _command(
    'Play',
    CastPhase.streaming,
    arguments: const {'TransportSpeed': '1'},
  );

  /// Relative seek, which is the only unit every renderer profile promises.
  Future<void> seek(Duration position) => _command(
    'Seek',
    _snapshot.phase,
    arguments: {'Unit': 'REL_TIME', 'Target': formatUpnpTime(position)},
    after: (result) => _snapshot.copyWith(position: position),
  );

  Future<void> stop() async {
    final av = _av;
    if (av == null) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      await av.call('Stop', arguments: const {'InstanceID': '0'});
    } on UpnpException catch (error) {
      _fail(error.message, item: _snapshot.item);
      return;
    }
    _emit(
      _snapshot.copyWith(
        phase: CastPhase.stopped,
        position: Duration.zero,
        clearError: true,
      ),
    );
  }

  Future<void> setVolume(int percent) async {
    final rc = _rc;
    if (rc == null) return;
    final value = percent.clamp(0, 100);
    try {
      await rc.call(
        'SetVolume',
        arguments: {
          'InstanceID': '0',
          'Channel': 'Master',
          'DesiredVolume': '$value',
        },
      );
    } on UpnpException catch (error) {
      _fail(error.message, item: _snapshot.item);
      return;
    }
    _emit(_snapshot.copyWith(volumePercent: value));
  }

  Future<void> dispose() async {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _controller.close();
  }

  Future<void> _command(
    String action,
    CastPhase phaseOnSuccess, {
    Map<String, String> arguments = const {},
    CastSnapshot Function(Map<String, String> result)? after,
  }) async {
    final av = _av;
    if (av == null) return;
    Map<String, String> result;
    try {
      result = await av.call(
        action,
        arguments: {'InstanceID': '0', ...arguments},
      );
    } on UpnpException catch (error) {
      _fail(error.message, item: _snapshot.item);
      return;
    }
    final next = after?.call(result) ?? _snapshot;
    _emit(
      next.copyWith(
        phase: phaseOnSuccess,
        item: _snapshot.item,
        clearError: true,
      ),
    );
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    final av = _av;
    if (av == null || _disposed) return;
    try {
      final info = await av.call(
        'GetPositionInfo',
        arguments: const {'InstanceID': '0'},
        returns: const ['RelTime', 'TrackDuration'],
      );
      final state = await av.call(
        'GetTransportInfo',
        arguments: const {'InstanceID': '0'},
        returns: const ['TransportState'],
      );
      _missedPolls = 0;
      final phase = _phaseOf(state['TransportState']) ?? _snapshot.phase;
      _emit(
        _snapshot.copyWith(
          phase: phase,
          position: parseUpnpTime(info['RelTime']) ?? _snapshot.position,
          duration: parseUpnpTime(info['TrackDuration']) ?? _snapshot.duration,
          clearError: true,
        ),
      );
      if (phase == CastPhase.stopped || phase == CastPhase.idle) {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    } on UpnpException {
      // One lost poll is a busy Wi-Fi; a run of them means the renderer went
      // away while we were watching.
      _missedPolls++;
      if (_missedPolls >= maxMissedPolls) {
        _fail('电视已无响应', item: _snapshot.item);
      }
    }
  }

  void _fail(String message, {DidlItem? item}) {
    _pollTimer?.cancel();
    _pollTimer = null;
    _emit(
      _snapshot.copyWith(
        phase: CastPhase.failed,
        item: item ?? _snapshot.item,
        error: message,
      ),
    );
  }

  void _emit(CastSnapshot next) {
    _snapshot = next;
    if (!_controller.isClosed) _controller.add(next);
  }
}

CastPhase? _phaseOf(String? transportState) => switch (transportState) {
  'PLAYING' => CastPhase.streaming,
  'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => CastPhase.paused,
  'STOPPED' || 'NO_MEDIA_PRESENT' => CastPhase.stopped,
  _ => null,
};

SoapService? _bind(
  UpnpDevice device,
  bool Function(UpnpService service) test,
  SoapPoster? post,
) {
  for (final service in device.services) {
    if (test(service)) {
      return SoapService(
        serviceType: service.serviceType,
        controlUrl: service.controlUrl,
        post: post,
      );
    }
  }
  return null;
}
