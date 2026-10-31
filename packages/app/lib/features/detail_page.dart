import '../downloads/download_selection.dart';
import '../navigation/app_navigation.dart';
import '../navigation/catalog_theme_handoff.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../platform/runtime.dart';
import '../playback/episode_pager.dart';
import '../recommendations/related_dramas_section.dart';
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

  /// The 主题 row of the discover page, read so a 标签 can be judged against it.
  List<CatalogFilter> _panel = const [];
  final _requestScope = CatalogRequestScope();
  @override
  void dispose() {
    _requestScope.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    detail = _load();
    unawaited(_loadPanel());
  }

  /// 「面板有 / 面板无」这条判据读的是发现页那一张表，所以对着它正在用的那一型去
  /// 映射：词表按类型发布，换一型就是一张新表。没来回的东西一律当「面板无」处理——
  /// 这一页不许画一枚点下去什么都不发生的标签。
  Future<void> _loadPanel() async {
    try {
      final panel = await _requestScope.run(
        () => widget.runtime.catalog.themes(catalogThemeHandoff.genre),
      );
      if (mounted) setState(() => _panel = panel);
    } on Object catch (_) {
      // No panel: every word stays a word.
    }
  }

  Future<DramaDetail> _load() async {
    DramaDetail result;
    try {
      result = await _requestScope.run(
        () => widget.runtime.catalog.detail(widget.initial.id),
      );
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
        // 题材 words are what both the 标签 row and 「同题材 · X」 read. Merging
        // without them would silently downgrade every recommendation block to
        // the hot board.
        tagNames: drama.tagNames.isNotEmpty ? drama.tagNames : initial.tagNames,
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

  /// 这部剧自己的题材词，一枚词一个位置：只有发现页的主题行也发过同一个词的那枚
  /// 才是入口，其余的只当文本读——「点它 = 回到发现页并带上这个筛选」这条承诺，
  /// 只有词表里真有其 id 才兑得了现。
  List<Widget> _tags(List<String> names) {
    final muted = TextStyle(
      fontSize: 13,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return [for (final name in names) _tag(name, _entryOf(name), muted)];
  }

  Widget _tag(String name, CatalogFilter? theme, TextStyle muted) =>
      theme == null
      ? Text(name, key: ValueKey('detail-tag-plain-$name'), style: muted)
      : ActionChip(
          key: ValueKey('detail-tag-entry-${theme.id}'),
          label: Text(name, style: const TextStyle(fontSize: 13)),
          onPressed: () => _openTheme(theme),
        );

  /// The same-word rule 「同题材 · X」 uses (`related_dramas.dart:94`): the
  /// panel's own name, trimmed, or nothing.
  CatalogFilter? _entryOf(String name) {
    for (final option in _panel) {
      if (option.name.trim() == name) return option;
    }
    return null;
  }

  void _openTheme(CatalogFilter theme) {
    catalogThemeHandoff.ask(theme);
    // 主题行是发现页自己的状态，而它在栈底：收掉这一层以上，它才看得见这一次 ask。
    Navigator.of(context).popUntil((route) => route.isFirst);
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
          tagNames: drama.tagNames,
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
                        if (display.tagNames.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: _tags(display.tagNames),
                          ),
                        ],
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
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                    child: EpisodePager(
                      episodes: data.episodes,
                      currentIndex: () => resumable
                          ? data.episodes.indexWhere((e) => e.vid == saved.vid)
                          : -1,
                      onSelected: play,
                      rows: MediaQuery.sizeOf(context).width < 720 ? 3 : 4,
                      cellExtent: MediaQuery.sizeOf(context).width < 720
                          ? 100
                          : 120,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                    child: RelatedDramasSection(
                      runtime: widget.runtime,
                      current: data,
                      onOpen: (next) => pushAppPage<void>(
                        context,
                        AppScreen.detail,
                        (_) =>
                            DetailPage(runtime: widget.runtime, initial: next),
                      ),
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
