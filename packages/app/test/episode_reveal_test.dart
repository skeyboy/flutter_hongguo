import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/playback/episode_reveal.dart';
import 'package:hongguo_app/playback/episode_workspace.dart';

/// The grid the player's 选集 list really is: the same delegate, the same
/// padding and a header whose height the reveal cannot assume, because that
/// header is where 已提前缓存 and the notices come and go.
Widget _list({
  required int count,
  required ScrollController scroll,
  required GlobalKey grid,
}) => CustomScrollView(
  // The page's own key, because the real panel restores where the list was left
  // before it is asked to aim again.
  key: const PageStorageKey('episode-options'),
  controller: scroll,
  slivers: [
    const SliverToBoxAdapter(child: SizedBox(height: 96)),
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      sliver: SliverGrid(
        key: grid,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 80,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.25,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => SizedBox(
            key: ValueKey('cell-$index'),
            child: Text('${index + 1}'),
          ),
          childCount: count,
        ),
      ),
    ),
  ],
);

void main() {
  late GlobalKey<EpisodeWorkspaceState> panel;
  late ScrollController scroll;
  late GlobalKey grid;
  late int count;
  late int index;
  late StateSetter update;

  Future<void> mount(
    WidgetTester tester, {
    required int at,
    int of = 90,
  }) async {
    panel = GlobalKey<EpisodeWorkspaceState>();
    scroll = ScrollController();
    grid = GlobalKey();
    count = of;
    index = at;
    addTearDown(scroll.dispose);
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: EpisodeWorkspace(
                key: panel,
                playing: false,
                busy: false,
                video: const ColoredBox(color: Colors.black),
                episodes: EpisodeReveal(
                  index: index,
                  count: count,
                  scroll: scroll,
                  grid: grid,
                  child: _list(count: count, scroll: scroll, grid: grid),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Deep in a long list: the panel opens on the episode being watched, with the
  /// rows on either side of it in view too, so the list reads as where the
  /// viewer is rather than as a wall of numbers.
  testWidgets('opening the panel lands on the playing episode, not on 第 1 集', (
    tester,
  ) async {
    await mount(tester, at: 40);
    expect(scroll.hasClients, isFalse);
    panel.currentState!.toggle();
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    final area = tester.getRect(find.byKey(const ValueKey('episode-panel')));
    for (final nearby in [36, 40, 44]) {
      expect(
        tester.getRect(find.byKey(ValueKey('cell-$nearby'))),
        isNot(equals(Rect.zero)),
        reason: 'cell $nearby',
      );
      expect(
        tester.getRect(find.byKey(ValueKey('cell-$nearby'))),
        liesIn(area),
      );
    }
    expect(find.byKey(const ValueKey('cell-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  /// The last of them cannot be lifted to the middle of the panel -- there is
  /// nothing below it to scroll past -- so the clamp holds it on screen instead.
  testWidgets('the final episodes are reached rather than centered', (
    tester,
  ) async {
    await mount(tester, at: 87);
    panel.currentState!.toggle();
    await tester.pumpAndSettle();
    final area = tester.getRect(find.byKey(const ValueKey('episode-panel')));
    expect(tester.getRect(find.byKey(const ValueKey('cell-87'))), liesIn(area));
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    expect(tester.takeException(), isNull);
  });

  /// A short list fits in the panel, so there is nowhere to travel and the
  /// highlight is already where the viewer put it.
  testWidgets('a list that already fits is not moved', (tester) async {
    await mount(tester, at: 5, of: 8);
    panel.currentState!.toggle();
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(tester.takeException(), isNull);
  });

  /// An episode near the top is not shoved down to make room for rows above it
  /// that the list does not have.
  testWidgets('an episode near the start is not pushed off the top', (
    tester,
  ) async {
    await mount(tester, at: 1);
    panel.currentState!.toggle();
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(tester.takeException(), isNull);
  });

  /// Reopening is not resuming: the viewer may have scrolled away last time,
  /// and the panel is asked for the episode they are on now.
  testWidgets('a reopened panel aims again at the current episode', (
    tester,
  ) async {
    await mount(tester, at: 12);
    panel.currentState!.toggle();
    await tester.pumpAndSettle();
    final aimed = scroll.offset;
    expect(aimed, greaterThan(0));
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    panel.currentState!.hide();
    await tester.pumpAndSettle();
    panel.currentState!.toggle();
    await tester.pumpAndSettle();
    expect(scroll.offset, aimed);
    expect(tester.takeException(), isNull);
  });

  /// With the panel already open the viewer chose where to look, so an episode
  /// they can already see is left where it is and only one off the panel is
  /// travelled to.
  testWidgets('a change while open follows only an episode out of view', (
    tester,
  ) async {
    await mount(tester, at: 40);
    panel.currentState!.toggle();
    await tester.pumpAndSettle();
    final area = tester.getRect(find.byKey(const ValueKey('episode-panel')));
    final aimed = scroll.offset;
    final neighbour = tester.getRect(find.byKey(const ValueKey('cell-45')));
    expect(neighbour, liesIn(area));
    update(() => index = 45);
    await tester.pumpAndSettle();
    expect(scroll.offset, aimed);
    update(() => index = 4);
    await tester.pumpAndSettle();
    expect(scroll.offset, lessThan(aimed));
    expect(tester.getRect(find.byKey(const ValueKey('cell-4'))), liesIn(area));
    expect(tester.takeException(), isNull);
  });
}

class _LiesIn extends Matcher {
  const _LiesIn(this.area);
  final Rect area;
  @override
  bool matches(Object? item, Map matchState) =>
      item is Rect &&
      item.left >= area.left &&
      item.top >= area.top - 1 &&
      item.bottom <= area.bottom + 1 &&
      item.right <= area.right;
  @override
  Description describe(Description d) => d.add('lies inside $area');
}

Matcher liesIn(Rect area) => _LiesIn(area);
