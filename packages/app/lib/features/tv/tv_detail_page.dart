import '../../catalog/detail_fallback.dart';
import '../../downloads/download_selection.dart';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import '../../platform/runtime.dart';
import '../../playback/episode_pager.dart';
import '../../personal/personal_library.dart';
import '../../recommendations/related_dramas_section.dart';
import '../downloads_page.dart';
import '../player_page.dart';
import '../../personal/favorite_button.dart';

class TvDetailPage extends StatefulWidget {
  final AppRuntime runtime;
  final Drama initial;
  const TvDetailPage({super.key, required this.runtime, required this.initial});
  @override
  State<TvDetailPage> createState() => _TvDetailPageState();
}

class _TvDetailPageState extends State<TvDetailPage> {
  late Future<DramaDetail> future;
  final playNode = FocusNode(debugLabel: 'tv-detail-play');
  final EpisodePagerController pager = EpisodePagerController();
  late final PersonalLibrary library;

  /// The page is showing the offline snapshot rather than a live read, so the
  /// remote needs a reachable way to ask for the live one again.
  bool offlineSnapshot = false;

  /// Global index of the episode this device left off on, or -1 with no record.
  /// The pager marks and reveals it so the remote lands on the watch-again
  /// episode instead of page one.
  int currentEpisode = -1;

  @override
  void initState() {
    super.initState();
    library = personalLibraryFor(widget.runtime);
    future = _open();
  }

  Future<DramaDetail> _open() async {
    DramaDetail detail;
    try {
      detail = mergeDetailFallbacks(
        await widget.runtime.catalog.detail(widget.initial.id),
        widget.initial,
      );
      offlineSnapshot = false;
    } catch (_) {
      // Same fallback as the touch page: a saved snapshot beats a dead screen,
      // but only the banner below admits it is not a live read.
      final runtime = widget.runtime;
      final cached = runtime is LibraryCacheRuntime
          ? await runtime.libraryCache.readDetail(widget.initial.id)
          : null;
      if (cached == null) rethrow;
      detail = mergeDetailFallbacks(cached, widget.initial);
      offlineSnapshot = true;
    }
    await _syncCurrent(detail);
    return detail;
  }

  /// A missing or unreadable record must not block the page: the grid simply
  /// starts unmarked.
  Future<void> _syncCurrent(DramaDetail detail) async {
    try {
      await library.load();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final vid = library.latestFor(detail.drama.id)?.vid;
    setState(
      () => currentEpisode = detail.episodes.indexWhere((e) => e.vid == vid),
    );
  }

  @override
  void dispose() {
    playNode.dispose();
    super.dispose();
  }

  Future<void> play(DramaDetail d, int? index) async {
    try {
      await rememberDramaMetadata(widget.runtime, d);
    } catch (_) {
      /* Metadata writes must not prevent playback. */
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/tv/player'),
        builder: (_) => PlayerPage(
          runtime: widget.runtime,
          detail: d,
          initialPosition: index ?? 0,
          resumeLastEpisode: index == null,
        ),
      ),
    );
    if (!mounted) return;
    // The player has written its record by now, so the grid can move to the
    // episode actually watched and show that page for the next selection.
    await _syncCurrent(d);
    if (!mounted) return;
    pager.showCurrent();
    playNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    // No Material AppBar: its leading arrow is the only way out of this route
    // on touch, it never takes the focus ring, and on a 10-foot screen an
    // arrow the remote cannot reach reads as decoration. The body carries an
    // explicit 返回 target that the D-pad walk lands on.
    body: TvNavigation(
      child: FutureBuilder<DramaDetail>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TvFocusable(
                label: '重试',
                autofocus: true,
                onActivate: () => setState(() {
                  future = _open();
                }),
                child: Text(
                  '加载失败：${snapshot.error}\n重试',
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return Center(
              child: TvFocusable(
                label: '返回',
                autofocus: true,
                onActivate: () => Navigator.maybePop(context),
                child: const Text('正在加载 · 返回', style: TextStyle(fontSize: 22)),
              ),
            );
          }
          final d = snapshot.data!;
          final downloads = widget.runtime;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (offlineSnapshot) ...[
                  // A snapshot is not a live read, and the page that admits it
                  // must also give the remote the one target that asks again:
                  // a banner with no reachable retry is a dead end but Back.
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '网络加载失败，正在显示已保存的剧集信息',
                          style: TextStyle(fontSize: 20),
                        ),
                      ),
                      const SizedBox(width: 16),
                      TvFocusable(
                        label: '重试刷新',
                        onActivate: () => setState(() {
                          future = _open();
                        }),
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('重试刷新', style: TextStyle(fontSize: 20)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    TvFocusable(
                      label: '返回目录',
                      onActivate: () => Navigator.maybePop(context),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text('‹ 返回', style: TextStyle(fontSize: 24)),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        d.drama.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                if (d.drama.tagNames.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  // 题材词 as words only. The remote family has no 发现页 that
                  // consumes a theme hand-off yet, so a focusable chip that
                  // goes nowhere would be the fake control the design forbids;
                  // plain text adds no target, so the documented focus order of
                  // this page (video-detail-redesign.md §8) is unchanged.
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      for (final name in d.drama.tagNames)
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 18,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  d.drama.intro,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 21),
                ),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // An empty episode list has nothing to play or download, so
                    // the action line offers the retry instead of a control the
                    // remote can only land on and not use.
                    if (d.episodes.isEmpty)
                      TvFocusable(
                        label: '刷新分集',
                        autofocus: true,
                        onActivate: () => setState(() {
                          future = _open();
                        }),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Text(
                            '暂无可播放的分集，可能已临时下架\n按确认刷新，或返回目录换个剧',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 22),
                          ),
                        ),
                      )
                    else
                      TvFocusable(
                        label: '开始观看',
                        autofocus: true,
                        focusNode: playNode,
                        onActivate: () => play(d, null),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('▶ 开始观看', style: TextStyle(fontSize: 24)),
                        ),
                      ),
                    if (d.episodes.isNotEmpty &&
                        widget.runtime is DownloadRuntime) ...[
                      const SizedBox(width: 16),
                      TvFocusable(
                        label: '下载剧集',
                        onActivate: () =>
                            showDownloadSelection(context, widget.runtime, d),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('下载剧集', style: TextStyle(fontSize: 20)),
                        ),
                      ),
                    ],
                    // 下载管理 gets its own target because the snackbar a phone
                    // gets after 下载剧集 is not one the remote can reach: its
                    // 「查看」 action never takes the focus ring, so the queue
                    // would only be readable through 我的.
                    if (downloads is DownloadRuntime) ...[
                      const SizedBox(width: 16),
                      TvFocusable(
                        label: '下载管理',
                        onActivate: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            settings: const RouteSettings(
                              name: '/tv/downloads',
                            ),
                            builder: (_) => DownloadsPage(runtime: downloads),
                          ),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('下载管理', style: TextStyle(fontSize: 20)),
                        ),
                      ),
                    ],
                    const SizedBox(width: 16),
                    FavoriteButton(
                      runtime: widget.runtime,
                      drama: d.drama,
                      tvLayout: true,
                    ),
                  ],
                ),
                if (d.episodes.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  EpisodePager(
                    episodes: d.episodes,
                    currentIndex: () => currentEpisode,
                    onSelected: (index) => play(d, index),
                    controller: pager,
                    rows: 4,
                    cellExtent: 170,
                    // The default 16/14 is a phone reading; on a 1920-wide
                    // screen it sat two steps below this page's own 32 title
                    // and the pager's 26 arrows (design §8, second option).
                    numberFontSize: 26,
                    pageFontSize: 18,
                  ),
                  if (currentEpisode >= 0) ...[
                    const SizedBox(height: 12),
                    Text(
                      '已定位到上次观看的第 ${d.episodes[currentEpisode].index} 集',
                      style: const TextStyle(fontSize: 18),
                    ),
                  ],
                ],
                const SizedBox(height: 32),
                RelatedDramasSection(
                  runtime: widget.runtime,
                  current: d,
                  tvLayout: true,
                  onOpen: (next) => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: '/tv/detail'),
                      builder: (_) =>
                          TvDetailPage(runtime: widget.runtime, initial: next),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
