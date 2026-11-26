import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

/// L2′ 更多筛选: every dimension of the upstream `selector_rows` panel except
/// 主题, which is the second row itself.
///
/// What the drawer is allowed to offer comes from the vocabulary of this request,
/// not from a list kept here: 漫剧 publishes 画风 and 状态, 真人剧 never did in
/// any sample, and a genre can lose the whole panel between one request and the
/// next. So a dimension that did not come back is not drawn at all, and the only
/// thing named in the footnote is one this type is known to publish.
class DiscoverFilterPanel extends StatelessWidget {
  final String genre;

  /// What this type is called, in the page's own words: the drawer is the one
  /// place that has to say which type's vocabulary it is showing, because the
  /// dimensions inside it differ per type.
  final String genreLabel;

  /// 触控族's sheet names its way out in the header (收起) while the mouse
  /// family's anchored drawer has 完成 and `Esc`. Null hides it.
  final String? dismissLabel;

  /// What `filterRows` returned for this type, in the order upstream sent it.
  final List<CatalogDim> rows;

  /// 题材属于二级，完整词表由当前一级的桶给出；换一级后这里读到的是新桶，
  /// 抽屉无需关闭重开就能跟上「30 → 9」（§7.9）。
  final List<CatalogFilter> themeItems;
  final String selectedTheme;
  final void Function(String themeId) onPickTheme;

  /// 完整词表默认收起：展开状态由页面持有，换一级后的重画不会把它关掉。
  final ValueNotifier<bool> themeVocabExpanded;

  /// One or no chosen item per dimension; an absent key is 「不限」. The shape is
  /// the request's (`select_items` takes a list per key) so that a choice here
  /// and the array that goes upstream are the same object, not a translation.
  final Map<String, List<String>> selected;
  final void Function(String dimKey, String? itemId) onPick;
  final VoidCallback onRetry;
  final VoidCallback onDone;
  final bool loading;
  final String? error;
  const DiscoverFilterPanel({
    super.key,
    required this.genre,
    required this.genreLabel,
    required this.rows,
    required this.themeItems,
    required this.selectedTheme,
    required this.onPickTheme,
    required this.themeVocabExpanded,
    required this.selected,
    required this.onPick,
    required this.onRetry,
    required this.onDone,
    this.dismissLabel,
    this.loading = false,
    this.error,
  });

  /// 主题 is the second row, not a line in this drawer: it changes which page of
  /// this type the viewer is on, while everything here only narrows the request.
  List<CatalogDim> get _sections =>
      rows.where((row) => row.key != categoryThemeKey).toList();

  List<String> get _missing {
    final offered = _sections.map((row) => row.key).toSet();
    return [
      for (final key in catalogDimKeysByGenre[genre] ?? const <String>[])
        if (!offered.contains(key) && key != categoryThemeKey)
          catalogDimRowNames[key] ?? key,
    ];
  }

  int get _count => selected.values.where((ids) => ids.isNotEmpty).length;

  bool _chosen(String dimKey, String itemId) =>
      (selected[dimKey] ?? const <String>[]).contains(itemId);

  bool _open(String dimKey) => (selected[dimKey] ?? const <String>[]).isEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sections = _sections;
    final missing = _missing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        key: const ValueKey('filter-panel'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '更多筛选 · $genreLabel',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // 一级换了，themeItems 就是另一个桶的长度（§7.9 抽屉 30 → 9）。
              // 完整词表默认收起，避免把「完成」顶出触控族抽屉的可视区。
              ValueListenableBuilder<bool>(
                valueListenable: themeVocabExpanded,
                builder: (context, expanded, _) => TextButton(
                  key: const ValueKey('filter-theme-toggle'),
                  onPressed: () =>
                      themeVocabExpanded.value = !themeVocabExpanded.value,
                  child: Text(expanded ? '题材收起' : '题材（${themeItems.length}）'),
                ),
              ),
              if (dismissLabel != null)
                TextButton(
                  key: const ValueKey('filter-panel-dismiss'),
                  onPressed: onDone,
                  child: Text(dismissLabel!),
                ),
            ],
          ),
          // 展开后才是完整词表；真值 feed 没有题材字段，所以明说是词表演示。
          ValueListenableBuilder<bool>(
            valueListenable: themeVocabExpanded,
            builder: (context, expanded, _) => expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 4),
                        child: Text(
                          '题材 · 二级完整词表（${themeItems.length}）',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _Item(
                            key: const ValueKey('filter-theme-all'),
                            label: '全部',
                            chosen: selectedTheme.isEmpty,
                            onTap: () => onPickTheme(''),
                          ),
                          for (final item in themeItems)
                            _Item(
                              key: ValueKey('filter-theme-${item.id}'),
                              label: item.name,
                              chosen: selectedTheme == item.id,
                              onTap: () => onPickTheme(item.id),
                            ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '题材为词表演示（真值 feed 无题材字段）',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          if (loading && sections.isEmpty && themeItems.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                key: ValueKey('filter-panel-loading'),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (sections.isEmpty && themeItems.isEmpty)
            // An absent vocabulary is still a drawer the viewer asked for: it
            // says so and offers the way back, rather than opening a blank box.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    error ?? '本次词表没给任何筛选维度。',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('filter-panel-retry'),
                      onPressed: onRetry,
                      child: const Text('现在重试'),
                    ),
                  ),
                ],
              ),
            )
          else
            for (final section in sections) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(
                  // Upstream's own words, so the drawer and the site agree about
                  // what a dimension is called.
                  section.label.isEmpty
                      ? (catalogDimRowNames[section.key] ?? section.key)
                      : section.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _Item(
                    key: ValueKey('filter-any-${section.key}'),
                    label: '不限',
                    chosen: _open(section.key),
                    onTap: () => onPick(section.key, null),
                  ),
                  for (final item in section.items)
                    _Item(
                      key: ValueKey('filter-dim-${section.key}-${item.id}'),
                      label: item.name,
                      chosen: _chosen(section.key, item.id),
                      onTap: () => onPick(section.key, item.id),
                    ),
                ],
              ),
            ],
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '本次词表没给：${missing.join('、')}',
                key: const ValueKey('filter-panel-missing'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          if (error != null && sections.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                key: const ValueKey('filter-panel-error'),
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 14),
            // Full width on either family: the drawer's one deliberate act is
            // 「看完了」, and it should not depend on where the thumb was left.
            child: FilledButton(
              key: const ValueKey('filter-panel-done'),
              onPressed: onDone,
              child: Text('完成（已选 $_count）'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One choice inside a dimension. Picking it narrows the list under the drawer
/// and leaves the drawer exactly where it was -- a multi-dimension decision is
/// made one line at a time, and closing it is the viewer's call.
class _Item extends StatelessWidget {
  final String label;
  final bool chosen;
  final VoidCallback onTap;
  const _Item({
    super.key,
    required this.label,
    required this.chosen,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: chosen ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      selected: chosen,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
  );
}
