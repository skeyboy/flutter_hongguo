import '../navigation/app_navigation.dart';
import '../personal/personal_library.dart';
import '../personal/favorite_button.dart';

import 'package:hongguo_tv/hongguo_tv.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../platform/runtime.dart';
import '../platform/background/playback_platform.dart';
import '../platform/background/host_policy.dart';
import '../platform/macos_window.dart';
import '../playback/prefetch_window.dart';
import '../playback/tv_video_view.dart';
import '../playback/local_playlist.dart';
import '../playback/episode_workspace.dart';
import '../playback/episode_swipe.dart';
import '../playback/compact_controls.dart';
import '../playback/playback_transport.dart';
import '../playback/capability_preferences.dart';
import '../cast/cast_device_sheet.dart';
import '../cast/cast_remote_page.dart';
import '../cast/cast_service.dart';
import 'settings_page.dart';

const bool softwareVideo = bool.fromEnvironment('HONGGUO_SOFTWARE_VIDEO');

class PlayerPage extends StatefulWidget {
  final AppRuntime runtime;
  final DramaDetail detail;
  final int initialPosition;
  final Duration initialOffset;
  final bool cachedOnly, resumeLastEpisode;
  final String? cachedQuality;
  final PlaybackReturnRecommendations? returnRecommendations;
  const PlayerPage({
    super.key,
    required this.runtime,
    required this.detail,
    this.initialPosition = 0,
    this.initialOffset = Duration.zero,
    this.cachedOnly = false,
    this.resumeLastEpisode = false,
    this.cachedQuality,
    this.returnRecommendations,
  });
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with WidgetsBindingObserver, RouteAware {
  ThemeData get playbackTheme =>
      macHost ? ThemeData.dark(useMaterial3: true) : Theme.of(context);

  bool windowPinned = false;
  bool pinUpdating = false;
  ModalRoute<dynamic>? _observedRoute;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (macHost) {
      final route = ModalRoute.of(context);
      if (route is PageRoute<dynamic> && route != _observedRoute) {
        macPlaybackRoutes.unsubscribe(this);
        _observedRoute = route;
        macPlaybackRoutes.subscribe(this, route);
      }
    }
  }

  @override
  void didPush() {
    unawaited(MacWindow.playerVisible(this, true));
  }

  @override
  void didPopNext() {
    unawaited(MacWindow.playerVisible(this, true));
  }

  @override
  void didPushNext() {
    unawaited(MacWindow.playerVisible(this, false));
  }

  @override
  void didPop() {
    unawaited(MacWindow.releasePlayer(this));
  }

  final playbackFocus = FocusNode(debugLabel: 'player-shortcuts');
  late final Player player;
  final platformPlayback = PlaybackPlatform();
  Future<void> platformUpdates = Future.value();
  bool appBackground = false, preparationInterrupted = false;
  bool fullscreen = false, menuOpen = false;
  bool hasPlayed = false, returnEligible = false, recommendationOpen = false;
  Timer? returnTimer;
  String? _historyVid;
  bool _episodePlayed = false, _episodeCompleted = false;
  DateTime? _historySaved;
  late Duration _resumeOffset;
  Duration _resumeSnapshotOffset = Duration.zero;

  void _saveHistory({bool force = false}) {
    if (!_episodePlayed ||
        _historyVid == null ||
        _historyVid != sourceVid ||
        preparing) {
      return;
    }
    final at = DateTime.now();
    if (!force &&
        _historySaved != null &&
        at.difference(_historySaved!).inSeconds < 10) {
      return;
    }
    _historySaved = at;
    final episode = widget.detail.episodes[position];
    final record = WatchRecord(
      drama: widget.detail.drama,
      vid: episode.vid,
      episode: episode.index,
      positionMs:
          (tvBuild
                  ? tvPlayback.position
                  : platformPlayback.externalPosition ??
                        player.state.position) ==
              Duration.zero
          ? _resumeSnapshotOffset.inMilliseconds
          : (tvBuild
                    ? tvPlayback.position
                    : platformPlayback.externalPosition ??
                          player.state.position)
                .inMilliseconds,
      durationMs: (tvBuild ? tvPlayback.duration : player.state.duration)
          .inMilliseconds,
      updated: at,
      quality: quality,
      local: widget.cachedOnly,
      finished: _episodeCompleted,
    );
    unawaited(
      personalLibraryFor(widget.runtime).record(record).catchError((Object _) {
        if (mounted) _redraw(() => playbackNotice = '观看记录保存失败，请检查本地存储空间');
      }),
    );
  }

  static final recommendations = PlaybackReturnRecommendations();

  late final VideoController controller;
  final tvPlayback = TvPlaybackController();
  bool tvCompletionReported = false;
  final subscriptions = <StreamSubscription<dynamic>>[];
  PlaybackJob? job;
  late final PrefetchWindow prefetch;
  String quality = 'best';
  String? sourceVid, sourceQuality;
  CastService? castService;
  PreparationProgress? progress;
  final preparationStages = <String>[];
  Object? error;
  String? audioNotice, playbackNotice;
  late final String cachedPreference;
  bool preparing = true, autoNext = true, playing = false;
  final episodeWorkspace = GlobalKey<EpisodeWorkspaceState>();
  final compactControls = GlobalKey<CompactControlsState>();
  Timer? edgeNoticeTimer;
  bool episodeHintDismissed = false;
  late int position;
  int generation = 0;
  List<TvQualityOption> tvQualities = const [TvQualityOption('best', '自动')];
  final tvQualityCache = <String, List<TvQualityOption>>{};
  bool tvQualitiesLoading = false;
  String? tvQualitiesError;
  int tvQualityTicket = 0;

  Future<void> _loadTvQualities() async {
    final vid = widget.detail.episodes[position].vid;
    final ticket = ++tvQualityTicket;
    _redraw(() {
      tvQualitiesLoading = true;
      tvQualitiesError = null;
    });
    try {
      final runtime = widget.runtime;
      final List<TvQualityOption> values;
      if (widget.cachedOnly && runtime is LocalMediaRuntime) {
        final files = await runtime.localEpisodes();
        final available =
            files
                .where((f) => f.vid == vid)
                .map((f) => f.quality)
                .toSet()
                .toList()
              ..sort();
        values = [
          for (final q in available)
            TvQualityOption(
              q,
              q == 'best' || q == 'auto' ? '自动（已缓存）' : '$q（已缓存）',
            ),
        ];
      } else if (tvQualityCache.containsKey(vid)) {
        values = tvQualityCache[vid]!;
      } else if (runtime is VideoQualityRuntime) {
        values = [
          for (final q in await runtime.videoQualities(vid))
            TvQualityOption(
              q.value,
              q.label,
              detail: q.width > 0 && q.height > 0
                  ? '${q.width}×${q.height}'
                  : '',
            ),
        ];
        tvQualityCache[vid] = values;
      } else {
        throw StateError('当前播放来源未提供清晰度信息');
      }
      if (!mounted ||
          ticket != tvQualityTicket ||
          widget.detail.episodes[position].vid != vid) {
        return;
      }
      _redraw(() {
        tvQualities = [
          if (!values.any((q) => q.value == quality))
            TvQualityOption(
              quality,
              quality == 'best' ? '自动（当前）' : '$quality（当前）',
            ),
          ...values,
        ];
        tvQualitiesLoading = false;
      });
    } catch (_) {
      if (mounted && ticket == tvQualityTicket) {
        _redraw(() {
          tvQualitiesLoading = false;
          tvQualitiesError = '清晰度信息暂不可用，可重试';
        });
      }
    }
  }

  Future<void> _changeTvQuality(String value) async {
    if (value == quality || !tvQualities.any((q) => q.value == value)) return;
    final offset = tvPlayback.position;
    final resume = error != null || tvPlayback.playing;
    quality = value;
    _resumeOffset = offset;
    await _play(position, resumePlaying: resume);
  }

  Future<void> _seekTv(Duration target) async {
    if (preparing || tvDuration == Duration.zero) return;
    try {
      await tvPlayback.seek(target);
      _resumeSnapshotOffset = Duration.zero;
      if (target < tvDuration) _episodeCompleted = false;
      _saveHistory(force: true);
    } catch (_) {
      if (mounted) _redraw(() => playbackNotice = '进度调整失败，请重试');
    }
  }

  Duration tvPosition = Duration.zero, tvDuration = Duration.zero;
  final panelRevision = ValueNotifier<int>(0);
  bool sheetOpen = false;
  void _redraw(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    panelRevision.value++;
  }

  @override
  void initState() {
    super.initState();
    final runtime = widget.runtime;
    if (runtime is DownloadRuntime) runtime.downloads.playbackEntered();
    if (!widget.cachedOnly && runtime is LibraryCacheRuntime) {
      unawaited(
        rememberDramaMetadata(runtime, widget.detail).catchError((Object _) {}),
      );
    }
    position = widget.initialPosition;
    _resumeOffset = widget.initialOffset;
    final preferences = settingsFor(widget.runtime);
    cachedPreference = widget.cachedQuality ?? preferences.defaultQuality;
    quality = cachedPreference;
    tvQualities = [
      TvQualityOption(
        quality,
        quality == 'best' || quality == 'auto' ? '自动' : quality,
      ),
    ];
    autoNext = preferences.autoNext;
    episodeHintDismissed = preferences.episodeSwipeHintShown;
    prefetch = PrefetchWindow(
      runtime: widget.runtime,
      episodes: widget.detail.episodes,
      onChanged: () {
        if (mounted) _redraw(() {});
      },
    );
    WidgetsBinding.instance.addObserver(this);
    player = Player();
    if (tvBuild) tvPlayback.addListener(_tvChanged);
    if (!tvBuild) {
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
    }
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
        if (value) {
          hasPlayed = true;
          _episodePlayed = true;
        }
        if (!value) _saveHistory(force: true);
        if (mounted && value != playing) _redraw(() => playing = value);
      }),
    );
    subscriptions.add(
      player.stream.position.listen((value) {
        if (value > Duration.zero) _resumeSnapshotOffset = Duration.zero;
        if (player.state.playing) _saveHistory();
      }),
    );
    HardwareKeyboard.instance.addHandler(_macEscape);
    platformPlayback.onWindowFocused = _restoreKeyboardFocus;
    platformPlayback.onExternalProgress = () =>
        _saveHistory(force: platformPlayback.externalPlaying == false);
    platformPlayback.onExternalCompleted = () => _completed(true);
    platformPlayback.floating.addListener(_platformChanged);
    platformPlayback.platformPip.addListener(_platformChanged);
    platformPlayback.nativeFullscreen.addListener(_nativeFullscreenChanged);
    if (castSupported(widget.runtime)) {
      // The session belongs to the app, so this page only borrows it.
      castService = castServiceFor(widget.runtime)..addListener(_onCastChanged);
    }
    if (runtime is ConfigurableRuntime) {
      subscriptions.add(
        runtime.settingsChanges.listen((_) {
          autoNext = settingsFor(runtime).autoNext;
          _configurePlatform();
          if (appBackground &&
              !allowBackgroundPlayback(
                tv: tvBuild,
                enabled: settingsFor(runtime).backgroundPlayback,
              ) &&
              !platformPlayback.floating.value) {
            _pausePlayback();
          }
          if (mounted) _redraw(() {});
        }),
      );
    }
    _configurePlatform();
    subscriptions.add(player.stream.completed.listen(_completed));
    _play(position, resumeSeries: widget.resumeLastEpisode);
  }

  void _completed(bool value) {
    if (!value || !mounted || preparing || error != null) return;
    if (!_episodeCompleted) {
      _episodeCompleted = true;
      _episodePlayed = true;
      _saveHistory(force: true);
    }
    if (!autoNext || position + 1 >= widget.detail.episodes.length) return;
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

  void _restoreKeyboardFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          !sheetOpen &&
          !menuOpen &&
          !recommendationOpen) {
        playbackFocus.requestFocus();
      }
    });
  }

  // Native full-screen transitions can temporarily move Flutter focus to its
  // root scope. Escape must remain available during that window transition.
  bool _macEscape(KeyEvent event) {
    if (!macHost ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        sheetOpen ||
        menuOpen ||
        recommendationOpen) {
      return false;
    }
    _back();
    return true;
  }

  void _nativeFullscreenChanged() {
    final value = platformPlayback.nativeFullscreen.value;
    if (mounted && value != null && value != fullscreen) {
      _redraw(() => fullscreen = value);
      compactControls.currentState?.show();
      _restoreKeyboardFocus();
    }
  }

  void _platformChanged() {
    if (macHost) {
      unawaited(
        MacWindow.playerPinned(
          this,
          windowPinned && !platformPlayback.platformPip.value,
        ),
      );
    }
    if (mounted) _redraw(() {});
  }

  Future<void> _toggleWindowPin() async {
    if (pinUpdating) return;
    _redraw(() => pinUpdating = true);
    final next = !windowPinned;
    try {
      // This user action reports platform failures rather than claiming success.
      await MacWindow.channel.invokeMethod<void>('topmost', next);
      if (!mounted) {
        await MacWindow.releasePlayer(this);
        return;
      }
      await MacWindow.playerPinned(
        this,
        next && !platformPlayback.platformPip.value,
      );
      if (mounted) _redraw(() => windowPinned = next);
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('窗口置顶未能生效，请重试')));
      }
    } on MissingPluginException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前运行环境不支持窗口置顶')));
      }
    } finally {
      if (mounted) _redraw(() => pinUpdating = false);
    }
  }

  void _tvChanged() {
    if (!mounted) return;
    final value = tvPlayback;
    final wasPlaying = playing;
    if (value.playing) {
      hasPlayed = true;
      _episodePlayed = true;
    }
    if (value.position > Duration.zero) _resumeSnapshotOffset = Duration.zero;
    _redraw(() {
      tvPosition = value.position;
      tvDuration = value.duration;
      playing = value.playing;
      if (value.error != null) error = value.error;
    });
    if (playing) _saveHistory();
    if (wasPlaying && !playing) _saveHistory(force: true);
    if (value.completed && !tvCompletionReported) {
      tvCompletionReported = true;
      _completed(true);
    }
  }

  Future<void> _pausePlayback() =>
      tvBuild ? tvPlayback.pause() : player.pause();

  void _configurePlatform() {
    if (tvBuild) return;
    platformUpdates = platformUpdates.catchError((Object _) {}).then((_) async {
      if (!mounted) return;
      try {
        await platformPlayback.configure(
          player,
          tvBuild
              ? settingsFor(widget.runtime).copyWith(
                  backgroundPlayback: false,
                  backgroundDownloads: false,
                  floatingPlayback: false,
                )
              : settingsFor(widget.runtime),
          '${widget.detail.drama.title} · 第 ${widget.detail.episodes[position].index} 集',
          step: (offset) async => _step(offset),
          foregroundMedia: tvBuild,
        );
      } catch (_) {
        if (mounted) {
          _redraw(() => playbackNotice = '后台媒体控制暂不可用，请检查系统权限或返回设置重试。');
        }
      }
    });
  }

  Future<void> _configurePlatformForFloating() async {
    _configurePlatform();
    await platformUpdates;
  }

  Future<void> _floating() async {
    if (preparing || sourceVid == null) return;
    try {
      episodeWorkspace.currentState?.hide();
      if (fullscreen) await _setFullscreen(false);
      if (macHost) await platformPlayback.fullscreenUpdates;
      if (platformPlayback.floating.value) {
        await platformPlayback.exit(player);
      } else {
        if (macHost && !settingsFor(widget.runtime).floatingPlayback) {
          final runtime = widget.runtime;
          if (runtime is ConfigurableRuntime) {
            await runtime.saveSettings(
              settingsFor(runtime).copyWith(floatingPlayback: true),
            );
          }
          await platformUpdates;
          await _configurePlatformForFloating();
        }
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

  void _onCastChanged() {
    if (!mounted) return;
    final service = castService;
    // The television owns playback, so the phone yields instead of double audio.
    if (service != null && service.active && playing) {
      unawaited(_pausePlayback());
    }
  }

  Future<void> _cast() async {
    final service = castService;
    if (service == null || preparing || sourceVid == null) return;
    episodeWorkspace.currentState?.hide();
    compactControls.currentState?.hide();
    if (fullscreen) await _setFullscreen(false);
    if (!service.active) {
      unawaited(service.browse());
      final renderer = await showCastDevicePicker(context, service);
      if (renderer == null || !mounted) return;
      await service.open(
        detail: widget.detail,
        index: position,
        renderer: renderer,
        quality: sourceQuality ?? quality,
        expectedDuration: player.state.duration == Duration.zero
            ? null
            : player.state.duration,
      );
      if (!mounted) return;
      if (!service.active) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(service.error ?? '电视拒绝接管播放，请稍后再试。')),
        );
        return;
      }
    }
    // A non-null result means the viewer pressed 退出投屏; closing the page leaves
    // the television running and the floating window holding the handle.
    final resumeAt = await showCastRemote(context, service);
    if (!mounted) return;
    if (resumeAt != null && resumeAt > Duration.zero) {
      await player.seek(resumeAt);
    }
    _saveHistory(force: true);
    _redraw(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _saveHistory(force: true);
    if (state == AppLifecycleState.resumed) {
      final returned = appBackground && returnEligible;
      appBackground = false;
      if (preparationInterrupted) {
        preparationInterrupted = false;
        _play(position);
      } else {
        _syncPrefetch();
      }
      if (returned) {
        returnEligible = false;
        returnTimer?.cancel();
        returnTimer = Timer(
          const Duration(milliseconds: 800),
          _recommendCapability,
        );
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      appBackground = true;
      returnTimer?.cancel();
      returnEligible =
          hasPlayed &&
          !platformPlayback.floating.value &&
          !platformPlayback.transitioning;
      final preferences = settingsFor(widget.runtime);
      if (!allowBackgroundPreparation(
        tv: tvBuild,
        enabled: preferences.backgroundDownloads,
      )) {
        prefetch.clear();
        if (preparing &&
            !allowBackgroundPlayback(
              tv: tvBuild,
              enabled: preferences.backgroundPlayback,
            )) {
          preparationInterrupted = true;
          job?.cancel();
        }
      }
      if (!allowBackgroundPlayback(
            tv: tvBuild,
            enabled: preferences.backgroundPlayback,
          ) &&
          !platformPlayback.floating.value) {
        _pausePlayback();
      }
    }
    // inactive also covers notification permission dialogs and brief window
    // transitions; it must not interrupt audio or a PiP hand-off.
  }

  Future<void> _play(
    int selected, {
    bool? resumePlaying,
    bool resumeSeries = false,
  }) async {
    if (selected < 0 || selected >= widget.detail.episodes.length) return;
    if (selected != position) {
      _resumeOffset = Duration.zero;
      tvQualityTicket++;
      tvQualitiesLoading = false;
      tvQualitiesError = null;
      tvQualities = [
        TvQualityOption(quality, quality == 'best' ? '自动' : quality),
      ];
    }
    _saveHistory(force: true);
    _historyVid = null;
    _episodePlayed = false;
    _episodeCompleted = false;
    tvCompletionReported = false;
    final ticket = ++generation;
    final keepPip = macHost && platformPlayback.platformPip.value;
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
      if (tvBuild) {
        await tvPlayback.close();
      } else {
        await player.stop();
      }
      if (!keepPip || discard) previous?.release();
      if (!widget.cachedOnly &&
          discard &&
          oldVid != null &&
          oldQuality != null) {
        await widget.runtime.evict(oldVid, quality: oldQuality);
      }
      if (!mounted || ticket != generation) return;
      try {
        final library = personalLibraryFor(widget.runtime);
        await library.flush();
        await library.load();
        if (!mounted || ticket != generation) return;
        final start = library.playbackStart(
          widget.detail,
          selected: resumeSeries ? null : selected,
        );
        selected = start.index;
        if (_resumeOffset == Duration.zero) _resumeOffset = start.offset;
        if (position != selected) _redraw(() => position = selected);
      } catch (_) {
        if (mounted) _redraw(() => playbackNotice = '观看记录暂不可用，将从头播放');
      }
      if (!mounted || ticket != generation) return;
      if (widget.cachedOnly) {
        final files = await (widget.runtime as LocalMediaRuntime)
            .localEpisodes();
        if (!mounted || ticket != generation) return;
        final available = localQualityFor(
          widget.detail.episodes[selected].vid,
          files,
          quality,
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
          (resumePlaying ?? true) &&
          (!appBackground ||
              allowBackgroundPlayback(
                tv: tvBuild,
                enabled: settingsFor(widget.runtime).backgroundPlayback,
              ) ||
              platformPlayback.floating.value);
      final offset = _resumeOffset;
      _resumeSnapshotOffset = offset;
      // Media.start is applied by the native file-loaded hook; an immediate
      // seek after open can run before the demuxer has loaded the timeline.
      if (tvBuild) {
        await tvPlayback.open(source, offset: offset, play: mayPlay());
      } else {
        await player.open(
          Media(source, start: offset > Duration.zero ? offset : null),
          play: mayPlay() && !(macHost && platformPlayback.platformPip.value),
        );
        if (keepPip) {
          final replaced = await platformPlayback.replaceFloating(
            player,
            source,
            offset: offset,
            play: mayPlay(),
          );
          if (replaced) {
            _episodePlayed = true;
            hasPlayed = true;
          } else if (mayPlay()) {
            await player.play();
          }
          previous?.release();
        }
      }
      if (!mounted || ticket != generation) return;
      _resumeOffset = Duration.zero;
      // The app can become hidden while the native player is opening a file.
      if (!mayPlay()) await _pausePlayback();
      if (!mounted || ticket != generation) return;
      _redraw(() => preparing = false);
      _historyVid = sourceVid;
      if (playing) _saveHistory(force: true);
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
      count: tvBuild
          ? preferences.prefetchEpisodes.clamp(0, 1)
          : preferences.prefetchEpisodes,
      enabled:
          !widget.cachedOnly &&
          preferences.prefetchEnabled &&
          (!appBackground ||
              allowBackgroundPreparation(
                tv: tvBuild,
                enabled: preferences.backgroundDownloads,
              )),
    );
  }

  Future<void> _settings() async {
    // Dismiss the transient panel before navigating so Back returns to video.
    episodeWorkspace.currentState?.hide();
    if (sheetOpen) {
      Navigator.of(context).pop();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final changed = await pushAppPage<bool>(
      context,
      AppScreen.settings,
      (_) => SettingsPage(runtime: widget.runtime),
    );
    if (!mounted) return;
    compactControls.currentState?.show();
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
    if (mounted &&
        autoNext &&
        (tvBuild ? tvPlayback.completed : player.state.completed)) {
      _completed(true);
    }
  }

  @override
  void dispose() {
    macPlaybackRoutes.unsubscribe(this);
    unawaited(MacWindow.releasePlayer(this));
    HardwareKeyboard.instance.removeHandler(_macEscape);
    playbackFocus.dispose();
    tvQualityTicket++;
    tvPlayback.removeListener(_tvChanged);
    _saveHistory(force: true);
    returnTimer?.cancel();
    edgeNoticeTimer?.cancel();
    if (fullscreen) unawaited(defaultExitNativeFullscreen());
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    // Leaving the page must not stop the television: the cast service outlives
    // this state and the floating window is what brings the controls back.
    castService?.removeListener(_onCastChanged);
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
    platformPlayback.nativeFullscreen.removeListener(_nativeFullscreenChanged);
    platformUpdates = platformUpdates
        .catchError((Object _) {})
        .then((_) async {
          await platformPlayback.dispose(player);
        })
        .catchError((Object _) {})
        .whenComplete(() async {
          await tvPlayback.close();
          tvPlayback.dispose();
          await player.dispose();
          active?.release();
        });
    unawaited(platformUpdates);
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
          height: MediaQuery.sizeOf(context).height * 0.65,
          child: ValueListenableBuilder<int>(
            valueListenable: panelRevision,
            builder: (_, _, _) => Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 20),
                    const Expanded(child: Text('选集')),
                    IconButton(
                      key: const ValueKey('episode-settings'),
                      tooltip: '播放设置',
                      onPressed: _settings,
                      icon: const Icon(Icons.settings_outlined, size: 20),
                    ),
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
    if (target >= 0 && target < widget.detail.episodes.length) {
      _play(target);
      return;
    }
    _fleetingNotice(offset > 0 ? '已经是最后一集' : '已经是第一集');
  }

  /// `playbackNotice` otherwise survives until the next episode loads, which a
  /// boundary message should not.
  void _fleetingNotice(String text) {
    edgeNoticeTimer?.cancel();
    _redraw(() => playbackNotice = text);
    compactControls.currentState?.show();
    edgeNoticeTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted && playbackNotice == text) {
        _redraw(() => playbackNotice = null);
      }
    });
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

  bool get castActive => castService?.active ?? false;

  bool _swipeBlocked() =>
      preparing ||
      error != null ||
      sheetOpen ||
      menuOpen ||
      recommendationOpen ||
      castActive ||
      platformPlayback.floating.value ||
      platformPlayback.platformPip.value;

  void _swipeDropped(int offset) {
    // Dropping a flick silently would read as a broken gesture.
    if (castActive) _fleetingNotice('投屏中请在投屏页或悬浮窗切换剧集');
  }

  String? _swipeHint() {
    if (episodeHintDismissed ||
        preparing ||
        error != null ||
        widget.detail.episodes.length < 2 ||
        castActive ||
        platformPlayback.floating.value ||
        platformPlayback.platformPip.value) {
      return null;
    }
    return platformPlayback.mobile
        ? '上滑下一集 · 下滑上一集'
        : 'Page Up / Page Down 切换上下集';
  }

  void _episodeHintSeen() {
    if (episodeHintDismissed) return;
    // Remembered in memory first: a failed write only costs one more hint,
    // while an error dialog in the middle of playback costs the viewing.
    episodeHintDismissed = true;
    final runtime = widget.runtime;
    if (runtime is! ConfigurableRuntime) return;
    unawaited(
      runtime
          .saveSettings(
            settingsFor(runtime).copyWith(episodeSwipeHintShown: true),
          )
          .catchError((Object _) {}),
    );
  }

  Widget _touchVideo() => EpisodeSwipeArea(
    blocked: _swipeBlocked,
    onStep: _step,
    onBlocked: _swipeDropped,
    hintText: _swipeHint(),
    onHintSeen: _episodeHintSeen,
    child: _video(),
  );

  Widget _video() => ColoredBox(
    color: Colors.black,
    child: Stack(
      children: [
        Positioned.fill(
          child: Video(
            controller: controller,
            // This page owns the background/PiP policy.
            pauseUponEnteringBackgroundMode: false,
            controls: NoVideoControls,
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
            Align(
              alignment: Alignment.centerRight,
              child: FavoriteButton(
                runtime: widget.runtime,
                drama: widget.detail.drama,
              ),
            ),
            if (prefetch.total > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  '已提前缓存 ${prefetch.ready} / ${prefetch.total} 集${prefetch.preparing > 0 ? ' · 正在准备' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: playbackTheme.colorScheme.onSurfaceVariant,
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
                                final resume = playing;
                                quality = value!;
                                _play(position, resumePlaying: resume);
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
                    ? playbackTheme.colorScheme.primary
                    : playbackTheme.colorScheme.surfaceContainerHighest,
                foregroundColor: index == position
                    ? playbackTheme.colorScheme.onPrimary
                    : playbackTheme.colorScheme.onSurface,
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
  Future<void> _recommendCapability() async {
    if (tvBuild) return;
    final runtime = widget.runtime;
    if (!mounted ||
        !platformPlayback.mobile ||
        appBackground ||
        preparing ||
        error != null ||
        sheetOpen ||
        recommendationOpen ||
        runtime is! ConfigurableRuntime ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final policy = widget.returnRecommendations ?? recommendations;
    final candidate = policy.next(runtime.settings);
    if (candidate == null) return;
    if (candidate == PlaybackCapability.floatingPlayback &&
        !await platformPlayback.supportsFloating()) {
      return;
    }
    if (!mounted ||
        appBackground ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _redraw(() => recommendationOpen = true);
    try {
      await runtime.saveSettings(policy.markAsked(runtime.settings, candidate));
      if (!mounted ||
          appBackground ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final enable = await confirmPlaybackCapability(
        context,
        candidate,
        true,
        recommendation: true,
      );
      if (enable) {
        await runtime.saveSettings(candidate.apply(runtime.settings, true));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('设置未能保存，请在设置页重试。')));
      }
    } finally {
      if (mounted) _redraw(() => recommendationOpen = false);
    }
  }

  Future<void> _setFullscreen(bool value) async {
    if (value == fullscreen) return;
    if (value && platformPlayback.floating.value) {
      await platformPlayback.exit(player);
    }
    if (macHost) {
      _redraw(() => fullscreen = value);
      try {
        await platformPlayback.setDesktopFullscreen(value);
      } on TimeoutException {
        if (mounted) {
          _redraw(
            () => fullscreen = platformPlayback.nativeFullscreen.value ?? false,
          );
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('全屏切换尚未完成，请稍后重试')));
        }
      }
      compactControls.currentState?.show();
      return;
    }
    if (platformPlayback.mobile) {
      await SystemChrome.setEnabledSystemUIMode(
        value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } else {
      if (value) {
        await defaultEnterNativeFullscreen();
      } else {
        await defaultExitNativeFullscreen();
      }
    }
    if (mounted) _redraw(() => fullscreen = value);
    compactControls.currentState?.show();
  }

  void _back() {
    if (episodeWorkspace.currentState?.visible == true) {
      episodeWorkspace.currentState?.hide();
    } else if (fullscreen) {
      _setFullscreen(false);
    } else {
      compactControls.currentState?.show();
    }
  }

  bool routeExitPending = false;
  Future<void> _exitPage() async {
    if (!mounted || routeExitPending) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent == false) return;
    routeExitPending = true;
    try {
      episodeWorkspace.currentState?.hide();
      if (fullscreen) await _setFullscreen(false);
      if (macHost) await platformPlayback.fullscreenUpdates;
      if (platformPlayback.floating.value) await platformPlayback.exit(player);
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && route?.isCurrent != false) {
        await Navigator.of(context).maybePop();
      }
    } finally {
      if (mounted && route?.isCurrent != false) routeExitPending = false;
    }
  }

  Widget _title() => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x80000000), Color(0x00000000)],
      ),
    ),
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 16, 8),
        child: Row(
          children: [
            BackButton(
              key: const ValueKey('player-exit'),
              color: Colors.white,
              onPressed: _exitPage,
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: macHost ? (_) => MacWindow.invoke('drag') : null,
                child: Semantics(
                  header: true,
                  child: Text(
                    macHost ? '返回' : widget.detail.drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
            if (macHost) ...[
              IconButton(
                key: const ValueKey('toggle-window-topmost'),
                tooltip: windowPinned ? '取消窗口置顶' : '窗口置顶',
                isSelected: windowPinned,
                onPressed: pinUpdating || platformPlayback.platformPip.value
                    ? null
                    : _toggleWindowPin,
                icon: const Icon(
                  Icons.push_pin_outlined,
                  color: Colors.white70,
                ),
                selectedIcon: const Icon(Icons.push_pin, color: Colors.amber),
              ),
              IconButton(
                tooltip: '最小化窗口',
                onPressed: () => MacWindow.invoke('minimize'),
                icon: const Icon(Icons.minimize, color: Colors.white70),
              ),
              IconButton(
                key: const ValueKey('hide-player-window'),
                tooltip: '隐藏窗口（继续播放）',
                onPressed: () => MacWindow.invoke('hide'),
                icon: const Icon(Icons.close, color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) {
      if (TvEnvironment.of(context)) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: TvPlayerSurface(
            video: TvVideoView(controller: tvPlayback),
            title:
                '${widget.detail.drama.title} · 第 ${widget.detail.episodes[position].index} 集',
            playing: playing,
            busy: preparing,
            error: error?.toString(),
            position: tvPosition,
            duration: tvDuration,
            toggle: () {
              tvPlayback.toggle();
            },
            seek: _seekTv,
            previous: () => _step(-1),
            next: () => _step(1),
            exit: () => _exitPage(),
            retry: () => _play(position),
            episodeLabels: [
              for (final e in widget.detail.episodes) '第 ${e.index} 集',
            ],
            episode: position,
            selectEpisode: (i) => _play(i),
            quality: quality,
            selectQuality: _changeTvQuality,
            qualityOptions: tvQualities,
            qualitiesLoading: tvQualitiesLoading,
            qualitiesError: tvQualitiesError,
            loadQualities: _loadTvQualities,
            notice: playbackNotice,
            videoInfo: tvPlayback.video?.value.isInitialized == true
                ? '${tvPlayback.video!.value.size.width.toInt()}×${tvPlayback.video!.value.size.height.toInt()}'
                : null,
            progress: progress?.label,
          ),
        );
      }
      final size = Size(viewport.maxWidth, viewport.maxHeight);
      final floating = platformPlayback.floating.value;
      final compact =
          (size.width < 720 && size.height >= size.width) || floating;
      if (platformPlayback.platformPip.value ||
          (platformPlayback.restoringPip && size.width < 280)) {
        if (macHost) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.picture_in_picture_alt,
                        color: Colors.white54,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.detail.drama.title,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      if (preparing)
                        Text(
                          progress?.label ?? '正在准备下一集',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      if (error != null) ...[
                        const Text(
                          '下一集准备失败',
                          style: TextStyle(color: Colors.amber),
                        ),
                        TextButton(
                          onPressed: () => _play(position),
                          child: const Text('重试'),
                        ),
                      ],
                      FilledButton.icon(
                        key: const ValueKey('restore-pip'),
                        onPressed: _floating,
                        icon: const Icon(Icons.open_in_full),
                        label: const Text('返回此窗口播放'),
                      ),
                    ],
                  ),
                ),
                _title(),
              ],
            ),
          );
        }
        return Scaffold(backgroundColor: Colors.black, body: _video());
      }
      void episodes() {
        compactControls.currentState?.show();
        if (compact) {
          _openEpisodes();
        } else {
          episodeWorkspace.currentState?.toggle();
        }
      }

      final episodeVisible =
          !compact && (episodeWorkspace.currentState?.visible ?? false);
      final chrome = CompactControls(
        key: compactControls,
        video: _touchVideo(),
        header: _title(),
        playing: playing,
        busy:
            preparing ||
            error != null ||
            sheetOpen ||
            (!macHost && episodeVisible) ||
            menuOpen ||
            recommendationOpen,
        controls: PlaybackTransport(
          player: player,
          title: macHost ? widget.detail.drama.title : null,
          playing: playing,
          fullscreen: fullscreen,
          busy: preparing || error != null,
          desktop: !platformPlayback.mobile,
          episode: widget.detail.episodes[position].index,
          canPrevious: position > 0,
          canNext: position + 1 < widget.detail.episodes.length,
          episodes: episodes,
          previous: () => _step(-1),
          next: () => _step(1),
          fullscreenToggle: () => _setFullscreen(!fullscreen),
          floating: (macHost || settingsFor(widget.runtime).floatingPlayback)
              ? _floating
              : null,
          cast: castService == null || sourceVid == null ? null : _cast,
          floatingActive: floating,
          onMenuChanged: (value) {
            if (mounted) _redraw(() => menuOpen = value);
          },
          notice: playbackNotice ?? audioNotice,
        ),
      );
      final picture = compact
          ? chrome
          : EpisodeWorkspace(
              key: episodeWorkspace,
              video: chrome,
              episodes: _episodes(),
              onSettings: _settings,
              playing: playing,
              hideWhileHovering: macHost,
              onActivity: macHost
                  ? () => compactControls.currentState?.pointerActivity()
                  : null,
              hideAfter: Duration(seconds: macHost ? 3 : 5),
              busy: preparing || error != null,
              manageBack: false,
              onVisibilityChanged: (value) {
                if (mounted) _redraw(() {});
              },
            );
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () {
            compactControls.currentState?.show();
            player.playOrPause();
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            compactControls.currentState?.show();
            _seek(-5);
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            compactControls.currentState?.show();
            _seek(5);
          },
          const SingleActivator(LogicalKeyboardKey.pageDown): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.pageUp): () => _step(-1),
          const SingleActivator(LogicalKeyboardKey.keyI): episodes,
          const SingleActivator(LogicalKeyboardKey.keyF): () =>
              _setFullscreen(!fullscreen),
          if (!macHost) const SingleActivator(LogicalKeyboardKey.escape): _back,
        },
        child: Focus(
          focusNode: playbackFocus,
          autofocus: true,
          child: PopScope(
            canPop: !fullscreen && !episodeVisible,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _back();
            },
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle.light,
              child: Theme(
                data: playbackTheme,
                child: Scaffold(backgroundColor: Colors.black, body: picture),
              ),
            ),
          ),
        ),
      );
    },
  );
}
