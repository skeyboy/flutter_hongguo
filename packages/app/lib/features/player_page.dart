import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../platform/runtime.dart';
import '../platform/background/playback_platform.dart';
import '../playback/prefetch_window.dart';
import '../playback/local_playlist.dart';
import '../playback/episode_workspace.dart';
import '../playback/compact_controls.dart';
import 'settings_page.dart';

const bool softwareVideo = bool.fromEnvironment('HONGGUO_SOFTWARE_VIDEO');

class PlayerPage extends StatefulWidget {
  final AppRuntime runtime;
  final DramaDetail detail;
  final int initialPosition;
  final bool cachedOnly;
  final String? cachedQuality;
  const PlayerPage({
    super.key,
    required this.runtime,
    required this.detail,
    this.initialPosition = 0,
    this.cachedOnly = false,
    this.cachedQuality,
  });
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final Player player;
  final platformPlayback = PlaybackPlatform();
  Future<void> platformUpdates = Future.value();
  bool appBackground = false, preparationInterrupted = false;

  late final VideoController controller;
  final subscriptions = <StreamSubscription<dynamic>>[];
  PlaybackJob? job;
  late final PrefetchWindow prefetch;
  String quality = 'best';
  String? sourceVid, sourceQuality;
  PreparationProgress? progress;
  final preparationStages = <String>[];
  Object? error;
  String? audioNotice, playbackNotice;
  late final String cachedPreference;
  bool preparing = true, autoNext = true, playing = false;
  final episodeWorkspace = GlobalKey<EpisodeWorkspaceState>();
  final compactControls = GlobalKey<CompactControlsState>();
  late int position;
  int generation = 0;
  final panelRevision = ValueNotifier<int>(0);
  bool sheetOpen = false;
  double verticalDrag = 0;
  void _redraw(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    panelRevision.value++;
  }

  @override
  void initState() {
    super.initState();
    final runtime = widget.runtime;
    if (!widget.cachedOnly && runtime is LibraryCacheRuntime) {
      unawaited(
        rememberDramaMetadata(runtime, widget.detail).catchError((Object _) {}),
      );
    }
    position = widget.initialPosition;
    final preferences = settingsFor(widget.runtime);
    cachedPreference = widget.cachedQuality ?? preferences.defaultQuality;
    quality = cachedPreference;
    autoNext = preferences.autoNext;
    prefetch = PrefetchWindow(
      runtime: widget.runtime,
      episodes: widget.detail.episodes,
      onChanged: () {
        if (mounted) _redraw(() {});
      },
    );
    WidgetsBinding.instance.addObserver(this);
    player = Player();
    controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        // GitHub-hosted macOS runners expose no accelerated OpenGL pixel format,
        // and media_kit_video force-unwraps CGLChoosePixelFormat's result, which
        // aborts the process. CPU rendering is the only native path available there.
        enableHardwareAcceleration: !softwareVideo,
        hwdec: softwareVideo ? 'no' : null,
      ),
    );
    subscriptions.add(
      player.stream.error.listen((value) {
        if (mounted && value.isNotEmpty) {
          final lower = value.toLowerCase();
          if (lower.contains('audio device') || lower.contains('no sound')) {
            _redraw(() => audioNotice = '声音暂不可用，画面可以继续播放。请检查音频输出设备。');
          } else {
            _redraw(() => error = value);
          }
        }
      }),
    );
    subscriptions.add(
      player.stream.playing.listen((value) {
        if (mounted && value != playing) _redraw(() => playing = value);
      }),
    );
    platformPlayback.onExternalCompleted = () => _completed(true);
    platformPlayback.floating.addListener(_platformChanged);
    platformPlayback.platformPip.addListener(_platformChanged);
    if (runtime is ConfigurableRuntime) {
      subscriptions.add(
        runtime.settingsChanges.listen((_) {
          _configurePlatform();
          if (appBackground &&
              !settingsFor(runtime).backgroundPlayback &&
              !platformPlayback.floating.value) {
            player.pause();
          }
          if (mounted) _redraw(() {});
        }),
      );
    }
    _configurePlatform();
    subscriptions.add(player.stream.completed.listen(_completed));
    _play(position);
  }

  void _completed(bool value) {
    if (!value ||
        !autoNext ||
        !mounted ||
        preparing ||
        error != null ||
        position + 1 >= widget.detail.episodes.length) {
      return;
    }
    final current = widget.detail.episodes[position],
        next = widget.detail.episodes[position + 1];
    if (widget.cachedOnly && !localEpisodesAreConsecutive(current, next)) {
      _redraw(
        () =>
            playbackNotice = '第 ${current.index + 1} 集尚未缓存，已停止连播。可手动选择其他已缓存分集。',
      );
      return;
    }
    _play(position + 1);
  }

  void _platformChanged() {
    if (mounted) _redraw(() {});
  }

  void _configurePlatform() {
    platformUpdates = platformUpdates.catchError((Object _) {}).then((_) async {
      if (!mounted) return;
      try {
        await platformPlayback.configure(
          player,
          settingsFor(widget.runtime),
          '${widget.detail.drama.title} · 第 ${widget.detail.episodes[position].index} 集',
          step: (offset) async => _step(offset),
        );
      } catch (_) {
        if (mounted) {
          _redraw(() => playbackNotice = '后台媒体控制暂不可用，请检查系统权限或返回设置重试。');
        }
      }
    });
  }

  Future<void> _floating() async {
    if (preparing || sourceVid == null) return;
    try {
      if (platformPlayback.floating.value) {
        await platformPlayback.exit(player);
      } else {
        await platformPlayback.enter(
          player,
          player.state.playlist.medias.single.uri,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is StateError ? e.message : '当前设备无法进入悬浮模式，请检查画中画权限或系统支持。',
            ),
          ),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      appBackground = false;
      if (preparationInterrupted) {
        preparationInterrupted = false;
        _play(position);
      } else {
        _syncPrefetch();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      appBackground = true;
      final preferences = settingsFor(widget.runtime);
      if (!preferences.backgroundDownloads) {
        prefetch.clear();
        if (preparing && !preferences.backgroundPlayback) {
          preparationInterrupted = true;
          job?.cancel();
        }
      }
      if (!preferences.backgroundPlayback && !platformPlayback.floating.value) {
        player.pause();
      }
    }
    // inactive also covers notification permission dialogs and brief window
    // transitions; it must not interrupt audio or a PiP hand-off.
  }

  Future<void> _play(int selected) async {
    final ticket = ++generation;
    final previous = job;
    final discard = error != null;
    final oldVid = sourceVid, oldQuality = sourceQuality;
    job = null;
    previous?.cancel();
    if (!mounted) return;
    _redraw(() {
      position = selected;
      preparing = true;
      error = null;
      audioNotice = null;
      playbackNotice = null;
      progress = const PreparationProgress('正在准备');
      preparationStages.clear();
    });
    try {
      // Close the old data source before releasing the cache pin (Windows too).
      await player.stop();
      previous?.release();
      if (!widget.cachedOnly &&
          discard &&
          oldVid != null &&
          oldQuality != null) {
        await widget.runtime.evict(oldVid, quality: oldQuality);
      }
      if (!mounted || ticket != generation) return;
      if (widget.cachedOnly) {
        final files = await (widget.runtime as LocalMediaRuntime)
            .localEpisodes();
        if (!mounted || ticket != generation) return;
        final available = localQualityFor(
          widget.detail.episodes[selected].vid,
          files,
          cachedPreference,
        );
        if (available == null) throw StateError('该集本地缓存已不存在，连播已停止；不会自动联网下载。');
        quality = available;
      }
      final active = widget.cachedOnly
          ? (widget.runtime as LocalMediaRuntime).prepareLocal(
              widget.detail.episodes[selected].vid,
              quality: quality,
            )
          : widget.runtime.prepare(
              widget.detail.episodes[selected].vid,
              quality: quality,
              onProgress: (p) {
                if (mounted && ticket == generation) {
                  _redraw(() {
                    progress = p;
                    if (preparationStages.isEmpty ||
                        preparationStages.last != p.label) {
                      preparationStages.add(p.label);
                    }
                  });
                }
              },
            );
      job = active;
      _syncPrefetch();
      sourceVid = widget.detail.episodes[selected].vid;
      sourceQuality = quality;
      final source = await active.source;
      if (!mounted || ticket != generation) {
        active.release();
        return;
      }
      bool mayPlay() =>
          !appBackground ||
          settingsFor(widget.runtime).backgroundPlayback ||
          platformPlayback.floating.value;
      await player.open(Media(source), play: mayPlay());
      // The app can become hidden while the native player is opening a file.
      if (!mayPlay()) await player.pause();
      if (!mounted || ticket != generation) return;
      _redraw(() => preparing = false);
      _syncPrefetch();
      _configurePlatform();
    } catch (e) {
      previous?.release();
      if (mounted && ticket == generation) {
        prefetch.clear();
        _redraw(() {
          error = e;
          preparing = false;
        });
      }
    }
  }

  void _syncPrefetch() {
    final preferences = settingsFor(widget.runtime);
    prefetch.sync(
      position: position,
      quality: quality,
      count: preferences.prefetchEpisodes,
      enabled:
          !widget.cachedOnly &&
          preferences.prefetchEnabled &&
          (!appBackground || preferences.backgroundDownloads),
    );
  }

  Future<void> _settings() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => SettingsPage(runtime: widget.runtime)),
    );
    if (!mounted) return;
    if (changed == true) {
      autoNext = settingsFor(widget.runtime).autoNext;
      prefetch.clear();
      _syncPrefetch();
      _redraw(() {});
    }
  }

  Future<void> _setAutoNext(bool value) async {
    final previous = autoNext;
    _redraw(() => autoNext = value);
    final runtime = widget.runtime;
    if (runtime is ConfigurableRuntime) {
      try {
        await runtime.saveSettings(runtime.settings.copyWith(autoNext: value));
      } catch (_) {
        if (mounted) {
          _redraw(() => autoNext = previous);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('连播偏好未能保存')));
        }
      }
    }
    if (mounted && autoNext && player.state.completed) _completed(true);
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    prefetch.dispose();
    panelRevision.dispose();
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    final active = job;
    // Cancel preparation now, release a playing file only after player closes.
    if (preparing) active?.cancel();
    platformPlayback.floating.removeListener(_platformChanged);
    platformPlayback.platformPip.removeListener(_platformChanged);
    unawaited(
      platformUpdates
          .catchError((Object _) {})
          .then((_) async {
            await platformPlayback.dispose(player);
          })
          .catchError((Object _) {})
          .whenComplete(() async {
            await player.dispose();
            active?.release();
          }),
    );
    super.dispose();
  }

  Future<void> _openEpisodes() async {
    if (sheetOpen) return;
    _redraw(() => sheetOpen = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: ValueListenableBuilder<int>(
            valueListenable: panelRevision,
            builder: (_, _, _) => Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 20),
                    const Expanded(child: Text('选择剧集')),
                    IconButton(
                      tooltip: '关闭选集',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Expanded(child: _episodes()),
              ],
            ),
          ),
        ),
      );
    } finally {
      if (mounted) _redraw(() => sheetOpen = false);
    }
  }

  void _selectEpisode(int index) {
    _play(index);
    episodeWorkspace.currentState?.selected();
    compactControls.currentState?.hide();
    if (sheetOpen) Navigator.pop(context);
  }

  void _step(int offset) {
    final target = position + offset;
    if (target >= 0 && target < widget.detail.episodes.length) _play(target);
  }

  void _seek(int seconds) {
    final requested = player.state.position + Duration(seconds: seconds);
    final clamped = requested < Duration.zero
        ? Duration.zero
        : requested > player.state.duration
        ? player.state.duration
        : requested;
    player.seek(clamped);
  }

  Widget _touchVideo() => GestureDetector(
    onVerticalDragStart: (_) => verticalDrag = 0,
    onVerticalDragUpdate: (details) => verticalDrag += details.delta.dy,
    onVerticalDragEnd: (details) {
      if (preparing) return;
      final velocity = details.primaryVelocity ?? 0;
      if (verticalDrag.abs() > 80 || velocity.abs() > 800) {
        _step((verticalDrag == 0 ? velocity : verticalDrag) < 0 ? 1 : -1);
      }
    },
    child: _video(),
  );

  Widget _video() => ColoredBox(
    color: Colors.black,
    child: Stack(
      children: [
        Positioned.fill(
          child: Video(
            controller: controller,
            // This page owns the background/PiP policy. Video's default
            // lifecycle observer would otherwise pause even when enabled.
            pauseUponEnteringBackgroundMode: false,
            controls: platformPlayback.platformPip.value
                ? NoVideoControls
                : AdaptiveVideoControls,
          ),
        ),
        if (playbackNotice != null || audioNotice != null)
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: IgnorePointer(
              child: Material(
                color: Colors.black.withValues(alpha: .7),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    playbackNotice ?? audioNotice!,
                    style: const TextStyle(color: Colors.amber, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        if (preparing)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.85),
              child: Center(
                child: SizedBox(
                  width: 240,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.local_movies_outlined,
                        color: Colors.white70,
                        size: 38,
                      ),
                      const SizedBox(height: 24),
                      LinearProgressIndicator(
                        value: progress?.fraction,
                        color: const Color(0xffef8a70),
                        backgroundColor: Colors.white12,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        progress?.label ?? '正在准备',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      if (progress?.fraction != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${(progress!.fraction! * 100).clamp(0, 100).toStringAsFixed(0)}%',
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (error != null)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.9),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.white70,
                        size: 36,
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '暂时无法播放',
                        style: TextStyle(color: Colors.white, fontSize: 20),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '$error',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white60),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () => _play(position),
                        child: const Text('重新准备'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
  Widget _episodes() => CustomScrollView(
    key: const PageStorageKey('episode-options'),
    slivers: [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (prefetch.total > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  '已提前缓存 ${prefetch.ready} / ${prefetch.total} 集${prefetch.preparing > 0 ? ' · 正在准备' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (playbackNotice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(playbackNotice!),
              ),
            if (audioNotice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  audioNotice!,
                  style: const TextStyle(
                    color: Color(0xff9a6418),
                    fontSize: 12,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '第 ${widget.detail.episodes[position].index} 集',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('清晰度'),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: quality,
                        underline: const SizedBox(),
                        items: widget.cachedOnly
                            ? [
                                DropdownMenuItem(
                                  value: quality,
                                  child: Text(
                                    quality == 'best' || quality == 'auto'
                                        ? '自动'
                                        : quality,
                                  ),
                                ),
                              ]
                            : const [
                                DropdownMenuItem(
                                  value: 'best',
                                  child: Text('自动'),
                                ),
                                DropdownMenuItem(
                                  value: '720p',
                                  child: Text('720p'),
                                ),
                                DropdownMenuItem(
                                  value: '1080p',
                                  child: Text('1080p'),
                                ),
                              ],
                        onChanged: widget.cachedOnly
                            ? null
                            : (value) {
                                quality = value!;
                                _play(position);
                              },
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('连播'),
                      Switch(
                        key: const ValueKey('episode-auto-next'),
                        value: autoNext,
                        onChanged: _setAutoNext,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: position > 0
                          ? () => _play(position - 1)
                          : null,
                      child: const Text('上一集'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: position + 1 < widget.detail.episodes.length
                          ? () => _play(position + 1)
                          : null,
                      child: const Text('下一集'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 80,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.25,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => FilledButton.tonal(
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: index == position
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                foregroundColor: index == position
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => _selectEpisode(index),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('${widget.detail.episodes[index].index}'),
                  if (widget.cachedOnly ||
                      prefetch.phaseFor(
                            widget.detail.episodes[index].vid,
                            quality,
                          ) ==
                          PrefetchPhase.ready)
                    const Text('已缓存', style: TextStyle(fontSize: 9)),
                ],
              ),
            ),
            childCount: widget.detail.episodes.length,
          ),
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) {
      final size = Size(viewport.maxWidth, viewport.maxHeight);
      final compact = size.width < 720 && size.height >= size.width;
      final floating = platformPlayback.floating.value;
      final pip = platformPlayback.platformPip.value;
      // Android may restore the Activity before its PiP-sized constraints grow.
      if (pip || (platformPlayback.restoringPip && size.width < 280)) {
        return Scaffold(backgroundColor: Colors.black, body: _video());
      }
      if (floating && !platformPlayback.mobile) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(child: _video()),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  tooltip: '退出悬浮播放',
                  onPressed: _floating,
                  icon: const Icon(Icons.fullscreen_exit),
                  color: Colors.white,
                ),
              ),
            ],
          ),
        );
      }
      final scaffold = Scaffold(
        backgroundColor: compact ? Colors.black : null,
        appBar: AppBar(
          backgroundColor: compact ? Colors.black : null,
          foregroundColor: compact ? Colors.white : null,
          title: Text(
            widget.detail.drama.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (settingsFor(widget.runtime).floatingPlayback)
              IconButton(
                tooltip: floating ? '退出悬浮播放' : '悬浮播放',
                onPressed: preparing ? null : _floating,
                icon: const Icon(Icons.picture_in_picture_alt),
              ),
            IconButton(
              key: const ValueKey('toggle-episodes'),
              tooltip: '显示或隐藏选集',
              onPressed: compact
                  ? _openEpisodes
                  : () => episodeWorkspace.currentState?.toggle(),
              icon: const Icon(Icons.view_sidebar_outlined),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: _settings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        body: compact
            ? CompactControls(
                key: compactControls,
                video: _touchVideo(),
                playing: playing,
                busy: preparing || error != null || sheetOpen,
                controls: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (playbackNotice != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          playbackNotice!,
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    if (audioNotice != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          audioNotice!,
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.cachedOnly)
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text(
                                    '本地连播',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  Switch(
                                    value: autoNext,
                                    onChanged: _setAutoNext,
                                  ),
                                ],
                              ),
                            if (prefetch.total > 0)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  '已提前缓存 ${prefetch.ready} / ${prefetch.total} 集',
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            Row(
                              children: [
                                IconButton(
                                  tooltip: '上一集',
                                  onPressed: position > 0
                                      ? () => _step(-1)
                                      : null,
                                  icon: const Icon(Icons.skip_previous_rounded),
                                  color: Colors.white,
                                  disabledColor: Colors.white24,
                                ),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: const BorderSide(
                                        color: Colors.white38,
                                      ),
                                    ),
                                    onPressed: _openEpisodes,
                                    icon: const Icon(
                                      Icons.format_list_numbered_rounded,
                                    ),
                                    label: Text(
                                      '第 ${widget.detail.episodes[position].index} 集 · 选集',
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '下一集',
                                  onPressed:
                                      position + 1 <
                                          widget.detail.episodes.length
                                      ? () => _step(1)
                                      : null,
                                  icon: const Icon(Icons.skip_next_rounded),
                                  color: Colors.white,
                                  disabledColor: Colors.white24,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : EpisodeWorkspace(
                key: episodeWorkspace,
                video: _video(),
                episodes: _episodes(),
                playing: playing,
                busy: preparing || error != null,
              ),
      );
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () =>
              player.playOrPause(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seek(-5),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seek(5),
          const SingleActivator(LogicalKeyboardKey.pageDown): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.pageUp): () => _step(-1),
        },
        child: Focus(autofocus: true, child: scaffold),
      );
    },
  );
}
