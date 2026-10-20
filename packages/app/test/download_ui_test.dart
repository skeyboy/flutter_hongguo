import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/downloads/download_manager.dart';
import 'package:hongguo_app/features/detail_page.dart';
import 'package:hongguo_app/features/my_page.dart';
import 'package:hongguo_app/features/downloads_page.dart';
import 'package:hongguo_app/features/local_cache_page.dart';

import 'download_fakes.dart';
import 'fakes.dart';

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(1280, 900),
    const Size(740, 360),
  ]) {
    testWidgets(
      'download selection → persistent task → My offline library at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final runtime = DownloadFakeRuntime();
        addTearDown(() async {
          final closing = runtime.dispose();
          await tester.pump();
          await closing;
        });
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(runtime: runtime, initial: FakeCatalog.demo),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('download-drama')),
        );
        await tester.tap(find.byKey(const ValueKey('download-drama')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('confirm-download')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('download-episode-0')));
        await tester.tap(find.byKey(const ValueKey('download-episode-1')));
        await tester.pumpAndSettle();
        expect(find.text('下载 2 集'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭下载选集'));
        await tester.pumpAndSettle();
        expect(runtime.calls, isEmpty);
        await tester.tap(find.byKey(const ValueKey('download-drama')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('download-episode-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('confirm-download')));
        await tester.pumpAndSettle();
        await tester.pump();
        expect(runtime.calls, ['11_best']);
        await runtime.complete('11_best');
        await tester.pump();
        expect(runtime.downloads.tasks.single.phase, DownloadPhase.ready);
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: MyPage(runtime: runtime),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('my-downloads')));
        await tester.tap(find.byKey(const ValueKey('my-downloads')));
        await tester.pumpAndSettle();
        expect(find.byType(DownloadsPage), findsOneWidget);
        expect(find.byTooltip('离线观看'), findsOneWidget);
        await tester.tap(find.byTooltip('查看离线剧集'));
        await tester.pumpAndSettle();
        expect(find.byType(LocalCachePage), findsOneWidget);
        expect(find.byKey(const ValueKey('local-drama-123')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'completed download requires confirmation and removes only its own file',
    (tester) async {
      final runtime = DownloadFakeRuntime();
      addTearDown(() async {
        final closing = runtime.dispose();
        await tester.pump();
        await closing;
      });
      await runtime.downloads.enqueue(await runtime.catalog.detail('123'), [
        0,
      ], 'best');
      await tester.pump();
      await runtime.complete('11_best');
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(home: DownloadsPage(runtime: runtime)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除下载记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(runtime.files, hasLength(1));
      await tester.tap(find.byTooltip('删除下载记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(runtime.files, isEmpty);
      expect(runtime.downloads.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
