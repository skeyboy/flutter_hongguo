import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

class _Catalog implements CatalogRepository {
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) async => CatalogPage([
    for (var i = 0; i < 6; i++)
      Drama(id: '$i', title: '剧集 $i', episodeCount: 2),
  ]);
  @override
  Future<CatalogPage> search(String q, {String? cursor}) async =>
      CatalogPage([Drama(id: '99', title: '搜索 $q')]);
  @override
  Future<DramaDetail> detail(String id) async => DramaDetail(
    Drama(id: id, title: '剧集 $id'),
    [const Episode(vid: '10', index: 1)],
  );
  @override
  Future<List<CatalogFilter>> themes(String genre) async => [];
}

class _Runtime implements AppRuntime {
  @override
  final catalog = _Catalog();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> clearCache() async {}
  @override
  Future<int> cacheBytes() async => 0;
  @override
  Future<void> evict(String vid, {String quality = 'best'}) async {}
  @override
  PlaybackJob prepare(
    String vid, {
    String quality = 'best',
    void Function(PreparationProgress)? onProgress,
    bool background = false,
  }) => throw UnimplementedError();
}

/// Whether the remote is standing on one of the dialog's two buttons, which is
/// the only thing 上下 can be for here: a button the viewer can then press.
bool _onDialogButton() {
  final where = FocusManager.instance.primaryFocus?.context;
  return where != null &&
      (where.findAncestorWidgetOfExactType<FilledButton>() != null ||
          where.findAncestorWidgetOfExactType<TextButton>() != null);
}

void main() {
  testWidgets(
    'the TV search box lets the remote out without losing the caret',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
          home: TvLibraryPage(runtime: _Runtime()),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('搜索'));
      await t.pumpAndSettle();
      final field = t.widget<TextField>(find.byType(TextField));
      final node = field.focusNode!;
      expect(
        node.hasFocus,
        isTrue,
        reason: 'the box should open ready to type',
      );

      // Left and right belong to the caret: the editor convention holds.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(node.hasFocus, isTrue);

      // Up and down are the remote's way out of the box and onto the buttons.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(node.hasFocus, isFalse);
      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: 'down should move inside the dialog, not leave it',
      );
      expect(
        _onDialogButton(),
        isTrue,
        reason: 'down should land on a button the remote can press',
      );

      // 返回 closes the dialog from wherever the ring stands.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('返回 inside the TV search box closes it from the caret', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
        home: TvLibraryPage(runtime: _Runtime()),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('搜索'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '红果');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('▶ 开始观看'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('向上 from the TV search box wraps to 搜索 and 确认 presses it', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
        home: TvLibraryPage(runtime: _Runtime()),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('搜索'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '红果');
    // Without the box's own ring walk this key goes nowhere: TvNavigation's
    // geometric move has nothing above a single-line box inside a modal.
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pumpAndSettle();
    expect(
      _onDialogButton(),
      isTrue,
      reason: 'up should wrap around the dialog ring onto a button',
    );
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.text('搜索 红果'),
      findsWidgets,
      reason: '确认 on the wrapped button ran the typed query',
    );
    await t.pumpWidget(const SizedBox());
  });
}
