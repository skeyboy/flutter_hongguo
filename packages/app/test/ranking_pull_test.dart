import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';

import 'desktop_fakes.dart';

/// A board that always answers one row and always says it has more -- the shape
/// that used to grow a 加载更多 button at the foot of the list.
class _BoardCatalog extends DesktopCatalog {
  /// The `cursor` of every rank request the page made, in order. Pulling the
  /// board refreshes it, so this list must stay all-null: asking for a second
  /// page is what the footer used to do.
  final cursors = <String?>[];

  @override
  Future<RankPage> rankBoard({
    String track = rankSeedTrack,
    String? board,
    String? cursor,
  }) async {
    cursors.add(cursor);
    return const RankPage(
      entries: [
        RankEntry(
          position: 0,
          drama: Drama(id: '123', title: '山海之间', episodeCount: 30),
        ),
      ],
      nextCursor: '18',
      tracks: [
        RankTrack('human', '真人剧', [
          RankBoard('human_hot_play', '热播榜', selected: true),
        ]),
      ],
    );
  }
}

/// 榜单 reached through the shell, because the destination is mounted as a layer
/// over the catalog and nothing outside the app owns one.
Future<_BoardCatalog> _openBoard(WidgetTester tester) async {
  final catalog = _BoardCatalog();
  await mount(tester, catalog);
  await tester.tap(find.text('榜单').first);
  await tester.pumpAndSettle();
  return catalog;
}

void main() {
  testWidgets('榜单 draws no 加载更多, even when upstream sends a cursor', (
    tester,
  ) async {
    final catalog = await _openBoard(tester);

    expect(find.text('山海之间'), findsWidgets);
    expect(find.text('加载更多'), findsNothing);
    expect(find.byKey(const ValueKey('rank-more')), findsNothing);
    // And nothing asked for the second page behind the viewer's back.
    expect(catalog.cursors, [null]);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉刷新 asks this 榜 again and keeps the rows', (tester) async {
    final catalog = await _openBoard(tester);
    final before = catalog.cursors.length;

    await tester.drag(
      find.byKey(const ValueKey('rank-list')),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();

    expect(catalog.cursors.length, greaterThan(before));
    expect(catalog.cursors, everyElement(isNull));
    expect(find.text('山海之间'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('页头那枚 刷新 让指针族不用拖也能再问一次', (tester) async {
    final catalog = await _openBoard(tester);
    final before = catalog.cursors.length;

    // 加载更多 used to be the only click target on this page. With it gone, the
    // 下拉 route asks again for a hand that can drag -- so the heading carries the
    // same question as a button, and a trackpad or a wheel never has to scroll.
    expect(find.byTooltip('刷新本榜'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rank-refresh')));
    await tester.pumpAndSettle();

    expect(catalog.cursors.length, greaterThan(before));
    expect(catalog.cursors, everyElement(isNull));
    // Still the same 榜, still the same rows: a refresh replaces, it does not
    // append and it does not move the viewer off the board they named.
    expect(find.text('真人剧'), findsWidgets);
    expect(find.text('山海之间'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}
