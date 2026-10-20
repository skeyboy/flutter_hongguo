import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/features/tv/tv_detail_page.dart';
import 'package:hongguo_app/playback/tv_video_view.dart';
import 'package:hongguo_core/hongguo_core.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'tv_remote_test.dart' show TvPlaybackFixtureRuntime;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  testWidgets('all eight TV menu actions operate the actual native player', (
    t,
  ) async {
    final asset = await rootBundle.load('assets/verification.cenc.mp4');
    final runtime = TvPlaybackFixtureRuntime(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      await Directory.systemTemp.createTemp('hongguo-tv-menu-'),
      episodes: 3,
      settings: const AppSettings(autoNext: false, prefetchEnabled: false),
    );
    addTearDown(runtime.dispose);
    final detail = await runtime.catalog.detail('123');
    await t.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
        home: TvDetailPage(runtime: runtime, initial: detail.drama),
      ),
    );
    await t.pumpAndSettle();
    for (
      var i = 0;
      i < 50 &&
          FocusManager.instance.primaryFocus?.debugLabel != 'tv-detail-play';
      i++
    ) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-detail-play');
    Future<void> key(int code) async {
      print('TV_SYSTEM_KEY=$code');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await t.pump();
    }

    TvPlayerSurface getSurface() =>
        t.widget<TvPlayerSurface>(find.byType(TvPlayerSurface));
    Future<void> ready(int episode) async {
      for (var i = 0; i < 150; i++) {
        await t.pump(const Duration(milliseconds: 100));
        if (find.byType(TvPlayerSurface).evaluate().isNotEmpty &&
            !getSurface().busy &&
            getSurface().episode == episode &&
            getSurface().duration > Duration.zero) {
          return;
        }
      }
      fail('Episode $episode not ready');
    }

    Future<void> menu(String id) async {
      if (find.text('选集').evaluate().isNotEmpty) await key(19);
      await key(19);
      final target = id == 'play' ? 'tv-play' : 'tv-menu-$id';
      for (
        var i = 0;
        i < 9 && FocusManager.instance.primaryFocus?.debugLabel != target;
        i++
      ) {
        await key(22);
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, target);
    }

    TvPlaybackController player() =>
        t.widget<TvVideoView>(find.byType(TvVideoView)).controller;

    await key(23);
    await ready(0);
    await player().pause();
    await menu('play');
    await key(23);
    expect(player().playing, isTrue);
    await key(23);
    expect(player().playing, isFalse);

    await menu('progress');
    await key(23);
    expect(find.textContaining('预览'), findsOneWidget);
    await key(22);
    await key(23);
    expect(player().position.inMilliseconds, greaterThan(500));
    final committed = player().position;
    await menu('progress');
    await key(23);
    await key(21);
    await key(4);
    expect((player().position - committed).inMilliseconds.abs(), lessThan(150));

    await menu('next');
    await key(23);
    await ready(1);
    expect(runtime.prepared.last.vid, '124');
    await player().pause();
    await menu('previous');
    await key(23);
    await ready(0);
    expect(runtime.prepared.last.vid, '123');
    await player().pause();

    await menu('episodes');
    await key(23);
    await t.pumpAndSettle();
    expect(find.text('选择分集'), findsOneWidget);
    expect(find.textContaining('共 3 集'), findsOneWidget);
    await key(22);
    await key(22);
    await key(23);
    await ready(2);
    expect(runtime.prepared.last.vid, '125');
    await player().pause();
    await player().seek(const Duration(milliseconds: 600));

    await menu('quality');
    await key(23);
    await t.pumpAndSettle();
    expect(find.text('选择清晰度'), findsOneWidget);
    expect(runtime.qualityRequests.last, '125');
    expect(find.text('160p · 160×288'), findsOneWidget);
    print('TV_SCREENSHOT=menu-quality-data');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await key(22);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-quality-160p');
    await key(23);
    await ready(2);
    expect(runtime.prepared.last.quality, '160p');
    expect(getSurface().quality, '160p');
    expect(player().playing, isFalse);
    expect(player().position.inMilliseconds, closeTo(600, 150));

    await menu('picture');
    await key(23);
    expect(find.text('选集'), findsNothing);
    expect(find.byType(TvPlayerSurface), findsOneWidget);
    await menu('exit');
    await key(23);
    await t.pumpAndSettle();
    expect(find.text('▶ 开始观看'), findsOneWidget);
    expect(find.byType(TvPlayerSurface), findsNothing);
    print(
      'TV_MENU_NATIVE_PASS play_pause=true previous_next=true seek_commit_cancel=true episodes=3 quality_source=true quality_resume_position=true quality_preserves_pause=true return_picture=true exit_one_route=true',
    );
    await t.pumpWidget(const SizedBox());
  });
}
