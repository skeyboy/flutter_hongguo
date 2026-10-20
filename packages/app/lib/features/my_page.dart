import 'downloads_page.dart';
import '../navigation/app_navigation.dart';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../personal/personal_library.dart';
import '../platform/runtime.dart';
import '../catalog/local_library.dart';
import '../playback/local_playlist.dart';
import 'detail_page.dart';
import '../widgets/drama_cover.dart';
import 'local_cache_page.dart';
import 'player_page.dart';
import 'settings_page.dart';

class MyPage extends StatefulWidget {
  final AppRuntime runtime;
  final VoidCallback? onSettingsChanged;
  const MyPage({super.key, required this.runtime, this.onSettingsChanged});
  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  late final PersonalLibrary library;
  bool favorites = false, loading = true, working = false;
  int? cachedCount;
  String? error;
  @override
  void initState() {
    super.initState();
    library = personalLibraryFor(widget.runtime);
    library.addListener(_changed);
    final runtime = widget.runtime;
    if (runtime is DownloadRuntime) runtime.downloads.addListener(_changed);
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    library.removeListener(_changed);
    final runtime = widget.runtime;
    if (runtime is DownloadRuntime) runtime.downloads.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await library.load();
      final runtime = widget.runtime;
      List<LocalEpisode>? files;
      if (runtime is LocalMediaRuntime) {
        try {
          files = await runtime.localEpisodes();
        } catch (_) {
          // A cache scan failure must not hide favorites and watch progress.
        }
      }
      if (mounted) {
        setState(() {
          cachedCount = files?.map((e) => e.vid).toSet().length;
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '个人记录读取失败，请重试';
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (working) return;
    setState(() => working = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作未完成，请检查网络或本地文件后重试')));
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _settings() async {
    final changed = await pushAppPage<bool>(
      context,
      AppScreen.settings,
      (_) => SettingsPage(runtime: widget.runtime, closeOnSave: false),
    );
    if (!mounted) return;
    if (changed == true) widget.onSettingsChanged?.call();
    await _load();
  }

  Future<void> _cache() async {
    await pushAppPage<void>(
      context,
      AppScreen.cache,
      (_) => LocalCachePage(runtime: widget.runtime),
    );
    if (mounted) await _load();
  }

  Future<void> _continue(WatchRecord record) async {
    final runtime = widget.runtime;
    DramaDetail detail;
    var start = 0;
    var quality = record.quality;
    if (record.local) {
      if (runtime is! LocalMediaRuntime) throw StateError('本地播放不可用');
      final files = await runtime.localEpisodes();
      final group = groupLocalEpisodes(files)
          .where((g) => g.files.any((e) => e.vid == record.vid))
          .firstOrNull;
      if (group == null) throw StateError('该集缓存已被删除');
      final file =
          group.files
              .where((e) => e.vid == record.vid && e.quality == quality)
              .firstOrNull ??
          group.files.firstWhere((e) => e.vid == record.vid);
      quality = file.quality;
      final queue = localPlaybackQueue(group, file);
      detail = queue.detail;
      start = queue.initialPosition;
    } else {
      final cached = runtime is LibraryCacheRuntime
          ? await runtime.libraryCache.readDetail(record.drama.id)
          : null;
      detail = cached ?? await runtime.catalog.detail(record.drama.id);
      start = detail.episodes.indexWhere((e) => e.vid == record.vid);
      if (start < 0) throw StateError('该分集已不可用');
    }
    if (!mounted) return;
    await pushAppPage<void>(
      context,
      AppScreen.player,
      (_) => PlayerPage(
        runtime: runtime,
        detail: detail,
        initialPosition: start,
        initialOffset: record.resumeAt,
        cachedOnly: record.local,
        cachedQuality: quality,
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看历史？'),
        content: const Text('将移除本机观看进度，不影响收藏和缓存视频。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _run(library.clearHistory);
  }

  Widget _shortcut(
    String label,
    IconData icon,
    String count,
    VoidCallback? onTap, {
    bool selected = false,
  }) => Card(
    elevation: 0,
    color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
        child: Column(
          children: [
            Icon(icon),
            const SizedBox(height: 8),
            Text(label),
            const SizedBox(height: 4),
            Text(count, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    ),
  );
  Widget _row(Drama drama, {WatchRecord? record}) => Card(
    elevation: 0,
    margin: const EdgeInsets.only(bottom: 10),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      leading: SizedBox(width: 48, height: 68, child: DramaCover(drama: drama)),
      title: Text(drama.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: record == null
          ? Text('${drama.episodeCount} 集 · 点击查看剧集')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '第 ${record.episode} 集 · ${record.completed ? "已看完，可重看" : "观看至 ${record.positionMs ~/ 60000}:${((record.positionMs ~/ 1000) % 60).toString().padLeft(2, '0')}"}${record.local ? " · 本地" : ""}',
                ),
                if (record.durationMs > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      value: (record.positionMs / record.durationMs).clamp(
                        0,
                        1,
                      ),
                      minHeight: 2,
                    ),
                  ),
              ],
            ),
      onTap: working
          ? null
          : () => _run(() async {
              if (record != null) {
                await _continue(record);
              } else {
                await pushAppPage<void>(
                  context,
                  AppScreen.detail,
                  (_) => DetailPage(runtime: widget.runtime, initial: drama),
                );
              }
            }),
      trailing: IconButton(
        tooltip: record == null ? '取消收藏' : '移除历史',
        onPressed: working
            ? null
            : () => _run(
                () => record == null
                    ? library.toggleFavorite(drama)
                    : library.removeHistory(drama.id),
              ),
        icon: Icon(record == null ? Icons.favorite : Icons.close, size: 20),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('我的'),
      automaticallyImplyLeading: false,
      actions: [
        IconButton(
          key: const ValueKey('my-settings'),
          tooltip: '设置',
          onPressed: working ? null : _settings,
          icon: const Icon(Icons.settings_outlined),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    Text(
                      '你的观影空间',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '收藏与观看进度保存在本机',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _shortcut(
                            '收藏',
                            Icons.favorite_outline,
                            '${library.favorites.length} 部',
                            () => setState(() => favorites = true),
                            selected: favorites,
                          ),
                        ),
                        Expanded(
                          child: _shortcut(
                            '观看历史',
                            Icons.history,
                            '${library.history.length} 部',
                            () => setState(() => favorites = false),
                            selected: !favorites,
                          ),
                        ),
                        Expanded(
                          child: _shortcut(
                            '本地缓存',
                            Icons.download_done_outlined,
                            cachedCount == null ? '当前不可用' : '$cachedCount 集',
                            cachedCount == null ? null : () => _run(_cache),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (widget.runtime is DownloadRuntime)
                      Card(
                        elevation: 0,
                        child: ListTile(
                          key: const ValueKey('my-downloads'),
                          leading: const Icon(Icons.download_outlined),
                          title: const Text('下载管理'),
                          subtitle: Text(
                            '${(widget.runtime as DownloadRuntime).downloads.pendingCount} 集进行中 · ${(widget.runtime as DownloadRuntime).downloads.readyCount} 集已下载',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: working
                              ? null
                              : () => _run(() async {
                                  await pushAppPage<void>(
                                    context,
                                    AppScreen.downloads,
                                    (_) => DownloadsPage(
                                      runtime:
                                          widget.runtime as DownloadRuntime,
                                    ),
                                  );
                                  if (mounted) await _load();
                                }),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            favorites ? '我的收藏' : '继续观看 / 历史',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (!favorites && library.history.isNotEmpty)
                          TextButton(
                            onPressed: working ? null : _clearHistory,
                            child: const Text('清空历史'),
                          ),
                      ],
                    ),
                    if (working) const LinearProgressIndicator(minHeight: 2),
                    const SizedBox(height: 10),
                    if ((favorites ? library.favorites : library.history)
                        .isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(
                          children: [
                            Icon(
                              favorites ? Icons.favorite_border : Icons.history,
                              size: 40,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              favorites
                                  ? '还没有收藏，去剧集详情页收藏喜欢的剧吧'
                                  : '开始播放后，这里会记录集数和观看进度',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    if (favorites)
                      ...library.favorites.map((d) => _row(d))
                    else
                      ...library.history.map((r) => _row(r.drama, record: r)),
                  ],
                ),
              ),
            ),
          ),
  );
}
