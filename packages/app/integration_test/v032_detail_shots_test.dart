/// v0.3.2 macOS verification driver (read-only wrt product code).
/// Opens the real window, renders the real DetailPage/SettingsPage and emits
/// V032SHOT markers so the orchestrator can screencapture the live window.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/features/settings_page.dart';
import 'package:hongguo_app/platform/macos_window.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_app/recommendations/related_dramas_section.dart';

const _seriesId = '7697273659248872472';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('v0.3.2 detail pager / related row / settings live shots', (
    tester,
  ) async {
    Future<void> settle([int frames = 3]) async {
      for (var i = 0; i < frames; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 160));
        await tester.pump();
      }
    }

    Future<void> marker(String name) async {
      print('V032SHOT=$name');
      for (var i = 0; i < 75; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 160));
        await tester.pump();
      }
      print('V032SHOT_DONE=$name');
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    final runtime = await createRuntime();
    final detail = await runtime.catalog.detail(_seriesId);
    print(
      'V032INFO episodes=${detail.episodes.length} title=${detail.drama.title}',
    );
    await MacWindow.invoke('zoom');
    await settle(6);
    final view = tester.view;
    final logical = Size(
      view.physicalSize.width / view.devicePixelRatio,
      view.physicalSize.height / view.devicePixelRatio,
    );
    print(
      'V032INFO window=${logical.width.round()}x${logical.height.round()} '
      'rowsExpect=${logical.width < 720 ? 3 : 4} '
      'cellExpect=${logical.width < 720 ? 100 : 120}',
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: DetailPage(runtime: runtime, initial: detail.drama),
      ),
    );
    for (var i = 0; i < 300; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
      final pager = find
          .byKey(const ValueKey('episode-pager-column'))
          .evaluate();
      if (pager.isNotEmpty) break;
    }
    expect(find.byKey(const ValueKey('episode-pager-column')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('episode-pager-pageview')),
      findsOneWidget,
    );

    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
      final lists = find
          .descendant(
            of: find.byType(RelatedDramasSection),
            matching: find.byType(ListView),
          )
          .evaluate();
      if (lists.isNotEmpty) break;
    }
    final relatedOnstage = find
        .descendant(
          of: find.byType(RelatedDramasSection),
          matching: find.byType(ListView),
        )
        .evaluate()
        .isNotEmpty;
    final anchor = relatedOnstage
        ? find
              .descendant(
                of: find.byType(RelatedDramasSection),
                matching: find.byType(ListView),
              )
              .first
        : find.byKey(const ValueKey('episode-pager-footer'));
    final anchorBottom = tester.getRect(anchor).bottom;
    final needed = anchorBottom - logical.height + 30;
    if (needed > 0) {
      final sp = Scrollable.of(
        tester.element(find.byKey(const ValueKey('episode-pager-column'))),
      ).position;
      sp.jumpTo(sp.pixels + needed);
    }
    await settle(6);

    String indicatorText() =>
        tester
            .widget<Text>(
              find.byKey(const ValueKey('episode-pager-page-indicator')),
            )
            .data ??
        '';
    double pagerHeight() => tester
        .getRect(find.byKey(const ValueKey('episode-pager-column')))
        .height;
    String cells() => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('episode-pager-pageview')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? '')
        .where((s) => RegExp(r'^\d+$').hasMatch(s))
        .join(',');

    final pagerRect = tester.getRect(
      find.byKey(const ValueKey('episode-pager-column')),
    );
    print(
      'V032INFO pager top=${pagerRect.top} bottom=${pagerRect.bottom} '
      'height=${pagerRect.height} viewport=${logical.height} '
      'indicator=${indicatorText()}',
    );
    if (relatedOnstage) {
      final r = tester.getRect(find.byType(RelatedDramasSection));
      print(
        'V032INFO related top=${r.top} bottom=${r.bottom} height=${r.height} '
        'bothVisible=${pagerRect.top >= 0 && r.bottom <= logical.height}',
      );
    } else {
      print('V032INFO relatedRow=not-rendered (no provable upstream relation)');
    }
    await marker('detail_full_page1');

    final h1 = pagerHeight();
    await tester.tap(find.byKey(const ValueKey('episode-pager-arrow-下一页')));
    await settle(8);
    final h2 = pagerHeight();
    print(
      'V032INFO afterArrow indicator=${indicatorText()} height=$h2 '
      'delta=${(h2 - h1).abs()} cells=${cells()}',
    );
    expect((h2 - h1).abs(), lessThan(0.01));
    await marker('episodes_page2');

    final pf = find.byKey(const ValueKey('episode-pager-pageview'));
    final pvSp = Scrollable.of(tester.element(pf)).position;
    print(
      'V032INFO pageviewPixelsBeforeDrag=${pvSp.pixels} max=${pvSp.maxScrollExtent}',
    );
    await tester.fling(pf, const Offset(700, 0), 1400);
    await settle(12);
    print('V032INFO pageviewPixelsAfterFling=${pvSp.pixels}');
    final h3 = pagerHeight();
    print(
      'V032INFO afterDrag indicator=${indicatorText()} height=$h3 '
      'delta=${(h3 - h1).abs()} cells=${cells()}',
    );
    expect((h3 - h1).abs(), lessThan(0.01));
    await marker('episodes_page1_after_drag');

    if (relatedOnstage) {
      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(RelatedDramasSection),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      final headline = texts.firstWhere(
        (s) => s.contains('同题材') || s.contains('平台热门'),
        orElse: () => '<none>',
      );
      final banned = texts
          .where((s) => s.contains('热度') || s.contains('最新'))
          .toList();
      print('V032INFO relatedHeadline=$headline bannedBadges=$banned');
      expect(
        headline == '平台热门' ||
            headline == '同题材' ||
            headline.startsWith('同题材 · '),
        isTrue,
      );
      expect(banned, isEmpty);
      final railRect = tester.getRect(
        find.descendant(
          of: find.byType(RelatedDramasSection),
          matching: find.byType(ListView),
        ),
      );
      print(
        'V032INFO relatedRailHeight=${railRect.height} sectionHeight=${tester.getRect(find.byType(RelatedDramasSection)).height}',
      );
      expect(railRect.height, 268.0);
    }

    // (c) settings page download area.
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: SettingsPage(runtime: runtime),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
      if (find.byType(SingleChildScrollView).evaluate().isNotEmpty) break;
    }
    expect(
      find.byKey(const ValueKey('download-concurrent-setting')),
      findsWidgets,
    );
    final pageSp = Scrollable.of(
      tester.element(find.byKey(const ValueKey('download-concurrent-setting'))),
    ).position;
    final concTop = tester.getRect(find.text('同时下载数量')).top;
    pageSp.jumpTo(
      (pageSp.pixels + concTop - logical.height * 0.2).clamp(
        pageSp.minScrollExtent,
        pageSp.maxScrollExtent,
      ),
    );
    await settle(4);
    List<String> onstageTexts() => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    var texts = onstageTexts();
    print(
      'V032INFO concurrentRect=${tester.getRect(find.text('同时下载数量'))} '
      'viewport=${logical.height}',
    );
    print(
      'V032INFO settingsConcurrentCopy=${texts.where((s) => s.contains('手动下载按此数量同时进行')).join('|')}',
    );
    await marker('settings_download_concurrent');

    final autoLabel = find.text('自动缓存剧集数量');
    expect(autoLabel, findsWidgets);
    final autoTop = tester.getRect(autoLabel).top;
    pageSp.jumpTo(
      (pageSp.pixels + autoTop - logical.height * 0.15).clamp(
        pageSp.minScrollExtent,
        pageSp.maxScrollExtent,
      ),
    );
    await settle(4);
    texts = onstageTexts();
    expect(texts.contains('自动缓存剧集数量'), isTrue);
    expect(texts.contains('自动缓存空间上限'), isTrue);
    print(
      'V032INFO autoLabelsInViewport='
      '${tester.getRect(find.text('自动缓存剧集数量')).top >= 0 && tester.getRect(find.text('自动缓存空间上限')).bottom <= logical.height}',
    );
    print(
      'V032INFO settingsAutoCacheCopy=${texts.where((s) => s.contains('这两项只限制自动缓存')).join('|')}',
    );
    expect(
      texts.any((s) => s.contains('手动下载可能超过上限')),
      isFalse,
      reason: 'v0.3.2 narrowed the auto-cache copy',
    );
    await marker('settings_auto_cache_words');

    print('V032DONE shots');
    await tester.pumpWidget(const SizedBox());
    await settle(3);
    await runtime.dispose();
  }, timeout: const Timeout(Duration(minutes: 12)));
}
