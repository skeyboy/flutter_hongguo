import 'package:hongguo_api/hongguo_api.dart';
import 'package:test/test.dart';

Drama drama(String id, String title) =>
    Drama(id: id, title: title, episodeCount: 3);

void main() {
  group('搜索聚合合并（M0）', () {
    test('红果结果原样在前，其它源按传入顺序尾随，游标取红果', () {
      final result = RoutingCatalogRepository.mergeSearchPages(
        CatalogPage([drama('hg:1', '同城爱情'), drama('hg:2', '逆袭')],
            nextCursor: '18'),
        [
          CatalogPage([drama('xf:1', '西饭独占剧')]),
          CatalogPage([drama('hm:1', '河马独占剧')], nextCursor: '99'),
        ],
      );
      expect(result.items.map((d) => d.title).toList(), [
        '同城爱情',
        '逆袭',
        '西饭独占剧',
        '河马独占剧',
      ]);
      expect(result.nextCursor, '18'); // 混入源的分页游标被忽略。
    });

    test('跨源同名剧去重：保留靠前来源的一条', () {
      final result = RoutingCatalogRepository.mergeSearchPages(
        CatalogPage([drama('hg:1', '同名剧')]),
        [
          CatalogPage([
            drama('xf:1', '同名剧'), // 与红果重名，丢弃。
            drama('xf:2', '西饭另一部'),
          ]),
          CatalogPage([drama('hm:1', '西饭另一部')]), // 与西饭重名，丢弃。
        ],
      );
      expect(result.items.map((d) => d.id).toList(), [
        'hg:1',
        'xf:2',
      ]);
    });

    test('失败源回空页不影响其它源；空标题跳过', () {
      final result = RoutingCatalogRepository.mergeSearchPages(
        const CatalogPage([]),
        [
          const CatalogPage([]), // 超时的源静默回空。
          CatalogPage([drama('hm:1', '  '), drama('hm:2', '有效剧')]),
        ],
      );
      expect(result.items.map((d) => d.title).toList(), ['有效剧']);
    });
  });
}
