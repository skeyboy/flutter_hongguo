import 'package:flutter/material.dart';
import 'package:hongguo_cast/hongguo_cast.dart';

import '../navigation/app_navigation.dart';
import 'cast_controller.dart';

/// The remote-control screen shown while the television does the playing.
///
/// Resolves to the position the television reached, which is where the player
/// screen resumes locally; `null` means the page closed while the session was
/// still running and the caller must stop it.
Future<Duration?> showCastRemote(
  BuildContext context,
  CastController controller,
) async {
  final position = await pushAppPage<double>(
    context,
    AppScreen.cast,
    (_) => CastRemotePage(controller: controller),
  );
  if (position == null) {
    return controller.active ? await controller.stop() : null;
  }
  return Duration(seconds: position.round());
}

class CastRemotePage extends StatefulWidget {
  final CastController controller;
  final VoidCallback? onPrevious, onNext;
  const CastRemotePage({
    super.key,
    required this.controller,
    this.onPrevious,
    this.onNext,
  });

  @override
  State<CastRemotePage> createState() => _CastRemotePageState();
}

class _CastRemotePageState extends State<CastRemotePage> {
  double? scrub;

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 359999);
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _exit() async {
    final position = await widget.controller.stop();
    if (mounted) Navigator.pop(context, position.inSeconds.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(controller.target?.friendlyName ?? '投屏'),
        actions: [
          IconButton(
            key: const ValueKey('cast-exit'),
            tooltip: '退出投屏',
            onPressed: _exit,
            icon: const Icon(Icons.cast_connected_rounded),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (_, _) {
          final total = controller.duration;
          final playing = controller.phase == CastPhase.streaming;
          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Text(
                    controller.title ?? '',
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _status(controller),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: controller.phase == CastPhase.failed
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (controller.error != null &&
                    controller.phase != CastPhase.failed)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      controller.error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        _clock(
                          Duration(
                            seconds: (scrub ?? controller.position.inSeconds)
                                .toInt(),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('cast-scrub'),
                          value: total == null || total.inSeconds == 0
                              ? 0
                              : (scrub ??
                                        controller.position.inSeconds
                                            .toDouble())
                                    .clamp(0.0, total.inSeconds.toDouble()),
                          max: total?.inSeconds.toDouble() ?? 1,
                          onChanged: total == null
                              ? null
                              : (value) => setState(() => scrub = value),
                          onChangeEnd: total == null
                              ? null
                              : (value) {
                                  scrub = null;
                                  controller.seekTo(
                                    Duration(seconds: value.round()),
                                  );
                                },
                        ),
                      ),
                      Text(_clock(total ?? Duration.zero)),
                    ],
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      key: const ValueKey('cast-previous'),
                      tooltip: '上一集',
                      onPressed: widget.onPrevious == null || !controller.active
                          ? null
                          : widget.onPrevious,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    IconButton(
                      key: const ValueKey('cast-play'),
                      tooltip: playing ? '暂停' : '继续播放',
                      onPressed: controller.active
                          ? () => playing
                                ? controller.pause()
                                : controller.resume()
                          : null,
                      iconSize: 44,
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('cast-next'),
                      tooltip: '下一集',
                      onPressed: widget.onNext == null || !controller.active
                          ? null
                          : widget.onNext,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      key: const ValueKey('cast-volume-down'),
                      tooltip: '音量减',
                      onPressed: controller.active
                          ? () => controller.setVolume(
                              ((controller.volumePercent ?? 50) - 10).clamp(
                                0,
                                100,
                              ),
                            )
                          : null,
                      icon: const Icon(Icons.volume_down_rounded),
                    ),
                    Text(
                      controller.volumePercent == null
                          ? '音量未知'
                          : '音量 ${controller.volumePercent}%',
                    ),
                    IconButton(
                      key: const ValueKey('cast-volume-up'),
                      tooltip: '音量加',
                      onPressed: controller.active
                          ? () => controller.setVolume(
                              ((controller.volumePercent ?? 50) + 10).clamp(
                                0,
                                100,
                              ),
                            )
                          : null,
                      icon: const Icon(Icons.volume_up_rounded),
                    ),
                  ],
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '退出后手机会从电视当前位置继续播放。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: FilledButton(
                    key: const ValueKey('cast-stop'),
                    onPressed: controller.active ? _exit : null,
                    child: const Text('退出投屏'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _status(CastController controller) => switch (controller.phase) {
  CastPhase.preparing => '正在把画面交给电视…',
  CastPhase.streaming => '正在 ${controller.target?.friendlyName ?? '电视'} 上播放',
  CastPhase.paused => '已在电视上暂停',
  CastPhase.stopped => '投屏已结束',
  CastPhase.failed => controller.error ?? '投屏失败',
  CastPhase.idle => '尚未开始投屏',
};
