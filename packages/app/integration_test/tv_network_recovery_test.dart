import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hongguo_app/platform/runtime.dart';

class _FaultAdapter implements HttpClientAdapter {
  int themeAttempts = 0, listAttempts = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    final body =
        jsonDecode(utf8.decode(await stream!.expand((v) => v).toList())) as Map;
    if (body['need_selector_panel'] == true) {
      if (++themeAttempts < 2) {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'data': {
            'selector_rows': [
              {
                'type': 'category_dim_theme',
                'items': [
                  {'show_name': '恢复的都市题材', 'selector_item_id': 'city'},
                ],
              },
            ],
          },
        }),
        200,
      );
    }
    if (++listAttempts == 1) return ResponseBody.fromString('{}', 503);
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
    'TV themes and resources recover automatically after injected network failures',
    (t) async {
      final faults = _FaultAdapter();
      final dio = Dio()..httpClientAdapter = faults;
      addTearDown(dio.close);
      final runtime = _Runtime(
        CatalogClient(dio: dio, deviceId: '1234567890123456'),
      );
      addTearDown(runtime.dispose);
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
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await t.pump();
        if (find.text('恢复的都市题材').evaluate().isNotEmpty &&
            find.text('恢复的剧集 0').evaluate().isNotEmpty) {
          break;
        }
      }
      await t.pumpAndSettle();
      expect(find.text('恢复的都市题材'), findsOneWidget);
      expect(find.text('恢复的剧集 0'), findsWidgets);
      expect(faults.themeAttempts, 2);
      expect(faults.listAttempts, 2);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'nav-0');
      Future<void> key(int code) async {
        print('TV_SYSTEM_KEY=$code');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await t.pumpAndSettle();
      }

      await key(22);
      for (
        var i = 0;
        i < 4 &&
            FocusManager.instance.primaryFocus?.debugLabel?.startsWith(
                  'tv-grid-',
                ) !=
                true;
        i++
      ) {
        await key(20);
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        startsWith('tv-grid-'),
      );
      print(
        'TV_NETWORK_RECOVERY_PASS theme_attempts=2 list_attempts=2 no_manual_retry=true focus_operable=true',
      );
      print('TV_SCREENSHOT=network-recovered');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    },
  );
}
