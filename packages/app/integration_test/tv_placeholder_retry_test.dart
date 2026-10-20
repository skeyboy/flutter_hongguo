import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_app/platform/runtime.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:integration_test/integration_test.dart';

class _Adapter implements HttpClientAdapter {
  int attempts = 0;
  bool recover = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    final body =
        jsonDecode(utf8.decode(await stream!.expand((v) => v).toList())) as Map;
    if (body['need_selector_panel'] == true) {
      return ResponseBody.fromString(
        '{"code":0,"data":{"selector_rows":[]}}',
        200,
      );
    }
    attempts++;
    if (!recover) return ResponseBody.fromString('{}', 503);
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'data': {
          'video_data': [
            for (var i = 0; i < 6; i++)
              {'series_id': '${100 + i}', 'title': '恢复的剧集 $i'},
          ],
          'has_more': false,
        },
      }),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Runtime implements AppRuntime {
  @override
  final CatalogRepository catalog;
  _Runtime(this.catalog);
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'TV failure placeholder is centered after three retries and remote retry recovers',
    (t) async {
      final faults = _Adapter();
      final dio = Dio()..httpClientAdapter = faults;
      addTearDown(dio.close);
      final runtime = _Runtime(
        CatalogClient(dio: dio, deviceId: '1234567890123456'),
      );
      await t.pumpWidget(
        TvBackDispatcher(
          builder: (_, key) => MaterialApp(
            navigatorKey: key,
            builder: (_, child) => TvEnvironment(
              enabled: true,
              child: TvNavigation(child: child!),
            ),
            home: TvLibraryPage(runtime: runtime),
          ),
        ),
      );
      for (var i = 0; i < 160; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await t.pump();
        if (faults.attempts <= 3) expect(find.text('加载失败'), findsNothing);
        if (find.text('加载失败').evaluate().isNotEmpty) break;
      }
      await t.pumpAndSettle();
      expect(faults.attempts, 4);
      expect(find.text('加载失败'), findsOneWidget);
      final area = t.getRect(find.byKey(const ValueKey('tv-feed-placeholder')));
      final content = t.getRect(
        find.byKey(const ValueKey('tv-feed-placeholder-content')),
      );
      final grid = t.getRect(find.byType(GridView));
      expect((area.center - content.center).distance, lessThan(1));
      expect(area, grid);
      expect(content.bottom, lessThan(area.bottom));
      print('TV_SCREENSHOT=first-page-failure-centered');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      Future<void> key(int code) async {
        print('TV_SYSTEM_KEY=$code');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await t.pumpAndSettle();
      }

      await key(22);
      await key(20);
      expect(FocusManager.instance.primaryFocus?.debugLabel, '重试');
      faults.recover = true;
      await key(23);
      for (var i = 0; i < 50 && find.text('恢复的剧集 0').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await t.pump();
      }
      await t.pumpAndSettle();
      expect(faults.attempts, 5);
      expect(find.text('加载失败'), findsNothing);
      expect(find.text('恢复的剧集 0'), findsWidgets);
      print(
        'TV_PLACEHOLDER_RETRY_PASS initial_plus_three_retries=true centered=true no_early_error=true remote_retry=true',
      );
    },
  );
}
