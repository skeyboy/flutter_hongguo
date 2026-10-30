import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../features/detail_page.dart';
import '../navigation/app_navigation.dart';
import '../platform/background/host_policy.dart';
import '../platform/runtime.dart';
import 'board_tabs.dart';
import 'rank_card.dart';
import 'ranking_controller.dart';

/// 榜单 as its own destination.
///
/// Two rows -- 赛道 then 榜 -- and a vertical ranked list under them, because the
/// request behind this page (`cell/change/v`) takes neither 类型 nor 题材: it is a
/// different question from the one the discover page asks, which is why it lives
/// beside those pages rather than inside one of their chip rows. The page is
/// layered over the catalog the same way 我的 is, so leaving it restores the list
/// and the scroll position the viewer was reading.
class RankingPage extends StatefulWidget {
  final AppRuntime runtime;

  /// Held by the shell in production so the destination keeps its own rows across
  /// a round trip to 发现 and back; a page built on its own creates one.
  final RankingController? controller;
  const RankingPage({super.key, required this.runtime, this.controller});

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  RankingController? _own;
  late RankingController controller;

  @override
  void initState() {
    super.initState();
    controller =
        widget.controller ??
        (_own = RankingController(catalog: widget.runtime.catalog));
    controller.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(controller.open());
    });
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(RankingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    controller.removeListener(_onChange);
    controller =
        widget.controller ??
        (_own = RankingController(catalog: widget.runtime.catalog));
    controller.addListener(_onChange);
  }

  @override
  void dispose() {
    controller.removeListener(_onChange);
    _own?.dispose();
    super.dispose();
  }

  /// The desktop row stops at eight chips and puts the rest in 更多 ▾: a pointer
  /// does not drag a list sideways to page it, and this app already refuses that
  /// gesture for pages. A finger gets the scrollable row.
  int? get _overflowAfter => desktopHost ? 8 : null;

  @override
  Widget build(BuildContext context) {
    final tracks = [
      for (final value in controller.tracks) (id: value.id, label: value.label),
    ];
    final boards = [
      for (final value in controller.boards) (id: value.id, label: value.label),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tracks.isEmpty)
          const _RowSkeleton()
        else
          RankSelectorRow(
            key: const ValueKey('rank-tracks'),
            label: '赛道',
            items: tracks,
            selectedId: controller.track,
            onPick: controller.selectTrack,
            keyPrefix: 'rank-track',
            scrollable: !desktopHost,
            overflowAfter: _overflowAfter,
          ),
        if (tracks.isNotEmpty && boards.isEmpty)
          // Upstream can publish a 赛道 whose sub-selector did not come back --
          // one of the four samples lost the 演员 track's entirely. The row says
          // so instead of painting an empty tab strip.
          const _NoBoardsStrip()
        else if (tracks.isNotEmpty)
          RankSelectorRow(
            key: const ValueKey('rank-boards'),
            label: '榜单',
            items: boards,
            selectedId: controller.board,
            onPick: controller.selectBoard,
            keyPrefix: 'rank-board',
            scrollable: !desktopHost,
            overflowAfter: _overflowAfter,
          ),
        _Heading(controller: controller),
        const Divider(height: 1),
        Expanded(
          child: _List(controller: controller, onOpen: _open),
        ),
      ],
    );
  }

  void _open(Drama drama) => pushAppPage<void>(
    context,
    AppScreen.detail,
    (_) => DetailPage(runtime: widget.runtime, initial: drama),
  );
}

/// The page's own line: which 榜 this is, and the one time claim upstream
/// allowed. 「实时」 is never written -- 推荐榜 answers `rank_version` empty.
class _Heading extends StatelessWidget {
  final RankingController controller;
  const _Heading({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = controller.selectedTrack?.label;
    String? board;
    for (final value in controller.boards) {
      if (value.id == controller.board) board = value.label;
    }
    final name = '${[?track, ?board].join(' · ')}榜';
    final updated = controller.updatedAt;
    final stamped = updated == null
        ? null
        : TextSpan(
            text: '  更新于 ${_hhmm(updated)}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          );
    return Padding(
      key: const ValueKey('rank-heading'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            ?stamped,
          ],
        ),
      ),
    );
  }

  static String _hhmm(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _List extends StatelessWidget {
  final RankingController controller;
  final ValueChanged<Drama> onOpen;
  const _List({required this.controller, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final entries = controller.entries;
    if (controller.loading && entries.isEmpty) return const _Skeleton();
    if (!controller.supported) {
      return _Message(
        key: const ValueKey('rank-unsupported'),
        text: '这个运行时没有接榜单接口',
      );
    }
    if (controller.error != null) {
      // The rows the viewer was reading stay; a failure is a strip over them,
      // not an erasure of the page.
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _why(controller.error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('rank-retry'),
                  onPressed: () => unawaited(controller.retry()),
                  child: const Text('现在重试'),
                ),
              ],
            ),
          ),
          if (entries.isEmpty)
            const Expanded(child: _Message(text: '这一榜还没有内容，重试可以再看一次'))
          else
            Expanded(
              child: _Rows(controller: controller, onOpen: onOpen),
            ),
        ],
      );
    }
    if (entries.isEmpty) {
      if (controller.unrecognizedCards > 0) {
        // A 演员榜 answers rows that are not episodes. That is not an empty list,
        // and pretending it is would hide what the board actually is.
        return _Message(
          key: const ValueKey('rank-not-dramas'),
          text: '这一榜排的是人，不是剧（${controller.unrecognizedCards} 条无法按剧集读出来），本版本未接',
        );
      }
      return _Message(
        key: const ValueKey('rank-empty'),
        text: '这一榜这次没有内容',
        action: () => unawaited(controller.retry()),
      );
    }
    return _Rows(
      controller: controller,
      onOpen: onOpen,
      footer: controller.cursor != null,
    );
  }

  static String _why(Object failure) =>
      failure is CatalogError ? failure.message : '榜单暂时读不出来，请重试';
}

class _Rows extends StatelessWidget {
  final RankingController controller;
  final ValueChanged<Drama> onOpen;
  final bool footer;
  const _Rows({
    required this.controller,
    required this.onOpen,
    this.footer = false,
  });

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: const ValueKey('rank-list'),
    controller: controller.scrollOf(controller.currentKey),
    slivers: [
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          if (footer && index == controller.entries.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: controller.loadingMore
                    ? const CircularProgressIndicator()
                    : TextButton(
                        key: const ValueKey('rank-more'),
                        onPressed: () => unawaited(controller.more()),
                        child: const Text('加载更多'),
                      ),
              ),
            );
          }
          final entry = controller.entries[index];
          return RankCard(entry: entry, onTap: () => onOpen(entry.drama));
        }, childCount: controller.entries.length + (footer ? 1 : 0)),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ],
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) => ListView(
    key: const ValueKey('rank-loading'),
    padding: const EdgeInsets.all(12),
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    children: const [
      _SkeletonRow(),
      _SkeletonRow(),
      _SkeletonRow(),
      _SkeletonRow(),
      _SkeletonRow(),
    ],
  );
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          width: 62,
          height: 82,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 14,
                width: 160,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              const SizedBox(height: 8),
              Container(
                height: 12,
                width: 100,
                color: Theme.of(context).colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The rows themselves are waiting on the first answer, so they hold the height
/// a real row would take: the list under them does not move when the vocabulary
/// arrives.
class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          for (final width in [56.0, 72.0, 56.0, 88.0])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                width: width,
                height: 28,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _NoBoardsStrip extends StatelessWidget {
  const _NoBoardsStrip();
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '这一赛道这次没有返回子榜',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  final String text;
  final VoidCallback? action;
  const _Message({super.key, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(text, textAlign: TextAlign.center),
        if (action != null)
          TextButton(
            key: const ValueKey('rank-message-retry'),
            onPressed: action,
            child: const Text('现在重试'),
          ),
      ],
    ),
  );
}
