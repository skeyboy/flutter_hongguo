import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_cast/hongguo_cast.dart';

import '../navigation/app_navigation.dart';
import '../platform/runtime.dart';
import '../playback/episode_pager.dart';
import 'cast_device_sheet.dart';
import 'cast_service.dart';

/// The remote-control screen shown while the television does the playing.
///
/// Resolves to the position the television reached **only when the viewer stopped
/// the cast**, which is where the player screen resumes locally. `null` means the
/// page was put away while the session keeps running — the floating window is
/// still there to bring it back.
Future<Duration?> showCastRemote(
  BuildContext context,
  CastService service,
) async {
  final stopped = await pushAppPage<double>(
    context,
    AppScreen.cast,
    (_) => CastRemotePage(service: service),
  );
  return stopped == null ? null : Duration(seconds: stopped.round());
}

class CastRemotePage extends StatefulWidget {
  final CastService service;
  const CastRemotePage({super.key, required this.service});

  @override
  State<CastRemotePage> createState() => _CastRemotePageState();
}

class _CastRemotePageState extends State<CastRemotePage> {
  double? scrub;

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 359999);
    final mmss =
        '${(seconds % 3600 ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    return seconds < 3600
        ? mmss
        : '${(seconds ~/ 3600).toString().padLeft(2, '0')}:$mmss';
  }

  Future<void> _exit() async {
    final position = await widget.service.stop();
    if (mounted) Navigator.pop(context, position.inSeconds.toDouble());
  }

  Future<void> _switchDevice() async {
    final service = widget.service;
    unawaited(service.browse());
    final picked = await showCastDevicePicker(context, service);
    if (picked == null || picked.udn == service.target?.udn) return;
    await service.switchTo(picked);
  }

  Future<void> _chooseQuality() async {
    final service = widget.service;
    final episode = service.episode;
    final local = service.runtime;
    if (episode == null || local is! LocalMediaRuntime) return;
    final files = await local.localEpisodes();
    if (!mounted) return;
    final cached =
        files
            .where((file) => file.vid == episode.vid)
            .map((file) => file.quality)
            .toSet()
          ..add(service.quality);
    final values = cached.toList()..sort();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('清晰度', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final value in values)
              ListTile(
                key: ValueKey('cast-quality-$value'),
                dense: true,
                title: Text(
                  value == 'best' || value == 'auto'
                      ? '自动（已缓存）'
                      : '$value（已缓存）',
                ),
                trailing: value == service.quality
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await service.setQuality(picked);
  }

  Future<void> _chooseEpisode() async {
    final service = widget.service;
    if (service.episodes.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .5,
        child: EpisodePager(
          episodes: service.episodes,
          currentIndex: () => service.index,
          onSelected: (index) {
            Navigator.pop(context);
            unawaited(service.playAt(index));
          },
          rows: 2,
          cellExtent: 100,
        ),
      ),
    );
  }

  void _nudge(int seconds) {
    final service = widget.service;
    final target = service.position + Duration(seconds: seconds);
    unawaited(service.seekTo(target < Duration.zero ? Duration.zero : target));
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        // Its own listener: the body rebuilds on its own, and a title that only
        // refreshes with the page would keep naming the episode before this one.
        title: ListenableBuilder(
          listenable: service,
          builder: (_, _) => Text(service.title ?? '投屏'),
        ),
        actions: [
          IconButton(
            key: const ValueKey('cast-exit'),
            tooltip: '退出投屏',
            onPressed: _exit,
            icon: const Icon(Icons.power_settings_new_rounded),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (_, _) {
          final total = service.duration;
          final playing = service.phase == CastPhase.streaming;
          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    service.target?.friendlyName ?? '未连接电视',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _status(service),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: service.phase == CastPhase.failed
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('cast-switch-device'),
                  onPressed: service.browsing ? null : _switchDevice,
                  icon: const Icon(Icons.tv_rounded, size: 18),
                  label: const Text('换设备'),
                ),
                if (service.error != null && service.phase != CastPhase.failed)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 8,
                    ),
                    child: Text(
                      service.error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Row(
                    children: [
                      Text(
                        _clock(
                          Duration(
                            seconds: (scrub ?? service.position.inSeconds)
                                .toInt(),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('cast-scrub'),
                          value: total == null || total.inSeconds == 0
                              ? 0
                              : (scrub ?? service.position.inSeconds.toDouble())
                                    .clamp(0.0, total.inSeconds.toDouble()),
                          max: total?.inSeconds.toDouble() ?? 1,
                          onChanged: total == null
                              ? null
                              : (value) => setState(() => scrub = value),
                          onChangeEnd: total == null
                              ? null
                              : (value) {
                                  scrub = null;
                                  service.seekTo(
                                    Duration(seconds: value.round()),
                                  );
                                },
                        ),
                      ),
                      Text(_clock(total ?? Duration.zero)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _Card(
                    child: Row(
                      children: [
                        Expanded(
                          child: _Action(
                            key: const ValueKey('cast-quality'),
                            label: '清晰度',
                            value: _qualityLabel(service.quality),
                            onTap: service.active ? _chooseQuality : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      key: const ValueKey('cast-back-10'),
                      tooltip: '后退 10 秒',
                      onPressed: service.active ? () => _nudge(-10) : null,
                      iconSize: 34,
                      icon: const Icon(Icons.replay_10_rounded),
                    ),
                    IconButton(
                      key: const ValueKey('cast-play'),
                      tooltip: playing ? '暂停' : '继续播放',
                      onPressed: service.active
                          ? () => playing ? service.pause() : service.resume()
                          : null,
                      iconSize: 44,
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('cast-forward-10'),
                      tooltip: '前进 10 秒',
                      onPressed: service.active ? () => _nudge(10) : null,
                      iconSize: 34,
                      icon: const Icon(Icons.forward_10_rounded),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      key: const ValueKey('cast-volume-down'),
                      tooltip: '音量减',
                      onPressed: service.active
                          ? () => _volume(service, -10)
                          : null,
                      icon: const Icon(Icons.volume_down_rounded),
                    ),
                    IconButton(
                      key: const ValueKey('cast-volume-up'),
                      tooltip: '音量加',
                      onPressed: service.active
                          ? () => _volume(service, 10)
                          : null,
                      icon: const Icon(Icons.volume_up_rounded),
                    ),
                  ],
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      TextButton(
                        key: const ValueKey('cast-episodes'),
                        onPressed: service.episodes.isEmpty
                            ? null
                            : _chooseEpisode,
                        child: const Text('选集'),
                      ),
                      const Spacer(),
                      TextButton(
                        key: const ValueKey('cast-previous'),
                        onPressed: service.canPrevious && service.active
                            ? () => unawaited(service.previous())
                            : null,
                        child: const Text('上一集'),
                      ),
                      TextButton(
                        key: const ValueKey('cast-next'),
                        onPressed: service.canNext && service.active
                            ? () => unawaited(service.next())
                            : null,
                        child: const Text('下一集'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    '返回或收起本页，电视会继续播放。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _volume(CastService service, int delta) => unawaited(
    service.setVolume(((service.volumePercent ?? 50) + delta).clamp(0, 100)),
  );
}

String _qualityLabel(String value) => switch (value) {
  'best' || 'auto' => '自动',
  _ => value,
};

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: child,
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final String label, value;
  final VoidCallback? onTap;
  const _Action({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: key,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(value, style: theme.textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}

String _status(CastService service) => switch (service.phase) {
  CastPhase.preparing => '正在把画面交给电视…',
  CastPhase.streaming => '正在 ${service.target?.friendlyName ?? '电视'} 上播放',
  CastPhase.paused => '已在电视上暂停',
  CastPhase.stopped => '投屏已结束',
  CastPhase.failed => service.error ?? '投屏失败',
  CastPhase.idle => '尚未开始投屏',
};
