import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../adapters/backend.dart';
import '../../playback/playback_controller.dart';
import '../library/library_store.dart';

class DetailPage extends StatefulWidget {
  final Backend backend;
  final Series series;
  final LibraryStore library;
  const DetailPage({
    super.key,
    required this.backend,
    required this.series,
    required this.library,
  });
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  SeriesDetail? detail;
  PlaybackController? playback;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.backend.catalog.detail(widget.series.id);
      if (!mounted) return;
      final controller = PlaybackController(
        widget.backend.playback,
        widget.library,
        loaded,
      );
      controller.addListener(_updated);
      setState(() {
        detail = loaded;
        playback = controller;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  void _updated() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    playback?.removeListener(_updated);
    playback?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = detail, controller = playback;
    return Scaffold(
      appBar: AppBar(
        title: Text(data?.series.title ?? widget.series.title),
        actions: [
          AnimatedBuilder(
            animation: widget.library,
            builder: (context, _) => IconButton(
              tooltip: '收藏',
              onPressed: () =>
                  widget.library.toggle(data?.series ?? widget.series),
              icon: Icon(
                widget.library.favorites.containsKey(widget.series.id)
                    ? Icons.favorite
                    : Icons.favorite_border,
              ),
            ),
          ),
        ],
      ),
      body: error != null
          ? Center(child: Text(error!))
          : data == null || controller == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Video(controller: controller.video),
                    ),
                  ),
                ),
                if (controller.state != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Expanded(child: Text(_stateName(controller.state!))),
                        if ({
                          PreparationState.queued,
                          PreparationState.downloading,
                          PreparationState.decrypting,
                          PreparationState.remuxing,
                        }.contains(controller.state))
                          TextButton(
                            onPressed: controller.cancel,
                            child: const Text('取消'),
                          ),
                      ],
                    ),
                  ),
                if (controller.error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      controller.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Row(
                  children: [
                    TextButton(
                      onPressed: controller.selected > 0
                          ? () => controller.select(controller.selected - 1)
                          : null,
                      child: const Text('上一集'),
                    ),
                    TextButton(
                      onPressed:
                          controller.selected >= 0 &&
                              controller.selected + 1 < data.episodes.length
                          ? () => controller.select(controller.selected + 1)
                          : null,
                      child: const Text('下一集'),
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<String>(
                      value: controller.quality,
                      items: const [
                        DropdownMenuItem(value: 'best', child: Text('自动')),
                        DropdownMenuItem(value: '720p', child: Text('720p')),
                        DropdownMenuItem(value: '1080p', child: Text('1080p')),
                      ],
                      onChanged: (q) {
                        if (q != null && controller.selected >= 0) {
                          unawaited(
                            controller.select(
                              controller.selected,
                              newQuality: q,
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
                if (data.series.intro.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(data.series.intro),
                  ),
                if (controller.selected < 0 &&
                    widget.library.history.containsKey(data.series.id))
                  TextButton.icon(
                    icon: const Icon(Icons.history),
                    label: const Text('继续上次观看'),
                    onPressed: () {
                      final record = widget.library.history[data.series.id]!;
                      final index = data.episodes.indexWhere(
                        (e) => e.index == record.episode,
                      );
                      unawaited(
                        controller.select(
                          index < 0 ? 0 : index,
                          resume: Duration(milliseconds: record.positionMs),
                        ),
                      );
                    },
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < data.episodes.length; i++)
                      ChoiceChip(
                        label: Text('第 ${data.episodes[i].index} 集'),
                        selected: controller.selected == i,
                        onSelected: (_) => controller.select(i),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  String _stateName(PreparationState state) => switch (state) {
    PreparationState.queued => '等待准备',
    PreparationState.downloading => '正在下载',
    PreparationState.decrypting => '正在解密',
    PreparationState.remuxing => '正在验证并缓存',
    PreparationState.ready => '已交给播放器',
    PreparationState.failed => '准备失败',
    PreparationState.cancelled => '已取消',
  };
}
