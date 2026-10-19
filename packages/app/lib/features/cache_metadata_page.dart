import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../platform/runtime.dart';

/// Explicit directory-only repair. A title alone never establishes ownership.
class CacheMetadataPage extends StatefulWidget {
  final AppRuntime runtime;
  final Set<String> videos;
  const CacheMetadataPage({
    super.key,
    required this.runtime,
    required this.videos,
  });
  @override
  State<CacheMetadataPage> createState() => _CacheMetadataPageState();
}

class _CacheMetadataPageState extends State<CacheMetadataPage> {
  final query = TextEditingController();
  List<Drama> items = [];
  bool busy = false;
  int revision = 0;
  String? error;
  @override
  void initState() {
    super.initState();
    _local();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _local() async {
    final current = revision;
    final runtime = widget.runtime;
    if (runtime is! LibraryCacheRuntime) return;
    final result = await runtime.libraryCache.knownDramas();
    if (mounted && current == revision) {
      setState(() => items = result.take(30).toList());
    }
  }

  Future<void> _search() async {
    final text = query.text.trim();
    if (text.isEmpty || busy) return;
    revision++;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.runtime.catalog.search(text);
      if (mounted) setState(() => items = result.items);
    } catch (_) {
      if (mounted) setState(() => error = '搜索失败，可检查网络后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _apply(Drama candidate) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final runtime = widget.runtime;
      final cached = runtime is LibraryCacheRuntime
          ? await runtime.libraryCache.readDetail(candidate.id)
          : null;
      DramaDetail detail;
      try {
        detail = await runtime.catalog.detail(candidate.id);
      } catch (_) {
        if (cached == null) rethrow;
        detail = cached;
      }
      final matches = detail.episodes
          .where((e) => widget.videos.contains(e.vid))
          .map((e) => e.vid)
          .toSet();
      if (matches.isEmpty) throw const FormatException('该剧没有匹配的本地视频，请选择正确的剧目。');
      final d = detail.drama;
      final enriched = DramaDetail(
        Drama(
          id: d.id.isEmpty ? candidate.id : d.id,
          title: d.title.isEmpty ? candidate.title : d.title,
          cover: d.cover.isEmpty ? candidate.cover : d.cover,
          intro: d.intro.isEmpty ? candidate.intro : d.intro,
          episodeCount: d.episodeCount > 0
              ? d.episodeCount
              : detail.episodes.length,
        ),
        detail.episodes,
      );
      await rememberDramaMetadata(runtime, enriched);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '剧目资料暂时无法获取或保存，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('补全剧目信息')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Text('按剧名搜索并选择。仅当分集 ID 与本地文件匹配时归类，不会下载视频。'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: query,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: '输入剧名补全缓存资料',
                      suffixIcon: IconButton(
                        tooltip: '搜索剧目',
                        onPressed: busy ? null : _search,
                        icon: const Icon(Icons.search),
                      ),
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('输入剧名搜索，或先浏览该剧详情以保存资料。'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final drama = items[index];
                        return ListTile(
                          title: Text(drama.title),
                          subtitle: Text('匹配并保存剧目资料 · ${drama.episodeCount} 集'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: busy ? null : () => _apply(drama),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
