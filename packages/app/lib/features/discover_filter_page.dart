import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../navigation/app_navigation.dart';
import '../platform/background/host_policy.dart';
import '../platform/runtime.dart';
import '../widgets/drama_card.dart';
import '../widgets/horizontal_wheel.dart';
import '../widgets/hover_glow.dart';
import 'detail_page.dart';

/// 三级内容的名字。发现页的行、抽屉与这一页共用同一张表：入口页顶栏与「内容类型」
/// 行说的必须是发现页正在说的那三个词，而不是第二套译名。
const discoverGenreNames = {
  'short_play': '短剧',
  'comic_series': '漫剧',
  'ai_series': 'AI 短剧',
};

/// 更多筛选入口页与发现页状态之间唯一的桥（模块 B1「实时写回同源状态」）。
///
/// 入口页不持有筛选状态的副本：它读写的 [dims] 就是发现页 [LibraryPageStateBase]
/// 里那份 `dims` 对象本身，genre/theme/sort 的每次改动都由发现页自己的
/// `_selectFilter` / `_pickDim` 写入——返回发现页后 `_dimCount` 与请求参数天然
/// 一致，不存在第二套重置规则，也不需要二次同步代码。
abstract interface class DiscoverFilterBinding {
  /// 当前一级（内容类型）。
  String get genre;

  /// 当前二级题材 id；null 是「全部」。
  String? get theme;

  /// L2′ 维度选中，`select_items` 的形状（每键一列）。写回发现页的同一份 map。
  Map<String, List<String>> get dims;

  /// 当前生效的排序档（`catalogSortKeys` 之一）。
  String get sort;

  /// 切一级：走发现页的换页语义（题材与维度随新类型归零）。
  void selectGenre(String genre);

  /// 选/清题材（空串是「全部」）。
  void selectTheme(String themeId);

  /// L2′ 的一维选中：`itemId` 为 null 即「不限」。
  void pickDim(String dimKey, String? itemId);

  /// 切排序档。
  void selectSort(String sort);

  /// 重置：清空题材与全部维度选中（排序是档位不是筛选，不在重置范围内）。
  void clearAll();
}

/// 发现 tab 的「更多筛选」入口页：逐级分类（一级内容类型 → 题材 → 各维度）+
/// 随筛选实时更新的 grid（模块 B2）。
///
/// 平台策略（模块 B3）：移动端全屏页 + AppBar 返回、维度行横滑点选居中；桌面与
/// Web 用同一套布局（kIsWeb 归入桌面分支渲染），行宽 ≥ 720px 的维度区改为 Wrap
/// 平铺——空间足够时不制造第二个滚动维度；Esc 关页。TV flavor 侧栏「分类」聚合
/// 保持现状，本期仅保证 TV 隔离路由下该页能以 `MaterialPageRoute` 兜底分支打开
/// 与返回，不新增 TV 专用布局（契约 B3 如实降级的边界）。
class DiscoverFilterPage extends StatefulWidget {
  final AppRuntime runtime;
  final DiscoverFilterBinding binding;
  const DiscoverFilterPage({
    super.key,
    required this.runtime,
    required this.binding,
  });
  @override
  State<DiscoverFilterPage> createState() => _DiscoverFilterPageState();
}

class _DiscoverFilterPageState extends State<DiscoverFilterPage>
    with SingleTickerProviderStateMixin {
  /// 「同桌面布局」：桌面宿主与 Web 都走鼠标那套（宽屏 Wrap / Esc 关页）。
  bool get desktopLayout => desktopHost || kIsWeb;

  /// `filterRows` 的三态。词表按一级重拉，一级没换就不重问。
  List<CatalogDim>? rows;
  bool vocabLoading = false;
  String? vocabError;

  /// grid 的状态。`items` 在刷新期间不清空——「切筛选不闪空」：旧列表原地
  /// 保留，新答案落地后整体淡入。
  final items = <Drama>[];
  String? cursor;
  bool refreshing = false;
  bool loadingMore = false;
  String? error;
  String? moreError;

  /// 请求序号：迟到的答案只属于发出它的那次筛选，不覆盖后来者。
  int requestToken = 0;
  Timer? refreshTimer;

  /// 每行一个 controller，与发现页 `rowAt` 同一契约：Scrollbar 与点选居中
  /// 都要能从外面问这一行滚到哪了。
  final rowScroll = <String, ScrollController>{};

  /// 顶栏筛选带随纵向列表的方向收展，与发现/榜单页同一套契约：向下看内容时
  /// 让出高度，任意一次向上滑都把筛选项带回手边，不必滚回页首。
  static const _collapseAfter = 40.0, _collapseBefore = 8.0;
  bool bandCollapsed = false;
  double _lastListOffset = 0;

  /// 刷新完成后的淡入。「重置系统动画偏好」下不跑动画，直接到位。
  late final AnimationController fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );

  ScrollController rowAt(String key) => rowScroll.putIfAbsent(key, () {
    final controller = ScrollController();
    return controller;
  });

  @override
  void initState() {
    super.initState();
    unawaited(_loadVocabulary());
    unawaited(_refresh());
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    for (final controller in rowScroll.values) {
      controller.dispose();
    }
    fade.dispose();
    super.dispose();
  }

  /// 词表来自这一级自己的请求（`filterRows`），上游按请求发面板，缺行如实呈现，
  /// 不画没给的维度。
  Future<void> _loadVocabulary() async {
    if (vocabLoading) return;
    setState(() {
      vocabLoading = true;
      vocabError = null;
    });
    final catalog = widget.runtime.catalog;
    try {
      if (catalog is! FilteredCatalogRepository) {
        // 入口 chip 只在该能力下出现，走到这里说明能力在会话中途退场了。
        throw const CatalogError('当前内容源不支持维度筛选');
      }
      final values = await catalog.filterRows(widget.binding.genre);
      if (!mounted) return;
      setState(() {
        rows = values;
        vocabLoading = false;
      });
    } catch (failure) {
      debugPrint('catalog.filterRows(${widget.binding.genre}) failed: $failure');
      if (!mounted) return;
      setState(() {
        vocabError = '词表加载失败';
        vocabLoading = false;
      });
    }
  }

  /// 任一筛选变化：cursor 归零、旧列表保留、防抖后只问最后一次的选择——
  /// 与发现页 `_rearmFeed` 同一条「连点合并成一次请求」的语义。
  void _onFilterChanged() {
    refreshTimer?.cancel();
    refreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) unawaited(_refresh());
    });
    setState(() {});
  }

  Future<void> _refresh({bool more = false}) async {
    final catalog = widget.runtime.catalog;
    if (catalog is! FilteredCatalogRepository) return;
    if (more && (loadingMore || cursor == null)) return;
    final token = ++requestToken;
    setState(() {
      if (more) {
        loadingMore = true;
      } else {
        refreshing = true;
      }
    });
    // 题材走 `category_dim_theme`，与发现页 `_requestPage` 组装请求的方式
    // 完全一致：两侧发出的字节是同一个问题。
    final theme = widget.binding.theme;
    final dims = <String, List<String>>{
      if (theme != null) categoryThemeKey: [theme],
      for (final entry in widget.binding.dims.entries)
        if (entry.value.isNotEmpty) entry.key: List<String>.of(entry.value),
    };
    try {
      final page = await catalog.browseFiltered(
        CatalogQuery(
          genre: widget.binding.genre,
          sort: widget.binding.sort,
          dims: dims,
          cursor: more ? cursor : null,
          seen: more ? items.map((d) => d.id).toList() : const [],
        ),
      );
      if (!mounted || token != requestToken) return;
      setState(() {
        if (more) {
          items.addAll(page.items);
          cursor = page.nextCursor;
          loadingMore = false;
          moreError = null;
        } else {
          items
            ..clear()
            ..addAll(page.items);
          cursor = page.nextCursor;
          refreshing = false;
          error = null;
          _restartFade();
        }
      });
    } catch (failure) {
      debugPrint('catalog.browseFiltered failed: $failure');
      if (!mounted || token != requestToken) return;
      setState(() {
        if (more) {
          loadingMore = false;
          moreError = '加载更多失败，请重试';
        } else {
          refreshing = false;
          error = '内容加载失败';
        }
      });
    }
  }

  void _restartFade() {
    // 禁动画偏好下直接到位：同一份结果，只是不演这一段。
    if (MediaQuery.disableAnimationsOf(context)) return;
    fade.value = 0;
    fade.forward();
  }

  void _explain(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(key: const ValueKey('filter-page-toast'), content: Text(message)),
    );
  }

  /// 一级切换：写回发现页（题材与维度随新类型归零），词表重拉，grid 重问。
  /// 「清失效值」要说出来，不能静默。
  Future<void> _pickGenre(String genre) async {
    if (genre == widget.binding.genre) return;
    final hadSelection =
        widget.binding.theme != null ||
        widget.binding.dims.values.any((ids) => ids.isNotEmpty);
    widget.binding.selectGenre(genre);
    _explain(
      hadSelection
          ? '已切换到${discoverGenreNames[genre] ?? genre}，已清空不适用于新类型的筛选'
          : '已切换到${discoverGenreNames[genre] ?? genre}',
    );
    await _loadVocabulary();
    refreshTimer?.cancel();
    unawaited(_refresh());
    setState(() {});
  }

  void _resetAll() {
    widget.binding.clearAll();
    _explain('已重置全部筛选');
    refreshTimer?.cancel();
    unawaited(_refresh());
    setState(() {});
  }

  /// 点选后把选中 chip 滚到行的水平中心：`target = chipCenter - viewportCenter
  /// + currentOffset`，clamp 到 [0, maxScrollExtent]。与模块 A2 同一算式；行
  /// 视口取 chip 自己所属的 Scrollable，而不是拿页面尺寸来算。
  void _centerChip(String rowKey, BuildContext chipContext) {
    final controller = rowScroll[rowKey];
    if (controller == null || !controller.hasClients) return;
    final scrollable = Scrollable.maybeOf(chipContext);
    if (scrollable == null) return;
    final viewport = scrollable.context.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached) return;
    final chipRender = chipContext.findRenderObject();
    if (chipRender is! RenderBox || !chipRender.attached) return;
    final position = controller.position;
    final chipCenter =
        chipRender.localToGlobal(Offset.zero, ancestor: viewport).dx +
        chipRender.size.width / 2;
    final target = (chipCenter - viewport.size.width / 2 + controller.offset)
        .clamp(0.0, position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.jumpTo(target);
      return;
    }
    controller.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  /// 维度名用上游原文，兜底映射表只在 `row_name` 没来时替它说话。
  String _dimLabel(CatalogDim row) =>
      row.label.isNotEmpty
      ? row.label
      : (catalogDimRowNames[row.key] ?? row.key);

  /// 词表该给而这次没给的维度：只点名，不画没给的维度。
  List<String> _missingRows(List<CatalogDim> present) {
    final offered = present.map((row) => row.key).toSet();
    return [
      for (final key in catalogDimKeysByGenre[widget.binding.genre] ?? const <String>[])
        if (!offered.contains(key) && key != categoryThemeKey)
          catalogDimRowNames[key] ?? key,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final genre = widget.binding.genre;
    final rows = this.rows ?? const <CatalogDim>[];
    final themeItems = rows
        .where((row) => row.key == categoryThemeKey)
        .expand((row) => row.items)
        .toList();
    final sections = rows
        .where((row) => row.key != categoryThemeKey)
        .toList();
    final missing = this.rows == null ? const <String>[] : _missingRows(rows);
    return Scaffold(
      appBar: AppBar(
        title: Text('更多筛选 · ${discoverGenreNames[genre] ?? genre}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              key: const ValueKey('filter-page-reset'),
              onPressed: _resetAll,
              child: const Text('重置'),
            ),
          ),
        ],
      ),
      body: desktopLayout
          // 桌面/Web：Esc 关页。绑定在这一页自己的子树里，关的是这一页的路由，
          // 不会漏到发现页壳层去关别的层。
          ? CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    Navigator.of(context).maybePop(),
              },
              // 打开即持有焦点：Esc 在观众第一次按键时就要答话，不必先点过
              // 一枚 chip 才有焦点可回落。
              child: Focus(
                autofocus: true,
                child: _body(context, themeItems, sections, missing),
              ),
            )
          : _body(context, themeItems, sections, missing),
    );
  }

  Widget _body(
    BuildContext context,
    List<CatalogFilter> themeItems,
    List<CatalogDim> sections,
    List<String> missing,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // 筛选带与 main 的发现/榜单页同构：收起的是高度，不是筛选状态。
      // 带外置在列表之上，收展只改变列表视口，不会改动观众正在看的 offset。
      AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: bandCollapsed
            ? const SizedBox(width: double.infinity)
            : _filterBand(context, themeItems, sections, missing),
      ),
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: CustomScrollView(
            key: const ValueKey('filter-page-results'),
            slivers: [_resultSliver()],
          ),
        ),
      ),
    ],
  );

  /// 自动加载是触控端的手：桌面用显式的「加载更多」，两种节奏各有其主。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0 &&
        notification.metrics.axis == Axis.vertical &&
        notification is ScrollUpdateNotification) {
      final offset = notification.metrics.pixels;
      final last = _lastListOffset;
      _lastListOffset = offset;
      if (!bandCollapsed && offset > last && offset > _collapseAfter) {
        setState(() => bandCollapsed = true);
      } else if (bandCollapsed &&
          (offset < last || offset <= _collapseBefore)) {
        setState(() => bandCollapsed = false);
      }
    }
    if (desktopLayout) return false;
    if (!settingsFor(widget.runtime).autoLoadMore) return false;
    if (notification.metrics.extentAfter < 600 &&
        cursor != null &&
        !loadingMore &&
        !refreshing) {
      unawaited(_refresh(more: true));
    }
    return false;
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4, left: 12, right: 12),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  /// 一行可选项。移动端横滑（点选居中），桌面/Web 行宽 ≥ 720px 时 Wrap 平铺：
  /// 空间足够时不制造第二个滚动维度，不够时才横滑（按空间自适应）。
  Widget _chipRow(
    String rowKey,
    List<Widget> chips, {
    bool scrollable = true,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = desktopLayout && constraints.maxWidth >= 720;
      if (wide || !scrollable) {
        return Padding(
          key: ValueKey('filter-page-row-$rowKey'),
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Wrap(spacing: 6, runSpacing: 4, children: chips),
        );
      }
      return Padding(
        key: ValueKey('filter-page-row-$rowKey'),
        padding: const EdgeInsets.only(bottom: 4),
        child: Scrollbar(
          controller: rowAt(rowKey),
          // 鼠标滚轮只在这条行还有词可看时横向滑动；到尽头仍把滚轮还给页面。
          child: HorizontalWheel(
            controller: rowAt(rowKey),
            child: SingleChildScrollView(
              controller: rowAt(rowKey),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: chips),
            ),
          ),
        ),
      );
    },
  );

  Widget _chip(
    String key,
    String label,
    bool chosen,
    VoidCallback onTap, {
    String? rowKey,
  }) => Builder(
    builder: (chipContext) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      // main 的高亮契约同样给筛选项：鼠标经过时 chip 抬起一档、整圈 rim 亮起；
      // 触屏不产生 hover，选中态仍是它唯一的回答。
      child: HoverGlow(
        scale: 1.04,
        radius: 18,
        child: ChoiceChip(
          key: ValueKey(key),
          label: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: chosen ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          selected: chosen,
          onSelected: (_) {
            onTap();
            if (rowKey != null) _centerChip(rowKey, chipContext);
          },
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
    ),
  );

  Widget _filterBand(
    BuildContext context,
    List<CatalogFilter> themeItems,
    List<CatalogDim> sections,
    List<String> missing,
  ) {
    final genre = widget.binding.genre;
    final theme = widget.binding.theme;
    return Column(
      key: const ValueKey('filter-page-band'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('内容类型'),
        _chipRow(
          'genre',
          [
            for (final entry in discoverGenreNames.entries)
              _chip(
                'filter-page-genre-${entry.key}',
                entry.value,
                entry.key == genre,
                () => unawaited(_pickGenre(entry.key)),
                rowKey: 'genre',
              ),
          ],
          scrollable: false,
        ),
        if (vocabError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  vocabError!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                TextButton(
                  key: const ValueKey('filter-page-vocab-retry'),
                  onPressed: () => unawaited(_loadVocabulary()),
                  child: const Text('现在重试'),
                ),
              ],
            ),
          )
        else if (rows == null || vocabLoading)
          const Padding(
            key: ValueKey('filter-page-vocab-loading'),
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else ...[
          // 题材是二级，完整词表来自当前一级的桶；换一级后这里读到的是新桶。
          _sectionLabel('题材'),
          _chipRow(
            'theme',
            [
              _chip(
                'filter-page-theme-all',
                '全部',
                theme == null || theme.isEmpty,
                () {
                  widget.binding.selectTheme('');
                  _onFilterChanged();
                },
                rowKey: 'theme',
              ),
              for (final item in themeItems)
                _chip(
                  'filter-page-theme-${item.id}',
                  item.name,
                  theme == item.id,
                  () {
                    widget.binding.selectTheme(item.id);
                    _onFilterChanged();
                  },
                  rowKey: 'theme',
                ),
            ],
          ),
          // 按 `filterRows` 返回的顺序逐维分区：上游给的顺序就是面板的顺序，
          // 页面不重新发明。
          for (final section in sections) ...[
            _sectionLabel(_dimLabel(section)),
            _chipRow(
              'dim-${section.key}',
              [
                _chip(
                  'filter-page-any-${section.key}',
                  '不限',
                  (widget.binding.dims[section.key] ?? const <String>[]).isEmpty,
                  () {
                    widget.binding.pickDim(section.key, null);
                    _onFilterChanged();
                  },
                  rowKey: 'dim-${section.key}',
                ),
                for (final item in section.items)
                  _chip(
                    'filter-page-dim-${section.key}-${item.id}',
                    item.name,
                    (widget.binding.dims[section.key] ?? const <String>[]).contains(item.id),
                    () {
                      widget.binding.pickDim(section.key, item.id);
                      _onFilterChanged();
                    },
                    rowKey: 'dim-${section.key}',
                  ),
              ],
            ),
          ],
          if (missing.isNotEmpty)
            Padding(
              key: const ValueKey('filter-page-missing'),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                '本次词表没给：${missing.join('、')}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
        _sectionLabel('排序'),
        // 排序继承发现页当前档位，页内可改三档；改动同样实时写回。
        _chipRow(
          'sort',
          [
            for (final key in catalogSortKeys)
              _chip(
                'filter-page-sort-$key',
                catalogSortLabels[key] ?? key,
                widget.binding.sort == key,
                () {
                  widget.binding.selectSort(key);
                  _onFilterChanged();
                },
                rowKey: 'sort',
              ),
          ],
          scrollable: false,
        ),
        const Divider(height: 1),
      ],
    );
  }

  /// 结果区：与发现页同一款 delegate 与 `DramaCard`；刷新期间旧列表原地保留，
  /// 新答案整体淡入；错误态重试、空结果空态、到底前可加载更多。
  Widget _resultSliver() {
    const delegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 210,
      mainAxisSpacing: 20,
      crossAxisSpacing: 14,
      childAspectRatio: 0.55,
    );
    final horizontalPadding = desktopLayout ? 24.0 : 12.0;
    Widget grid(int count, Widget? Function(BuildContext, int) builder) =>
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverFadeTransition(
            opacity: fade.drive(CurveTween(curve: Curves.easeOutCubic)),
            sliver: SliverGrid(
              gridDelegate: delegate,
              delegate: SliverChildBuilderDelegate(builder, childCount: count),
            ),
          ),
        );
    if (refreshing && items.isEmpty) {
      return const SliverToBoxAdapter(
        key: ValueKey('filter-page-loading'),
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (error != null && items.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          key: const ValueKey('filter-page-error'),
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(Icons.cloud_off_outlined, size: 32),
              const SizedBox(height: 12),
              Text(error!, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              OutlinedButton(
                key: const ValueKey('filter-page-retry'),
                onPressed: () => unawaited(_refresh()),
                child: const Text('现在重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (!refreshing && items.isEmpty) {
      return const SliverToBoxAdapter(
        key: ValueKey('filter-page-empty'),
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Column(
            children: [
              Icon(Icons.search_off_rounded, size: 42),
              SizedBox(height: 14),
              Text('这个组合暂时没有内容'),
              SizedBox(height: 8),
              Text('试试放宽筛选条件。'),
            ],
          ),
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        grid(items.length, (context, index) {
          final drama = items[index];
          return DramaCard(
            key: ValueKey('filter-page-card-${drama.id}'),
            drama: drama,
            onTap: () => pushAppPage<void>(
              context,
              AppScreen.detail,
              (_) => DetailPage(runtime: widget.runtime, initial: drama),
            ),
          );
        }),
        if (moreError != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: TextButton(
                  key: const ValueKey('filter-page-more-retry'),
                  onPressed: () => unawaited(_refresh(more: true)),
                  child: Text(moreError!),
                ),
              ),
            ),
          )
        else if (loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          )
        else if (cursor != null)
          // 到底前的显式入口：触控端另有接近底部自动加载（偏好开关生效），
          // 桌面端则只有这一条路到下一页。
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: OutlinedButton(
                  key: const ValueKey('filter-page-more'),
                  onPressed: () => unawaited(_refresh(more: true)),
                  child: const Text('加载更多'),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
