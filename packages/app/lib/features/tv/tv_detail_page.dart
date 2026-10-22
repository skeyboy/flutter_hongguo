import '../../downloads/download_selection.dart';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import '../../platform/runtime.dart';
import '../../playback/episode_pager.dart';
import '../../recommendations/related_dramas_section.dart';
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
  @override
  void initState() {
    super.initState();
    future = widget.runtime.catalog.detail(widget.initial.id);
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
    if (mounted) playNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.initial.title)),
    body: TvNavigation(
      child: FutureBuilder<DramaDetail>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TvFocusable(
                label: '重试',
                autofocus: true,
                onActivate: () => setState(
                  () =>
                      future = widget.runtime.catalog.detail(widget.initial.id),
                ),
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
                child: const Text('正在加载 · 返回'),
              ),
            );
          }
          final d = snapshot.data!;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.drama.title,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
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
                    TvFocusable(
                      label: '开始观看',
                      autofocus: true,
                      focusNode: playNode,
                      onActivate: d.episodes.isEmpty
                          ? null
                          : () => play(d, null),
                      child: const Padding(
                        padding: EdgeInsets.all(14),
                        child: Text('▶ 开始观看', style: TextStyle(fontSize: 24)),
                      ),
                    ),
                    if (widget.runtime is DownloadRuntime) ...[
                      const SizedBox(width: 16),
                      TvFocusable(
                        label: '下载剧集',
                        onActivate: d.episodes.isEmpty
                            ? null
                            : () => showDownloadSelection(
                                context,
                                widget.runtime,
                                d,
                              ),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('下载剧集', style: TextStyle(fontSize: 20)),
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
                const SizedBox(height: 24),
                EpisodePager(
                  episodes: d.episodes,
                  currentIndex: () => -1,
                  onSelected: (index) => play(d, index),
                  rows: 4,
                  cellExtent: 170,
                ),
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
