import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// A shared transport bar; the surrounding chrome owns its visibility clock.
class PlaybackTransport extends StatefulWidget {
  final Player player;
  final bool playing,
      fullscreen,
      busy,
      desktop,
      canPrevious,
      canNext,
      floatingActive;
  final int episode;
  final ValueChanged<bool> onMenuChanged;
  final VoidCallback episodes, previous, next, fullscreenToggle;
  final VoidCallback? floating;
  final String? notice;
  const PlaybackTransport({
    super.key,
    required this.player,
    required this.playing,
    required this.fullscreen,
    required this.busy,
    required this.desktop,
    required this.episode,
    required this.canPrevious,
    required this.canNext,
    required this.onMenuChanged,
    this.floatingActive = false,
    required this.episodes,
    required this.previous,
    required this.next,
    required this.fullscreenToggle,
    this.floating,
    this.notice,
  });
  @override
  State<PlaybackTransport> createState() => _PlaybackTransportState();
}

class _PlaybackTransportState extends State<PlaybackTransport> {
  double? seeking;
  String time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 360000);
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$mm:${(seconds % 60).toString().padLeft(2, '0')}';
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
        minimum: const EdgeInsets.symmetric(horizontal: 8),
        child: LayoutBuilder(
          builder: (context, box) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    widget.notice!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.amber, fontSize: 12),
                  ),
                ),
              StreamBuilder<Duration>(
                stream: widget.player.stream.duration,
                initialData: widget.player.state.duration,
                builder: (context, duration) => StreamBuilder<Duration>(
                  stream: widget.player.stream.position,
                  initialData: widget.player.state.position,
                  builder: (context, position) {
                    final total = (duration.data ?? Duration.zero)
                        .inMilliseconds
                        .toDouble();
                    final value =
                        seeking ??
                        (position.data ?? Duration.zero).inMilliseconds
                            .toDouble();
                    return Row(
                      children: [
                        Text(time(Duration(milliseconds: value.toInt()))),
                        Expanded(
                          child: Slider(
                            value: total > 0 ? value.clamp(0, total) : 0,
                            max: total > 0 ? total : 1,
                            onChangeStart: total > 0
                                ? (v) => setState(() => seeking = v)
                                : null,
                            onChanged: total > 0
                                ? (v) => setState(() => seeking = v)
                                : null,
                            onChangeEnd: total > 0
                                ? (v) async {
                                    await widget.player.seek(
                                      Duration(milliseconds: v.toInt()),
                                    );
                                    if (mounted) setState(() => seeking = null);
                                  }
                                : null,
                          ),
                        ),
                        Text(time(duration.data ?? Duration.zero)),
                      ],
                    );
                  },
                ),
              ),
              Row(
                children: [
                  if (box.maxWidth >= 600)
                    IconButton(
                      tooltip: '上一集',
                      onPressed: widget.canPrevious && !widget.busy
                          ? widget.previous
                          : null,
                      icon: const Icon(Icons.skip_previous),
                    ),
                  IconButton(
                    key: const ValueKey('transport-play'),
                    tooltip: widget.playing ? '暂停' : '播放',
                    onPressed: widget.busy ? null : widget.player.playOrPause,
                    icon: Icon(
                      widget.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  if (box.maxWidth >= 600)
                    IconButton(
                      tooltip: '下一集',
                      onPressed: widget.canNext && !widget.busy
                          ? widget.next
                          : null,
                      icon: const Icon(Icons.skip_next),
                    ),
                  Expanded(
                    child: TextButton(
                      key: const ValueKey('toggle-episodes'),
                      onPressed: widget.episodes,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        '第 ${widget.episode} 集 · 选集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (widget.desktop && box.maxWidth >= 600)
                    PopupMenuButton<double>(
                      tooltip: '音量',
                      icon: const Icon(Icons.volume_up, color: Colors.white),
                      onOpened: () => widget.onMenuChanged(true),
                      onCanceled: () => widget.onMenuChanged(false),
                      onSelected: (v) {
                        widget.onMenuChanged(false);
                        widget.player.setVolume(v);
                      },
                      itemBuilder: (_) => [
                        for (final v in [0, 25, 50, 75, 100])
                          PopupMenuItem(
                            value: v.toDouble(),
                            child: Text('$v%'),
                          ),
                      ],
                    ),
                  PopupMenuButton<double>(
                    tooltip: '播放速度',
                    onOpened: () => widget.onMenuChanged(true),
                    onCanceled: () => widget.onMenuChanged(false),
                    onSelected: (v) async {
                      widget.onMenuChanged(false);
                      await widget.player.setRate(v);
                      if (mounted) setState(() {});
                    },
                    itemBuilder: (_) => [
                      for (final v in [.5, .75, 1.0, 1.25, 1.5, 2.0])
                        PopupMenuItem(value: v, child: Text('$v×')),
                    ],
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: Text('${widget.player.state.rate}×'),
                      ),
                    ),
                  ),
                  if (widget.floating != null && !widget.floatingActive)
                    IconButton(
                      tooltip: '悬浮播放',
                      onPressed: widget.floating,
                      icon: const Icon(Icons.picture_in_picture_alt_outlined),
                    ),
                  if (widget.floatingActive)
                    IconButton(
                      tooltip: '退出悬浮播放',
                      onPressed: widget.floating,
                      icon: const Icon(Icons.fullscreen_exit),
                    )
                  else
                    IconButton(
                      tooltip: widget.fullscreen ? '退出全屏' : '全屏',
                      onPressed: widget.fullscreenToggle,
                      icon: Icon(
                        widget.fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
