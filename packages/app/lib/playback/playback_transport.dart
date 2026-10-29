import 'package:flutter/material.dart';

import 'player_progress_bar.dart';
import 'transport_player.dart';

/// Which of the two shapes this bar wears. Computed by the page from the host,
/// the orientation and the width, so no widget below has to re-derive it.
enum ControlSurface {
  desktopWide,
  desktopNarrow,
  mobilePortrait,
  mobileLandscape;

  bool get desktop =>
      this == ControlSurface.desktopWide ||
      this == ControlSurface.desktopNarrow;
  bool get touch => !desktop;
  bool get portrait => this == ControlSurface.mobilePortrait;

  /// The order things are dropped in when the row runs out of room. Play,
  /// episodes, speed and fullscreen are never dropped.
  static const List<String> dropOrder = [
    'clock-seconds',
    'episodes-pair',
    'skip-pair',
    'volume-slider',
    'quality',
    'picture-in-picture',
    'cast',
  ];
}

/// The transport bar: where the clip is, what it will cost to move, and the
/// settings that belong to this episode rather than to the app.
///
/// The surrounding chrome owns when this is visible; this widget only owns what
/// it shows.
class PlaybackTransport extends StatefulWidget {
  final TransportPlayer player;
  final ControlSurface surface;
  final bool playing,
      fullscreen,
      busy,
      buffering,
      canPrevious,
      canNext,
      floatingActive,
      castActive;
  final int episode;
  final ValueChanged<bool> onMenuChanged;
  final VoidCallback episodes, previous, next, fullscreenToggle;
  final VoidCallback? floating, cast;
  final String? notice, title, castDevice;

  /// The current source label plus the ones this episode can be fetched at; an
  /// empty list hides the control (a cached episode has nothing to choose).
  final String quality;
  final List<String> qualities;
  final ValueChanged<String>? onQuality;

  /// Hovering or dragging the progress bar is an activity the chrome has to
  /// honour; the bar forwards it straight to the page.
  final ValueChanged<bool>? onProgressActivity;

  /// Lets the page answer a ±10s move so the picture can flash which half moved,
  /// the same shape a double tap on the picture uses. Seeks locally when absent.
  final ValueChanged<int>? onSeekBy;

  const PlaybackTransport({
    super.key,
    required this.player,
    required this.surface,
    required this.playing,
    required this.fullscreen,
    required this.busy,
    required this.episode,
    required this.onMenuChanged,
    required this.episodes,
    required this.previous,
    required this.next,
    required this.fullscreenToggle,
    required this.canPrevious,
    required this.canNext,
    required this.qualities,
    required this.quality,
    this.onQuality,
    this.onProgressActivity,
    this.onSeekBy,
    this.floating,
    this.cast,
    this.notice,
    this.title,
    this.buffering = false,
    this.castActive = false,
    this.floatingActive = false,
    this.castDevice,
  });

  static const speeds = <double>[.5, .75, 1.0, 1.25, 1.5, 2.0];

  @override
  State<PlaybackTransport> createState() => PlaybackTransportState();
}

class PlaybackTransportState extends State<PlaybackTransport> {
  /// The level to come back to when the viewer unmutes; 0 is not a preference.
  double _beforeMute = 100;

  String _speedLabel(double rate) =>
      rate == rate.roundToDouble() ? '${rate.toInt()}×' : '$rate×';

  Future<void> _skip(int seconds) async {
    final total = widget.player.durationValue;
    if (total <= Duration.zero) return;
    final target = widget.player.positionValue + Duration(seconds: seconds);
    await widget.player.seek(
      target < Duration.zero
          ? Duration.zero
          : target > total
          ? total
          : target,
    );
  }

  /// A ±10s move from a button: the page owns the seek when it can, because it
  /// also has to light up the half of the picture that answered.
  void _nudge(int seconds) {
    final cb = widget.onSeekBy;
    if (cb == null) {
      _skip(seconds);
    } else {
      cb(seconds);
    }
  }

  Future<void> _toggleMute() async {
    final volume = widget.player.volumeValue;
    if (volume > 0) {
      _beforeMute = volume;
      await widget.player.setVolume(0);
    } else {
      await widget.player.setVolume(_beforeMute <= 0 ? 100 : _beforeMute);
    }
  }

  IconData _volumeIcon(double volume) => volume <= 0
      ? Icons.volume_off_rounded
      : volume < 45
      ? Icons.volume_down_rounded
      : Icons.volume_up_rounded;

  Widget _icon(
    String key,
    IconData icon,
    String tooltip,
    VoidCallback? onPressed,
  ) => IconButton(
    key: ValueKey(key),
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon),
  );

  Widget _clock({bool withSeconds = true}) => StreamBuilder<Duration>(
    stream: widget.player.position,
    initialData: widget.player.positionValue,
    builder: (context, position) => StreamBuilder<Duration>(
      stream: widget.player.duration,
      initialData: widget.player.durationValue,
      builder: (context, duration) {
        final at = position.data ?? Duration.zero;
        final total = duration.data ?? Duration.zero;
        final text = withSeconds
            ? '${formatTransportTime(at)} / ${formatTransportTime(total)}'
            : '${(at.inSeconds ~/ 60).toString().padLeft(2, '0')}:${(at.inSeconds % 60).toString().padLeft(2, '0')} / '
                  '${(total.inSeconds ~/ 60).toString().padLeft(2, '0')}分';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(text, style: const TextStyle(fontSize: 12)),
        );
      },
    ),
  );

  Widget _volume() {
    final surface = widget.surface;
    final slider = StreamBuilder<double>(
      stream: widget.player.volume,
      initialData: widget.player.volumeValue,
      builder: (context, volume) {
        final at = volume.data ?? widget.player.volumeValue;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _icon(
              'transport-volume',
              _volumeIcon(at),
              at <= 0 ? '取消静音（M）' : '静音（M）',
              _toggleMute,
            ),
            if (surface == ControlSurface.desktopWide)
              SizedBox(
                width: 92,
                child: Slider(
                  key: const ValueKey('transport-volume-slider'),
                  value: at.clamp(0, 100),
                  max: 100,
                  onChanged: (value) => widget.player.setVolume(value),
                ),
              )
            else
              PopupMenuButton<void>(
                tooltip: '音量',
                icon: const Icon(Icons.tune, size: 20),
                onOpened: () => widget.onMenuChanged(true),
                onCanceled: () => widget.onMenuChanged(false),
                itemBuilder: (_) => [
                  PopupMenuItem<void>(
                    enabled: false,
                    child: Slider(
                      value: at.clamp(0, 100),
                      max: 100,
                      onChanged: (value) {
                        widget.player.setVolume(value);
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
    return slider;
  }

  Widget _speed() => StreamBuilder<double>(
    stream: widget.player.rate,
    initialData: widget.player.rateValue,
    builder: (context, rate) {
      final at = rate.data ?? widget.player.rateValue;
      return PopupMenuButton<double>(
        key: const ValueKey('transport-speed'),
        tooltip: '播放速度',
        onOpened: () => widget.onMenuChanged(true),
        onCanceled: () => widget.onMenuChanged(false),
        onSelected: (value) async {
          widget.onMenuChanged(false);
          await widget.player.setRate(value);
          if (mounted) setState(() {});
        },
        itemBuilder: (_) => [
          for (final value in PlaybackTransport.speeds)
            PopupMenuItem(
              value: value,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: (value - at).abs() < .01
                        ? const Icon(Icons.check, size: 16)
                        : null,
                  ),
                  Text('$value×'),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Text(
            _speedLabel(at),
            key: const ValueKey('transport-speed-label'),
          ),
        ),
      );
    },
  );

  Widget _quality() {
    final options = widget.qualities;
    if (options.isEmpty || widget.onQuality == null) return const SizedBox();
    return PopupMenuButton<String>(
      key: const ValueKey('transport-quality'),
      tooltip: '清晰度',
      enabled: options.length > 1,
      onOpened: () => widget.onMenuChanged(true),
      onCanceled: () => widget.onMenuChanged(false),
      onSelected: (value) {
        widget.onMenuChanged(false);
        widget.onQuality!(value);
      },
      itemBuilder: (_) => [
        for (final option in options)
          PopupMenuItem(
            value: option,
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: option == widget.quality
                      ? const Icon(Icons.check, size: 16)
                      : null,
                ),
                Text(option == 'best' || option == 'auto' ? '自动' : option),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Text(
          widget.quality == 'best' || widget.quality == 'auto'
              ? '自动'
              : widget.quality,
        ),
      ),
    );
  }

  Widget _episodes() => TextButton(
    key: const ValueKey('toggle-episodes'),
    onPressed: widget.episodes,
    style: TextButton.styleFrom(
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    child: Text(
      '第 ${widget.episode} 集 · 选集',
      key: const ValueKey('transport-episodes-label'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );

  Widget _cast() {
    if (widget.cast == null) return const SizedBox();
    return _icon(
      'cast-device',
      widget.castActive ? Icons.cast_connected : Icons.cast_outlined,
      widget.castActive
          ? '投屏中${widget.castDevice == null ? '' : '：${widget.castDevice}'}'
          : '投屏到电视',
      widget.cast,
    );
  }

  Widget _floating() {
    if (widget.floating == null) return const SizedBox();
    if (widget.floatingActive) {
      return _icon(
        'exit-pip',
        Icons.fullscreen_exit,
        '退出悬浮播放',
        widget.floating,
      );
    }
    return _icon(
      'enter-pip',
      Icons.picture_in_picture_alt_outlined,
      widget.title != null ? '画中画' : '悬浮播放',
      widget.floating,
    );
  }

  Widget _fullscreen() => _icon(
    'transport-fullscreen',
    widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
    widget.fullscreen ? '退出全屏' : '全屏',
    widget.fullscreenToggle,
  );

  List<Widget> _left() {
    final surface = widget.surface;
    return [
      IconButton(
        key: const ValueKey('transport-play'),
        tooltip: widget.playing
            ? (surface.desktop ? '暂停（空格）' : '暂停')
            : (surface.desktop ? '播放（空格）' : '播放'),
        onPressed: widget.busy ? null : widget.player.playOrPause,
        icon: Icon(
          widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        ),
      ),
      if (surface != ControlSurface.mobilePortrait) ...[
        _icon(
          'transport-seek-back',
          Icons.replay_10_rounded,
          surface.desktop ? '快退 10 秒（J）' : '快退 10 秒',
          widget.busy ? null : () => _nudge(-10),
        ),
        _icon(
          'transport-seek-forward',
          Icons.forward_10_rounded,
          surface.desktop ? '快进 10 秒（L）' : '快进 10 秒',
          widget.busy ? null : () => _nudge(10),
        ),
      ],
      if (surface == ControlSurface.desktopWide) ...[
        _icon(
          'transport-previous',
          Icons.skip_previous,
          '上一集（Page Up）',
          widget.canPrevious && !widget.busy ? widget.previous : null,
        ),
        _icon(
          'transport-next',
          Icons.skip_next,
          '下一集（Page Down）',
          widget.canNext && !widget.busy ? widget.next : null,
        ),
      ],
      if (surface.desktop) _volume(),
      if (surface == ControlSurface.desktopNarrow ||
          surface == ControlSurface.mobileLandscape)
        _clock(),
    ];
  }

  List<Widget> _right() {
    final surface = widget.surface;
    return [
      if (surface.portrait)
        // A phone held in portrait is the one row that can run out of room for
        // the episode label, and ellipsising it beats a layout error.
        Flexible(child: _episodes())
      else
        _episodes(),
      if (surface == ControlSurface.desktopWide ||
          surface == ControlSurface.mobileLandscape)
        _quality(),
      _speed(),
      if (surface != ControlSurface.mobilePortrait) _cast(),
      if (surface == ControlSurface.desktopWide) _floating(),
      _fullscreen(),
    ];
  }

  @override
  Widget build(BuildContext context) => IconButtonTheme(
    data: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white24,
      ),
    ),
    child: DefaultTextStyle(
      style: const TextStyle(color: Colors.white, fontSize: 12),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${widget.title} · 第 ${widget.episode} 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            if (widget.notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.notice!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.amber, fontSize: 12),
                  ),
                ),
              ),
            if (widget.surface == ControlSurface.desktopWide ||
                widget.surface == ControlSurface.mobilePortrait)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: _clock(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: PlayerProgressBar(
                key: const ValueKey('player-progress'),
                player: widget.player,
                touch: widget.surface.touch,
                onActivityChanged: widget.onProgressActivity,
                enabled:
                    !widget.busy && widget.player.durationValue > Duration.zero,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(children: [..._left(), const Spacer(), ..._right()]),
            ),
          ],
        ),
      ),
    ),
  );
}
