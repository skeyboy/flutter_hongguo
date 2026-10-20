import '../downloads/download_selection.dart';
import '../navigation/app_navigation.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../platform/runtime.dart';
import '../widgets/drama_cover.dart';
import '../personal/favorite_button.dart';
import 'player_page.dart';

class DetailPage extends StatefulWidget {
  final AppRuntime runtime;
  final Drama initial;
  const DetailPage({super.key, required this.runtime, required this.initial});
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late Future<DramaDetail> detail;
  bool offlineSnapshot = false;
  @override
  void initState() {
    super.initState();
    detail = _load();
  }

  Future<DramaDetail> _load() async {
    DramaDetail result;
    try {
      result = await widget.runtime.catalog.detail(widget.initial.id);
      offlineSnapshot = false;
    } catch (_) {
      final runtime = widget.runtime;
      final cached = runtime is LibraryCacheRuntime
          ? await runtime.libraryCache.readDetail(widget.initial.id)
          : null;
      if (cached == null) rethrow;
      result = cached;
      offlineSnapshot = true;
    }
    final initial = widget.initial, drama = result.drama;
    final merged = DramaDetail(
      Drama(
        id: drama.id.isEmpty ? initial.id : drama.id,
        title: drama.title.trim().isEmpty ? initial.title : drama.title,
        cover: drama.cover.isEmpty ? initial.cover : drama.cover,
        intro: drama.intro.isEmpty ? initial.intro : drama.intro,
        episodeCount: drama.episodeCount > 0
            ? drama.episodeCount
            : result.episodes.length,
      ),
      result.episodes,
    );
    try {
      await personalLibraryFor(widget.runtime).load();
    } catch (_) {
      // Unavailable progress must not prevent browsing or a fresh playback.
    }
    unawaited(
      rememberDramaMetadata(widget.runtime, merged).catchError((Object _) {}),
    );
    return merged;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.initial.title),
      actions: [FavoriteButton(runtime: widget.runtime, drama: widget.initial)],
    ),
    body: FutureBuilder<DramaDetail>(
      future: detail,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 40),
                  const SizedBox(height: 16),
                  Text('${snapshot.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      detail = _load();
                    }),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!, drama = data.drama;
        final display = Drama(
          id: drama.id,
          title: drama.title.isEmpty ? widget.initial.title : drama.title,
          cover: drama.cover.isEmpty ? widget.initial.cover : drama.cover,
          intro: drama.intro,
          episodeCount: data.episodes.length,
        );
        final saved = personalLibraryFor(widget.runtime).latestFor(drama.id);
        final resumable =
            saved != null && data.episodes.any((e) => e.vid == saved.vid);
        Future<void> play(int? position) async {
          await pushAppPage<void>(
            context,
            AppScreen.player,
            (_) => PlayerPage(
              runtime: widget.runtime,
              detail: data,
              initialPosition: position ?? 0,
              resumeLastEpisode: position == null,
            ),
          );
          await personalLibraryFor(widget.runtime).flush();
          if (mounted) setState(() {});
        }

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: CustomScrollView(
              slivers: [
                if (offlineSnapshot)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        children: [
                          const Expanded(child: Text('网络加载失败，正在显示已保存的剧集信息')),
                          TextButton(
                            onPressed:
                                snapshot.connectionState ==
                                    ConnectionState.waiting
                                ? null
                                : () => setState(() {
                                    detail = _load();
                                  }),
                            child: Text(
                              snapshot.connectionState ==
                                      ConnectionState.waiting
                                  ? '正在刷新…'
                                  : '重试刷新',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 130,
                              height: 180,
                              child: DramaCover(drama: display),
                            ),
                            const SizedBox(width: 24),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    display.title,
                                    style: const TextStyle(
                                      fontSize: 26,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.7,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    '共 ${data.episodes.length} 集',
                                    style: const TextStyle(
                                      color: Color(0xff8a8279),
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  if (resumable)
                                    Text(
                                      '上次看到第 ${saved.episode} 集',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      FilledButton.icon(
                                        onPressed: data.episodes.isEmpty
                                            ? null
                                            : () => play(null),
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                        ),
                                        label: Text(
                                          !resumable
                                              ? '开始观看'
                                              : saved.completed
                                              ? '重新观看'
                                              : '继续观看',
                                        ),
                                      ),
                                      if (widget.runtime is DownloadRuntime)
                                        OutlinedButton.icon(
                                          key: const ValueKey('download-drama'),
                                          onPressed: data.episodes.isEmpty
                                              ? null
                                              : () => showDownloadSelection(
                                                  context,
                                                  widget.runtime,
                                                  data,
                                                ),
                                          icon: const Icon(
                                            Icons.download_outlined,
                                          ),
                                          label: const Text('下载'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (display.intro.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          Text(
                            display.intro,
                            style: const TextStyle(height: 1.8),
                          ),
                        ],
                        const SizedBox(height: 32),
                        const Text(
                          '选择剧集',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '选择一集，故事即刻开始。',
                          style: TextStyle(color: Color(0xff8a8279)),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 100,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.5,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          side: const BorderSide(color: Color(0xffddd7ce)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => play(index),
                        child: Text('${data.episodes[index].index}'),
                      ),
                      childCount: data.episodes.length,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
