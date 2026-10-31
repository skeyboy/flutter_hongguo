import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart' show TvFocusable;

import '../features/library_page.dart' show DramaCard;
import '../navigation/catalog_theme_handoff.dart';
import '../platform/runtime.dart';
import '../widgets/drama_cover.dart';
import 'related_dramas.dart';

export 'related_dramas.dart' show RelatedDramas;

/// 「同题材」block for a detail page: a horizontal rail of related dramas.
///
/// Renders nothing while loading and nothing at all when the upstream gave us
/// no provable relation, so a detail page never shows an error state or an
/// empty shell for this optional block (design §3.3).
class RelatedDramasSection extends StatefulWidget {
  final AppRuntime runtime;
  final DramaDetail current;
  final ValueChanged<Drama> onOpen;
  final bool tvLayout;
  const RelatedDramasSection({
    super.key,
    required this.runtime,
    required this.current,
    required this.onOpen,
    this.tvLayout = false,
  });

  @override
  State<RelatedDramasSection> createState() => _RelatedDramasSectionState();
}

class _RelatedDramasSectionState extends State<RelatedDramasSection> {
  RelatedDramas? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RelatedDramasSection old) {
    super.didUpdateWidget(old);
    if (old.current.drama.id != widget.current.drama.id) {
      _result = null;
      _load();
    }
  }

  Future<void> _load() async {
    // 面板词是按类型发布的，而块名声称的是「这次 browse 按该题材筛」——所以取数
    // 必须用详情页那行标签所映射的同一张面板，否则拿着 A 类型查到的 id 去筛 B
    // 类型的列表，名字与请求就对不上了。
    final value = await loadRelated(
      widget.runtime,
      widget.current,
      genre: catalogThemeHandoff.genre,
    );
    if (mounted) setState(() => _result = value);
  }

  @override
  Widget build(BuildContext context) {
    final value = _result;
    if (value == null || value.items.isEmpty) return const SizedBox.shrink();
    final cardWidth = widget.tvLayout ? 168.0 : 150.0;
    final cardHeight = widget.tvLayout ? 284.0 : 268.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value.themeName.isEmpty
              ? value.relation
              : '${value.relation} · ${value.themeName}',
          style: TextStyle(
            fontSize: widget.tvLayout ? 26 : 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: value.items.length,
            separatorBuilder: (_, _) =>
                SizedBox(width: widget.tvLayout ? 20 : 14),
            itemBuilder: (context, index) => SizedBox(
              width: cardWidth,
              child: widget.tvLayout
                  ? _TvDramaTile(
                      drama: value.items[index],
                      onOpen: widget.onOpen,
                    )
                  : DramaCard(
                      drama: value.items[index],
                      onTap: () => widget.onOpen(value.items[index]),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TvDramaTile extends StatelessWidget {
  final Drama drama;
  final ValueChanged<Drama> onOpen;
  const _TvDramaTile({required this.drama, required this.onOpen});

  @override
  Widget build(BuildContext context) => TvFocusable(
    label: '推荐：${drama.title.isEmpty ? '未命名短剧' : drama.title}',
    onActivate: () => onOpen(drama),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: DramaCover(drama: drama),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          drama.title.isEmpty ? '未命名短剧' : drama.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, height: 1.35),
        ),
      ],
    ),
  );
}
