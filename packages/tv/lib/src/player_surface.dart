import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'back_scope.dart';
import 'environment.dart';
import 'focusable.dart';
import 'grid.dart';
import 'player_state.dart';

class TvQualityOption {
  final String value, label, detail;
  const TvQualityOption(this.value, this.label, {this.detail = ''});
}

class TvPlayerSurface extends StatefulWidget {
  final Widget video;
  final String title;
  final bool playing, busy;
  final String? error;
  final Duration position, duration;
  final VoidCallback toggle, previous, next, exit, retry;
  final ValueChanged<Duration> seek;
  final List<String> episodeLabels;
  final int episode;
  final ValueChanged<int> selectEpisode;
  final String quality;
  final ValueChanged<String> selectQuality;
  final List<TvQualityOption> qualityOptions;
  final bool qualitiesLoading;
  final String? qualitiesError, videoInfo, notice;
  final VoidCallback? loadQualities;
  final String? progress;
  const TvPlayerSurface({
    super.key,
    required this.video,
    required this.title,
    required this.playing,
    required this.busy,
    this.error,
    required this.position,
    required this.duration,
    required this.toggle,
    required this.previous,
    required this.next,
    required this.exit,
    required this.retry,
    required this.seek,
    required this.episodeLabels,
    required this.episode,
    required this.selectEpisode,
    required this.quality,
    required this.selectQuality,
    this.progress,
    this.qualityOptions = const [TvQualityOption('best', '自动')],
    this.qualitiesLoading = false,
    this.qualitiesError,
    this.loadQualities,
    this.videoInfo,
    this.notice,
  });
  @override
  State<TvPlayerSurface> createState() => _TvPlayerSurfaceState();
}

class _MenuAction {
  final String id, label;
  final VoidCallback? action;
  const _MenuAction(this.id, this.label, this.action);
}

class _TvPlayerSurfaceState extends State<TvPlayerSurface> {
  final state = TvPlayerState();
  final root = FocusNode(debugLabel: 'tv-video');
  final errorRetry = FocusNode(debugLabel: 'tv-error-retry');
  final nodes = <String, FocusNode>{};
  String panel = 'episodes';
  int menuIndex = 0;
  Timer? idleTimer;
  bool exiting = false, seekFromControls = false;
  FocusNode node(String id) =>
      nodes.putIfAbsent(id, () => FocusNode(debugLabel: id));
  FocusNode get play => node('tv-play');

  @override
  void initState() {
    super.initState();
    state.addListener(_update);
    HardwareKeyboard.instance.addHandler(_handleActivity);
  }

  void _update() {
    _restartIdle();
    if (mounted) setState(() {});
  }

  bool _handleActivity(KeyEvent event) {
    // Child buttons can consume confirm keys before the surface's Focus handler.
    // Observe activity without consuming it or changing player transport state.
    if (root.hasFocus &&
        (event is KeyDownEvent || event is KeyRepeatEvent) &&
        ModalRoute.of(context)?.isCurrent != false) {
      _restartIdle();
    }
    return false;
  }

  void _restartIdle() {
    idleTimer?.cancel();
    if (!mounted || exiting || state.layer != TvPlayerLayer.controls) return;
    idleTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted || exiting || state.layer != TvPlayerLayer.controls) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _restartIdle();
        return;
      }
      hideControls();
    });
  }

  void _focus(FocusNode target) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !exiting &&
          target.context != null &&
          target.canRequestFocus) {
        target.requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void back() {
    if (exiting || ModalRoute.of(context)?.isCurrent == false) return;
    final old = state.layer;
    if (state.back()) {
      if (old == TvPlayerLayer.seek && seekFromControls) {
        state.showControls();
        _focus(node('tv-menu-progress'));
      } else {
        _focus(old == TvPlayerLayer.panel ? _menuNode(menuIndex) : root);
      }
    } else {
      _exit();
    }
  }

  void _exit() {
    if (exiting || ModalRoute.of(context)?.isCurrent == false) return;
    idleTimer?.cancel();
    setState(() => exiting = true);
    widget.exit();
  }

  void show() {
    if (widget.busy) return;
    state.showControls();
    menuIndex = 0;
    _focus(play);
  }

  void hideControls() {
    if (state.layer != TvPlayerLayer.controls) return;
    state.back();
    _focus(root);
  }

  void panelOpen(String value) {
    panel = value;
    state.openPanel();
    if (value == 'quality') {
      widget.loadQualities?.call();
      final option =
          widget.qualityOptions
              .where((q) => q.value == widget.quality)
              .firstOrNull ??
          widget.qualityOptions.firstOrNull;
      _focus(
        option == null
            ? node('tv-panel-close')
            : node('tv-quality-${option.value}'),
      );
    }
  }

  void startSeek() {
    seekFromControls = true;
    state.seekBy(Duration.zero, widget.position, widget.duration);
    _focus(root);
  }

  void commitSeek() {
    final target = state.commit();
    if (target == null) return;
    widget.seek(target);
    if (seekFromControls) {
      state.showControls();
      _focus(node('tv-menu-progress'));
    } else {
      _focus(root);
    }
  }

  List<_MenuAction> get actions => [
    _MenuAction(
      'play',
      widget.error != null
          ? '重试'
          : widget.playing
          ? '暂停'
          : '播放',
      widget.error == null ? widget.toggle : widget.retry,
    ),
    _MenuAction('previous', '上一集', widget.episode > 0 ? widget.previous : null),
    _MenuAction(
      'next',
      '下一集',
      widget.episode + 1 < widget.episodeLabels.length ? widget.next : null,
    ),
    _MenuAction(
      'progress',
      '进度',
      widget.duration > Duration.zero && widget.error == null
          ? startSeek
          : null,
    ),
    _MenuAction(
      'episodes',
      '选集',
      widget.episodeLabels.isEmpty ? null : () => panelOpen('episodes'),
    ),
    _MenuAction('quality', '清晰度', () => panelOpen('quality')),
    _MenuAction('picture', '返回画面', hideControls),
    _MenuAction('exit', '退出播放', _exit),
  ];
  FocusNode _menuNode(int index) =>
      index == 0 ? play : node('tv-menu-${actions[index].id}');
  void moveMenu(int delta) {
    final menu = actions;
    for (
      var next = menuIndex + delta;
      next >= 0 && next < menu.length;
      next += delta
    ) {
      if (menu[next].action != null) {
        menuIndex = next;
        _focus(_menuNode(next));
        return;
      }
    }
    _focus(_menuNode(menuIndex));
  }

  KeyEventResult key(FocusNode _, KeyEvent event) {
    final k = event.logicalKey;
    if (isRemoteBack(k)) {
      if (event is KeyDownEvent) back();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      if (event is KeyDownEvent &&
          !widget.busy &&
          widget.error == null &&
          (k == LogicalKeyboardKey.mediaPlayPause ||
              widget.playing != (k == LogicalKeyboardKey.mediaPlay))) {
        widget.toggle();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext ||
        k == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent && !widget.busy) {
        if (k == LogicalKeyboardKey.mediaTrackNext &&
            widget.episode + 1 < widget.episodeLabels.length) {
          widget.next();
        }
        if (k == LogicalKeyboardKey.mediaTrackPrevious && widget.episode > 0) {
          widget.previous();
        }
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (state.layer == TvPlayerLayer.panel) return KeyEventResult.ignored;
    if (state.layer == TvPlayerLayer.controls) {
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        moveMenu(k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (isRemoteConfirm(k)) {
        if (event is KeyDownEvent) actions[menuIndex].action?.call();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        if (event is KeyDownEvent) hideControls();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) return KeyEventResult.handled;
      return KeyEventResult.ignored;
    }
    if (widget.busy) return KeyEventResult.handled;
    if (widget.error != null) {
      // 焦点已经在错误卡片的按钮上时，方向键交给 TvNavigation 在
      // 重试 → 选集 → 返回之间走；确认键由 TvFocusable 自己消费并激活，
      // 这里再处理一次就会把同一次按键执行两遍。
      if (!root.hasPrimaryFocus) return KeyEventResult.ignored;
      if (event is KeyDownEvent) {
        if (isRemoteConfirm(k)) {
          // 焦点还落在播放器根节点时，确认键直接重试，不再先打开控制栏。
          widget.retry();
        } else if (k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown) {
          // 保留方向键打开控制栏的入口：上一集/下一集/清晰度仍可达。
          show();
        }
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      if (state.layer != TvPlayerLayer.seek) seekFromControls = false;
      state.seekBy(
        Duration(seconds: k == LogicalKeyboardKey.arrowLeft ? -5 : 5),
        widget.position,
        widget.duration,
      );
      return KeyEventResult.handled;
    }
    if (isRemoteConfirm(k)) {
      if (event is KeyDownEvent) {
        if (state.layer == TvPlayerLayer.seek) {
          commitSeek();
        } else {
          widget.toggle();
          show();
        }
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent) show();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(TvPlayerSurface old) {
    super.didUpdateWidget(old);
    final errorAppeared = widget.error != null && old.error == null;
    if (errorAppeared) {
      // 错误卡片出现时回到纯画面层，让重试/选集/返回这组按钮可见。
      state.layer = TvPlayerLayer.video;
      idleTimer?.cancel();
    }
    if (widget.busy && !old.busy) {
      state.layer = TvPlayerLayer.video;
      idleTimer?.cancel();
      if (!errorAppeared) _focus(root);
    }
    if (old.busy && !widget.busy) {
      if (state.layer == TvPlayerLayer.controls && widget.error == null) {
        _focus(_menuNode(menuIndex));
      } else if (state.layer != TvPlayerLayer.panel && !errorAppeared) {
        _focus(root);
      }
    }
    if (widget.error == null &&
        state.layer == TvPlayerLayer.controls &&
        !widget.busy) {
      final disabled = actions[menuIndex].action == null;
      if (disabled) menuIndex = 0;
      if (disabled ||
          root.hasPrimaryFocus ||
          !_menuNode(menuIndex).canRequestFocus) {
        _focus(_menuNode(menuIndex));
      }
    }
    if (old.error != null && widget.error == null) _focus(root);
    // 错误出现（包括和 busy→idle 同一帧）时把焦点交给重试。排在上面所有
    // _focus(root) 之后排队：同一帧里后请求的焦点胜出，避免根节点抢走它。
    if (widget.error != null && (errorAppeared || (old.busy && !widget.busy))) {
      _focus(errorRetry);
    }
  }

  @override
  void dispose() {
    idleTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleActivity);
    state.removeListener(_update);
    state.dispose();
    root.dispose();
    errorRetry.dispose();
    for (final n in nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  String time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  Widget button(
    String label,
    VoidCallback? action, {
    FocusNode? focusNode,
    bool autofocus = false,
    bool selected = false,
    ValueChanged<bool>? onFocusChange,
  }) => TvFocusable(
    label: label,
    onActivate: action == null
        ? null
        : () {
            _restartIdle();
            action();
          },
    focusNode: focusNode,
    autofocus: autofocus,
    selected: selected,
    onFocusChange: onFocusChange,
    child: Opacity(
      opacity: action == null ? .38 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Text(label, style: const TextStyle(fontSize: 20)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final controls = state.layer == TvPlayerLayer.controls,
        inPanel = state.layer == TvPlayerLayer.panel;
    final menu = actions;
    return PopScope(
      canPop: exiting || state.layer == TvPlayerLayer.video,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: TvBackScope(
        onBack: back,
        child: Focus(
          focusNode: root,
          // 错误态下重试按钮才是入口：根节点先入树，两个 autofocus 并存时
          // 根节点会赢，遥控器就停在空焦点上。
          autofocus: widget.error == null,
          onKeyEvent: key,
          child: Theme(
            data: ThemeData.dark(useMaterial3: true),
            child: DefaultTextStyle(
              style: const TextStyle(color: Colors.white, fontSize: 20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ExcludeFocus(child: widget.video),
                  if ((widget.busy || widget.error != null) &&
                      !controls &&
                      !inPanel)
                    Center(
                      child: SizedBox(
                        width: 640,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.busy) const CircularProgressIndicator(),
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                widget.error != null
                                    ? '播放失败，可重试或选择其他分集'
                                    : widget.progress ?? '准备播放',
                              ),
                            ),
                            if (widget.error != null) ...[
                              button(
                                '重试',
                                widget.retry,
                                focusNode: errorRetry,
                                autofocus: true,
                              ),
                              button('选集', () => panelOpen('episodes')),
                            ],
                            button(
                              '返回',
                              _exit,
                              autofocus: widget.error == null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (controls && !widget.busy)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: ColoredBox(
                        color: Colors.black87,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 24),
                              ),
                              Text(
                                '${time(widget.position)} / ${time(widget.duration)}${widget.videoInfo == null ? '' : ' · ${widget.videoInfo}'}',
                                style: const TextStyle(fontSize: 18),
                              ),
                              if (widget.notice != null)
                                Text(
                                  widget.notice!,
                                  style: const TextStyle(fontSize: 16),
                                ),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (var i = 0; i < menu.length; i++)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: button(
                                          menu[i].label,
                                          menu[i].action == null
                                              ? null
                                              : () {
                                                  menuIndex = i;
                                                  menu[i].action!();
                                                },
                                          focusNode: _menuNode(i),
                                          onFocusChange: (focused) {
                                            if (focused) menuIndex = i;
                                          },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (state.layer == TvPlayerLayer.seek)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        padding: const EdgeInsets.all(32),
                        color: Colors.black87,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '预览 ${time(state.preview)} / ${time(widget.duration)}　← → 调整 · 确认跳转 · 返回取消',
                              style: const TextStyle(fontSize: 24),
                            ),
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                              value: widget.duration > Duration.zero
                                  ? (state.preview.inMilliseconds /
                                            widget.duration.inMilliseconds)
                                        .clamp(0, 1)
                                  : 0,
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (inPanel)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black87,
                        child: FocusScope(
                          child: TvNavigation(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    panel == 'episodes' ? '选择分集' : '选择清晰度',
                                    style: const TextStyle(fontSize: 28),
                                  ),
                                  if (panel == 'episodes')
                                    Text(
                                      '共 ${widget.episodeLabels.length} 集 · 当前：${widget.episodeLabels.elementAtOrNull(widget.episode) ?? ''}',
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                  const SizedBox(height: 16),
                                  Expanded(
                                    child: panel == 'episodes'
                                        ? TvGrid(
                                            ids: [
                                              for (
                                                var i = 0;
                                                i < widget.episodeLabels.length;
                                                i++
                                              )
                                                'episode-$i',
                                            ],
                                            initialFocusId:
                                                'episode-${widget.episode}',
                                            maxExtent: 150,
                                            aspectRatio: 2.4,
                                            label: (i) =>
                                                widget.episodeLabels[i],
                                            activate: (i) {
                                              back();
                                              widget.selectEpisode(i);
                                            },
                                            itemBuilder: (_, i) => Center(
                                              child: Text(
                                                '${widget.episodeLabels[i]}${i == widget.episode ? ' · 当前' : ''}',
                                              ),
                                            ),
                                          )
                                        : SingleChildScrollView(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (widget.qualitiesLoading)
                                                  const LinearProgressIndicator(),
                                                if (widget.qualitiesError !=
                                                    null) ...[
                                                  Text(widget.qualitiesError!),
                                                  if (widget.loadQualities !=
                                                      null)
                                                    button(
                                                      '重试清晰度',
                                                      widget.loadQualities,
                                                    ),
                                                ],
                                                Wrap(
                                                  spacing: 12,
                                                  runSpacing: 12,
                                                  children: [
                                                    for (final q
                                                        in widget
                                                            .qualityOptions)
                                                      button(
                                                        '${q.label}${q.detail.isEmpty ? '' : ' · ${q.detail}'}',
                                                        () {
                                                          back();
                                                          widget.selectQuality(
                                                            q.value,
                                                          );
                                                        },
                                                        focusNode: node(
                                                          'tv-quality-${q.value}',
                                                        ),
                                                        selected:
                                                            q.value ==
                                                            widget.quality,
                                                      ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                  ),
                                  button(
                                    '关闭',
                                    back,
                                    focusNode: node('tv-panel-close'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
